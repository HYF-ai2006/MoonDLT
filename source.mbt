///|
/// Stable random-access input. The callback returns exactly the requested bytes.
/// Offsets use UInt64, allowing large recordings with small in-memory windows.
pub struct Source {
  size : UInt64
  read_at : (UInt64, Int) -> Bytes raise DltError
}

///|
pub fn Source::new(size : UInt64,
  read_at : (UInt64, Int) -> Bytes raise DltError) -> Source {
  { size, read_at }
}

///|
pub fn Source::size(self : Source) -> UInt64 { self.size }

///|
pub fn Source::from_bytes(bytes : Bytes) -> Source {
  Source::new(bytes.length().to_uint64(), (offset, length) => {
    guard offset <= bytes.length().to_uint64() && length >= 0 &&
      length.to_uint64() <= bytes.length().to_uint64() - offset else {
      raise Truncated(0, "source read outside immutable byte buffer")
    }
    bytes[offset.to_int():offset.to_int() + length].to_owned()
  })
}

///|
fn Source::read_checked(self : Source, offset : UInt64, length : Int) -> Bytes raise DltError {
  guard length >= 0 && offset <= self.size && length.to_uint64() <= self.size - offset else {
    raise Truncated(0, "requested source range is outside file at \{offset}")
  }
  let data = (self.read_at)(offset, length)
  guard data.length() == length else {
    raise Truncated(0, "source returned short read at \{offset}, expected \{length}")
  }
  data
}

///|
/// Index metadata does not imply that verbose payloads have been validated.
pub(all) struct SourceEntry {
  offset : UInt64
  length : Int
  framing : Framing
  storage : StorageHeader?
  header : Header
  payload_offset : UInt64
  payload_length : Int
} derive(Eq, @debug.Debug)

///|
/// Sequential metadata iterator with explicit I/O and entry limits. Each call
/// reads a framing prefix followed by only the optional header bytes.
pub struct SourceCursor {
  source : Source
  framing : Framing
  limits : Limits
  max_entries : UInt64
  mut offset : UInt64
  mut count : UInt64
  mut header_bytes_read : UInt64
}

///|
pub fn SourceCursor::new(source : Source, framing? : Framing = Storage,
  limits? : Limits = Limits::default(), max_entries? : UInt64 = 1000000UL,
  start? : UInt64 = 0UL) -> SourceCursor raise DltError {
  check_limits(limits)
  guard start <= source.size else { raise Invalid(0, "cursor start exceeds source size") }
  { source, framing, limits, max_entries, offset: start, count: 0UL, header_bytes_read: 0UL }
}

///|
pub fn SourceCursor::position(self : SourceCursor) -> UInt64 { self.offset }

///|
pub fn SourceCursor::entry_count(self : SourceCursor) -> UInt64 { self.count }

///|
pub fn SourceCursor::header_bytes_read(self : SourceCursor) -> UInt64 { self.header_bytes_read }

///|
pub fn SourceCursor::next_entry(self : SourceCursor) -> SourceEntry? raise DltError {
  if self.offset == self.source.size { return None }
  guard self.count < self.max_entries else { raise Limit(0, "source index exceeds entry budget") }
  let prefix = prefix_size(self.framing)
  let fixed_size = prefix + 4
  let fixed = self.source.read_checked(self.offset, fixed_size)
  let total = match framed_size(fixed[:], self.framing, self.limits) {
    Some(n) => n
    None => raise Truncated(0, "incomplete source header")
  }
  guard total.to_uint64() <= self.source.size - self.offset else {
    raise Truncated(0, "message at \{self.offset} extends past source end")
  }
  let header_size = header_size_from_flags(fixed[prefix].to_int())
  let extra_size = header_size - 4
  let all_headers = @buffer.Buffer::Buffer()
  all_headers.write_bytes(fixed[:])
  if extra_size > 0 {
    all_headers.write_bytes(self.source.read_checked(self.offset + fixed_size.to_uint64(), extra_size)[:])
  }
  let bytes = all_headers.to_bytes()
  let storage = if self.framing == Storage { Some(decode_storage(bytes[:])) } else { None }
  let header = decode_header(bytes[:], prefix, self.limits)
  let entry = { offset: self.offset, length: total, framing: self.framing,
    storage, header, payload_offset: self.offset + (prefix + header_size).to_uint64(),
    payload_length: total - prefix - header_size }
  self.offset += total.to_uint64()
  self.count += 1UL
  self.header_bytes_read += bytes.length().to_uint64()
  Some(entry)
}

///|
/// Confirms the referenced entry against the source before returning its bytes.
/// The caller must still keep a callback-backed source immutable between reads.
pub fn Source::read_entry(self : Source, entry : SourceEntry,
  limits? : Limits = Limits::default()) -> Message raise DltError {
  check_limits(limits)
  let minimum = prefix_size(entry.framing) + entry.header.wire_size()
  guard entry.length >= minimum && entry.length <= prefix_size(entry.framing) + limits.message_bytes else {
    raise Invalid(0, "invalid indexed message length")
  }
  guard entry.offset <= self.size && entry.length.to_uint64() <= self.size - entry.offset else {
    raise Invalid(0, "index entry outside source")
  }
  let wire = self.read_checked(entry.offset, entry.length)
  let message = decode_exact(wire[:], framing=entry.framing, limits~)
  guard message.header == entry.header && message.storage == entry.storage &&
    entry.payload_length == message.payload.length() &&
    entry.payload_offset == entry.offset + minimum.to_uint64() else {
    raise Invalid(0, "index metadata does not match source message")
  }
  message
}

