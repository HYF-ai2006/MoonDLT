///|
/// JSON interchange keeps integer decimal strings and IEEE floating-point bits.
/// JavaScript consumers never have to represent a 64-bit integer as Number.
pub fn Argument::to_json(self : Argument) -> Json {
  match self {
    Boolean(value) => { "kind": "bool", "value": value }
    Signed(width, value) =>
      { "kind": "signed", "width": width, "value": value.to_string() }
    Unsigned(width, value) =>
      { "kind": "unsigned", "width": width, "value": value.to_string() }
    Floating(width, value) => {
      let out = @buffer.Buffer::Buffer()
      if width == 32 {
        write_u32(out, Float::from_double(value).reinterpret_as_uint(), Big)
      } else {
        write_u64(out, value.reinterpret_as_uint64(), Big)
      }
      { "kind": "float", "width": width, "bits": hex_encode(out.to_bytes()[:]) }
    }
    Text(encoding, value) =>
      {
        "kind": "text",
        "encoding": if encoding == Ascii {
          "ascii"
        } else {
          "utf8"
        },
        "value": value,
      }
    Raw(value) => { "kind": "raw", "hex": hex_encode(value[:]) }
  }
}

///|
/// Parse the tagged JSON form and validate width, range, text and byte limits.
pub fn Argument::from_json(
  json : Json,
  limits~ : Limits = Limits::default(),
) -> Argument raise DltError {
  check_limits(limits)
  let object = verbose_object(json)
  let kind = verbose_string(verbose_field(object, "kind"))
  let argument = match kind {
    "bool" => {
      verbose_fields(object, ["kind", "value"])
      Boolean(
        match verbose_field(object, "value") {
          True => true
          False => false
          _ => raise Invalid(0, "Boolean JSON value must be true or false")
        },
      )
    }
    "signed" => {
      verbose_fields(object, ["kind", "width", "value"])
      let width = verbose_width(verbose_field(object, "width"))
      let text = verbose_string(verbose_field(object, "value"))
      let value = @string.parse_int64(text[:]) catch {
        _ =>
          raise Invalid(0, "signed JSON value is not an Int64 decimal string")
      }
      guard text == value.to_string() else {
        raise Invalid(
          0, "signed JSON value must use canonical decimal spelling",
        )
      }
      Signed(width, value)
    }
    "unsigned" => {
      verbose_fields(object, ["kind", "width", "value"])
      let width = verbose_width(verbose_field(object, "width"))
      let text = verbose_string(verbose_field(object, "value"))
      let value = @string.parse_uint64(text[:]) catch {
        _ =>
          raise Invalid(0, "unsigned JSON value is not a UInt64 decimal string")
      }
      guard text == value.to_string() else {
        raise Invalid(
          0, "unsigned JSON value must use canonical decimal spelling",
        )
      }
      Unsigned(width, value)
    }
    "float" => {
      verbose_fields(object, ["kind", "width", "bits"])
      let width = verbose_width(verbose_field(object, "width"))
      let text = verbose_string(verbose_field(object, "bits"))
      guard text.length() == width / 4 else {
        raise Invalid(
          0, "floating-point bit spelling disagrees with JSON width",
        )
      }
      let bytes = hex_decode(text)
      guard bytes.length() == width / 8 else {
        raise Invalid(0, "floating-point bits disagree with JSON width")
      }
      if width == 32 {
        Floating(
          width,
          Float::reinterpret_from_uint(read_u32(bytes[:], 0, Big)).to_double(),
        )
      } else if width == 64 {
        Floating(width, read_u64(bytes[:], 0, Big).reinterpret_as_double())
      } else {
        raise Unsupported(0, "JSON float supports binary32/binary64")
      }
    }
    "text" => {
      verbose_fields(object, ["kind", "encoding", "value"])
      let encoding = match verbose_string(verbose_field(object, "encoding")) {
        "ascii" => Ascii
        "utf8" => Utf8
        _ => raise Invalid(0, "unknown JSON string encoding")
      }
      Text(encoding, verbose_string(verbose_field(object, "value")))
    }
    "raw" => {
      verbose_fields(object, ["kind", "hex"])
      let text = verbose_string(verbose_field(object, "hex"))
      guard text.length() <= limits.string_bytes * 2 else {
        raise Limit(0, "JSON raw hex exceeds byte limit")
      }
      Raw(hex_decode(text))
    }
    _ => raise Invalid(0, "unknown JSON parameter kind")
  }
  ignore(argument_wire_length(argument, limits))
  argument
}

