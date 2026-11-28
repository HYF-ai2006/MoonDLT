///|
fn read_control_flag(bytes : BytesView, at : Int32) -> Bool raise DltError {
  require_range(bytes, at, 1)
  match bytes[at] {
    b'\x00' => false
    b'\x01' => true
    _ => raise Invalid(at, "expected control flag 0 or 1")
  }
}

///|
pub(all) struct ControlContextInfo {
  id : String
  level : Int32
  trace : Bool
  description : Bytes?
} derive(Eq, @debug.Debug)

///|
pub(all) struct ControlApplicationInfo {
  id : String
  contexts : Array[ControlContextInfo]
  description : Bytes?
} derive(Eq, @debug.Debug)

///|
pub(all) enum ControlData {
  Ack
  ErrorStatus(Int32)
  DefaultLogLevelValue(Int32)
  TraceStatusValue(Bool)
  LogChannels(Array[String])
  LogChannelThreshold(Int32, Bool)
  OverflowCount(UInt32)
  SynchronizedTime(UInt64, UInt32)
  SoftwareVersionValue(String)
  LogInformation(Array[ControlApplicationInfo])
  OpaqueControl(Bytes)
} derive(Eq, @debug.Debug)

///|
fn read_log_description(
  body : BytesView,
  pos : Int32,
  endian : Endian,
) -> (Bytes, Int32) raise DltError {
  let length = read_u16(body, pos, endian)
  require_range(body, pos + 2, length)
  (body[pos + 2:pos + 2 + length].to_owned(), pos + 2 + length)
}

///|
fn read_log_information(
  body : BytesView,
  status : Int32,
  endian : Endian,
) -> Array[ControlApplicationInfo] raise DltError {
  let count = read_u16(body, 0, endian)
  let mut pos = 2
  let apps = []
  let descriptions = status == 7
  require_range(body, pos, count * (if descriptions { 8 } else { 6 }) + 4)
  for _ in 0..<count {
    let id = read_id(body, pos)
    let context_count = read_u16(body, pos + 4, endian)
    pos += 6
    require_range(
      body,
      pos,
      context_count * (if descriptions { 8 } else { 6 }) + 4,
    )
    let contexts = []
    for _ in 0..<context_count {
      let context = read_id(body, pos)
      require_range(body, pos + 4, 2)
      let level = body[pos + 4].to_int()
      control_default_level(level, false)
      let trace = read_control_flag(body, pos + 5)
      pos += 6
      let description = if descriptions {
        let (v, next) = read_log_description(body, pos, endian)
        pos = next
        Some(v)
      } else {
        None
      }
      contexts.push({ id: context, level, trace, description, })
    }
    let description = if descriptions {
      let (v, next) = read_log_description(body, pos, endian)
      pos = next
      Some(v)
    } else {
      None
    }
    apps.push({ id, contexts, description, })
  }
  control_exact(body, pos + 4)
  apps
}

