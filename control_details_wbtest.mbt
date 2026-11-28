///|
test "R19-11 extra passive service requests keep fields and canonical NOAR" {
  let vectors : Array[(ControlRequest, String)] = [
    (SetMessageFiltering(true), "0000000a01"),
    (GetDefaultTraceStatus, "00000015"),
    (GetLogChannelNames, "00000017"),
    (GetTraceStatus("APP", "CTL"), "0000001f4150500043544c00"),
    (
      SetLogChannelAssignment("APP", "CTL", "CH1", false),
      "000000204150500043544c004348310000",
    ),
    (SetLogChannelThreshold("CH1", 6, true), "00000021434831000601"),
    (GetLogChannelThreshold("CH1"), "0000002243483100"),
  ]
  for (request, hex) in vectors {
    let bytes = encode_control_request(request, Big)
    assert_eq(hex_encode(bytes[:]), hex)
    for endian in [Little, Big] {
      let frame = control_request_message(request, Header::new(endian~))
      guard frame.header.extended is Some(ext) else {
        fail("missing control header")
      }
      assert_eq(ext.argument_count, 0)
      let raw = encode(frame, framing=Network)
      assert_eq(
        decode_exact(raw[:], framing=Network).control_request(),
        request,
      )
    }
  }
  let invalid = hex_decode("00000021434831000602")
  assert_true(
    try {
      ignore(decode_control_request(invalid[:], Big))
      false
    } catch {
      Invalid(9, _) => true
      _ => false
    },
  )
}

///|
test "R19-11 GetLogInfo list and nested descriptions are length checked" {
  for
    (endian, hex) in [
      (Big, "0000000307000141505000000143544c00040100017800017900000000"),
      (Little, "0300000007010041505000010043544c00040101007801007900000000"),
    ] {
    let apps : Array[ControlApplicationInfo] = [
      {
        id: "APP",
        description: Some(b"y"),
        contexts: [
          { id: "CTL", level: 4, trace: true, description: Some(b"x"), },
        ],
      },
    ]
    let response = log_information_response(apps, descriptions=true, endian)
    let payload = encode_control_response(response, endian)
    assert_eq(hex_encode(payload[:]), hex)
    assert_eq(response.interpret(endian), LogInformation(apps))
    let h = control_header(Header::new(endian~), 2)
    guard h.extended is Some(ext) else { fail("missing response header") }
    let msg = response.standard_message(Header::new(endian~))
    guard msg.header.extended is Some(canonical) else {
      fail("missing status 7 header")
    }
    assert_eq(canonical, { ..ext, verbose: true, argument_count: 1, })
    assert_eq(msg.standard_control_response(), response)
    assert_true(
      try {
        ignore(Message::new(h, payload).standard_control_response())
        false
      } catch {
        Invalid(_, _) => true
        _ => false
      },
    )
    for prefix in 0..<response.data.length() {
      let truncated = { ..response, data: response.data[:prefix].to_owned(), }
      assert_true(
        try {
          ignore(truncated.interpret(endian))
          false
        } catch {
          _ => true
        },
      )
    }
  }
  let no_text = [
    {
      id: "APP",
      description: None,
      contexts: [{ id: "CTL", level: 0, trace: false, description: None, }],
    },
  ]
  assert_eq(
    log_information_response(no_text, descriptions=false, Big).interpret(Big),
    LogInformation(no_text),
  )
}

///|
test "standard control notifications decode wire timestamp and overflow count" {
  for
    (hex, expected) in [
      ("000000240000000005012345670002", SynchronizedTime(0x000201234567UL, 5U)),
      ("0000002300ffffffff", OverflowCount(0xffffffffU)),
      ("0000001700024348310043483200", LogChannels(["CH1", "CH2"])),
      ("00000022000601", LogChannelThreshold(6, true)),
      ("000000150000", TraceStatusValue(false)),
      ("0000001502", ErrorStatus(2)),
    ] {
    let bytes = hex_decode(hex)
    let response = decode_control_response(bytes[:], Big)
    assert_eq(response.interpret(Big), expected)
    assert_eq(expected.response(response.service_id, Big), response)
    assert_eq(
      expected.response(response.service_id, Little).interpret(Little),
      expected,
    )
  }
}

///|
test "canonical controls ignore reserved inbound bytes and write zero" {
  let request = SetLogLevel("APP", "CTL", 3, "COM")
  let canonical = request.standard_message(Header::new(endian=Big))
  assert_eq(
    hex_encode(canonical.payload[:]),
    "000000014150500043544c000300000000",
  )
  let capture = hex_decode("000000014150500043544c0003ffef8300")
  let decoded = Message::new(canonical.header, capture)
  assert_eq(
    decoded.standard_control_request(),
    SetLogLevel("APP", "CTL", 3, ""),
  )
  let reserved_option = GetLogInfo(1, "", "", "").standard_message(
    Header::new(),
  )
  assert_eq(
    reserved_option.standard_control_request(),
    GetLogInfo(1, "", "", ""),
  )
}

///|
test "R19 control preflight distinguishes busy, deprecated, unknown and dispatchable" {
  assert_eq(r19_request_status(GetDefaultTraceStatus, busy=true), 2)
  assert_eq(
    r19_request_status(GetDefaultTraceStatus, valid_configuration=false),
    2,
  )
  assert_eq(r19_request_status(GetDefaultTraceStatus), 0)
  assert_eq(r19_request_status(Unknown(9U, b"")), 1)
  assert_eq(r19_request_status(Unknown(123U, b"")), 2)
  assert_eq(r19_request_status(SetMessageFiltering(false)), 1)
  assert_eq(
    r19_request_status(SetMessageFiltering(false), filtering_supported=true),
    0,
  )
  assert_eq(r19_request_status(GetLogInfo(2, "", "", "")), 1)
}
