///|
/// Encode the DLT v1 scalar verbose profile. All lengths include a string's NUL.
/// Type words and payload numbers follow HTYP.MSBF, unlike header fields.
pub fn encode_arguments(
  args : Array[Argument],
  endian : Endian,
  limits~ : Limits = Limits::default(),
) -> Bytes raise DltError {
  check_limits(limits)
  guard args.length() <= limits.arguments else {
    raise Limit(0, "verbose argument count exceeds configured maximum")
  }
  let out = @buffer.Buffer::Buffer()
  for arg in args {
    let size = argument_wire_length(arg, limits)
    guard size <= limits.message_bytes - out.length() else {
      raise Limit(out.length(), "verbose payload exceeds message limit")
    }
    write_u32(out, argument_type_word(arg), endian)
    write_argument_value(out, arg, endian, limits)
  }
  out.to_bytes()
}

///|
/// Decode exactly count scalar parameters and require complete consumption.
/// Unsupported compound types are rejected; the outer Message retains raw bytes.
pub fn decode_arguments(
  data : BytesView,
  count : Int32,
  endian : Endian,
  limits~ : Limits = Limits::default(),
) -> Array[Argument] raise DltError {
  check_limits(limits)
  guard count >= 0 else { raise Invalid(0, "negative argument count") }
  guard count <= limits.arguments else {
    raise Limit(0, "verbose argument count exceeds configured maximum")
  }
  guard data.length() <= limits.message_bytes else {
    raise Limit(0, "verbose payload exceeds message limit")
  }
  let result : Array[Argument] = []
  let mut pos = 0
  for _ in 0..<count {
    let info = read_u32(data, pos, endian)
    let at = pos
    pos += 4
    let (value, end) = read_argument_value(data, pos, info, endian, limits)
    guard end > at else {
      raise Invalid(at, "argument parser made no progress")
    }
    result.push(value)
    pos = end
  }
  guard pos == data.length() else {
    raise Invalid(pos, "trailing payload bytes disagree with argument count")
  }
  result
}

///|
pub fn Message::arguments(
  self : Message,
  limits~ : Limits = Limits::default(),
) -> Array[Argument] raise DltError {
  let ext = match self.header.extended {
    Some(value) => value
    None => raise Invalid(0, "verbose decoding requires an extended header")
  }
  guard ext.verbose else { raise Invalid(0, "message is non-verbose") }
  decode_arguments(
    self.payload[:],
    ext.argument_count,
    self.header.endian,
    limits~,
  )
}

///|
/// Build a verbose message, deriving NOAR from the actual parameter array.
pub fn Message::with_arguments(
  header : Header,
  args : Array[Argument],
  storage? : StorageHeader,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  let ext = match header.extended {
    Some(value) => value
    None => raise Invalid(0, "verbose construction requires an extended header")
  }
  guard ext.verbose else { raise Invalid(0, "extended header is non-verbose") }
  let extended = Some({ ..ext, argument_count: args.length(), })
  finish_verbose_message(
    { ..header, extended, },
    encode_arguments(args, header.endian, limits~),
    storage,
    limits,
  )
}

///|
/// Payload budgets do not include the outer header, so message construction
/// performs a final complete-message check before returning a writable value.
fn finish_verbose_message(
  header : Header,
  payload : Bytes,
  storage : StorageHeader?,
  limits : Limits,
) -> Message raise DltError {
  let scratch = @buffer.Buffer::Buffer()
  write_header(scratch, header, payload.length(), limits)
  if storage is Some(info) {
    ignore(info.time_microseconds())
    scratch.reset()
    write_id(scratch, info.ecu)
  }
  { header, storage, payload, }
}

///|
fn width_code(width : Int32) -> UInt32 raise DltError {
  match width {
    8 => 1U
    16 => 2U
    32 => 3U
    64 => 4U
    128 =>
      raise Unsupported(
        0, "128-bit verbose numbers are outside the common profile",
      )
    _ => raise Invalid(0, "numeric width must be 8, 16, 32 or 64 bits")
  }
}

///|
fn word_width(info : UInt32, at : Int32) -> Int32 raise DltError {
  match info & 15U {
    1U => 8
    2U => 16
    3U => 32
    4U => 64
    5U =>
      raise Unsupported(
        at, "128-bit verbose numbers are outside the common profile",
      )
    _ => raise Invalid(at, "invalid numeric type length")
  }
}