///|
/// Interpret the documented §5.3 packed response fields. Reserved bytes are
/// ignored on input. Opaque service data remains available in the envelope.
pub fn ControlResponse::interpret(
  self : ControlResponse,
  endian : Endian,
) -> ControlData raise DltError {
  let body = self.data[:]
  guard body.length() <= 65530 else {
    raise Limit(5, "control response exceeds wire length")
  }
  if self.service_id >= 4095U {
    control_exact(body, 0)
    return match self.status {
      0 => Ack
      1 | 2 | 3 => ErrorStatus(self.status)
      _ => raise Invalid(4, "unknown application service status")
    }
  }
  if self.service_id == 3U {
    return match self.status {
      6 | 7 => LogInformation(read_log_information(body, self.status, endian))
      1 | 2 | 8 | 9 => {
        control_exact(body, 4)
        ErrorStatus(self.status)
      }
      _ => OpaqueControl(self.data)
    }
  }
  match self.service_id {
    1U
    | 2U
    | 4U
    | 5U
    | 6U
    | 10U
    | 17U
    | 18U
    | 19U
    | 21U
    | 23U
    | 31U
    | 32U
    | 33U
    | 34U
    | 35U
    | 36U => ()
    _ => return OpaqueControl(self.data)
  }
  if self.status == 1 || self.status == 2 {
    control_exact(body, 0)
    return ErrorStatus(self.status)
  }
  guard self.status == 0 else {
    raise Invalid(4, "unknown response status for standard service")
  }
  match self.service_id {
    4U => DefaultLogLevelValue(self.default_log_level())
    19U => SoftwareVersionValue(self.software_version(endian))
    21U | 31U | 33U => {
      control_exact(body, 1)
      TraceStatusValue(read_control_flag(body, 0))
    }
    23U => {
      require_range(body, 0, 1)
      let count = body[0].to_int()
      control_exact(body, 1 + 4 * count)
      let names = []
      for i in 0..<count {
        names.push(read_id(body, 1 + 4 * i))
      }
      LogChannels(names)
    }
    34U => {
      control_exact(body, 2)
      let level = body[0].to_int()
      control_default_level(level, false)
      LogChannelThreshold(level, read_control_flag(body, 1))
    }
    35U => {
      control_exact(body, 4)
      OverflowCount(read_u32(body, 0, endian))
    }
    36U => {
      control_exact(body, 10)
      let nanos = read_u32(body, 0, endian)
      guard nanos < 1000000000U else {
        raise Invalid(5, "nanoseconds exceed one second")
      }
      let seconds = (read_u16(body, 8, endian).to_uint64() << 32) |
        read_u32(body, 4, endian).to_uint64()
      SynchronizedTime(seconds, nanos)
    }
    _ => {
      control_exact(body, 0)
      Ack
    }
  }
}

///|
fn write_control_description(
  out : @buffer.Buffer,
  description : Bytes?,
  enabled : Bool,
  endian : Endian,
) -> Unit raise DltError {
  match description {
    Some(value) if enabled => {
      guard value.length() <= 65530 - out.length() - 2 else {
        raise Limit(out.length(), "control description exceeds wire budget")
      }
      write_u16(out, value.length(), endian)
      out.write_bytes(value[:])
    }
    None if !enabled => ()
    _ =>
      raise Invalid(
        out.length(),
        "description presence disagrees with GetLogInfo status",
      )
  }
}

///|
pub fn log_information_response(
  apps : Array[ControlApplicationInfo],
  descriptions~ : Bool,
  endian : Endian,
) -> ControlResponse raise DltError {
  let out = @buffer.Buffer::Buffer()
  guard apps.length() <= 65524 / 6 else {
    raise Limit(0, "too many application entries")
  }
  write_u16(out, apps.length(), endian)
  for app in apps {
    guard app.contexts.length() <= (65526 - out.length() - 6) / 6 else {
      raise Limit(out.length(), "too many context entries")
    }
    guard out.length() <= 65520 else {
      raise Limit(out.length(), "GetLogInfo exceeds wire budget")
    }
    write_id(out, app.id)
    write_u16(out, app.contexts.length(), endian)
    for context in app.contexts {
      guard out.length() <= 65520 else {
        raise Limit(out.length(), "GetLogInfo exceeds wire budget")
      }
      write_id(out, context.id)
      control_default_level(context.level, false)
      out.write_byte(context.level.to_byte())
      out.write_byte(if context.trace { b'\x01' } else { b'\x00' })
      write_control_description(out, context.description, descriptions, endian)
    }
    write_control_description(out, app.description, descriptions, endian)
  }
  guard out.length() <= 65526 else {
    raise Limit(out.length(), "GetLogInfo exceeds wire budget")
  }
  write_u32(out, 0U, endian)
  {
    service_id: 3U,
    status: if descriptions {
      7
    } else {
      6
    },
    data: out.to_bytes(),
  }
}