///|
pub fn VerboseParameter::to_json(self : VerboseParameter) -> Json {
  let value : Json = match self.value {
    Scalar(argument) => { "kind": "scalar", "argument": argument.to_json() }
    NumericArray(kind, dimensions, arguments) =>
      {
        "kind": "array",
        "element_type": numeric_type_json(kind),
        "dimensions": Json::array(
          dimensions.map(d => Json::number(d.to_double())),
        ),
        "arguments": Json::array(arguments.map(a => a.to_json())),
      }
  }
  let variable : Json = match self.variable {
    None => Json::null()
    Some(info) =>
      {
        "name": info.name,
        "unit": match info.unit {
          None => Json::null()
          Some(s) => Json::string(s)
        },
      }
  }
  let scaling : Json = match self.scaling {
    None => Json::null()
    Some(scale) => {
      let bits = @buffer.Buffer::Buffer()
      write_u32(bits, scale.quantization.reinterpret_as_uint(), Big)
      {
        "quantization_bits": hex_encode(bits.to_bytes()[:]),
        "offset": scale.offset.to_string(),
      }
    }
  }
  { "value": value, "variable": variable, "scaling": scaling }
}

///|
pub fn VerboseParameter::from_json(
  json : Json,
  limits~ : Limits = Limits::default(),
) -> VerboseParameter raise DltError {
  check_limits(limits)
  let object = verbose_object(json)
  verbose_fields(object, ["value", "variable", "scaling"])
  let descriptor = verbose_object(verbose_field(object, "value"))
  let value = match verbose_string(verbose_field(descriptor, "kind")) {
    "scalar" => {
      verbose_fields(descriptor, ["kind", "argument"])
      Scalar(
        Argument::from_json(verbose_field(descriptor, "argument"), limits~),
      )
    }
    "array" => {
      verbose_fields(descriptor, [
        "kind", "element_type", "dimensions", "arguments",
      ])
      let kind = numeric_type_from_json(
        verbose_field(descriptor, "element_type"),
      )
      let dimension_json = verbose_array(
        verbose_field(descriptor, "dimensions"),
      )
      guard dimension_json.length() <= 16 else {
        raise Limit(0, "JSON numeric array has more than sixteen dimensions")
      }
      let dimensions : Array[Int32] = []
      for dimension in dimension_json {
        dimensions.push(verbose_small_integer(dimension, 65535))
      }
      let count = dimensions_count(dimensions, numeric_type_width(kind), limits)
      let argument_json = verbose_array(verbose_field(descriptor, "arguments"))
      guard argument_json.length() == count else {
        raise Invalid(0, "JSON array values disagree with dimension product")
      }
      let arguments : Array[Argument] = []
      for element in argument_json {
        let arg = Argument::from_json(element, limits~)
        guard argument_matches_numeric(arg, kind) else {
          raise Invalid(0, "JSON array element type disagrees with descriptor")
        }
        arguments.push(arg)
      }
      NumericArray(kind, dimensions, arguments)
    }
    _ => raise Invalid(0, "unknown JSON parameter shape")
  }
  let variable = match verbose_field(object, "variable") {
    Null => None
    json => {
      let item = verbose_object(json)
      verbose_fields(item, ["name", "unit"])
      let name = verbose_string(verbose_field(item, "name"))
      let unit = match verbose_field(item, "unit") {
        Null => None
        value => Some(verbose_string(value))
      }
      Some({ name, unit, })
    }
  }
  let scaling = match verbose_field(object, "scaling") {
    Null => None
    json => {
      let item = verbose_object(json)
      verbose_fields(item, ["quantization_bits", "offset"])
      let text_bits = verbose_string(verbose_field(item, "quantization_bits"))
      guard text_bits.length() == 8 else {
        raise Invalid(0, "quantization requires eight hex digits")
      }
      let bits = hex_decode(text_bits)
      guard bits.length() == 4 else {
        raise Invalid(0, "quantization bits require four bytes")
      }
      let quantization = Float::reinterpret_from_uint(read_u32(bits[:], 0, Big))
      let text = verbose_string(verbose_field(item, "offset"))
      let offset = @string.parse_int64(text[:]) catch {
        _ =>
          raise Invalid(0, "fixed-point offset is not an Int64 decimal string")
      }
      guard text == offset.to_string() else {
        raise Invalid(
          0, "fixed-point offset must use canonical decimal spelling",
        )
      }
      Some({ quantization, offset, })
    }
  }
  let parameter = { value, variable, scaling, }
  ignore(encode_one_parameter(parameter, Little, limits))
  parameter
}

