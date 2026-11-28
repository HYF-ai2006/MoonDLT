///|
/// Application settings for the in-memory DLT host. None inherits the ECU's default.
pub(all) struct R19ContextConfig {
  application : String
  context : String
  log_level : Int32?
  trace : Bool?
  channels : Array[String]
  application_description : Bytes
  context_description : Bytes
} derive(Eq, @debug.Debug)

///|
pub(all) struct R19ChannelConfig {
  name : String
  log_level : Int32
  trace : Bool
} derive(Eq, @debug.Debug)

///|
pub(all) struct R19HostConfig {
  default_log_level : Int32
  default_trace : Bool
  filtering : Bool
  contexts : Array[R19ContextConfig]
  channels : Array[R19ChannelConfig]
} derive(Eq, @debug.Debug)

///|
pub(all) struct R19HostOptions {
  queue_records : Int32
  queue_bytes : Int32
  overflow_interval_ms : UInt64
  retries : Int32
  filtering_supported : Bool
} derive(Eq, @debug.Debug)

///|
pub fn R19HostOptions::default() -> R19HostOptions {
  {
    queue_records: 256,
    queue_bytes: 1048576,
    overflow_interval_ms: 1000UL,
    retries: 1,
    filtering_supported: false,
  }
}

///|
pub(all) struct R19ContextChange {
  application : String
  context : String
  log_level : Int32
  trace : Bool
} derive(Eq, @debug.Debug)

///|
pub(all) struct R19ControlResult {
  response : ControlResponse
  changed : Array[R19ContextChange]
} derive(Eq, @debug.Debug)

///|
pub(all) struct R19WallTime {
  seconds : UInt64
  nanoseconds : UInt32
} derive(Eq, @debug.Debug)

///|
pub(all) enum R19EnqueueResult {
  Filtered
  Queued(Int32)
  Overflowed(Int32)
} derive(Eq, @debug.Debug)

///|
pub(all) struct R19Delivery {
  channel : String
  counter : Int32
  attempts : Int32
  accepted : Bool
} derive(Eq, @debug.Debug)

///|
struct R19Pending {
  channel : String
  message : Message
  bytes : Int32
}

///|
/// Offline host for one ECU. All external actions are data or caller-provided
/// hooks, with deterministic registration order and no system-clock dependency.
pub struct R19Host {
  factory : R19HostConfig
  mut config : R19HostConfig
  software_version : String
  options : R19HostOptions
  queue : Array[R19Pending]
  mut bytes : Int32
  mut counter : Int32
  mut loss : UInt32
  mut last_overflow : UInt64?
  mut last_sync : UInt64?
  mut last_sync_available : Bool
  mut last_poll : UInt64?
  mut busy : Bool
}

///|
fn copy_r19_config(config : R19HostConfig) -> R19HostConfig {
  {
    ..config,
    contexts: config.contexts.map(entry => {
      ..entry,
      channels: entry.channels.copy(),
    }),
    channels: config.channels.copy(),
  }
}

///|
fn r19_id(scratch : @buffer.Buffer, id : String) -> Unit raise DltError {
  guard id != "" else { raise Invalid(0, "empty registration ID") }
  scratch.reset()
  write_id(scratch, id)
}

///|
fn validate_r19_config(config : R19HostConfig) -> Unit raise DltError {
  control_default_level(config.default_log_level, false)
  guard config.contexts.length() <= 4096 && config.channels.length() <= 255 else {
    raise Limit(0, "too many DLT host registrations")
  }
  let scratch = @buffer.Buffer::Buffer()
  let channels : Map[String, Bool] = Map([])
  for channel in config.channels {
    r19_id(scratch, channel.name)
    control_default_level(channel.log_level, false)
    guard !channels.contains(channel.name) else {
      raise Invalid(0, "duplicate DLT channel")
    }
    channels[channel.name] = true
  }
  let contexts : Map[(String, String), Bool] = Map([])
  let app_descriptions : Map[String, Bytes] = Map([])
  for entry in config.contexts {
    r19_id(scratch, entry.application)
    r19_id(scratch, entry.context)
    let key = (entry.application, entry.context)
    guard !contexts.contains(key) else {
      raise Invalid(0, "duplicate DLT context")
    }
    contexts[key] = true
    if entry.log_level is Some(level) {
      control_default_level(level, false)
    }
    guard entry.application_description.length() <= 65535 &&
      entry.context_description.length() <= 65535 else {
      raise Limit(0, "description exceeds uint16 length")
    }
    if app_descriptions.get(entry.application) is Some(previous) {
      guard previous == entry.application_description else {
        raise Invalid(0, "inconsistent DLT application description")
      }
    } else {
      app_descriptions[entry.application] = entry.application_description
    }
    guard entry.channels.length() <= config.channels.length() else {
      raise Invalid(0, "too many channel assignments")
    }
    let assigned : Map[String, Bool] = Map([])
    for channel in entry.channels {
      guard channels.contains(channel) && !assigned.contains(channel) else {
        raise Invalid(0, "unknown or duplicate channel assignment")
      }
      assigned[channel] = true
    }
  }
}

