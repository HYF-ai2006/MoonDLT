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
