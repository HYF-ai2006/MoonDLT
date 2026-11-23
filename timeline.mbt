///|
/// Continuity analysis assumes messages arrive in capture order within each key.
/// Counter gaps indicate missing counter values, not a proven packet-loss count.
pub(all) enum ContinuityEvent {
  First
  SessionChanged(UInt32?, UInt32?)
  RepeatedCounter(Int32)
  CounterGap(Int32, Int32, Int32)
  CounterJump(Int32, Int32)
  TimestampWrapped(UInt32, UInt32)
  TimestampBackwards(UInt32, UInt32)
  ReceptionBackwards(UInt64, UInt64)
} derive(Eq, @debug.Debug)

///|
pub(all) struct StreamKey {
  ecu : String
  application : String
  context : String
} derive(Eq, @debug.Debug)

///|
pub fn Message::stream_key(self : Message) -> StreamKey {
  let ecu = self.effective_ecu().unwrap_or("")
  match self.header.extended {
    Some(ext) => { ecu, application: ext.application, context: ext.context, }
    None => { ecu, application: "", context: "", }
  }
}

///|
fn StreamKey::map_key(self : StreamKey) -> String {
  "\{self.ecu.length()}:\{self.ecu}\{self.application.length()}:\{self.application}\{self.context.length()}:\{self.context}"
}

///|
pub(all) struct ContinuityConfig {
  max_streams : Int32
  max_forward_gap : Int32
  wrap_previous_min : UInt32
  wrap_current_max : UInt32
} derive(Eq, @debug.Debug)

///|
pub fn ContinuityConfig::default() -> ContinuityConfig {
  {
    max_streams: 10000,
    max_forward_gap: 127,
    wrap_previous_min: 0xF0000000U,
    wrap_current_max: 0x0FFFFFFFU,
  }
}

///|
struct TimelineState {
  key : StreamKey
  counter : Int32
  session : UInt32?
  timestamp : UInt32?
  reception : UInt64?
  wraps : UInt64
  messages : UInt64
  gaps : UInt64
  repeated : UInt64
  jumps : UInt64
  backwards : UInt64
}

///|
pub(all) struct ContinuityObservation {
  key : StreamKey
  events : Array[ContinuityEvent]
  extended_timestamp : UInt64?
  stream_messages : UInt64
} derive(Eq, @debug.Debug)

///|
pub(all) struct StreamSummary {
  key : StreamKey
  messages : UInt64
  missing_counter_values : UInt64
  repeated_counters : UInt64
  counter_jumps : UInt64
  clock_backwards : UInt64
  timestamp_wraps : UInt64
  last_counter : Int32
  last_session : UInt32?
  last_timestamp : UInt32?
} derive(Eq, @debug.Debug)

///|
pub struct ContinuityTracker {
  config : ContinuityConfig
  states : Map[String, TimelineState]
  order : Array[String]
  mut total : UInt64
}

///|
pub fn ContinuityTracker::new(
  config~ : ContinuityConfig = ContinuityConfig::default(),
) -> ContinuityTracker raise DltError {
  guard config.max_streams > 0 &&
    config.max_forward_gap >= 1 &&
    config.max_forward_gap <= 127 &&
    config.wrap_current_max < config.wrap_previous_min else {
    raise Invalid(0, "invalid continuity tracker configuration")
  }
  { config, states: Map([]), order: [], total: 0UL, }
}

///|
fn extended_ticks(timestamp : UInt32?, wraps : UInt64) -> UInt64? {
  match timestamp {
    None => None
    Some(ticks) => Some((wraps << 32) | ticks.to_uint64())
  }
}

///|
pub fn ContinuityTracker::observe(
  self : ContinuityTracker,
  message : Message,
) -> ContinuityObservation raise DltError {
  guard message.header.counter >= 0 && message.header.counter <= 255 else {
    raise Invalid(0, "message counter is outside byte range")
  }
  let key = message.stream_key()
  let map_key = key.map_key()
  let counter = message.header.counter
  let session = message.header.session
  let timestamp = message.header.timestamp
  let reception = message.storage_microseconds()
  let events : Array[ContinuityEvent] = []
  let previous = self.states.get(map_key)
  let state = match previous {
    None => {
      guard self.states.length() < self.config.max_streams else {
        raise Limit(0, "continuity stream count exceeds max_streams")
      }
      self.order.push(map_key)
      events.push(First)
      {
        key,
        counter,
        session,
        timestamp,
        reception,
        wraps: 0UL,
        messages: 1UL,
        gaps: 0UL,
        repeated: 0UL,
        jumps: 0UL,
        backwards: 0UL,
      }
    }
    Some(old) => {
      let session_changed = session != old.session
      let mut wraps = if session_changed { 0UL } else { old.wraps }
      let mut gaps = old.gaps
      let mut repeated = old.repeated
      let mut jumps = old.jumps
      let mut backwards = old.backwards
      if session_changed {
        events.push(SessionChanged(old.session, session))
      } else {
        let delta = (counter - old.counter + 256) % 256
        if delta == 0 {
          repeated += 1UL
          events.push(RepeatedCounter(counter))
        } else if delta > 1 && delta <= self.config.max_forward_gap + 1 {
          gaps += (delta - 1).to_uint64()
          events.push(CounterGap(old.counter, counter, delta - 1))
        } else if delta > self.config.max_forward_gap + 1 {
          jumps += 1UL
          events.push(CounterJump(old.counter, counter))
        }
        match (old.timestamp, timestamp) {
          (Some(before), Some(now)) =>
            if now < before {
              if before >= self.config.wrap_previous_min &&
                now <= self.config.wrap_current_max {
                guard wraps < 0xFFFFFFFFUL else {
                  raise Limit(0, "extended timestamp overflow")
                }
                wraps += 1UL
                events.push(TimestampWrapped(before, now))
              } else {
                backwards += 1UL
                events.push(TimestampBackwards(before, now))
              }
            }
          _ => ()
        }
      }
      match (old.reception, reception) {
        (Some(before), Some(now)) =>
          if now < before {
            backwards += 1UL
            events.push(ReceptionBackwards(before, now))
          }
        _ => ()
      }
      {
        key,
        counter,
        session,
        timestamp,
        reception,
        wraps,
        messages: old.messages + 1UL,
        gaps,
        repeated,
        jumps,
        backwards,
      }
    }
  }
  self.states[map_key] = state
  self.total += 1UL
  {
    key,
    events,
    extended_timestamp: extended_ticks(timestamp, state.wraps),
    stream_messages: state.messages,
  }
}