///|
pub fn R19Host::new(
  factory : R19HostConfig,
  software_version~ : String,
  options~ : R19HostOptions = R19HostOptions::default(),
) -> R19Host raise DltError {
  validate_r19_config(factory)
  guard options.queue_records >= 0 &&
    options.queue_records <= 4096 &&
    options.queue_bytes >= 0 &&
    options.retries >= 0 &&
    options.retries <= 32 else {
    raise Invalid(0, "invalid DLT host queue or retry budget")
  }
  let version = software_version_response(software_version, Little)
  // A standard control response always includes the extended header.
  let reply = control_response_message(version, Header::new())
  ignore(encode(reply, framing=Network))
  {
    factory: copy_r19_config(factory),
    config: copy_r19_config(factory),
    software_version,
    options,
    queue: [],
    bytes: 0,
    counter: 0,
    loss: 0U,
    last_overflow: None,
    last_sync: None,
    last_sync_available: false,
    last_poll: None,
    busy: false,
  }
}

///|
pub fn R19Host::configuration(self : R19Host) -> R19HostConfig {
  copy_r19_config(self.config)
}

///|
fn r19_matches(
  entry : R19ContextConfig,
  app : String,
  context : String,
) -> Bool {
  app == "" ||
  (entry.application == app && (context == "" || entry.context == context))
}

///|
fn r19_resolved(
  entry : R19ContextConfig,
  config : R19HostConfig,
) -> R19ContextChange {
  {
    application: entry.application,
    context: entry.context,
    log_level: if config.filtering {
      entry.log_level.unwrap_or(config.default_log_level)
    } else {
      6
    },
    trace: if config.filtering {
      entry.trace.unwrap_or(config.default_trace)
    } else {
      true
    },
  }
}

///|
fn r19_context_index(
  config : R19HostConfig,
  app : String,
  context : String,
) -> Int32? {
  for i, entry in config.contexts {
    if entry.application == app && entry.context == context {
      return Some(i)
    }
  }
  None
}

///|
fn r19_channel_index(config : R19HostConfig, channel : String) -> Int32? {
  for i, entry in config.channels {
    if entry.name == channel {
      return Some(i)
    }
  }
  None
}

///|
fn r19_filter_diff(
  old : R19HostConfig,
  fresh : R19HostConfig,
) -> Array[R19ContextChange] {
  let changed = []
  for i, entry in fresh.contexts {
    let new_filter = r19_resolved(entry, fresh)
    if new_filter != r19_resolved(old.contexts[i], old) {
      changed.push(new_filter)
    }
  }
  changed
}

///|
fn r19_error(
  service : UInt32,
  status : Int32,
  endian : Endian,
) -> ControlResponse raise DltError {
  if service == 3U {
    ErrorStatus(status).response(service, endian)
  } else {
    { service_id: service, status, data: b"", }
  }
}

///|
fn r19_log_info(
  config : R19HostConfig,
  option : Int32,
  app : String,
  context : String,
  endian : Endian,
) -> ControlResponse raise DltError {
  let apps : Array[ControlApplicationInfo] = []
  let indexes : Map[String, Int32] = Map([])
  for entry in config.contexts {
    if !r19_matches(entry, app, context) {
      continue
    }
    let idx = match indexes.get(entry.application) {
      Some(idx) => idx
      None => {
        let idx = apps.length()
        indexes[entry.application] = idx
        apps.push({
          id: entry.application,
          contexts: [],
          description: if option == 7 {
            Some(entry.application_description)
          } else {
            None
          },
        })
        idx
      }
    }
    let value = r19_resolved(entry, config)
    apps[idx].contexts.push({
      id: entry.context,
      level: value.log_level,
      trace: value.trace,
      description: if option == 7 {
        Some(entry.context_description)
      } else {
        None
      },
    })
  }
  if apps.is_empty() {
    return r19_error(3U, 8, endian)
  }
  let result = log_information_response(apps, descriptions=option == 7, endian) catch {
    Limit(_, _) => return r19_error(3U, 9, endian)
    error => raise error
  }
  let framed = result.standard_message(Header::new(endian~)) catch {
    Limit(_, _) => return r19_error(3U, 9, endian)
    error => raise error
  }
  ignore(framed)
  result
}

