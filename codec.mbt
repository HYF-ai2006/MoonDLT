///|
/// Size of the standard and optional extended headers, excluding storage/serial.
pub fn Header::wire_size(self : Header) -> Int {
  let mut size = 4
  if self.ecu is Some(_) { size += 4 }
  if self.session is Some(_) { size += 4 }
  if self.timestamp is Some(_) { size += 4 }
  if self.extended is Some(_) { size += 10 }
  size
}

///|
fn prefix_size(framing : Framing) -> Int {
  match framing { Network => 0; Serial => 4; Storage => 16 }
}

///|
fn check_prefix(data : BytesView, framing : Framing) -> Unit raise DltError {
  match framing {
    Network => ()
    Storage => {
      require_range(data, 0, 4)
      guard data[:4] == b"DLT\x01"[:] else { raise Invalid(0, "expected DLT storage magic") }
    }
    Serial => {
      require_range(data, 0, 4)
      guard data[:4] == b"DLS\x01"[:] else { raise Invalid(0, "expected DLT serial magic") }
    }
  }
}

///|
/// Reads only the length prefix. Returns None until its full prefix is available.
/// It rejects unsupported protocol versions before waiting for an alleged payload.
fn framed_size(data : BytesView, framing : Framing, limits : Limits) -> Int? raise DltError {
  let prefix = prefix_size(framing)
  if data.length() < prefix + 4 { return None }
  check_prefix(data, framing)
  let htyp = data[prefix].to_int()
  guard htyp >> 5 == 1 else { raise Unsupported(prefix, "only DLT protocol v1 is supported") }
  let length = read_u16(data, prefix + 2, Big)
  let minimum = header_size_from_flags(htyp)
  guard length >= minimum else { raise Invalid(prefix + 2, "message length is smaller than its headers") }
  guard length <= limits.message_bytes else { raise Limit(prefix + 2, "message exceeds message_bytes") }
  Some(prefix + length)
}

///|
fn header_size_from_flags(flags : Int) -> Int {
  let mut size = 4
  if (flags & 4) != 0 { size += 4 }
  if (flags & 8) != 0 { size += 4 }
  if (flags & 16) != 0 { size += 4 }
  if (flags & 1) != 0 { size += 10 }
  size
}

///|
fn decode_storage(data : BytesView) -> StorageHeader raise DltError {
  require_range(data, 0, 16)
  let seconds = read_u32(data, 4, Little)
  let microseconds = read_u32(data, 8, Little)
  guard microseconds < 1000000U else { raise Invalid(8, "storage microseconds must be below one million") }
  { seconds, microseconds, ecu: read_id(data, 12) }
}

///|
fn decode_header(data : BytesView, start : Int, limits : Limits) -> Header raise DltError {
  require_range(data, start, 4)
  let flags = data[start].to_int()
  guard flags >> 5 == 1 else { raise Unsupported(start, "only DLT protocol v1 is supported") }
  require_range(data, start, header_size_from_flags(flags))
  let mut pos = start + 4
  let ecu = if (flags & 4) != 0 {
    let value = read_id(data, pos)
    pos += 4
    Some(value)
  } else { None }
  let session = if (flags & 8) != 0 {
    let value = read_u32(data, pos, Big)
    pos += 4
    Some(value)
  } else { None }
  let timestamp = if (flags & 16) != 0 {
    let value = read_u32(data, pos, Big)
    pos += 4
    Some(value)
  } else { None }
  let extended = if (flags & 1) != 0 {
    let msin = data[pos].to_int()
    let count = data[pos + 1].to_int()
    guard count <= limits.arguments else { raise Limit(pos + 1, "argument count exceeds configured limit") }
    Some({ verbose: (msin & 1) != 0, message_type: (msin >> 1) & 7,
      subtype: msin >> 4, argument_count: count,
      application: read_id(data, pos + 2), context: read_id(data, pos + 6) })
  } else { None }
  { endian: if (flags & 2) != 0 { Big } else { Little },
    counter: data[start + 1].to_int(), ecu, session, timestamp, extended }
}

///|
/// Decodes exactly one framed message and reports its length. Remaining bytes
/// belong to the caller; use decode_exact for a standalone datagram.
pub fn decode(data : BytesView, framing? : Framing = Storage,
  limits? : Limits = Limits::default()) -> Decoded raise DltError {
  check_limits(limits)
  check_prefix(data, framing)
  let size = match framed_size(data, framing, limits) {
    Some(size) => size
    None => raise Truncated(data.length(), "incomplete framing or standard header")
  }
  require_range(data, 0, size)
  let prefix = prefix_size(framing)
  let storage = if framing == Storage { Some(decode_storage(data)) } else { None }
  let header = decode_header(data, prefix, limits)
  let payload_start = prefix + header.wire_size()
  { message: { storage, header, payload: data[payload_start:size].to_owned() }, consumed: size }
}

