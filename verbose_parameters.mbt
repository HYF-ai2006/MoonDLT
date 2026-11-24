///|
/// Optional VARI names; numeric parameters carry a unit as well as a name.
/// Text, raw and Boolean parameters have a name only (unit must be None).
pub(all) struct VariableInfo {
  name : String
  unit : String?
} derive(Eq, @debug.Debug)

///|
/// FIXP descriptor: logical = stored * quantization + offset.
/// The wire quantization is binary32; offset is signed32 for <=32-bit values,
/// signed64 for 64-bit values. Integer storage stays exact in ParameterValue.
pub(all) struct FixedPoint {
  quantization : Float
  offset : Int64
} derive(Eq, @debug.Debug)

///|
/// A homogeneous DLT numeric array element descriptor.
pub(all) enum NumericType {
  Bool8
  IntValue(Int32)
  UIntValue(Int32)
  FloatValue(Int32)
} derive(Eq, @debug.Debug)

///|
/// Dimensions follow the wire order; values are stored flat without transposition.
/// Array storage is row-major according to the producer's dimension convention.
pub(all) enum ParameterValue {
  Scalar(Argument)
  NumericArray(NumericType, Array[Int32], Array[Argument])
} derive(Eq, @debug.Debug)

///|
/// Advanced verbose parameter, preserving variable metadata and array dimensions.
/// This deliberately excludes trace-info, structs and 128-bit data.
pub(all) struct VerboseParameter {
  value : ParameterValue
  variable : VariableInfo?
  scaling : FixedPoint?
} derive(Eq, @debug.Debug)

///|
pub fn VerboseParameter::scalar(
  argument : Argument,
  variable? : VariableInfo,
  scaling? : FixedPoint,
) -> VerboseParameter {
  { value: Scalar(argument), variable, scaling, }
}

///|
pub fn VerboseParameter::array(
  element_type : NumericType,
  dimensions : Array[Int32],
  values : Array[Argument],
  variable? : VariableInfo,
  scaling? : FixedPoint,
) -> VerboseParameter {
  {
    value: NumericArray(element_type, dimensions.copy(), values.copy()),
    variable,
    scaling,
  }
}

///|
pub fn encode_parameters(
  parameters : Array[VerboseParameter],
  endian : Endian,
  limits~ : Limits = Limits::default(),
) -> Bytes raise DltError {
  check_limits(limits)
  guard parameters.length() <= limits.arguments else {
    raise Limit(0, "verbose parameter count exceeds configured maximum")
  }
  let out = @buffer.Buffer::Buffer()
  for parameter in parameters {
    let bytes = encode_one_parameter(parameter, endian, limits)
    guard bytes.length() <= limits.message_bytes - out.length() else {
      raise Limit(out.length(), "parameter payload exceeds message limit")
    }
    out.write_bytes(bytes[:])
  }
  out.to_bytes()
}

///|
pub fn decode_parameters(
  data : BytesView,
  count : Int32,
  endian : Endian,
  limits~ : Limits = Limits::default(),
) -> Array[VerboseParameter] raise DltError {
  check_limits(limits)
  guard count >= 0 else { raise Invalid(0, "negative parameter count") }
  guard count <= limits.arguments else {
    raise Limit(0, "verbose parameter count exceeds configured maximum")
  }
  guard data.length() <= limits.message_bytes else {
    raise Limit(0, "parameter payload exceeds message limit")
  }
  let parameters : Array[VerboseParameter] = []
  let mut pos = 0
  for _ in 0..<count {
    let (parameter, end) = decode_one_parameter(data, pos, endian, limits)
    parameters.push(parameter)
    pos = end
  }
  guard pos == data.length() else {
    raise Invalid(pos, "trailing bytes disagree with parameter count")
  }
  parameters
}

///|
pub fn Message::parameters(
  self : Message,
  limits~ : Limits = Limits::default(),
) -> Array[VerboseParameter] raise DltError {
  let ext = match self.header.extended {
    Some(value) => value
    None => raise Invalid(0, "parameter decoding requires an extended header")
  }
  guard ext.verbose else { raise Invalid(0, "message is non-verbose") }
  decode_parameters(
    self.payload[:],
    ext.argument_count,
    self.header.endian,
    limits~,
  )
}

