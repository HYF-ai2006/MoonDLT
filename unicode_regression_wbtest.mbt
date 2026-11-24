///|
test "invalid UTF-16 text is rejected consistently across protocol entry points" {
  let text = "🙂"
  let high = text.unsafe_substring(start=0, end=1)
  let low = text.unsafe_substring(start=1, end=2)
  for invalid in [high, low, high + "A", low + high] {
    assert_true(
      try {
        ignore(hex_decode(invalid))
        false
      } catch {
        _ => true
      },
    )
    assert_true(
      try {
        ignore(software_version_response(invalid, Little))
        false
      } catch {
        _ => true
      },
    )
    assert_true(
      try {
        ignore(FilterExpr::parse(invalid))
        false
      } catch {
        _ => true
      },
    )
    assert_true(
      try {
        ({ ..Filter::all(), ecus: Some([invalid]), } : Filter).validate()
        false
      } catch {
        _ => true
      },
    )
    assert_true(
      try {
        write_id(@buffer.Buffer::Buffer(), invalid)
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(
    encode_text_checked("éΩ🙂", max_bytes=8),
    @utf8.encode("éΩ🙂"),
  )
  assert_true(
    try {
      ignore(encode_text_checked("éΩ🙂", max_bytes=7))
      false
    } catch {
      _ => true
    },
  )
  let dictionary = Dictionary::new()
  let key = { application: "A", context: "C", message_id: 1U, }
  dictionary.register({
    key,
    fields: [{ name: "text", unit: None, kind: FixedText(Utf8, 8), }],
  })
  assert_true(
    try {
      ignore(
        dictionary.encode(
          key,
          [{ name: "text", unit: None, value: Text(Utf8, high), }][:],
          Little,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}
