///|
test "header expressions preserve precedence, clock units and missing field semantics" {
  let message = sample_message()
  for
    text in [
      "apid == \"APP\" && level <= 4", "counter == 255 && session == 305419896",
      "time_us == 1000002 && timestamp == 2882400001", "verbose == true || counter == 255",
      "!(ecu == \"NOPE\") && storage_ecu == \"ECU\"", "true || false && false", "(false || true) && !false",
    ] {
    assert_true(FilterExpr::parse(text).matches(message))
  }
  for
    text in [
      "apid != \"APP\"", "level > 4", "counter < 255", "session != 305419896", "(true || false) && false",
    ] {
    assert_true(!FilterExpr::parse(text).matches(message))
  }
  let absent = { ..message, storage: None, header: Header::new(), }
  assert_true(!FilterExpr::parse("apid != \"APP\"").matches(absent))
  assert_true(FilterExpr::parse("!(apid == \"APP\")").matches(absent))
  assert_true(FilterExpr::parse("verbose == false").matches(absent))
  let quoted = { ..message, header: { ..message.header, ecu: Some("A\"B"), }, }
  assert_true(FilterExpr::parse("ecu == \"A\\\"B\"").matches(quoted))
}

///|
test "expression parser rejects malformed syntax, wrong types and out of domain literals" {
  for
    text in [
      "", "()", "true false", "apid", "apid = \"APP\"", "apid == APP", "unknown == 1",
      "counter == -1", "counter == 256", "counter == 1.5", "counter == 18446744073709551616",
      "counter == true", "verbose == 1", "ecu > \"A\"", "level == 7", "ecu == \"TOOLONG\"",
      "true & false", "true | false", "(true", "true)", "!", "ecu == \"unclosed",
      "ecu == \"\\q\"", "true &&",
    ] {
    assert_true(
      try {
        ignore(FilterExpr::parse(text))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "expression parsing and manual AST evaluation enforce independent budgets" {
  let defaults = ExpressionLimits::default()
  for
    limits in [
      { ..defaults, input_bytes: 3, },
      { ..defaults, tokens: 1, },
      { ..defaults, nodes: 0, },
      { ..defaults, depth: 0, },
    ] {
    assert_true(
      try {
        ignore(FilterExpr::parse("true", limits~))
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      ignore(
        FilterExpr::parse("true || false", limits={ ..defaults, nodes: 2, }),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(FilterExpr::parse("!!!true", limits={ ..defaults, depth: 3, }))
      false
    } catch {
      _ => true
    },
  )
  let mut expression = FilterExpr::Constant(true)
  for _ in 0..<33 {
    expression = Negation(expression)
  }
  assert_true(
    try {
      ignore(expression.matches(sample_message()))
      false
    } catch {
      _ => true
    },
  )
  let entries = build_index(
    encode_all([sample_message(), sample_message()][:])[:],
  )
  assert_eq(
    query_expression(entries[:], FilterExpr::parse("counter == 255"), limit=1).length(),
    1,
  )
  assert_eq(query_expression(entries[:], FilterExpr::Constant(true), limit=0), [])
}
