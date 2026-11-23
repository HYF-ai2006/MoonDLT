///|
fn check_limits(limits : Limits) -> Unit raise DltError {
  guard limits.message_bytes >= 4 &&
    limits.message_bytes <= 65535 &&
    limits.buffered_bytes >= limits.message_bytes + 16 &&
    limits.arguments >= 0 &&
    limits.arguments <= 255 &&
    limits.string_bytes >= 0 &&
    limits.string_bytes <= 65535 &&
    limits.resync_bytes >= 0 else {
    raise Invalid(0, "invalid decoder limits")
  }
}

///|
fn require_range(
  data : BytesView,
  offset : Int32,
  length : Int32,
) -> Unit raise DltError {
  guard offset >= 0 &&
    length >= 0 &&
    offset <= data.length() &&
    length <= data.length() - offset else {
    raise Truncated(offset, "byte range exceeds input")
  }
}

///|
fn read_u16(
  data : BytesView,
  offset : Int32,
  endian : Endian,
) -> Int32 raise DltError {
  require_range(data, offset, 2)
  let a = data[offset].to_int()
  let b = data[offset + 1].to_int()
  match endian {
    Big => (a << 8) | b
    Little => a | (b << 8)
  }
}

///|
fn read_u32(
  data : BytesView,
  offset : Int32,
  endian : Endian,
) -> UInt32 raise DltError {
  require_range(data, offset, 4)
  let mut v = 0U
  for i in 0..<4 {
    let shift = match endian {
      Little => i * 8
      Big => (3 - i) * 8
    }
    v = v | (data[offset + i].to_uint() << shift)
  }
  v
}

///|
fn read_u64(
  data : BytesView,
  offset : Int32,
  endian : Endian,
) -> UInt64 raise DltError {
  require_range(data, offset, 8)
  let mut v = 0UL
  for i in 0..<8 {
    let shift = match endian {
      Little => i * 8
      Big => (7 - i) * 8
    }
    v = v | (data[offset + i].to_uint64() << shift)
  }
  v
}

///|
fn write_u16(out : @buffer.Buffer, value : Int32, endian : Endian) -> Unit {
  match endian {
    Big => {
      out.write_byte((value >> 8).to_byte())
      out.write_byte(value.to_byte())
    }
    Little => {
      out.write_byte(value.to_byte())
      out.write_byte((value >> 8).to_byte())
    }
  }
}

///|
fn write_u32(out : @buffer.Buffer, value : UInt32, endian : Endian) -> Unit {
  match endian {
    Big => out.write_uint_be(value)
    Little => out.write_uint_le(value)
  }
}

///|
fn write_u64(out : @buffer.Buffer, value : UInt64, endian : Endian) -> Unit {
  match endian {
    Big => out.write_uint64_be(value)
    Little => out.write_uint64_le(value)
  }
}

///|
/// Identifiers are ASCII with zero padding; embedded zeros and nonzero padding fail.
fn read_id(data : BytesView, offset : Int32) -> String raise DltError {
  require_range(data, offset, 4)
  let out = @buffer.Buffer::Buffer()
  let mut ended = false
  for i in 0..<4 {
    let b = data[offset + i]
    if b == b'\x00' {
      ended = true
    } else {
      guard !ended && b >= b' ' && b <= b'~' else {
        raise Invalid(offset + i, "identifier must be padded printable ASCII")
      }
      out.write_byte(b)
    }
  }
  @utf8.decode(out.to_bytes()[:]) catch {
    _ => raise Invalid(offset, "invalid identifier")
  }
}

///|
fn write_id(out : @buffer.Buffer, id : String) -> Unit raise DltError {
  let bytes = @utf8.encode(id)
  guard bytes.length() <= 4 else {
    raise Invalid(0, "identifier exceeds four bytes")
  }
  for b in bytes {
    guard b >= b' ' && b <= b'~' else {
      raise Invalid(0, "identifier must be printable ASCII")
    }
  }
  out.write_bytes(bytes[:])
  for _ in bytes.length()..<4 {
    out.write_byte(b'\x00')
  }
}

///|
pub fn hex_encode(bytes : BytesView) -> String {
  let digits = b"0123456789abcdef"
  let out = @buffer.Buffer::Buffer()
  for b in bytes {
    out.write_byte(digits[b.to_int() >> 4])
    out.write_byte(digits[b.to_int() & 15])
  }
  @utf8.decode_lossy(out.to_bytes()[:])
}

///|
pub fn hex_decode(text : String) -> Bytes raise DltError {
  let bytes = @utf8.encode(text)
  guard bytes.length() % 2 == 0 else {
    raise Invalid(0, "hex requires even length")
  }
  let out = @buffer.Buffer::Buffer()
  for i = 0; i < bytes.length(); i = i + 2 {
    let a = hex_nibble(bytes[i], i)
    let b = hex_nibble(bytes[i + 1], i + 1)
    out.write_byte(((a << 4) | b).to_byte())
  }
  out.to_bytes()
}

///|
fn hex_nibble(b : Byte, position : Int32) -> Int32 raise DltError {
  if b >= b'0' && b <= b'9' {
    b.to_int() - 48
  } else if b >= b'a' && b <= b'f' {
    b.to_int() - 87
  } else if b >= b'A' && b <= b'F' {
    b.to_int() - 55
  } else {
    raise Invalid(position, "invalid hexadecimal digit")
  }
}