///|
pub fn decode_exact(data : BytesView, framing? : Framing = Storage,
  limits? : Limits = Limits::default()) -> Message raise DltError {
  let decoded = decode(data, framing~, limits~)
  guard decoded.consumed == data.length() else { raise Invalid(decoded.consumed, "trailing bytes after message") }
  decoded.message
}

///|
/// Validates every framing boundary without attempting to guess payload types.
pub fn decode_all(data : BytesView, framing? : Framing = Storage,
  limits? : Limits = Limits::default(), max_messages? : Int = 1000000) -> Array[Message] raise DltError {
  guard max_messages >= 0 else { raise Invalid(0, "negative message count limit") }
  let result : Array[Message] = []
  let mut offset = 0
  while offset < data.length() {
    guard result.length() < max_messages else { raise Limit(offset, "message count exceeds limit") }
    let next = decode(data[offset:], framing~, limits~)
    result.push(next.message)
    offset += next.consumed
  }
  result
}

///|
fn write_header(out : @buffer.Buffer, header : Header, payload_size : Int, limits : Limits) -> Unit raise DltError {
  guard header.counter >= 0 && header.counter <= 255 else { raise Invalid(1, "message counter outside byte range") }
  let size = header.wire_size()
  guard payload_size >= 0 && payload_size <= limits.message_bytes - size else {
    raise Limit(2, "encoded message exceeds message_bytes")
  }
  let mut flags = 32
  if header.endian == Big { flags = flags | 2 }
  if header.ecu is Some(_) { flags = flags | 4 }
  if header.session is Some(_) { flags = flags | 8 }
  if header.timestamp is Some(_) { flags = flags | 16 }
  if header.extended is Some(_) { flags = flags | 1 }
  out.write_byte(flags.to_byte())
  out.write_byte(header.counter.to_byte())
  write_u16(out, size + payload_size, Big)
  if header.ecu is Some(id) { write_id(out, id) }
  if header.session is Some(value) { write_u32(out, value, Big) }
  if header.timestamp is Some(value) { write_u32(out, value, Big) }
  if header.extended is Some(ext) {
    guard ext.message_type >= 0 && ext.message_type <= 7 &&
      ext.subtype >= 0 && ext.subtype <= 15 else { raise Invalid(size - 10, "extended header type out of range") }
    guard ext.argument_count >= 0 && ext.argument_count <= limits.arguments else {
      raise Limit(size - 9, "extended header count exceeds limit")
    }
    let msin = (if ext.verbose { 1 } else { 0 }) | (ext.message_type << 1) | (ext.subtype << 4)
    out.write_byte(msin.to_byte())
    out.write_byte(ext.argument_count.to_byte())
    write_id(out, ext.application)
    write_id(out, ext.context)
  }
}

///|
/// Deterministic writer. Framing conversion is explicit: storage framing requires
/// a reception timestamp; network/serial framing omits that storage metadata.
pub fn encode(message : Message, framing? : Framing = Storage,
  limits? : Limits = Limits::default()) -> Bytes raise DltError {
  check_limits(limits)
  let out = @buffer.Buffer::Buffer()
  match framing {
    Storage => {
      let storage = match message.storage {
        Some(s) => s
        None => raise Invalid(0, "storage framing requires a storage header")
      }
      guard storage.microseconds < 1000000U else { raise Invalid(8, "storage microseconds must be below one million") }
      out.write_bytes(b"DLT\x01"[:])
      write_u32(out, storage.seconds, Little)
      write_u32(out, storage.microseconds, Little)
      write_id(out, storage.ecu)
    }
    Serial => out.write_bytes(b"DLS\x01"[:])
    Network => ()
  }
  write_header(out, message.header, message.payload.length(), limits)
  out.write_bytes(message.payload[:])
  out.to_bytes()
}

///|
pub fn encode_all(messages : ArrayView[Message], framing? : Framing = Storage,
  limits? : Limits = Limits::default(), max_bytes? : Int = 67108864) -> Bytes raise DltError {
  guard max_bytes >= 0 else { raise Invalid(0, "negative output byte limit") }
  let out = @buffer.Buffer::Buffer()
  for message in messages {
    let bytes = encode(message, framing~, limits~)
    guard bytes.length() <= max_bytes - out.length() else { raise Limit(out.length(), "output exceeds byte budget") }
    out.write_bytes(bytes[:])
  }
  out.to_bytes()
}

///|
pub fn Message::effective_ecu(self : Message) -> String? {
  match self.header.ecu {
    Some(ecu) => Some(ecu)
    None => match self.storage { Some(storage) => Some(storage.ecu); None => None }
  }
}

///|
pub fn Message::storage_microseconds(self : Message) -> UInt64? {
  match self.storage {
    Some(s) => Some(s.seconds.to_uint64() * 1000000UL + s.microseconds.to_uint64())
    None => None
  }
}
