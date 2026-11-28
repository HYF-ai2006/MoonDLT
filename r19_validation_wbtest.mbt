///|
test "strict R19 validation distinguishes reserved and user-defined subtypes" {
  let request = control_request_message(GetDefaultTraceStatus, Header::new())
  request.validate_r19()
  guard request.header.extended is Some(e) else {
    fail("missing control header")
  }
  let compatibility = {
    ..request,
    header: { ..request.header, extended: Some({ ..e, argument_count: 1, }), },
  }
  assert_eq(compatibility.control_request(), GetDefaultTraceStatus)
  assert_true(
    try {
      compatibility.validate_r19()
      false
    } catch {
      Invalid(_, _) => true
      _ => false
    },
  )
  let net = Message::new(
    {
      ..request.header,
      extended: Some({ ..e, message_type: 2, subtype: 15, }),
    },
    b"\x01\x00\x00\x00",
  )
  net.validate_r19()
  let reserved = {
    ..net,
    header: {
      ..net.header,
      extended: Some({ ..e, message_type: 1, subtype: 15, }),
    },
  }
  assert_true(
    try {
      reserved.validate_r19()
      false
    } catch {
      Unsupported(_, _) => true
      _ => false
    },
  )
  let storage = net.with_reception(
    seconds=1600000000U,
    microseconds=42U,
    ecu="ECU1",
  )
  let bytes = encode(storage)
  let read = decode_exact(bytes[:])
  assert_eq(
    read.storage,
    Some({ seconds: 1600000000U, microseconds: 42U, ecu: "ECU1", }),
  )
  assert_eq(read.payload, net.payload)
}

///|
test "source location is the first two verbose parameters with the specified VARI names" {
  let items = r19_source_location_parameters("file:///model.c", 42U)
  items.push(TraceInfo(Ascii, "startup"))
  let message = Message::with_wire_parameters(review_header(Little), items)
  message.validate_r19()
  let parameters = message.wire_parameters()
  guard parameters
    is [
      StringParameter(Utf8, "file:///model.c", Some("source_file")),
      Numeric(line),
      TraceInfo(Ascii, "startup"),
    ] else {
    fail("source location and event parameters changed order or kind")
  }
  assert_eq(line.kind, UIntValue(32))
  assert_eq(line.variable, Some({ name: "line_number", unit: Some(""), }))
  assert_eq(line.elements[0].low, 42UL)
  assert_eq(message.header.extended.unwrap().argument_count, 3)
}

///|
test "strict validation checks tree settings even for nonverbose records" {
  let message = control_request_message(GetDefaultTraceStatus, Header::new())
  assert_true(
    try {
      message.validate_r19(budget={ depth: -1, nodes: 1, })
      false
    } catch {
      Invalid(_, _) => true
      _ => false
    },
  )
}