///|
pub fn Message::with_parameters(
  header : Header,
  parameters : Array[VerboseParameter],
  storage? : StorageHeader,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  let ext = match header.extended {
    Some(value) => value
    None =>
      raise Invalid(0, "parameter construction requires an extended header")
  }
  guard ext.verbose else { raise Invalid(0, "extended header is non-verbose") }
  let extended = Some({ ..ext, argument_count: parameters.length(), })
  finish_verbose_message(
    { ..header, extended, },
    encode_parameters(parameters, header.endian, limits~),
    storage,
    limits,
  )
}

///|
fn numeric_type_word(kind : NumericType) -> UInt32 raise DltError {
  match kind {
    Bool8 => 0x11U
    IntValue(width) => 0x20U | width_code(width)
    UIntValue(width) => 0x40U | width_code(width)
    FloatValue(width) => {
      guard width == 32 || width == 64 else {
        raise Unsupported(
          0, "numeric array supports only binary32/binary64 floats",
        )
      }
      0x80U | width_code(width)
    }
  }
}

///|
fn numeric_type_from_word(
  info : UInt32,
  at : Int32,
) -> NumericType raise DltError {
  let base = check_scalar_type_word(info, at)
  let width = word_width(info, at)
  if base == 0x10U {
    guard width == 8 else {
      raise Invalid(at, "Boolean array requires 8-bit width")
    }
    Bool8
  } else if base == 0x20U {
    IntValue(width)
  } else if base == 0x40U {
    UIntValue(width)
  } else if base == 0x80U {
    guard width == 32 || width == 64 else {
      raise Unsupported(at, "unsupported floating array width")
    }
    FloatValue(width)
  } else {
    raise Unsupported(at, "only Boolean and numeric arrays are supported")
  }
}

///|
fn numeric_type_width(kind : NumericType) -> Int32 raise DltError {
  ignore(numeric_type_word(kind))
  match kind {
    Bool8 => 1
    IntValue(width) | UIntValue(width) | FloatValue(width) => width / 8
  }
}

///|
fn argument_matches_numeric(arg : Argument, kind : NumericType) -> Bool {
  match (arg, kind) {
    (Boolean(_), Bool8) => true
    (Signed(a, _), IntValue(b)) => a == b
    (Unsigned(a, _), UIntValue(b)) => a == b
    (Floating(a, _), FloatValue(b)) => a == b
    _ => false
  }
}

///|
fn dimensions_count(
  dimensions : Array[Int32],
  element_bytes : Int32,
  limits : Limits,
) -> Int32 raise DltError {
  guard dimensions.length() > 0 && dimensions.length() <= 16 else {
    raise Limit(0, "array requires one to sixteen dimensions")
  }
  let maximum = limits.message_bytes / element_bytes
  let mut count = 1
  for dimension in dimensions {
    guard dimension > 0 && dimension <= 65535 else {
      raise Invalid(0, "array dimension must be in 1..65535")
    }
    guard count <= maximum / dimension else {
      raise Limit(0, "array element count exceeds message limit")
    }
    count *= dimension
  }
  count
}

///|
fn metadata_bytes(text : String, limits : Limits) -> Bytes raise DltError {
  argument_text_bytes(Ascii, text, limits)
}

///|
fn write_metadata(
  out : @buffer.Buffer,
  info : VariableInfo,
  numeric_unit : Bool,
  endian : Endian,
  limits : Limits,
) -> Unit raise DltError {
  let name = metadata_bytes(info.name, limits)
  if numeric_unit {
    let unit = metadata_bytes(
      match info.unit {
        Some(s) => s
        None =>
          raise Invalid(
            0, "numeric metadata requires a unit; use an empty string for unitless values",
          )
      },
      limits,
    )
    write_u16(out, name.length() + 1, endian)
    write_u16(out, unit.length() + 1, endian)
    out.write_bytes(name[:])
    out.write_byte(b'\x00')
    out.write_bytes(unit[:])
    out.write_byte(b'\x00')
  } else {
    guard info.unit is None else {
      raise Invalid(0, "Boolean, text and raw metadata cannot contain a unit")
    }
    write_u16(out, name.length() + 1, endian)
    out.write_bytes(name[:])
    out.write_byte(b'\x00')
  }
}

