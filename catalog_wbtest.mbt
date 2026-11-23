///|
test "lossless JSON envelope preserves unknown_payload payload and every header" {
  let message = sample_message()
  assert_eq(Message::from_json(message.to_json()), message)
  assert_eq(Header::from_json(message.header.to_json()), message.header)
  let unknown_payload = { ..message, payload: b"\x00\xff\x81\x00", }
  assert_eq(
    Message::from_json(unknown_payload.to_json()).payload,
    unknown_payload.payload,
  )
  assert_true(
    try {
      ignore(Header::from_json({ "endian": "little" }))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(Message::from_json({ "format": "unknown" }))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "persistent catalog reload, metadata query and stale source detection" {
  let messages = [
    sample_message(),
    { ..sample_message(), header: Header::new(), },
  ]
  let bytes = encode_all(messages[:])
  let source = Source::from_bytes(bytes)
  let catalog = SourceCatalog::build(source)
  let loaded = SourceCatalog::from_json(catalog.to_json())
  assert_eq(loaded.length(), 2)
  for offset in 0..<bytes.length() {
    assert_eq(
      loaded.containing(offset.to_uint64()),
      Some(if offset < catalog.entry(0).length { 0 } else { 1 }),
    )
  }
  assert_eq(loaded.containing(bytes.length().to_uint64()), None)
  let opened = loaded.open(source)
  assert_eq(opened.read(1), messages[1])
  assert_eq(opened.select(Filter::all()), messages)
  assert_eq(opened.query({ ..Filter::all(), applications: Some(["APP"]), }), [0])
  assert_true(
    try {
      ignore(opened.select(Filter::all(), payload_budget=0))
      false
    } catch {
      _ => true
    },
  )
  let changed = encode_all([sample_message()][:])
  assert_true(
    try {
      ignore(loaded.open(Source::from_bytes(changed)))
      false
    } catch {
      _ => true
    },
  )
  let result : Array[Message] = []
  assert_eq(
    opened.visit_range(1, 2, message => {
      result.push(message)
      true
    }),
    1,
  )
  assert_eq(result, [messages[1]])
}

///|
test "empty catalog and malformed sidecar fields" {
  let empty = SourceCatalog::build(Source::from_bytes(b""))
  assert_eq(SourceCatalog::from_json(empty.to_json()).length(), 0)
  let json = empty.to_json()
  if json is Object(object) {
    let corrupt = object.copy()
    corrupt["records"] = Json::array([Json::null()])
    assert_true(
      try {
        ignore(SourceCatalog::from_json(Json::object(corrupt)))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(SourceCatalog::build(Source::from_bytes(b""), sample_bytes=0))
      false
    } catch {
      _ => true
    },
  )
}
