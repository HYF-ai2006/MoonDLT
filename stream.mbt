///|
/// Bounded incremental framing. A failing feed poisons the decoder until reset;
/// this avoids silently delivering only a prefix of an unsuccessful batch.
pub struct StreamDecoder {
  framing : Framing
  limits : Limits
  recover : Bool
  mut pending : Bytes
  mut total_input : UInt64
  mut total_messages : UInt64
  mut total_skipped : UInt64
  mut consecutive_skipped : Int32
  mut closed : Bool
  mut failed : Bool
}

///|
pub fn StreamDecoder::new(
  framing~ : Framing = Storage,
  limits~ : Limits = Limits::default(),
  recover~ : Bool = false,
) -> StreamDecoder raise DltError {
  check_limits(limits)
  guard !recover || framing != Network else {
    raise Invalid(0, "network framing has no unique marker for recovery")
  }
  {
    framing,
    limits,
    recover,
    pending: b"",
    total_input: 0UL,
    total_messages: 0UL,
    total_skipped: 0UL,
    consecutive_skipped: 0,
    closed: false,
    failed: false,
  }
}

///|
pub fn StreamDecoder::buffered_bytes(self : StreamDecoder) -> Int32 {
  self.pending.length()
}

///|
pub fn StreamDecoder::input_bytes(self : StreamDecoder) -> UInt64 {
  self.total_input
}

///|
pub fn StreamDecoder::message_count(self : StreamDecoder) -> UInt64 {
  self.total_messages
}

///|
pub fn StreamDecoder::skipped_bytes(self : StreamDecoder) -> UInt64 {
  self.total_skipped
}

///|
pub fn StreamDecoder::is_failed(self : StreamDecoder) -> Bool {
  self.failed
}

///|
pub fn StreamDecoder::reset(self : StreamDecoder) -> Unit {
  self.pending = b""
  self.total_input = 0UL
  self.total_messages = 0UL
  self.total_skipped = 0UL
  self.consecutive_skipped = 0
  self.closed = false
  self.failed = false
}

///|
fn marker_byte(framing : Framing, index : Int32) -> Byte {
  if framing == Storage {
    b"DLT\x01"[index]
  } else {
    b"DLS\x01"[index]
  }
}

///|
fn marker_matches(
  data : BytesView,
  position : Int32,
  framing : Framing,
) -> Bool {
  if data.length() - position < 4 {
    return false
  }
  for i in 0..<4 {
    if data[position + i] != marker_byte(framing, i) {
      return false
    }
  }
  true
}

///|
/// Retain a proper magic prefix at the end of a chunk for a split marker.
fn marker_suffix(data : BytesView, framing : Framing) -> Int32 {
  for n = 3; n > 0; n = n - 1 {
    if data.length() >= n {
      let mut matches = true
      for i in 0..<n {
        if data[data.length() - n + i] != marker_byte(framing, i) {
          matches = false
        }
      }
      if matches {
        return n
      }
    }
  }
  0
}

///|
fn StreamDecoder::skip(
  self : StreamDecoder,
  length : Int32,
) -> Unit raise DltError {
  guard length <= self.limits.resync_bytes - self.consecutive_skipped else {
    raise Limit(0, "recovery exceeded consecutive resync_bytes")
  }
  self.consecutive_skipped += length
  self.total_skipped += length.to_uint64()
}

///|
fn StreamDecoder::process(
  self : StreamDecoder,
  chunk : BytesView,
) -> StreamBatch raise DltError {
  guard chunk.length() <= self.limits.buffered_bytes - self.pending.length() else {
    raise Limit(
      0, "chunk and pending bytes exceed buffered_bytes; feed smaller chunks",
    )
  }
  let joined = @buffer.Buffer::Buffer()
  joined.write_bytes(self.pending[:])
  joined.write_bytes(chunk)
  let bytes = joined.to_bytes()
  self.total_input += chunk.length().to_uint64()
  let messages : Array[Message] = []
  let mut offset = 0
  let mut skipped = 0
  while offset < bytes.length() {
    let remaining = bytes[offset:]
    if self.recover && !marker_matches(remaining, 0, self.framing) {
      let mut next = 1
      while next < remaining.length() &&
            !marker_matches(remaining, next, self.framing) {
        next += 1
      }
      let advance = if next < remaining.length() {
        next
      } else {
        remaining.length() - marker_suffix(remaining, self.framing)
      }
      if advance == 0 {
        break
      }
      self.skip(advance)
      skipped += advance
      offset += advance
      continue
    }
    let size = framed_size(remaining, self.framing, self.limits) catch {
      err => {
        if !self.recover {
          raise err
        }
        self.skip(1)
        skipped += 1
        offset += 1
        continue
      }
    }
    let length = match size {
      None => break
      Some(n) => n
    }
    if remaining.length() < length {
      break
    }
    let decoded = decode(
      remaining[:length],
      framing=self.framing,
      limits=self.limits,
    ) catch {
      err => {
        if !self.recover {
          raise err
        }
        self.skip(1)
        skipped += 1
        offset += 1
        continue
      }
    }
    messages.push(decoded.message)
    self.total_messages += 1UL
    self.consecutive_skipped = 0
    offset += decoded.consumed
  }
  self.pending = bytes[offset:].to_owned()
  { messages, skipped, }
}