///|
pub fn ContinuityTracker::total_messages(self : ContinuityTracker) -> UInt64 {
  self.total
}

///|
pub fn ContinuityTracker::stream_count(self : ContinuityTracker) -> Int32 {
  self.states.length()
}

///|
pub fn ContinuityTracker::reset(self : ContinuityTracker) -> Unit {
  self.states.clear()
  self.order.clear()
  self.total = 0UL
}

///|
pub fn ContinuityTracker::summaries(
  self : ContinuityTracker,
) -> Array[StreamSummary] {
  let result : Array[StreamSummary] = []
  for key in self.order {
    if self.states.get(key) is Some(state) {
      result.push({
        key: state.key,
        messages: state.messages,
        missing_counter_values: state.gaps,
        repeated_counters: state.repeated,
        counter_jumps: state.jumps,
        clock_backwards: state.backwards,
        timestamp_wraps: state.wraps,
        last_counter: state.counter,
        last_session: state.session,
        last_timestamp: state.timestamp,
      })
    }
  }
  result
}

///|
/// Receive-time windows use integer microseconds to avoid floating rounding.
pub(all) struct TimeWindow {
  start : UInt64
  end : UInt64
} derive(Eq, @debug.Debug)

///|
pub fn TimeWindow::new(
  start : UInt64,
  end : UInt64,
) -> TimeWindow raise DltError {
  guard start <= end else { raise Invalid(0, "window start is after end") }
  { start, end, }
}

///|
pub fn TimeWindow::contains(self : TimeWindow, time : UInt64) -> Bool {
  time >= self.start && time < self.end
}

///|
pub fn TimeWindow::intersect(
  self : TimeWindow,
  other : TimeWindow,
) -> TimeWindow? {
  let start = if self.start > other.start { self.start } else { other.start }
  let end = if self.end < other.end { self.end } else { other.end }
  if start < end {
    Some({ start, end, })
  } else {
    None
  }
}

///|
pub(all) struct TimeBucket {
  window : TimeWindow
  messages : UInt64
  payload_bytes : UInt64
  min_counter : Int32
  max_counter : Int32
} derive(Eq, @debug.Debug)

///|
/// Bounded tumbling windows for streaming log-volume visualization. Input order
/// is irrelevant; results are sorted by bucket start and missing storage times fail.
pub struct TimeHistogram {
  origin : UInt64
  width : UInt64
  max_buckets : Int32
  buckets : Map[UInt64, TimeBucket]
}

///|
pub fn TimeHistogram::new(
  width_microseconds : UInt64,
  origin~ : UInt64 = 0UL,
  max_buckets~ : Int32 = 10000,
) -> TimeHistogram raise DltError {
  guard width_microseconds > 0UL && max_buckets > 0 else {
    raise Invalid(0, "histogram width and bucket count must be positive")
  }
  { origin, width: width_microseconds, max_buckets, buckets: Map([]), }
}

///|
pub fn TimeHistogram::add(
  self : TimeHistogram,
  message : Message,
) -> Unit raise DltError {
  let time = match message.storage_microseconds() {
    Some(value) => value
    None => raise Invalid(0, "histogram requires storage timestamps")
  }
  guard time >= self.origin else {
    raise Invalid(0, "message is earlier than histogram origin")
  }
  let slot = (time - self.origin) / self.width
  let start = self.origin + slot * self.width
  guard self.width <= 0xFFFFFFFFFFFFFFFFUL - start else {
    raise Limit(0, "histogram bucket end would overflow")
  }
  let counter = message.header.counter
  guard counter >= 0 && counter <= 255 else {
    raise Invalid(0, "invalid message counter")
  }
  let bucket = match self.buckets.get(slot) {
    None => {
      guard self.buckets.length() < self.max_buckets else {
        raise Limit(0, "histogram bucket count exceeded")
      }
      {
        window: { start, end: start + self.width, },
        messages: 1UL,
        payload_bytes: message.payload.length().to_uint64(),
        min_counter: counter,
        max_counter: counter,
      }
    }
    Some(old) =>
      {
        ..old,
        messages: old.messages + 1UL,
        payload_bytes: old.payload_bytes + message.payload.length().to_uint64(),
        min_counter: if counter < old.min_counter {
          counter
        } else {
          old.min_counter
        },
        max_counter: if counter > old.max_counter {
          counter
        } else {
          old.max_counter
        },
      }
  }
  self.buckets[slot] = bucket
}

///|
pub fn TimeHistogram::buckets(self : TimeHistogram) -> Array[TimeBucket] {
  let slots = self.buckets.keys().collect()
  slots.sort()
  let result : Array[TimeBucket] = []
  for slot in slots {
    if self.buckets.get(slot) is Some(bucket) {
      result.push(bucket)
    }
  }
  result
}

///|
pub fn TimeHistogram::clear(self : TimeHistogram) -> Unit {
  self.buckets.clear()
}
