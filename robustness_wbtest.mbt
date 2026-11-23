///|
test "hostile standard header matrix is bounded and never reads outside datagram" {
  for flags in 0..<256 {
    for advertised in [0, 3, 4, 26, 64, 255, 256, 65535] {
      let out = @buffer.Buffer::Buffer()
      out.write_byte(flags.to_byte())
      out.write_byte(b'\xff')
      write_u16(out, advertised, Big)
      for _ in 4..<256 {
        out.write_byte(b'\x00')
      }
      let bytes = out.to_bytes()
      try {
        let decoded = decode(bytes[:], framing=Network)
        assert_true(decoded.consumed >= decoded.message.header.wire_size())
        assert_true(decoded.consumed <= bytes.length())
        assert_eq(decoded.consumed, advertised)
      } catch {
        Invalid(_, _) | Truncated(_, _) | Unsupported(_, _) | Limit(_, _) => ()
        other => raise other
      }
    }
  }
}

///|
test "unsuccessful mixed stream batch poisons until explicit reset" {
  let wire = encode(sample_message())
  let joined = @buffer.Buffer::Buffer()
  joined.write_bytes(wire[:])
  joined.write_bytes(
    b"BAD!\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x04"[:],
  )
  let decoder = StreamDecoder::new()
  assert_true(
    try {
      ignore(decoder.feed(joined.to_bytes()[:]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(decoder.is_failed())
  assert_true(
    try {
      ignore(decoder.feed(wire[:]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      decoder.finish()
      false
    } catch {
      _ => true
    },
  )
  decoder.reset()
  assert_eq(decoder.message_count(), 0UL)
  assert_eq(decoder.input_bytes(), 0UL)
  assert_eq(decoder.feed(wire[:]).messages.length(), 1)
  decoder.finish()
}

///|
test "consecutive recovery budget survives chunk splits and resets after good messages" {
  let limits = { ..Limits::default(), resync_bytes: 3, }
  let decoder = StreamDecoder::new(limits~, recover=true)
  assert_eq(decoder.feed(b"xx"[:]).skipped, 2)
  assert_true(
    try {
      ignore(decoder.feed(b"xx"[:]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(decoder.is_failed())
  let recovery = StreamDecoder::new(limits~, recover=true)
  let wire = encode(sample_message())
  for _ in 0..<3 {
    assert_eq(recovery.feed(b"xxx"[:]).skipped, 3)
    assert_eq(recovery.feed(wire[:]).messages.length(), 1)
  }
  recovery.finish()
  assert_eq(recovery.skipped_bytes(), 9UL)
  assert_eq(recovery.message_count(), 3UL)
}

///|
test "source validates short long callbacks and forged index metadata" {
  let wire = encode(sample_message())
  for surplus in [-1, 1] {
    let source = Source::new(wire.length().to_uint64(), (_, length) => {
      Bytes::from_array(Array::make(length + surplus, b'\x00'))
    })
    let cursor = SourceCursor::new(source)
    assert_true(
      try {
        ignore(cursor.next_entry())
        false
      } catch {
        _ => true
      },
    )
    assert_eq(cursor.position(), 0UL)
    assert_eq(cursor.entry_count(), 0UL)
  }
  let source = Source::from_bytes(wire)
  let entry = source.catalog()[0]
  for
    forged in [
      { ..entry, offset: 0xFFFFFFFFFFFFFFFFUL, },
      { ..entry, payload_offset: entry.payload_offset + 1UL, },
      { ..entry, payload_length: entry.payload_length + 1, },
      { ..entry, header: { ..entry.header, counter: 0, }, },
      { ..entry, length: 0, },
    ] {
    assert_true(
      try {
        ignore(source.read_entry(forged))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "window source checks boundaries and serves stable overlapping ranges" {
  let bytes = b"0123456789abcdefghijklmnopqrstuvwxyz"
  let window = WindowSource::new(Source::from_bytes(bytes), window_bytes=8)
  assert_eq(window.read(4UL, 3), b"456")
  assert_eq(window.read(5UL, 6), b"56789a")
  assert_eq(window.cache_hits(), 1UL)
  assert_eq(window.backing_reads(), 1UL)
  assert_eq(window.read(35UL, 1), b"z")
  assert_eq(window.read(36UL, 0), b"")
  assert_true(
    try {
      ignore(window.read(36UL, 1))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(window.read(0xFFFFFFFFFFFFFFFFUL, 1))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(window.read(0UL, -1))
      false
    } catch {
      _ => true
    },
  )
  window.invalidate()
  assert_eq(window.read(0UL, bytes.length()), bytes)
  assert_eq(window.backing_reads(), 3UL)
}
