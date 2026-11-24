///|
test "default control services cannot select an implicit default" {
  for endian in [Little, Big] {
    for request in [SetDefaultLogLevel(-1, ""), SetDefaultTraceStatus(-1, "")] {
      assert_true(
        try {
          ignore(encode_control_request(request, endian))
          false
        } catch {
          _ => true
        },
      )
    }
    for service in [17U, 18U] {
      let bytes = @buffer.Buffer::Buffer()
      write_u32(bytes, service, endian)
      bytes.write_bytes(b"\xff\x00\x00\x00\x00"[:])
      assert_true(
        try {
          ignore(decode_control_request(bytes.to_bytes()[:], endian))
          false
        } catch {
          _ => true
        },
      )
    }
    for
      request in [
        SetLogLevel("APP", "CTX", -1, ""),
        SetTraceStatus("APP", "CTX", -1, ""),
      ] {
      assert_eq(
        decode_control_request(
          encode_control_request(request, endian)[:],
          endian,
        ),
        request,
      )
    }
  }
}

///|
test "omitted optional timestamps do not erase the continuity baseline" {
  let tracker = ContinuityTracker::new()
  let msg = sample_message()
  ignore(
    tracker.observe({
      ..msg,
      header: { ..msg.header, counter: 1, timestamp: Some(0xFFFFFFF0U), },
    }),
  )
  let omitted = tracker.observe({
    ..msg,
    header: { ..msg.header, counter: 2, timestamp: None, },
  })
  assert_eq(omitted.extended_timestamp, None)
  assert_eq(omitted.events, [])
  let wrapped = tracker.observe({
    ..msg,
    header: { ..msg.header, counter: 3, timestamp: Some(32U), },
  })
  assert_eq(wrapped.extended_timestamp, Some(4294967328UL))
  assert_eq(wrapped.events, [TimestampWrapped(0xFFFFFFF0U, 32U)])
}

///|
test "omitted optional session does not invent an ECU restart" {
  let tracker = ContinuityTracker::new()
  let msg = sample_message()
  ignore(
    tracker.observe({
      ..msg,
      header: { ..msg.header, counter: 1, timestamp: Some(0xFFFFFFF0U), },
    }),
  )
  let omitted = tracker.observe({
    ..msg,
    header: { ..msg.header, counter: 2, session: None, timestamp: Some(32U), },
  })
  assert_eq(omitted.extended_timestamp, Some(4294967328UL))
  assert_eq(omitted.events, [TimestampWrapped(0xFFFFFFF0U, 32U)])
  let resumed = tracker.observe({
    ..msg,
    header: { ..msg.header, counter: 3, timestamp: Some(64U), },
  })
  assert_eq(resumed.extended_timestamp, Some(4294967360UL))
  assert_eq(resumed.events, [])
  let restarted = tracker.observe({
    ..msg,
    header: {
      ..msg.header,
      counter: 0,
      session: Some(99U),
      timestamp: Some(1U),
    },
  })
  assert_eq(restarted.extended_timestamp, Some(1UL))
  assert_eq(restarted.events, [SessionChanged(msg.header.session, Some(99U))])
}

///|
test "missing reception metadata does not erase wall clock continuity" {
  let tracker = ContinuityTracker::new()
  let msg = sample_message()
  ignore(
    tracker.observe({
      ..msg,
      storage: Some({ seconds: 2U, microseconds: 0U, ecu: "ECU", }),
      header: { ..msg.header, counter: 1, },
    }),
  )
  ignore(
    tracker.observe({
      ..msg,
      storage: None,
      header: { ..msg.header, counter: 2, },
    }),
  )
  let reversed = tracker.observe({
    ..msg,
    storage: Some({ seconds: 1U, microseconds: 0U, ecu: "ECU", }),
    header: { ..msg.header, counter: 3, },
  })
  assert_eq(reversed.events, [ReceptionBackwards(2000000UL, 1000000UL)])
}