///|
/// Apply one control request and return the configuration changes an application
/// can observe. The optional save hook receives its own snapshot, and failure
/// reports a standard ERROR. The host applies no vendor-specific callbacks.
pub fn R19Host::control(
  self : R19Host,
  request : ControlRequest,
  endian : Endian,
  busy~ : Bool = false,
  save? : (R19HostConfig) -> Bool,
) -> R19ControlResult raise DltError {
  let service = request.service_id()
  let status = r19_request_status(
    request,
    busy=busy || self.busy,
    filtering_supported=self.options.filtering_supported,
  )
  if status != 0 {
    return { response: r19_error(service, status, endian), changed: [], }
  }
  // The canonical writer checks direct API requests just as the wire reader does.
  let valid = try {
    ignore(request.canonical_bytes(endian))
    true
  } catch {
    _ => false
  }
  if !valid {
    return { response: r19_error(service, 2, endian), changed: [], }
  }
  let old = self.config
  let mut updated = old
  let mut data = ControlData::Ack
  match request {
    SetLogLevel(app, ctid, value, _) => {
      let mut found = false
      let contexts = old.contexts.map(entry => {
        if r19_matches(entry, app, ctid) {
          found = true
          { ..entry, log_level: if value == -1 { None } else { Some(value) }, }
        } else {
          entry
        }
      })
      if found {
        updated = { ..old, contexts, }
      } else {
        data = ErrorStatus(2)
      }
    }
    SetTraceStatus(app, ctid, value, _) => {
      let mut found = false
      let contexts = old.contexts.map(entry => {
        if r19_matches(entry, app, ctid) {
          found = true
          { ..entry, trace: if value == -1 { None } else { Some(value == 1) }, }
        } else {
          entry
        }
      })
      if found {
        updated = { ..old, contexts, }
      } else {
        data = ErrorStatus(2)
      }
    }
    GetLogInfo(option, app, ctid, _) =>
      return {
        response: r19_log_info(old, option, app, ctid, endian),
        changed: [],
      }
    GetDefaultLogLevel => data = DefaultLogLevelValue(old.default_log_level)
    StoreConfiguration =>
      match save {
        None => data = ErrorStatus(1)
        Some(store) => {
          self.busy = true
          let ok = store(copy_r19_config(old))
          self.busy = false
          if !ok {
            data = ErrorStatus(2)
          }
        }
      }
    ResetConfiguration => updated = copy_r19_config(self.factory)
    SetDefaultLogLevel(value, _) =>
      updated = {
        ..old,
        default_log_level: if value == -1 {
          6
        } else {
          value
        },
      }
    SetDefaultTraceStatus(value, _) =>
      updated = { ..old, default_trace: value == 1, }
    GetSoftwareVersion => data = SoftwareVersionValue(self.software_version)
    SetMessageFiltering(on) => updated = { ..old, filtering: on, }
    GetDefaultTraceStatus => data = TraceStatusValue(old.default_trace)
    GetLogChannelNames =>
      data = LogChannels(old.channels.map(channel => channel.name))
    GetTraceStatus(app, ctid) =>
      match r19_context_index(old, app, ctid) {
        Some(idx) =>
          data = TraceStatusValue(r19_resolved(old.contexts[idx], old).trace)
        None => data = ErrorStatus(2)
      }
    SetLogChannelAssignment(app, ctid, channel, add) =>
      match
        (r19_context_index(old, app, ctid), r19_channel_index(old, channel)) {
        (Some(ctx), Some(_)) => {
          let contexts = old.contexts.copy()
          let entry = contexts[ctx]
          let channels = entry.channels.filter(name => name != channel)
          if add {
            channels.push(channel)
          }
          contexts[ctx] = { ..entry, channels, }
          updated = { ..old, contexts, }
        }
        _ => data = ErrorStatus(2)
      }
    SetLogChannelThreshold(channel, level, trace) =>
      match r19_channel_index(old, channel) {
        Some(idx) => {
          let channels = old.channels.copy()
          channels[idx] = { name: channel, log_level: level, trace, }
          updated = { ..old, channels, }
          data = TraceStatusValue(trace)
        }
        None => data = ErrorStatus(2)
      }
    GetLogChannelThreshold(channel) =>
      match r19_channel_index(old, channel) {
        Some(idx) => {
          let cfg = old.channels[idx]
          data = LogChannelThreshold(cfg.log_level, cfg.trace)
        }
        None => data = ErrorStatus(2)
      }
    Unknown(_, _) => data = ErrorStatus(2)
  }
  let response = data.response(service, endian)
  let changed = r19_filter_diff(old, updated)
  self.config = updated
  { response, changed, }
}