///|
fn numeric_type_json(kind : NumericType) -> Json {
  match kind {
    Bool8 => { "kind": "bool", "width": 8 }
    IntValue(width) => { "kind": "signed", "width": width }
    UIntValue(width) => { "kind": "unsigned", "width": width }
    FloatValue(width) => { "kind": "float", "width": width }
  }
}

///|
fn numeric_type_from_json(json : Json) -> NumericType raise DltError {
  let object = verbose_object(json)
  verbose_fields(object, ["kind", "width"])
  let width = verbose_width(verbose_field(object, "width"))
  let kind = match verbose_string(verbose_field(object, "kind")) {
    "bool" => {
      guard width == 8 else {
        raise Invalid(0, "Boolean JSON descriptor requires width 8")
      }
      Bool8
    }
    "signed" => IntValue(width)
    "unsigned" => UIntValue(width)
    "float" => FloatValue(width)
    _ => raise Invalid(0, "unknown JSON numeric element kind")
  }
  ignore(numeric_type_word(kind))
  kind
}

///|
fn verbose_object(json : Json) -> Map[String, Json] raise DltError {
  match json {
    Object(value) => value
    _ => raise Invalid(0, "expected JSON object")
  }
}

///|
fn verbose_string(json : Json) -> String raise DltError {
  match json {
    String(value) => value
    _ => raise Invalid(0, "expected JSON string")
  }
}

///|
fn verbose_array(json : Json) -> Array[Json] raise DltError {
  match json {
    Array(value) => value
    _ => raise Invalid(0, "expected JSON array")
  }
}

///|
fn verbose_field(
  object : Map[String, Json],
  name : String,
) -> Json raise DltError {
  match object.get(name) {
    Some(value) => value
    None => raise Invalid(0, "missing JSON field: " + name)
  }
}

///|
fn verbose_fields(
  object : Map[String, Json],
  fields : Array[String],
) -> Unit raise DltError {
  guard object.length() == fields.length() else {
    raise Invalid(0, "unexpected or missing JSON fields")
  }
  for name in fields {
    ignore(verbose_field(object, name))
  }
}

///|
fn verbose_small_integer(json : Json, maximum : Int32) -> Int32 raise DltError {
  match json {
    Number(value, ..) => {
      guard value >= 0.0 &&
        value <= maximum.to_double() &&
        value == value.floor() else {
        raise Invalid(0, "JSON integer is out of range or fractional")
      }
      value.to_int()
    }
    _ => raise Invalid(0, "expected JSON numeric integer")
  }
}

///|
fn verbose_width(json : Json) -> Int32 raise DltError {
  let width = verbose_small_integer(json, 64)
  ignore(width_code(width))
  width
}
