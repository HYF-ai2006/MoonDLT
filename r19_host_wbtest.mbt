///|
fn r19_test_config() -> R19HostConfig {
  let base : R19ContextConfig = {
    application: "MTR",
    context: "PWR",
    log_level: None,
    trace: None,
    channels: ["LOG1"],
    application_description: b"motor",
    context_description: b"power",
  }
  {
    default_log_level: 3,
    default_trace: false,
    filtering: true,
    channels: [
      { name: "LOG1", log_level: 6, trace: true, },
      { name: "LOG2", log_level: 2, trace: false, },
    ],
    contexts: [
      base,
      { ..base, context: "TEMP", context_description: b"temperature", },
      {
        ..base,
        application: "INV",
        application_description: b"inverter",
        log_level: Some(1),
      },
    ],
  }
}

///|
test "R19 host applies wildcard, default, channel and persistence changes" {
  let options = { ..R19HostOptions::default(), filtering_supported: true, }
  let initial = r19_test_config()
  let host = R19Host::new(initial, software_version="simulator", options~)
  initial.contexts[0].channels.clear()
  assert_eq(host.configuration().contexts[0].channels, ["LOG1"])
  let one = host.control(SetLogLevel("MTR", "", 5, ""), Big)
  assert_eq(one.response.interpret(Big), Ack)
  assert_eq(one.changed, [
    { application: "MTR", context: "PWR", log_level: 5, trace: false, },
    { application: "MTR", context: "TEMP", log_level: 5, trace: false, },
  ])
  let both = host.control(SetTraceStatus("", "NA", 1, ""), Big)
  assert_eq(both.changed.length(), 3)
  assert_eq(
    host.control(GetTraceStatus("INV", "PWR"), Big).response.interpret(Big),
    TraceStatusValue(true),
  )
  let before_failed = host.configuration()
  assert_eq(
    host.control(SetLogLevel("BAD", "NA", 0, ""), Big).response.status,
    2,
  )
  assert_eq(
    host.control(SetLogLevel("MTR", "PWR", 1, ""), Big, busy=true).response.status,
    2,
  )
  assert_eq(host.configuration(), before_failed)
  assert_eq(host.control(Unknown(7U, b""), Big).response.status, 1)
  assert_eq(host.control(Unknown(99U, b""), Big).response.status, 2)
  assert_eq(host.control(GetLogInfo(1, "", "", ""), Big).response.status, 1)
  assert_eq(host.control(GetLogInfo(6, "BAD", "", ""), Big).response.status, 8)
  let request = ControlRequest::GetLogInfo(7, "MTR", "PWR", "").standard_message(
    Header::new(endian=Big),
  )
  let request_bytes = encode(request, framing=Network)
  let inbound = decode_exact(request_bytes[:], framing=Network)
  let response = host.control(
      inbound.standard_control_request(),
      inbound.header.endian,
    ).response
  assert_eq(response.status, 7)
  let wire = encode(
    response.standard_message(Header::new(endian=Big)),
    framing=Network,
  )
  assert_eq(
    decode_exact(wire[:], framing=Network)
    .standard_control_response()
    .interpret(Big),
    LogInformation([
      {
        id: "MTR",
        description: Some(b"motor"),
        contexts: [
          { id: "PWR", level: 5, trace: true, description: Some(b"power"), },
        ],
      },
    ]),
  )
  assert_eq(
    host.control(SetLogLevel("MTR", "PWR", -1, ""), Big).response.status,
    0,
  )
  assert_eq(host.control(SetDefaultLogLevel(-1, ""), Big).response.status, 0)
  assert_eq(host.configuration().default_log_level, 6)
  assert_eq(host.configuration().contexts[0].log_level, None)
  assert_eq(
    host.control(SetLogChannelThreshold("LOG2", 4, true), Big).response.interpret(
      Big,
    ),
    TraceStatusValue(true),
  )
  assert_eq(
    host.control(GetLogChannelThreshold("LOG2"), Big).response.interpret(Big),
    LogChannelThreshold(4, true),
  )
  assert_eq(
    host.control(SetLogChannelAssignment("MTR", "PWR", "LOG2", true), Big).response.status,
    0,
  )
  assert_eq(host.configuration().contexts[0].channels, ["LOG1", "LOG2"])
  assert_eq(host.control(SetMessageFiltering(false), Big).response.status, 0)
  assert_true(!host.configuration().filtering)
  assert_eq(host.control(StoreConfiguration, Big).response.status, 1)
  assert_eq(
    host.control(StoreConfiguration, Big, save=_ => false).response.status,
    2,
  )
  let save = host.control(StoreConfiguration, Big, save=snapshot => {
    snapshot.contexts[0].channels.clear()
    // The callback cannot re-enter another command while the save is active.
    let during_save = host.control(ResetConfiguration, Big) catch {
      _ => abort("unexpected error")
    }
    during_save.response.status == 2 && snapshot.default_log_level == 6
  })
  assert_eq(save.response.status, 0)
  assert_eq(host.configuration().contexts[0].channels, ["LOG1", "LOG2"])
  assert_eq(host.control(ResetConfiguration, Big).response.status, 0)
  assert_eq(host.configuration(), r19_test_config())
}

