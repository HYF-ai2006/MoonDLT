///|
fn tools_message(
  counter : Int32,
  seconds : UInt32,
  app : String,
  level : Int32,
) -> Message {
  {
    storage: Some({ seconds, microseconds: 0U, ecu: "ECU", }),
    header: {
      endian: Little,
      counter,
      ecu: None,
      session: None,
      timestamp: None,
      extended: Some({
        verbose: false,
        message_type: 0,
        subtype: level,
        argument_count: 0,
        application: app,
        context: "CTX",
      }),
    },
    payload: b"\x78\x56\x34\x12",
  }
}

///|
fn tools_dictionary() -> Dictionary raise DltError {
  let dictionary = Dictionary::new()
  dictionary.register({
    key: { application: "APP", context: "CTX", message_id: 0x12345678U, },
    fields: [
      { name: "temperature", kind: SignedInteger(16), unit: Some("degC"), },
      { name: "name", kind: FixedText(Ascii, 4), unit: None, },
      { name: "active", kind: Flag, unit: None, },
    ],
  })
  dictionary
}

///|
test "control request exact v1 golden bytes and both payload endians" {
  let request = ControlRequest::SetLogLevel("APP", "CTX", 4, "")
  let little = encode_control_request(request, Little)
  let big = encode_control_request(request, Big)
  assert_eq(hex_encode(little[:]), "0100000041505000435458000400000000")
  assert_eq(hex_encode(big[:]), "0000000141505000435458000400000000")
  assert_eq(decode_control_request(little[:], Little), request)
  assert_eq(decode_control_request(big[:], Big), request)
  let info = hex_decode("03000000074150500043545800434f4d00")
  assert_eq(
    decode_control_request(info[:], Little),
    GetLogInfo(7, "APP", "CTX", "COM"),
  )
  for n in 0..<little.length() {
    assert_true(
      try {
        ignore(decode_control_request(little[:n], Little))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "all typed controls roundtrip with strict body and value validation" {
  let requests : Array[ControlRequest] = [
    SetLogLevel("", "", -1, "CAN"),
    SetTraceStatus("APP", "CTX", 1, ""),
    SetTraceStatus("APP", "CTX", -1, ""),
    GetLogInfo(3, "", "", ""),
    GetDefaultLogLevel,
    StoreConfiguration,
    ResetConfiguration,
    SetDefaultLogLevel(0, ""),
    SetDefaultTraceStatus(0, ""),
    GetSoftwareVersion,
    Unknown(0x12345678U, b"\x00\xff"),
  ]
  for endian in [Little, Big] {
    for request in requests {
      let bytes = encode_control_request(request, endian)
      assert_eq(decode_control_request(bytes[:], endian), request)
    }
  }
  for
    request in [
      SetLogLevel("APP", "CTX", 7, ""),
      SetTraceStatus("APP", "CTX", 2, ""),
      GetLogInfo(2, "", "", ""),
      SetDefaultLogLevel(-2, ""),
      Unknown(19U, b""),
      SetLogLevel("TOOLONG", "CTX", 1, ""),
    ] {
    assert_true(
      try {
        ignore(encode_control_request(request, Little))
        false
      } catch {
        _ => true
      },
    )
  }
  let trailing = hex_decode("1300000000")
  assert_true(
    try {
      ignore(decode_control_request(trailing[:], Little))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "control responses preserve unusual status and parse software version length" {
  let unusual : ControlResponse = {
    service_id: 3U,
    status: 7,
    data: b"\x00\xff",
  }
  let encoded = encode_control_response(unusual, Little)
  assert_eq(decode_control_response(encoded[:], Little), unusual)
  for endian in [Little, Big] {
    let response = software_version_response("ECU 1.2", endian)
    assert_eq(response.software_version(endian), "ECU 1.2")
    let payload = encode_control_response(response, endian)
    assert_eq(decode_control_response(payload[:], endian), response)
  }
  let terminated : ControlResponse = {
    service_id: 19U,
    status: 0,
    data: b"\x04\x00\x00\x00v1!\x00",
  }
  assert_eq(terminated.software_version(Little), "v1!")
  let bad : ControlResponse = {
    service_id: 19U,
    status: 0,
    data: b"\x03\x00\x00\x00v1!\x00",
  }
  assert_true(
    try {
      ignore(bad.software_version(Little))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(terminated.software_version(Little, maximum_bytes=3))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    ({ service_id: 4U, status: 0, data: b"\x04", } : ControlResponse).default_log_level(),
    4,
  )
}

///|
test "control message header classification prevents payload confusion" {
  let request = control_request_message(GetSoftwareVersion, Header::new())
  assert_eq(request.control_request(), GetSoftwareVersion)
  assert_true(
    try {
      ignore(request.control_response())
      false
    } catch {
      _ => true
    },
  )
  let response = control_response_message(
    software_version_response("v1", Little),
    Header::new(),
  )
  assert_eq(response.control_response().software_version(Little), "v1")
  assert_true(
    try {
      ignore(tools_message(0, 0U, "APP", 4).control_request())
      false
    } catch {
      _ => true
    },
  )
}

///|
test "explicit nonverbose dictionary golden fixed fields and exact length" {
  let dictionary = tools_dictionary()
  let msg = {
    ..tools_message(0, 0U, "APP", 4),
    payload: b"\x78\x56\x34\x12\xfe\xffab\x00\x00\x01",
  }
  let values = dictionary.decode(msg)
  assert_eq(values, [
    { name: "temperature", unit: Some("degC"), value: Signed(16, -2L), },
    { name: "name", unit: None, value: Text(Ascii, "ab"), },
    { name: "active", unit: None, value: Boolean(true), },
  ])
  assert_eq(dictionary.encode(msg.schema_key(), values[:], Little), msg.payload)
  let big = dictionary.encode(msg.schema_key(), values[:], Big)
  assert_eq(hex_encode(big[:]), "12345678fffe6162000001")
  assert_eq(
    dictionary.decode({
      ..msg,
      header: { ..msg.header, endian: Big, },
      payload: big,
    }),
    values,
  )
  for n in 0..<msg.payload.length() {
    assert_true(
      try {
        ignore(
          dictionary.decode({ ..msg, payload: msg.payload[:n].to_owned(), }),
        )
        false
      } catch {
        _ => true
      },
    )
  }
  let unknown = { ..msg, payload: b"\x00\x00\x00\x00", }
  assert_true(
    try {
      ignore(dictionary.decode(unknown))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "dictionary validates registration aliases, bounds, field values and text padding" {
  let dictionary = tools_dictionary()
  let schema = dictionary
    .lookup({ application: "APP", context: "CTX", message_id: 0x12345678U, })
    .unwrap()
  schema.fields.clear()
  assert_eq(dictionary.lookup(schema.key).unwrap().fields.length(), 3)
  assert_true(
    try {
      dictionary.register(schema)
      false
    } catch {
      _ => true
    },
  )
  let empty = Dictionary::new(capacity=0)
  assert_true(
    try {
      empty.register({ key: schema.key, fields: [], })
      false
    } catch {
      _ => true
    },
  )
  let badfields = [{ name: "x", kind: SignedInteger(24), unit: None, }]
  assert_true(
    try {
      empty.register({ key: schema.key, fields: badfields, })
      false
    } catch {
      _ => true
    },
  )
  let bad = {
    ..tools_message(0, 0U, "APP", 4),
    payload: b"\x78\x56\x34\x12\xfe\xffa\x00b\x00\x01",
  }
  assert_true(
    try {
      ignore(dictionary.decode(bad))
      false
    } catch {
      _ => true
    },
  )
  assert_true(dictionary.remove(schema.key))
  assert_true(!dictionary.remove(schema.key))
  assert_eq(dictionary.length(), 0)
}

///|
test "dictionary portable JSON preserves semantics and rejects unknown properties" {
  let original = tools_dictionary()
  let restored = Dictionary::from_json(original.to_json())
  assert_eq(restored.to_json(), original.to_json())
  assert_eq(restored.length(), 1)
  let invalid = Json::object(
    Map([
      ("format", Json::string("moondlt-nonverbose")),
      ("version", Json::number(1.0)),
      ("schemas", Json::array([])),
      ("ignored_typo", Json::boolean(true)),
    ]),
  )
  assert_true(
    try {
      ignore(Dictionary::from_json(invalid))
      false
    } catch {
      _ => true
    },
  )
  let badversion = Json::object(
    Map([
      ("format", Json::string("moondlt-nonverbose")),
      ("version", Json::number(1.5)),
      ("schemas", Json::array([])),
    ]),
  )
  assert_true(
    try {
      ignore(Dictionary::from_json(badversion))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(Dictionary::from_json(original.to_json(), capacity=0))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "query indices preserve source offsets and reject stale headers" {
  let first = tools_message(1, 10U, "APP", 4)
  let second = tools_message(2, 20U, "SYS", 2)
  let bytes = encode_messages([first, second][:])
  let index = build_index(bytes[:])
  assert_eq(index.length(), 2)
  assert_eq(index[0].offset, 0)
  assert_eq(index[1].offset, encode(first).length())
  let filter = {
    ..Filter::all(),
    applications: Some(["SYS"]),
    maximum_log_level: Some(2),
    minimum_time: Some(15000000UL),
  }
  let selected = query_index(index[:], filter)
  assert_eq(selected.length(), 1)
  assert_eq(extract_indexed(bytes[:], selected[:]), [second])
  assert_eq(copy_indexed(bytes[:], selected[:]), encode(second))
  let stale = [{ ..index[0], header: { ..index[0].header, counter: 99, }, }]
  assert_true(
    try {
      ignore(extract_indexed(bytes[:], stale[:]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(copy_indexed(bytes[:], selected[:], maximum_bytes=1))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(build_index(bytes[:], max_entries=1))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "filters distinguish absent metadata from explicit empty lists and log levels" {
  let msg = tools_message(1, 10U, "APP", 4)
  assert_true(Filter::all().matches(msg))
  assert_true(!({ ..Filter::all(), ecus: Some([]), } : Filter).matches(msg))
  assert_true(({ ..Filter::all(), ecus: Some(["ECU"]), } : Filter).matches(msg))
  assert_true(
    !({ ..Filter::all(), maximum_log_level: Some(3), } : Filter).matches(msg),
  )
  let absent = { ..msg, storage: None, header: Header::new(), }
  assert_true(
    !({ ..Filter::all(), minimum_time: Some(0UL), } : Filter).matches(absent),
  )
  assert_true(
    ({ ..Filter::all(), verbose: Some(false), } : Filter).matches(absent),
  )
  assert_eq(filter_messages([msg][:], Filter::all(), limit=0), [])
  assert_true(
    try {
      ignore(
        ({ ..Filter::all(), maximum_log_level: Some(7), } : Filter).matches(msg),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "merge uses wall clock and deterministic input tie ordering" {
  let a = tools_message(1, 20U, "A", 4)
  let b = tools_message(2, 10U, "B", 4)
  let c = tools_message(3, 20U, "C", 4)
  assert_eq(merge_messages([[a], [b, c]][:]), [b, a, c])
  assert_true(
    try {
      ignore(merge_messages([[a]][:], maximum_messages=0))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(merge_messages([[{ ..a, storage: None, }]][:]))
      false
    } catch {
      _ => true
    },
  )
}
