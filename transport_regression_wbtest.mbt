///|
test "copy selected rejects a valid replacement with different selected metadata" {
  let original = sample_message()
  let replacement = {
    ..original,
    header: { ..original.header, ecu: Some("BAD"), },
  }
  let original_wire = encode(original)
  let replacement_wire = encode(replacement)
  assert_eq(original_wire.length(), replacement_wire.length())
  let emitted : Array[Bytes] = []
  let source = Source::new(original_wire.length().to_uint64(), (offset, length) => {
    // A changing callback supplies the selected header, then a different valid record.
    if length == original_wire.length() {
      replacement_wire
    } else {
      original_wire[offset.to_int():offset.to_int() + length].to_owned()
    }
  })
  assert_true(
    try {
      ignore(
        source.copy_selected(entry => entry.header.ecu == Some("ECU"), bytes => {
          emitted.push(bytes)
        }),
      )
      false
    } catch {
      Invalid(_, _) => true
      other => raise other
    },
  )
  assert_eq(emitted.length(), 0)
}

///|
test "empty indexed selections and ranges still reject invalid decoder limits" {
  let source = Source::from_bytes(b"")
  let opened = SourceCatalog::build(source).open(source)
  let invalid = { ..Limits::default(), message_bytes: 0, }
  assert_true(
    try {
      ignore(opened.select(Filter::all(), limits=invalid))
      false
    } catch {
      Invalid(_, _) => true
      other => raise other
    },
  )
  assert_true(
    try {
      ignore(opened.visit_range(0, 0, _ => true, limits=invalid))
      false
    } catch {
      Invalid(_, _) => true
      other => raise other
    },
  )
}