///|
fn read_metadata(
  data : BytesView,
  pos : Int32,
  numeric_unit : Bool,
  endian : Endian,
  limits : Limits,
) -> (VariableInfo, Int32) raise DltError {
  let name_length = read_u16(data, pos, endian)
  if numeric_unit {
    let unit_length = read_u16(data, pos + 2, endian)
    let name = read_text_value(data, pos + 4, name_length, Ascii, limits)
    let unit_pos = pos + 4 + name_length
    let unit = read_text_value(data, unit_pos, unit_length, Ascii, limits)
    ({ name, unit: Some(unit), }, unit_pos + unit_length)
  } else {
    let name = read_text_value(data, pos + 2, name_length, Ascii, limits)
    ({ name, unit: None, }, pos + 2 + name_length)
  }
}

///|
fn scalar_has_unit(arg : Argument) -> Bool {
  match arg {
    Signed(_, _) | Unsigned(_, _) | Floating(_, _) => true
    _ => false
  }
}

///|
fn metadata_wire_length(
  info : VariableInfo,
  numeric_unit : Bool,
  limits : Limits,
) -> Int32 raise DltError {
  let name = metadata_bytes(info.name, limits)
  if numeric_unit {
    let unit = match info.unit {
      Some(text) => metadata_bytes(text, limits)
      None => raise Invalid(0, "numeric metadata requires an explicit unit")
    }
    6 + name.length() + unit.length()
  } else {
    guard info.unit is None else {
      raise Invalid(0, "Boolean, text and raw metadata cannot contain a unit")
    }
    3 + name.length()
  }
}

///|
/// Preflight validates the whole typed value and its encoded budget before a
/// writer allocates output or a numerical consumer accepts malformed values.
fn parameter_wire_length(
  parameter : VerboseParameter,
  limits : Limits,
) -> Int32 raise DltError {
  let (type_word, numeric_unit, base_length) = match parameter.value {
    Scalar(arg) =>
      (
        argument_type_word(arg),
        scalar_has_unit(arg),
        argument_wire_length(arg, limits),
      )
    NumericArray(kind, dimensions, values) => {
      validate_numeric_array(kind, dimensions, values, limits)
      (
        numeric_type_word(kind),
        true,
        6 + dimensions.length() * 2 + values.length() * numeric_type_width(kind),
      )
    }
  }
  let mut length = base_length
  if parameter.variable is Some(variable) {
    length += metadata_wire_length(variable, numeric_unit, limits)
  }
  if parameter.scaling is Some(scaling) {
    validate_scaling(type_word, scaling)
    length += if word_width(type_word, 0) <= 32 { 8 } else { 12 }
  }
  guard length <= limits.message_bytes else {
    raise Limit(0, "encoded parameter exceeds message limit")
  }
  length
}

