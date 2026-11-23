///|
test "range scanner reads metadata without payload and verifies selected entries" {
  let msg = sample_message()
  let bytes = encode_all([msg, msg][:])
  let reads : Array[(UInt64, Int32)] = []
  let source = Source::new(bytes.length().to_uint64(), (offset, length) => {
    reads.push((offset, length))
    bytes[offset.to_int():offset.to_int() + length].to_owned()
  })
  let catalog = source.catalog()
  assert_eq(catalog.length(), 2)
  let mut total = 0
  for (_, length) in reads {
    total += length
  }
  assert_eq(total, 84)
  assert_eq(source.read_entry(catalog[1]), msg)
  let forged = { ..catalog[0], payload_length: 0, }
  assert_true(
    try {
      ignore(source.read_entry(forged))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "64-bit offsets without allocating a large file" {
  let wire = encode(sample_message())
  let base = 0x100000000UL
  let source = Source::new(base + wire.length().to_uint64(), (offset, length) => {
    guard offset >= base else {
      raise Invalid(0, "unexpected read before virtual recording")
    }
    wire[(offset - base).to_int():(offset - base).to_int() + length].to_owned()
  })
  let cursor = SourceCursor::new(source, start=base)
  let entry = cursor.next_entry().unwrap()
  assert_eq(entry.offset, base)
  assert_eq(source.read_entry(entry), sample_message())
  assert_eq(cursor.next_entry(), None)
}

///|
test "short source callbacks and entry budget reject safely" {
  let bytes = encode(sample_message())
  let short = Source::new(100UL, (_, _) => b"x")
  assert_true(
    try {
      ignore(short.catalog())
      false
    } catch {
      _ => true
    },
  )
  let source = Source::from_bytes(bytes)
  assert_true(
    try {
      ignore(source.catalog(max_entries=0))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(source.verify(), 1UL)
  assert_eq(source.visit(_ => false), 1UL)
}

///|
test "read-through cache bounded reads and invalidation" {
  let bytes = encode_all([sample_message(), sample_message()][:])
  let cached = WindowSource::new(Source::from_bytes(bytes), window_bytes=32)
  assert_eq(cached.read(0UL, 20), bytes[:20].to_owned())
  assert_eq(cached.read(4UL, 8), bytes[4:12].to_owned())
  assert_eq(cached.backing_reads(), 1UL)
  assert_eq(cached.cache_hits(), 1UL)
  assert_eq(cached.read(40UL, 40), bytes[40:80].to_owned())
  assert_eq(cached.backing_reads(), 2UL)
  cached.invalidate()
  assert_eq(cached.read(4UL, 8), bytes[4:12].to_owned())
  assert_eq(cached.backing_reads(), 3UL)
  assert_eq(cached.as_source().catalog().length(), 2)
}
