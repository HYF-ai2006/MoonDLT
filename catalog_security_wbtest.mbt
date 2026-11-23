///|
test "untrusted catalog metadata cannot hide source records from safe queries" {
  let message = sample_message()
  let wire = encode(message)
  let source = Source::from_bytes(wire)
  let catalog = SourceCatalog::build(source)
  let object = match catalog.to_json() {
    Object(value) => value.copy()
    _ => abort("catalog must be an object")
  }
  let records = match object.get("records").unwrap() {
    Array(value) => value.copy()
    _ => abort("catalog records must be an array")
  }
  let record = match records[0] {
    Object(value) => value.copy()
    _ => abort("catalog record must be an object")
  }
  // Preserve the real signature, offsets, lengths and all other metadata.
  record["header"] = { ..message.header, ecu: Some("FAKE"), }.to_json()
  records[0] = Json::object(record)
  object["records"] = Json::array(records)
  let changed = SourceCatalog::from_json(Json::object(object))
  assert_true(
    try {
      ignore(changed.open(source))
      false
    } catch {
      _ => true
    },
  )
  // This explicitly named fast path requires the caller to trust the metadata.
  let trusted = changed.open_trusted(source)
  assert_eq(trusted.query({ ..Filter::all(), ecus: Some(["ECU"]), }), [])
  assert_eq(trusted.query({ ..Filter::all(), ecus: Some(["FAKE"]), }), [0])
  assert_true(
    try {
      ignore(trusted.read(0))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(catalog.open(source).read(0), message)
}

///|
test "empty batch functions validate decoder configuration" {
  let limits = { ..Limits::default(), message_bytes: 0, }
  assert_true(
    try {
      ignore(decode_all(b""[:], limits~))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(encode_all([][:], limits~))
      false
    } catch {
      _ => true
    },
  )
}