///|
/// Select and queue a standard data record for the named host channel. The
/// sequence advances for every valid, registered record supplied to the module.
/// queue_bytes measures DLT header plus payload, excluding storage framing.
pub fn R19Host::enqueue(
  self : R19Host,
  channel : String,
  message : Message,
) -> R19EnqueueResult raise DltError {
  guard message.header.extended is Some(ext) && ext.message_type <= 2 else {
    raise Invalid(0, "a host record needs an extended data header")
  }
  message.validate_r19()
  guard r19_context_index(self.config, ext.application, ext.context)
    is Some(idx) &&
    r19_channel_index(self.config, channel) is Some(channel_idx) else {
    raise Invalid(
      0, "host record references an unregistered context or channel",
    )
  }
  let entry = self.config.contexts[idx]
  let settings = r19_resolved(entry, self.config)
  let threshold = self.config.channels[channel_idx]
  let counter = self.counter
  self.counter = (counter + 1) & 255
  let pass = if ext.message_type == 0 {
    ext.subtype <= settings.log_level && ext.subtype <= threshold.log_level
  } else {
    settings.trace && threshold.trace
  }
  guard entry.channels.contains(channel) && pass else { return Filtered }
  let message = { ..message, header: { ..message.header, counter, }, }
  let bytes = message.header.wire_size() + message.payload.length()
  if self.queue.length() >= self.options.queue_records ||
    bytes > self.options.queue_bytes - self.bytes {
    if self.loss < 0xFFFFFFFFU {
      self.loss += 1U
    }
    return Overflowed(counter)
  }
  self.queue.push({ channel, message, bytes, })
  self.bytes += bytes
  Queued(counter)
}

///|
/// Dequeue one record and apply at most retries + 1 attempts to the supplied
/// in-memory callback. A nested drain during an attempt receives no record.
pub fn R19Host::drain_one(
  self : R19Host,
  attempt : (String, Message) -> Bool,
) -> R19Delivery? {
  if self.busy || self.queue.is_empty() {
    return None
  }
  let entry = self.queue.remove(0)
  self.bytes -= entry.bytes
  let mut tries = 0
  let mut accepted = false
  self.busy = true
  while tries <= self.options.retries && !accepted {
    tries += 1
    accepted = attempt(entry.channel, entry.message)
  }
  self.busy = false
  Some({
    channel: entry.channel,
    counter: entry.message.header.counter,
    attempts: tries,
    accepted,
  })
}

///|
/// Generate due notifications at a host-provided monotonic millisecond timestamp.
/// A missing wall clock reports the unavailable sync status. The host marks each
/// returned notification handled so repeated polls do not emit duplicates.
pub fn R19Host::poll(
  self : R19Host,
  monotonic_ms : UInt64,
  endian : Endian,
  wall_time? : R19WallTime,
  clock_jump~ : Bool = false,
) -> Array[ControlResponse] raise DltError {
  if self.last_poll is Some(last) {
    guard monotonic_ms >= last else {
      raise Invalid(0, "host clock ran backwards")
    }
  }
  let result = []
  if wall_time is Some(wall) {
    guard wall.seconds <= 0xFFFFFFFFFFFFUL && wall.nanoseconds < 1000000000U else {
      raise Invalid(0, "wall clock does not fit R19 synchronized timestamp")
    }
  }
  let available = wall_time is Some(_)
  let sync_due = clock_jump ||
    available != self.last_sync_available ||
    (match self.last_sync {
      None => true
      Some(last) => monotonic_ms - last >= 600000UL
    })
  if sync_due {
    let sync = match wall_time {
      Some(wall) => SynchronizedTime(wall.seconds, wall.nanoseconds)
      None => ErrorStatus(1)
    }
    result.push(sync.response(36U, endian))
    self.last_sync = Some(monotonic_ms)
    self.last_sync_available = available
  }
  let overflow_due = match self.last_overflow {
    None => true
    Some(last) => monotonic_ms - last >= self.options.overflow_interval_ms
  }
  if self.loss > 0U && overflow_due {
    result.push(OverflowCount(self.loss).response(35U, endian))
    self.last_overflow = Some(monotonic_ms)
    self.loss = 0U
  }
  self.last_poll = Some(monotonic_ms)
  result
}