///|
fn r19_test_log(level : Int32) -> Message raise DltError {
  Message::with_arguments(
    {
      ..Header::new(counter=7),
      extended: Some({
        verbose: true,
        message_type: 0,
        subtype: level,
        argument_count: 0,
        application: "MTR",
        context: "PWR",
      }),
    },
    [Text(Ascii, "reading")],
  )
}

///|
test "R19 host filters then queues data, retries through a caller and throttles overflow" {
  let options = {
    ..R19HostOptions::default(),
    queue_records: 1,
    overflow_interval_ms: 100UL,
    retries: 2,
  }
  let host = R19Host::new(
    r19_test_config(),
    software_version="simulator",
    options~,
  )
  assert_eq(host.enqueue("LOG1", r19_test_log(6)), Filtered)
  assert_eq(host.enqueue("LOG1", r19_test_log(3)), Queued(1))
  assert_eq(host.enqueue("LOG1", r19_test_log(1)), Overflowed(2))
  let utc : R19WallTime = { seconds: 1700000000UL, nanoseconds: 123U, }
  let events = host.poll(100UL, Big, wall_time=utc)
  assert_eq(events.length(), 2)
  assert_eq(
    events[0].interpret(Big),
    SynchronizedTime(utc.seconds, utc.nanoseconds),
  )
  assert_eq(events[1].interpret(Big), OverflowCount(1U))
  assert_eq(host.enqueue("LOG1", r19_test_log(2)), Overflowed(3))
  assert_true(host.poll(199UL, Big, wall_time=utc).is_empty())
  let next = host.poll(200UL, Big, wall_time=utc)
  assert_eq(next.length(), 1)
  assert_eq(next[0].interpret(Big), OverflowCount(1U))
  let mut attempted = 0
  let delivery = host.drain_one((channel, message) => {
    attempted += 1
    channel == "LOG1" && message.header.counter == 1 && attempted == 3
  })
  assert_eq(
    delivery,
    Some({ channel: "LOG1", counter: 1, attempts: 3, accepted: true, }),
  )
  assert_eq(host.drain_one((_, _) => true), None)
  assert_eq(host.enqueue("LOG1", r19_test_log(2)), Queued(4))
  assert_eq(
    host.drain_one((_, _) => false),
    Some({ channel: "LOG1", counter: 4, attempts: 3, accepted: false, }),
  )
  assert_true(host.poll(600099UL, Little, wall_time=utc).is_empty())
  let sync = host.poll(600100UL, Little, wall_time=utc)
  assert_eq(
    sync[0].interpret(Little),
    SynchronizedTime(utc.seconds, utc.nanoseconds),
  )
  let jump = host.poll(600101UL, Little, wall_time=utc, clock_jump=true)
  assert_eq(
    jump[0].interpret(Little),
    SynchronizedTime(utc.seconds, utc.nanoseconds),
  )
  assert_eq(host.poll(600102UL, Little)[0].interpret(Little), ErrorStatus(1))
  assert_true(host.poll(600103UL, Little).is_empty())
  assert_eq(
    host.poll(600104UL, Little, wall_time=utc)[0].interpret(Little),
    SynchronizedTime(utc.seconds, utc.nanoseconds),
  )
  assert_true(
    try {
      ignore(host.poll(600102UL, Little, wall_time=utc))
      false
    } catch {
      Invalid(_, _) => true
      _ => false
    },
  )
}

///|
test "R19 host wraps MCNT and returns oversized GetLogInfo and byte queue failures" {
  let config = r19_test_config()
  config.contexts[0] = {
    ..config.contexts[0],
    context_description: Bytes::make(65535, b'x'),
  }
  let options = { ..R19HostOptions::default(), queue_bytes: 0, }
  let host = R19Host::new(config, software_version="simulator", options~)
  let record = r19_test_log(1)
  for counter in 0..<256 {
    assert_eq(host.enqueue("LOG1", record), Overflowed(counter))
  }
  assert_eq(host.enqueue("LOG1", record), Overflowed(0))
  assert_eq(
    host.control(GetLogInfo(7, "MTR", "PWR", ""), Little).response.status,
    9,
  )
  assert_eq(host.poll(1UL, Little)[1].interpret(Little), OverflowCount(257U))
}