///|
fn encode_one_parameter(
  parameter : VerboseParameter,
  endian : Endian,
  limits : Limits,
) -> Bytes raise DltError {
  ignore(parameter_wire_length(parameter, limits))
  let out = @buffer.Buffer::Buffer()
  let variable_flag = if parameter.variable is Some(_) { 0x800U } else { 0U }
  let scaling_flag = if parameter.scaling is Some(_) { 0x1000U } else { 0U }
  match parameter.value {
    Scalar(arg) => {
      ignore(argument_wire_length(arg, limits))
      let type_word = argument_type_word(arg)
      if parameter.scaling is Some(scale) {
        validate_scaling(type_word, scale)
      }
      write_u32(out, type_word | variable_flag | scaling_flag, endian)
      match arg {
        Text(encoding, value) => {
          let bytes = argument_text_bytes(encoding, value, limits)
          write_u16(out, bytes.length() + 1, endian)
          if parameter.variable is Some(variable) {
            write_metadata(out, variable, false, endian, limits)
          }
          out.write_bytes(bytes[:])
          out.write_byte(b'\x00')
        }
        Raw(bytes) => {
          write_u16(out, bytes.length(), endian)
          if parameter.variable is Some(variable) {
            write_metadata(out, variable, false, endian, limits)
          }
          out.write_bytes(bytes[:])
        }
        _ => {
          if parameter.variable is Some(variable) {
            write_metadata(out, variable, scalar_has_unit(arg), endian, limits)
          }
          if parameter.scaling is Some(scale) {
            write_scaling(out, type_word, scale, endian)
          }
          write_argument_value(out, arg, endian, limits)
        }
      }
    }
    NumericArray(kind, dimensions, values) => {
      let count = dimensions_count(dimensions, numeric_type_width(kind), limits)
      guard count == values.length() else {
        raise Invalid(0, "array value count disagrees with dimensions")
      }
      let type_word = numeric_type_word(kind)
      if parameter.scaling is Some(scale) {
        validate_scaling(type_word, scale)
      }
      write_u32(out, type_word | 0x100U | variable_flag | scaling_flag, endian)
      write_u16(out, dimensions.length(), endian)
      for dimension in dimensions {
        write_u16(out, dimension, endian)
      }
      if parameter.variable is Some(variable) {
        write_metadata(out, variable, true, endian, limits)
      }
      if parameter.scaling is Some(scale) {
        write_scaling(out, type_word, scale, endian)
      }
      for value in values {
        guard argument_matches_numeric(value, kind) else {
          raise Invalid(
            out.length(),
            "array element type/width disagrees with descriptor",
          )
        }
        write_argument_value(out, value, endian, limits)
      }
    }
  }
  guard out.length() <= limits.message_bytes else {
    raise Limit(0, "encoded parameter exceeds message limit")
  }
  out.to_bytes()
}

///|
fn decode_one_parameter(
  data : BytesView,
  at : Int32,
  endian : Endian,
  limits : Limits,
) -> (VerboseParameter, Int32) raise DltError {
  let info = read_u32(data, at, endian)
  guard (info & 0x6000U) == 0U else {
    raise Unsupported(at, "trace-info and struct parameters are unsupported")
  }
  let scalar_info = info & 0xFFFFE6FFU
  let base = check_scalar_type_word(scalar_info, at)
  let has_variable = (info & 0x800U) != 0U
  let is_array = (info & 0x100U) != 0U
  let has_scaling = (info & 0x1000U) != 0U
  if has_scaling {
    guard base == 0x20U || base == 0x40U else {
      raise Invalid(
        at, "fixed point is legal only for signed/unsigned integers",
      )
    }
  }
  let mut pos = at + 4
  if is_array {
    let kind = numeric_type_from_word(scalar_info, at)
    let dimension_count = read_u16(data, pos, endian)
    pos += 2
    guard dimension_count > 0 && dimension_count <= 16 else {
      raise Limit(pos - 2, "array requires one to sixteen dimensions")
    }
    let dimensions : Array[Int32] = []
    for _ in 0..<dimension_count {
      dimensions.push(read_u16(data, pos, endian))
      pos += 2
    }
    let width = numeric_type_width(kind)
    let count = dimensions_count(dimensions, width, limits)
    let variable = if has_variable {
      let (variable, next) = read_metadata(data, pos, true, endian, limits)
      pos = next
      Some(variable)
    } else {
      None
    }
    let scaling = if has_scaling {
      let (scaling, next) = read_scaling(data, pos, scalar_info, endian)
      pos = next
      Some(scaling)
    } else {
      None
    }
    require_range(data, pos, count * width)
    let values : Array[Argument] = []
    for _ in 0..<count {
      let (value, next) = read_argument_value(
        data, pos, scalar_info, endian, limits,
      )
      values.push(value)
      pos = next
    }
    ({ value: NumericArray(kind, dimensions, values), variable, scaling, }, pos)
  } else if base == 0x200U || base == 0x400U {
    let length = read_u16(data, pos, endian)
    pos += 2
    let variable = if has_variable {
      let (variable, next) = read_metadata(data, pos, false, endian, limits)
      pos = next
      Some(variable)
    } else {
      None
    }
    let arg = if base == 0x200U {
      let encoding = match scalar_info & 0x38000U {
        0U => Ascii
        0x8000U => Utf8
        _ => raise Unsupported(at, "unsupported string character encoding")
      }
      Text(encoding, read_text_value(data, pos, length, encoding, limits))
    } else {
      guard length <= limits.string_bytes else {
        raise Limit(pos, "raw parameter exceeds maximum")
      }
      require_range(data, pos, length)
      Raw(data[pos:pos + length].to_owned())
    }
    ({ value: Scalar(arg), variable, scaling: None, }, pos + length)
  } else {
    let variable = if has_variable {
      let (variable, next) = read_metadata(
        data,
        pos,
        base != 0x10U,
        endian,
        limits,
      )
      pos = next
      Some(variable)
    } else {
      None
    }
    let scaling = if has_scaling {
      let (scaling, next) = read_scaling(data, pos, scalar_info, endian)
      pos = next
      Some(scaling)
    } else {
      None
    }
    let (arg, next) = read_argument_value(
      data, pos, scalar_info, endian, limits,
    )
    ({ value: Scalar(arg), variable, scaling, }, next)
  }
}