///|
fn argument_type_word(arg : Argument) -> UInt32 raise DltError {
  match arg {
    Boolean(_) => 0x11U
    Signed(width, _) => 0x20U | width_code(width)
    Unsigned(width, _) => 0x40U | width_code(width)
    Floating(width, _) => {
      guard width == 32 || width == 64 else {
        raise Unsupported(0, "only IEEE binary32 and binary64 are supported")
      }
      0x80U | width_code(width)
    }
    Text(Ascii, _) => 0x200U
    Text(Utf8, _) => 0x8200U
    Raw(_) => 0x400U
  }
}

///|
fn check_signed(width : Int32, value : Int64) -> Unit raise DltError {
  ignore(width_code(width))
  if width < 64 {
    let bound = 1L << (width - 1)
    guard value >= -bound && value < bound else {
      raise Invalid(0, "signed value cannot be represented in requested width")
    }
  }
}

///|
fn check_unsigned(width : Int32, value : UInt64) -> Unit raise DltError {
  ignore(width_code(width))
  if width < 64 {
    guard value < 1UL << width else {
      raise Invalid(
        0, "unsigned value cannot be represented in requested width",
      )
    }
  }
}

///|
fn argument_text_bytes(
  encoding : TextEncoding,
  text : String,
  limits : Limits,
) -> Bytes raise DltError {
  guard limits.string_bytes > 0 else {
    raise Limit(0, "string including terminator exceeds maximum")
  }
  let bytes = encode_text_checked(text, max_bytes=limits.string_bytes - 1)
  for byte in bytes {
    guard byte != b'\x00' else {
      raise Invalid(0, "embedded NUL in verbose string")
    }
    if encoding == Ascii {
      guard byte.to_int() < 128 else {
        raise Invalid(0, "non-ASCII byte in ASCII parameter")
      }
    }
  }
  bytes
}

///|
fn argument_wire_length(
  arg : Argument,
  limits : Limits,
) -> Int32 raise DltError {
  match arg {
    Boolean(_) => 5
    Signed(width, value) => {
      check_signed(width, value)
      4 + width / 8
    }
    Unsigned(width, value) => {
      check_unsigned(width, value)
      4 + width / 8
    }
    Floating(width, _) => {
      ignore(argument_type_word(arg))
      4 + width / 8
    }
    Text(encoding, value) =>
      7 + argument_text_bytes(encoding, value, limits).length()
    Raw(value) => {
      guard value.length() <= 65535 && value.length() <= limits.string_bytes else {
        raise Limit(0, "raw argument exceeds maximum")
      }
      6 + value.length()
    }
  }
}

///|
fn write_integer_bits(
  out : @buffer.Buffer,
  width : Int32,
  value : UInt64,
  endian : Endian,
) -> Unit {
  let size = width / 8
  for i in 0..<size {
    let shift = if endian == Big { (size - 1 - i) * 8 } else { i * 8 }
    out.write_byte((value >> shift).to_byte())
  }
}

///|
fn write_argument_value(
  out : @buffer.Buffer,
  arg : Argument,
  endian : Endian,
  limits : Limits,
) -> Unit raise DltError {
  match arg {
    Boolean(value) => out.write_byte(if value { b'\x01' } else { b'\x00' })
    Signed(width, value) => {
      check_signed(width, value)
      write_integer_bits(out, width, value.reinterpret_as_uint64(), endian)
    }
    Unsigned(width, value) => {
      check_unsigned(width, value)
      write_integer_bits(out, width, value, endian)
    }
    Floating(32, value) =>
      write_u32(out, Float::from_double(value).reinterpret_as_uint(), endian)
    Floating(64, value) => write_u64(out, value.reinterpret_as_uint64(), endian)
    Floating(_, _) => raise Unsupported(0, "unsupported floating width")
    Text(encoding, text) => {
      let bytes = argument_text_bytes(encoding, text, limits)
      write_u16(out, bytes.length() + 1, endian)
      out.write_bytes(bytes[:])
      out.write_byte(b'\x00')
    }
    Raw(bytes) => {
      guard bytes.length() <= 65535 && bytes.length() <= limits.string_bytes else {
        raise Limit(out.length(), "raw argument exceeds maximum")
      }
      write_u16(out, bytes.length(), endian)
      out.write_bytes(bytes[:])
    }
  }
}

///|
fn read_integer_bits(
  data : BytesView,
  pos : Int32,
  width : Int32,
  endian : Endian,
) -> UInt64 raise DltError {
  let size = width / 8
  require_range(data, pos, size)
  let mut value = 0UL
  for i in 0..<size {
    let shift = if endian == Big { (size - 1 - i) * 8 } else { i * 8 }
    value = value | (data[pos + i].to_uint64() << shift)
  }
  value
}

