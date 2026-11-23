///|
test "counter wrap, missing values, duplicate and sessions are distinct" {
  let tracker = ContinuityTracker::new()
  let msg = sample_message()
  assert_eq(tracker.observe(msg).events, [First])
  let next = { ..msg, header: { ..msg.header, counter: 0, }, }
  assert_eq(tracker.observe(next).events, [])
  let gap = { ..msg, header: { ..msg.header, counter: 3, }, }
  assert_eq(tracker.observe(gap).events, [CounterGap(0, 3, 2)])
  assert_eq(tracker.observe(gap).events, [RepeatedCounter(3)])
  let session = { ..gap, header: { ..gap.header, session: Some(99U), }, }
  assert_eq(tracker.observe(session).events, [
    SessionChanged(Some(0x12345678U), Some(99U)),
  ])
  let summary = tracker.summaries()[0]
  assert_eq(summary.messages, 5UL)
  assert_eq(summary.missing_counter_values, 2UL)
  assert_eq(summary.repeated_counters, 1UL)
}

///|
test "ECU uptime wrap and ordinary reversal follow explicit thresholds" {
  let tracker = ContinuityTracker::new()
  let msg = sample_message()
  let first = {
    ..msg,
    header: { ..msg.header, counter: 0, timestamp: Some(0xFFFFFFF0U), },
  }
  ignore(tracker.observe(first))
  let next = {
    ..msg,
    header: { ..msg.header, counter: 1, timestamp: Some(32U), },
  }
  let observed = tracker.observe(next)
  assert_eq(observed.extended_timestamp, Some(0x100000020UL))
  assert_eq(observed.events, [TimestampWrapped(0xFFFFFFF0U, 32U)])
  let backwards = {
    ..msg,
    header: { ..msg.header, counter: 2, timestamp: Some(16U), },
  }
  assert_eq(tracker.observe(backwards).events, [TimestampBackwards(32U, 16U)])
}

///|
test "stream budgets, identifier keys, histogram bounds" {
  let tracker = ContinuityTracker::new(config={
    ..ContinuityConfig::default(),
    max_streams: 1,
  })
  let msg = sample_message()
  ignore(tracker.observe(msg))
  let other = { ..msg, header: { ..msg.header, ecu: Some("ECU2"), }, }
  assert_true(
    try {
      ignore(tracker.observe(other))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(tracker.total_messages(), 1UL)
  tracker.reset()
  assert_eq(tracker.stream_count(), 0)
  let histogram = TimeHistogram::new(1000000UL, max_buckets=1)
  histogram.add(msg)
  histogram.add({ ..msg, header: { ..msg.header, counter: 0, }, })
  let bucket = histogram.buckets()[0]
  assert_eq(bucket.messages, 2UL)
  assert_eq(bucket.window.start, 1000000UL)
  assert_eq(bucket.min_counter, 0)
  assert_eq(bucket.max_counter, 255)
  let later = {
    ..msg,
    storage: Some({ seconds: 2U, microseconds: 0U, ecu: "E", }),
  }
  assert_true(
    try {
      histogram.add(later)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    TimeWindow::new(0UL, 10UL).intersect(TimeWindow::new(10UL, 20UL)),
    None,
  )
}