///|
/// The R19-11 status-7 variant carries the ordinary GetLogInfo service
/// envelope with the VERB bit on. Ordinary verbose parameters use a different API.
pub fn Message::standard_control_response(
  self : Message,
) -> ControlResponse raise DltError {
  guard self.header.extended is Some(e) && e.message_type == 3 && e.subtype == 2 else {
    raise Invalid(0, "expected control response header")
  }
  let result = decode_control_response(self.payload[:], self.header.endian)
  if result.service_id == 3U && result.status == 7 {
    guard e.verbose else {
      raise Invalid(0, "GetLogInfo status 7 requires VERB")
    }
  } else {
    guard !e.verbose && e.argument_count == 0 else {
      raise Invalid(0, "expected nonverbose control and NOAR=0")
    }
  }
  ignore(result.interpret(self.header.endian))
  result
}

///|
/// Build a standard packed control response from the interpreted fields.
/// Preserve vendor/unknown data through the legacy ControlResponse envelope.
pub fn ControlData::response(
  self : ControlData,
  service_id : UInt32,
  endian : Endian,
  descriptions~ : Bool = false,
) -> ControlResponse raise DltError {
  let out = @buffer.Buffer::Buffer()
  let mut status = 0
  match (service_id, self) {
    (3U, LogInformation(apps)) =>
      return log_information_response(apps, descriptions~, endian)
    (19U, SoftwareVersionValue(version)) =>
      return software_version_response(version, endian)
    (3U, ErrorStatus(value)) if value == 1 ||
      value == 2 ||
      value == 8 ||
      value == 9 => {
      status = value
      write_u32(out, 0U, endian)
    }
    (id, Ack) if id >= 4095U => ()
    (id, ErrorStatus(3)) if id >= 4095U => status = 3
    (_, ErrorStatus(value)) if value == 1 || value == 2 => status = value
    (1U | 2U | 5U | 6U | 10U | 17U | 18U | 32U, Ack) => ()
    (4U, DefaultLogLevelValue(level)) => {
      control_default_level(level, false)
      out.write_byte(level.to_byte())
    }
    (21U | 31U | 33U, TraceStatusValue(on)) =>
      out.write_byte(if on { b'\x01' } else { b'\x00' })
    (23U, LogChannels(channels)) => {
      guard channels.length() <= 255 else {
        raise Limit(5, "too many log channel names")
      }
      out.write_byte(channels.length().to_byte())
      for channel in channels {
        write_id(out, channel)
      }
    }
    (34U, LogChannelThreshold(level, trace)) => {
      control_default_level(level, false)
      out.write_byte(level.to_byte())
      out.write_byte(if trace { b'\x01' } else { b'\x00' })
    }
    (35U, OverflowCount(count)) => write_u32(out, count, endian)
    (36U, SynchronizedTime(seconds, nanos)) => {
      guard seconds <= 0xFFFFFFFFFFFFUL && nanos < 1000000000U else {
        raise Invalid(5, "synchronized time does not fit its wire fields")
      }
      write_u32(out, nanos, endian)
      write_u32(out, seconds.to_uint(), endian)
      write_u16(out, (seconds >> 32).to_int(), endian)
    }
    _ => raise Invalid(0, "control response does not match the service ID")
  }
  let result : ControlResponse = { service_id, status, data: out.to_bytes(), }
  guard self == result.interpret(endian) else {
    raise Invalid(0, "service has no standard typed response")
  }
  result
}

///|
/// Create a canonical request while preserving the legacy vendor interface API.
pub fn ControlRequest::canonical_bytes(
  self : ControlRequest,
  endian : Endian,
) -> Bytes raise DltError {
  let request : ControlRequest = match self {
    SetLogLevel(a, c, v, _) => SetLogLevel(a, c, v, "")
    SetTraceStatus(a, c, v, _) => SetTraceStatus(a, c, v, "")
    GetLogInfo(v, a, c, _) => {
      guard v >= 0 && v <= 255 else {
        raise Invalid(4, "GetLogInfo option must fit one byte")
      }
      let out = @buffer.Buffer::Buffer()
      write_u32(out, 3U, endian)
      out.write_byte(v.to_byte())
      write_id(out, a)
      write_id(out, c)
      write_u32(out, 0U, endian)
      return out.to_bytes()
    }
    SetDefaultLogLevel(v, _) => SetDefaultLogLevel(v, "")
    SetDefaultTraceStatus(v, _) => SetDefaultTraceStatus(v, "")
    _ => self
  }
  encode_control_request(request, endian)
}