///|
/// Maximum accepted chunk plus pending bytes is limits.buffered_bytes.
/// No callback or socket is owned by the decoder, so backpressure stays explicit.
pub fn StreamDecoder::feed(
  self : StreamDecoder,
  chunk : BytesView,
) -> StreamBatch raise DltError {
  guard !self.closed && !self.failed else {
    raise Invalid(0, "stream is closed or failed; reset before feeding")
  }
  errdefer {
    self.failed = true
  }
  self.process(chunk)
}

///|
/// Strict end-of-input: even in recovery mode, a partial candidate is an error.
/// Call discard_tail only when the caller intentionally accepts data loss.
pub fn StreamDecoder::finish(self : StreamDecoder) -> Unit raise DltError {
  guard !self.failed else {
    raise Invalid(0, "stream failed; reset before finishing")
  }
  self.closed = true
  if self.pending.length() != 0 {
    self.failed = true
    raise Truncated(
      self.pending.length(),
      "end of stream inside a message or marker",
    )
  }
}

///|
pub fn StreamDecoder::discard_tail(
  self : StreamDecoder,
) -> Int32 raise DltError {
  guard self.recover && !self.failed && !self.closed else {
    raise Invalid(0, "discard_tail requires an open recovery stream")
  }
  let size = self.pending.length()
  self.skip(size)
  self.pending = b""
  self.closed = true
  size
}

///|
/// Callback based transcode holds at most one output chunk; emit can implement
/// a file, a Web Worker message, or a caller-controlled ring buffer.
pub struct StreamTranscoder {
  decoder : StreamDecoder
  output : Framing
  select : (Message) -> Bool
  transform : (Message) -> Message raise DltError
  emit : (Bytes) -> Unit raise DltError
  mut emitted_messages : UInt64
  mut emitted_bytes : UInt64
  mut failed : Bool
}

///|
pub fn StreamTranscoder::new(
  input : Framing,
  output : Framing,
  emit : (Bytes) -> Unit raise DltError,
  select~ : (Message) -> Bool = _ => true,
  transform~ : (Message) -> Message raise DltError = message => message,
  limits~ : Limits = Limits::default(),
) -> StreamTranscoder raise DltError {
  {
    decoder: StreamDecoder::new(framing=input, limits~),
    output,
    select,
    transform,
    emit,
    emitted_messages: 0UL,
    emitted_bytes: 0UL,
    failed: false,
  }
}

///|
pub fn StreamTranscoder::feed(
  self : StreamTranscoder,
  bytes : BytesView,
) -> Int32 raise DltError {
  guard !self.failed else { raise Invalid(0, "transcoder failed") }
  errdefer {
    self.failed = true
  }
  let batch = self.decoder.feed(bytes)
  let mut emitted = 0
  for message in batch.messages {
    if (self.select)(message) {
      let changed = (self.transform)(message)
      let wire = encode(
        changed,
        framing=self.output,
        limits=self.decoder.limits,
      )
      (self.emit)(wire)
      self.emitted_messages += 1UL
      self.emitted_bytes += wire.length().to_uint64()
      emitted += 1
    }
  }
  emitted
}

///|
pub fn StreamTranscoder::finish(self : StreamTranscoder) -> Unit raise DltError {
  guard !self.failed else { raise Invalid(0, "transcoder failed") }
  self.decoder.finish()
}

///|
pub fn StreamTranscoder::message_count(self : StreamTranscoder) -> UInt64 {
  self.emitted_messages
}

///|
pub fn StreamTranscoder::output_bytes(self : StreamTranscoder) -> UInt64 {
  self.emitted_bytes
}