///|
fn validate_scaling(info : UInt32, scaling : FixedPoint) -> Unit raise DltError {
  let base = info & 0xF0U
  guard base == 0x20U || base == 0x40U else {
    raise Invalid(0, "fixed point is legal only for signed/unsigned integers")
  }
  let width = word_width(info, 0)
  if width <= 32 {
    check_signed(32, scaling.offset)
  }
}

///|
fn write_scaling(
  out : @buffer.Buffer,
  info : UInt32,
  scaling : FixedPoint,
  endian : Endian,
) -> Unit raise DltError {
  validate_scaling(info, scaling)
  write_u32(out, scaling.quantization.reinterpret_as_uint(), endian)
  let width = word_width(info, 0)
  write_integer_bits(
    out,
    if width <= 32 {
      32
    } else {
      64
    },
    scaling.offset.reinterpret_as_uint64(),
    endian,
  )
}

///|
fn read_scaling(
  data : BytesView,
  pos : Int32,
  info : UInt32,
  endian : Endian,
) -> (FixedPoint, Int32) raise DltError {
  let quantization = Float::reinterpret_from_uint(read_u32(data, pos, endian))
  let width = word_width(info, pos)
  let offset_width = if width <= 32 { 32 } else { 64 }
  let raw = read_integer_bits(data, pos + 4, offset_width, endian)
  let scaling = {
    quantization,
    offset: signed_integer_value(raw, offset_width),
  }
  validate_scaling(info, scaling)
  (scaling, pos + 4 + offset_width / 8)
}

///|
/// Approximate logical numeric values; exact raw integers remain in `value`.
/// Values beyond Double's integer precision are intentionally not rounded in APIs
/// that return Argument or JSON decimal strings.
pub fn VerboseParameter::logical_values(
  self : VerboseParameter,
) -> Array[Double] raise DltError {
  ignore(parameter_wire_length(self, Limits::default()))
  let arguments = match self.value {
    Scalar(value) => [value]
    NumericArray(_, _, values) => values
  }
  let out : Array[Double] = []
  for argument in arguments {
    let numeric = match argument {
      Boolean(value) => if value { 1.0 } else { 0.0 }
      Signed(_, _) | Unsigned(_, _) | Floating(_, _) =>
        argument.as_double(allow_lossy=true)
      _ => raise Invalid(0, "logical values require numeric parameters")
    }
    out.push(
      match self.scaling {
        Some(scale) =>
          numeric * scale.quantization.to_double() + scale.offset.to_double()
        None => numeric
      },
    )
  }
  out
}