///|
fn signed_integer_value(raw : UInt64, width : Int32) -> Int64 {
  if width == 64 {
    raw.reinterpret_as_int64()
  } else {
    let sign = 1UL << (width - 1)
    if (raw & sign) == 0UL {
      raw.reinterpret_as_int64()
    } else {
      (raw | (0xFFFFFFFFFFFFFFFFUL << width)).reinterpret_as_int64()
    }
  }
}

///|
fn read_text_value(
  data : BytesView,
  pos : Int32,
  length : Int32,
  encoding : TextEncoding,
  limits : Limits,
) -> String raise DltError {
  guard length > 0 else {
    raise Invalid(pos, "string length must include its NUL")
  }
  guard length <= limits.string_bytes else {
    raise Limit(pos, "string exceeds maximum")
  }
  require_range(data, pos, length)
  guard data[pos + length - 1] == b'\x00' else {
    raise Invalid(pos + length - 1, "string is missing NUL terminator")
  }
  for i in pos..<(pos + length - 1) {
    let b = data[i]
    guard b != b'\x00' else {
      raise Invalid(i, "embedded NUL in verbose string")
    }
    if encoding == Ascii {
      guard b.to_int() < 128 else {
        raise Invalid(i, "non-ASCII verbose string")
      }
    }
  }
  @utf8.decode(data[pos:pos + length - 1]) catch {
    _ => raise Invalid(pos, "invalid UTF-8 verbose string")
  }
}

///|
fn check_scalar_type_word(info : UInt32, at : Int32) -> UInt32 raise DltError {
  guard (info & 0xFFFC0000U) == 0U else {
    raise Unsupported(at, "reserved verbose type flags")
  }
  guard (info & 0x7900U) == 0U else {
    raise Unsupported(
      at, "array, variable info, fixed point, trace or struct parameter",
    )
  }
  let base = info & 0x6F0U
  guard base == 0x10U ||
    base == 0x20U ||
    base == 0x40U ||
    base == 0x80U ||
    base == 0x200U ||
    base == 0x400U else {
    raise Invalid(at, "verbose parameter must have exactly one base type")
  }
  if base != 0x200U {
    guard (info & 0x38000U) == 0U else {
      raise Invalid(at, "string coding flags on non-string parameter")
    }
  }
  if base == 0x200U || base == 0x400U {
    guard (info & 15U) == 0U else {
      raise Invalid(at, "string/raw parameter must not specify numeric width")
    }
  }
  base
}

///|
fn read_argument_value(
  data : BytesView,
  pos : Int32,
  info : UInt32,
  endian : Endian,
  limits : Limits,
) -> (Argument, Int32) raise DltError {
  let base = check_scalar_type_word(info, pos - 4)
  if base == 0x10U {
    guard (info & 15U) == 1U else {
      raise Invalid(pos - 4, "Boolean must use 8-bit width")
    }
    require_range(data, pos, 1)
    guard data[pos] == b'\x00' || data[pos] == b'\x01' else {
      raise Invalid(pos, "Boolean value must be zero or one")
    }
    (Boolean(data[pos] == b'\x01'), pos + 1)
  } else if base == 0x20U || base == 0x40U {
    let width = word_width(info, pos - 4)
    let raw = read_integer_bits(data, pos, width, endian)
    let value = if base == 0x20U {
      Signed(width, signed_integer_value(raw, width))
    } else {
      Unsigned(width, raw)
    }
    (value, pos + width / 8)
  } else if base == 0x80U {
    let width = word_width(info, pos - 4)
    let value = if width == 32 {
      Float::reinterpret_from_uint(read_u32(data, pos, endian)).to_double()
    } else if width == 64 {
      read_u64(data, pos, endian).reinterpret_as_double()
    } else {
      raise Unsupported(pos - 4, "unsupported IEEE floating-point width")
    }
    (Floating(width, value), pos + width / 8)
  } else if base == 0x200U {
    let encoding = match info & 0x38000U {
      0U => Ascii
      0x8000U => Utf8
      _ => raise Unsupported(pos - 4, "unsupported string character encoding")
    }
    let length = read_u16(data, pos, endian)
    (
      Text(encoding, read_text_value(data, pos + 2, length, encoding, limits)),
      pos + 2 + length,
    )
  } else {
    let length = read_u16(data, pos, endian)
    guard length <= limits.string_bytes else {
      raise Limit(pos, "raw parameter exceeds maximum")
    }
    require_range(data, pos + 2, length)
    (Raw(data[pos + 2:pos + 2 + length].to_owned()), pos + 2 + length)
  }
}