///|
pub fn Message::standard_control_request(
  self : Message,
) -> ControlRequest raise DltError {
  require_control(self, 1)
  guard self.header.extended is Some(e) && e.argument_count == 0 else {
    raise Invalid(0, "expected canonical control NOAR")
  }
  let body = self.payload[:]
  let order = self.header.endian
  match read_u32(body, 0, order) {
    3U => {
      control_exact(body, 17)
      GetLogInfo(body[4].to_int(), read_id(body, 5), read_id(body, 9), "")
    }
    1U | 2U | 17U | 18U as id => {
      let reserved_start = if id <= 2U { 13 } else { 5 }
      control_exact(body, reserved_start + 4)
      let buffer = @buffer.Buffer::Buffer()
      buffer.write_bytes(body[:reserved_start])
      write_u32(buffer, 0U, order)
      decode_control_request(buffer.to_bytes()[:], order)
    }
    _ => decode_control_request(body, order)
  }
}

///|
pub fn ControlRequest::standard_message(
  self : ControlRequest,
  header : Header,
  storage? : StorageHeader,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  check_limits(limits)
  finish_verbose_message(
    control_header(header, 1),
    self.canonical_bytes(header.endian),
    storage,
    limits,
  )
}

///|
pub fn ControlResponse::standard_message(
  self : ControlResponse,
  header : Header,
  storage? : StorageHeader,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  check_limits(limits)
  ignore(self.interpret(header.endian))
  let canonical = control_header(header, 2)
  guard canonical.extended is Some(ext) else {
    raise Invalid(0, "missing control header")
  }
  // In the packed status-7 representation, one logical application list
  // accompanies the service envelope. Generic verbose decoding is separate.
  let h = if self.service_id == 3U && self.status == 7 {
    {
      ..canonical,
      extended: Some({ ..ext, verbose: true, argument_count: 1, }),
    }
  } else {
    canonical
  }
  finish_verbose_message(
    h,
    encode_control_response(self, header.endian),
    storage,
    limits,
  )
}

///|
/// Report §5.6 rejection status before applying a supported standard command.
/// Zero means the caller can proceed with the application's configuration.
pub fn r19_request_status(
  request : ControlRequest,
  busy~ : Bool = false,
  valid_configuration~ : Bool = true,
  filtering_supported~ : Bool = false,
) -> Int32 {
  if busy || !valid_configuration {
    return 2
  }
  match request {
    GetLogInfo(option, _, _, _) if option != 6 && option != 7 => 1
    SetMessageFiltering(_) if !filtering_supported => 1
    Unknown(id, _) =>
      match id {
        7U
        | 8U
        | 9U
        | 12U
        | 13U
        | 14U
        | 15U
        | 16U
        | 20U
        | 22U
        | 24U
        | 25U
        | 26U
        | 27U
        | 28U
        | 29U
        | 30U => 1
        // Application-assigned services require explicit host integration.
        _ if id >= 4095U => 1
        _ => 2
      }
    _ => 0
  }
}

///|
/// Read application-assigned service bytes from a captured request.
/// Data is interpreted only as an opaque field of the declared size.
pub fn ControlRequest::application_data(
  self : ControlRequest,
  endian : Endian,
) -> Bytes raise DltError {
  guard self is Unknown(id, data) && id >= 4095U else {
    raise Invalid(0, "expected an application-assigned control service")
  }
  guard data.length() <= 65531 else {
    raise Limit(4, "application service body exceeds wire length")
  }
  let view = data[:]
  let size = read_u32(view, 0, endian)
  let available = (data.length() - 4).reinterpret_as_uint()
  guard size <= available else {
    raise Truncated(8, "application service data truncated")
  }
  guard size == available else {
    raise Invalid(
      8 + size.reinterpret_as_int(),
      "trailing application service data",
    )
  }
  view[4:].to_owned()
}