///|
/// Visits selected metadata records without buffering the whole recording.
/// Returning false stops immediately; no future source data will be requested.
pub fn Source::visit(self : Source, visit : (SourceEntry) -> Bool raise DltError,
  framing? : Framing = Storage, limits? : Limits = Limits::default(),
  max_entries? : UInt64 = 1000000UL) -> UInt64 raise DltError {
  let cursor = SourceCursor::new(self, framing~, limits~, max_entries~)
  while cursor.next_entry() is Some(entry) {
    if !visit(entry) { break }
  }
  cursor.entry_count()
}

///|
/// Builds a bounded catalog; for unbounded recordings prefer visit or next_entry.
pub fn Source::catalog(self : Source, framing? : Framing = Storage,
  limits? : Limits = Limits::default(), max_entries? : Int = 100000) -> Array[SourceEntry] raise DltError {
  guard max_entries >= 0 else { raise Invalid(0, "negative catalog entry budget") }
  let cursor = SourceCursor::new(self, framing~, limits~, max_entries=max_entries.to_uint64())
  let entries : Array[SourceEntry] = []
  while cursor.next_entry() is Some(entry) { entries.push(entry) }
  entries
}

///|
/// Copies selected records in original order without decoding payload arguments.
/// Sink effects are incremental: an error cannot roll back earlier emissions.
pub fn Source::copy_selected(self : Source,
  select : (SourceEntry) -> Bool, emit : (Bytes) -> Unit raise DltError,
  framing? : Framing = Storage, limits? : Limits = Limits::default(),
  max_entries? : UInt64 = 1000000UL) -> UInt64 raise DltError {
  let cursor = SourceCursor::new(self, framing~, limits~, max_entries~)
  let mut copied = 0UL
  while cursor.next_entry() is Some(entry) {
    if select(entry) {
      let bytes = self.read_checked(entry.offset, entry.length)
      ignore(decode_exact(bytes[:], framing~, limits~))
      emit(bytes)
      copied += 1UL
    }
  }
  copied
}

///|
/// Validates the complete source message-by-message. Payload validity can be
/// checked by passing a verifier, e.g. a verbose parameter decoder.
pub fn Source::verify(self : Source,
  check? : (Message) -> Unit raise DltError = _ => (),
  framing? : Framing = Storage, limits? : Limits = Limits::default(),
  max_entries? : UInt64 = 1000000UL) -> UInt64 raise DltError {
  let cursor = SourceCursor::new(self, framing~, limits~, max_entries~)
  while cursor.next_entry() is Some(entry) { check(self.read_entry(entry, limits~)) }
  cursor.entry_count()
}

///|
/// Small read-through cache for high-latency callback sources. It owns one window
/// and never requests beyond the backing source; large requests bypass the cache.
pub struct WindowSource {
  backing : Source
  window_bytes : Int
  mut start : UInt64
  mut window : Bytes
  mut reads : UInt64
  mut hits : UInt64
}

///|
pub fn WindowSource::new(backing : Source, window_bytes? : Int = 65536) -> WindowSource raise DltError {
  guard window_bytes > 0 && window_bytes <= 16777216 else {
    raise Invalid(0, "window size must be within 1..16777216")
  }
  { backing, window_bytes, start: 0UL, window: b"", reads: 0UL, hits: 0UL }
}

///|
pub fn WindowSource::as_source(self : WindowSource) -> Source {
  Source::new(self.backing.size, (offset, length) => self.read(offset, length))
}

///|
pub fn WindowSource::read(self : WindowSource, offset : UInt64, length : Int) -> Bytes raise DltError {
  guard length >= 0 && offset <= self.backing.size && length.to_uint64() <= self.backing.size - offset else {
    raise Truncated(0, "cached source request is outside file")
  }
  if length == 0 { return b"" }
  if offset >= self.start {
    let relative = offset - self.start
    if relative <= self.window.length().to_uint64() &&
      length.to_uint64() <= self.window.length().to_uint64() - relative {
      self.hits += 1UL
      let start = relative.to_int()
      return self.window[start:start + length].to_owned()
    }
  }
  self.reads += 1UL
  if length > self.window_bytes { return self.backing.read_checked(offset, length) }
  let available = self.backing.size - offset
  let read_length = if available < self.window_bytes.to_uint64() { available.to_int() } else { self.window_bytes }
  let bytes = self.backing.read_checked(offset, read_length)
  self.start = offset
  self.window = bytes
  bytes[:length].to_owned()
}

///|
pub fn WindowSource::backing_reads(self : WindowSource) -> UInt64 { self.reads }

///|
pub fn WindowSource::cache_hits(self : WindowSource) -> UInt64 { self.hits }

///|
pub fn WindowSource::invalidate(self : WindowSource) -> Unit {
  self.start = 0UL
  self.window = b""
}
