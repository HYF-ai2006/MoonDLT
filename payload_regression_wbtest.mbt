///|
test "JSON scalar decoding respects the complete encoded argument byte budget" {
  let limits = { ..Limits::default(), message_bytes: 4, }
  assert_true(
    try {
      ignore(Argument::from_json({ "kind": "bool", "value": true }, limits~))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "logical values reject malformed typed parameters before numerical analysis" {
  for
    parameter in [
      VerboseParameter::scalar(Signed(8, 128L)),
      VerboseParameter::scalar(Floating(16, 1.0)),
      VerboseParameter::scalar(Boolean(true), scaling={
        quantization: Float::from_double(1.0),
        offset: 1L,
      }),
      VerboseParameter::array(IntValue(8), [2, 2], [Signed(8, 1L)]),
      VerboseParameter::array(IntValue(8), [1], [Unsigned(8, 1UL)]),
    ] {
    assert_true(
      try {
        ignore(parameter.logical_values())
        false
      } catch {
        _ => true
      },
    )
  }
  let value = 1.1
  assert_eq(VerboseParameter::scalar(Floating(32, value)).logical_values(), [
    Float::from_double(value).to_double(),
  ])
}

///|
fn regression_verbose_header() -> Header {
  {
    ..Header::new(),
    extended: Some({
      verbose: true,
      message_type: 0,
      subtype: 4,
      argument_count: 0,
      application: "APP",
      context: "CTX",
    }),
  }
}

///|
test "verbose message builders reserve the full wire header byte budget" {
  let limits = { ..Limits::default(), message_bytes: 40, }
  let header = regression_verbose_header()
  let argument = Text(Ascii, "01234567890123456789")
  assert_true(
    try {
      ignore(Message::with_arguments(header, [argument], limits~))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(
        Message::with_parameters(
          header,
          [VerboseParameter::scalar(argument)],
          limits~,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
  let exact = Raw(b"01234567890123456789")
  let built = Message::with_arguments(header, [exact], limits~)
  assert_eq(encode(built, framing=Network, limits~).length(), 40)
}

///|
test "verbose message builders reject invalid header and storage metadata" {
  let header = { ..regression_verbose_header(), counter: 256, }
  assert_true(
    try {
      ignore(Message::with_arguments(header, []))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(Message::with_parameters(header, []))
      false
    } catch {
      _ => true
    },
  )
  let storage = { seconds: 0U, microseconds: 1000000U, ecu: "E", }
  assert_true(
    try {
      ignore(Message::with_arguments(regression_verbose_header(), [], storage~))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "UTF-16 surrogate errors are rejected before platform UTF-8 encoding" {
  let high = "🙂".unsafe_substring(start=0, end=1)
  let low = "🙂".unsafe_substring(start=1, end=2)
  for value in [high, low, high + "x"] {
    assert_true(
      try {
        ignore(encode_arguments([Text(Utf8, value)], Little))
        false
      } catch {
        _ => true
      },
    )
    assert_true(
      try {
        ignore(
          Argument::from_json({
            "kind": "text",
            "encoding": "utf8",
            "value": value,
          }),
        )
        false
      } catch {
        _ => true
      },
    )
  }
  let limits = { ..Limits::default(), string_bytes: 4, }
  assert_true(
    try {
      ignore(encode_arguments([Text(Utf8, "🙂")], Little, limits~))
      false
    } catch {
      _ => true
    },
  )
  let argument = Text(Utf8, "🙂")
  assert_eq(
    decode_arguments(encode_arguments([argument], Little)[:], 1, Little),
    [argument],
  )
}
