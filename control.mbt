///|
/// Passive codec for DLT v1 control services. It never opens a connection or
/// sends requests. Unknown service bodies remain available without interpretation.
/// A level/status of -1 selects the configured default (wire byte 0xff).
pub(all) enum ControlRequest {
  SetLogLevel(String, String, Int32, String)
  SetTraceStatus(String, String, Int32, String)
  GetLogInfo(Int32, String, String, String)
  GetDefaultLogLevel
  StoreConfiguration
  ResetConfiguration
  SetDefaultLogLevel(Int32, String)
  SetDefaultTraceStatus(Int32, String)
  GetSoftwareVersion
  Unknown(UInt32, Bytes)
} derive(Eq, @debug.Debug)

///|
pub(all) struct ControlResponse {
  service_id : UInt32
  status : Int32
  data : Bytes
} derive(Eq, @debug.Debug)

///|
pub fn ControlRequest::service_id(self : ControlRequest) -> UInt32 {
  match self {
    SetLogLevel(_, _, _, _) => 1U
    SetTraceStatus(_, _, _, _) => 2U
    GetLogInfo(_, _, _, _) => 3U
    GetDefaultLogLevel => 4U
    StoreConfiguration => 5U
    ResetConfiguration => 6U
    SetDefaultLogLevel(_, _) => 17U
    SetDefaultTraceStatus(_, _) => 18U
    GetSoftwareVersion => 19U
    Unknown(id, _) => id
  }
}

///|
fn control_level(value : Int32, trace : Bool) -> Unit raise DltError {
  let maximum = if trace { 1 } else { 6 }
  guard value >= -1 && value <= maximum else {
    raise Invalid(
      0, "control log level/trace status is outside its wire domain",
    )
  }
}

///|
fn control_option(value : Int32) -> Unit raise DltError {
  guard value >= 3 && value <= 7 else {
    raise Invalid(0, "GetLogInfo option must be 3..7")
  }
}

///|
fn control_exact(data : BytesView, length : Int32) -> Unit raise DltError {
  require_range(data, 0, length)
  guard data.length() == length else {
    raise Invalid(length, "unexpected trailing control request data")
  }
}

///|
fn control_byte(value : Byte) -> Int32 {
  if value == b'\xff' {
    -1
  } else {
    value.to_int()
  }
}

///|
pub fn encode_control_request(
  request : ControlRequest,
  endian : Endian,
) -> Bytes raise DltError {
  let out = @buffer.Buffer::Buffer()
  write_u32(out, request.service_id(), endian)
  match request {
    SetLogLevel(application, context, level, interface) => {
      control_level(level, false)
      write_id(out, application)
      write_id(out, context)
      out.write_byte(level.to_byte())
      write_id(out, interface)
    }
    SetTraceStatus(application, context, status, interface) => {
      control_level(status, true)
      write_id(out, application)
      write_id(out, context)
      out.write_byte(status.to_byte())
      write_id(out, interface)
    }
    GetLogInfo(option, application, context, interface) => {
      control_option(option)
      out.write_byte(option.to_byte())
      write_id(out, application)
      write_id(out, context)
      write_id(out, interface)
    }
    SetDefaultLogLevel(level, interface) => {
      control_level(level, false)
      out.write_byte(level.to_byte())
      write_id(out, interface)
    }
    SetDefaultTraceStatus(status, interface) => {
      control_level(status, true)
      out.write_byte(status.to_byte())
      write_id(out, interface)
    }
    GetDefaultLogLevel
    | StoreConfiguration
    | ResetConfiguration
    | GetSoftwareVersion => ()
    Unknown(id, bytes) => {
      guard id != 1U &&
        id != 2U &&
        id != 3U &&
        id != 4U &&
        id != 5U &&
        id != 6U &&
        id != 17U &&
        id != 18U &&
        id != 19U else {
        raise Invalid(
          0, "known control service requires its typed request variant",
        )
      }
      guard bytes.length() <= 65531 else {
        raise Limit(4, "unknown control request body exceeds wire length")
      }
      out.write_bytes(bytes[:])
    }
  }
  out.to_bytes()
}

///|
pub fn decode_control_request(
  data : BytesView,
  endian : Endian,
) -> ControlRequest raise DltError {
  guard data.length() <= 65535 else {
    raise Limit(0, "control request exceeds wire length")
  }
  let id = read_u32(data, 0, endian)
  match id {
    1U => {
      control_exact(data, 17)
      let application = read_id(data, 4)
      let context = read_id(data, 8)
      let level = control_byte(data[12])
      control_level(level, false)
      SetLogLevel(application, context, level, read_id(data, 13))
    }
    2U => {
      control_exact(data, 17)
      let application = read_id(data, 4)
      let context = read_id(data, 8)
      let status = control_byte(data[12])
      control_level(status, true)
      SetTraceStatus(application, context, status, read_id(data, 13))
    }
    3U => {
      control_exact(data, 17)
      let option = data[4].to_int()
      control_option(option)
      GetLogInfo(option, read_id(data, 5), read_id(data, 9), read_id(data, 13))
    }
    4U => {
      control_exact(data, 4)
      GetDefaultLogLevel
    }
    5U => {
      control_exact(data, 4)
      StoreConfiguration
    }
    6U => {
      control_exact(data, 4)
      ResetConfiguration
    }
    17U => {
      control_exact(data, 9)
      let level = control_byte(data[4])
      control_level(level, false)
      SetDefaultLogLevel(level, read_id(data, 5))
    }
    18U => {
      control_exact(data, 9)
      let status = control_byte(data[4])
      control_level(status, true)
      SetDefaultTraceStatus(status, read_id(data, 5))
    }
    19U => {
      control_exact(data, 4)
      GetSoftwareVersion
    }
    _ => Unknown(id, data[4:].to_owned())
  }
}

///|
/// Generic responses preserve service-specific status values and the full body.
/// GetLogInfo responses use special status values 3..9, so status is not reduced
/// to a success/failure Boolean. Its nested application list is kept raw.
pub fn decode_control_response(
  data : BytesView,
  endian : Endian,
) -> ControlResponse raise DltError {
  require_range(data, 0, 5)
  guard data.length() <= 65535 else {
    raise Limit(0, "control response exceeds wire length")
  }
  {
    service_id: read_u32(data, 0, endian),
    status: data[4].to_int(),
    data: data[5:].to_owned(),
  }
}

///|
pub fn encode_control_response(
  response : ControlResponse,
  endian : Endian,
) -> Bytes raise DltError {
  guard response.status >= 0 && response.status <= 255 else {
    raise Invalid(4, "response status must fit one byte")
  }
  guard response.data.length() <= 65530 else {
    raise Limit(5, "control response body exceeds wire length")
  }
  let out = @buffer.Buffer::Buffer()
  write_u32(out, response.service_id, endian)
  out.write_byte(response.status.to_byte())
  out.write_bytes(response.data[:])
  out.to_bytes()
}

///|
pub fn ControlResponse::software_version(
  self : ControlResponse,
  endian : Endian,
  maximum_bytes~ : Int32 = 65526,
) -> String raise DltError {
  guard self.service_id == 19U && self.status == 0 else {
    raise Invalid(0, "expected successful GetSoftwareVersion response")
  }
  guard maximum_bytes >= 0 else {
    raise Invalid(0, "negative software version bound")
  }
  let length = read_u32(self.data[:], 0, endian)
  guard length.to_uint64() <= maximum_bytes.to_uint64() else {
    raise Limit(9, "software version exceeds configured byte bound")
  }
  guard length.to_uint64() == (self.data.length() - 4).to_uint64() else {
    raise Invalid(5, "software version length does not match response body")
  }
  let mut end = self.data.length()
  if end > 4 && self.data[end - 1] == b'\x00' {
    end = end - 1
  }
  for i in 4..<end {
    guard self.data[i] != b'\x00' else {
      raise Invalid(i + 5, "software version contains embedded NUL")
    }
  }
  @utf8.decode(self.data[4:end]) catch {
    _ => raise Invalid(9, "software version is not UTF-8")
  }
}

///|
pub fn software_version_response(
  version : String,
  endian : Endian,
) -> ControlResponse raise DltError {
  let bytes = @utf8.encode(version)
  guard bytes.length() <= 65526 else {
    raise Limit(0, "software version exceeds wire length")
  }
  for b in bytes {
    guard b != b'\x00' else {
      raise Invalid(0, "software version contains embedded NUL")
    }
  }
  let data = @buffer.Buffer::Buffer()
  write_u32(data, bytes.length().reinterpret_as_uint(), endian)
  data.write_bytes(bytes[:])
  { service_id: 19U, status: 0, data: data.to_bytes(), }
}

///|
pub fn ControlResponse::default_log_level(
  self : ControlResponse,
) -> Int32 raise DltError {
  guard self.service_id == 4U && self.status == 0 && self.data.length() == 1 else {
    raise Invalid(
      0, "expected successful GetDefaultLogLevel response with one byte",
    )
  }
  let level = self.data[0].to_int()
  guard level <= 6 else {
    raise Invalid(5, "default log level is outside 0..6")
  }
  level
}

///|
fn require_control(message : Message, subtype : Int32) -> Unit raise DltError {
  let extended = match message.header.extended {
    Some(value) => value
    None => raise Invalid(0, "control message requires extended header")
  }
  guard !extended.verbose &&
    extended.message_type == 3 &&
    extended.subtype == subtype else {
    raise Invalid(0, "message is not the expected nonverbose control subtype")
  }
}

///|
pub fn Message::control_request(
  self : Message,
) -> ControlRequest raise DltError {
  require_control(self, 1)
  decode_control_request(self.payload[:], self.header.endian)
}

///|
pub fn Message::control_response(
  self : Message,
) -> ControlResponse raise DltError {
  require_control(self, 2)
  decode_control_response(self.payload[:], self.header.endian)
}

///|
fn control_header(header : Header, subtype : Int32) -> Header {
  let (application, context) = match header.extended {
    Some(extended) => (extended.application, extended.context)
    None => ("DLTC", "DLTC")
  }
  {
    endian: header.endian,
    counter: header.counter,
    ecu: header.ecu,
    session: header.session,
    timestamp: header.timestamp,
    extended: Some({
      verbose: false,
      message_type: 3,
      subtype,
      argument_count: 1,
      application,
      context,
    }),
  }
}

///|
pub fn control_request_message(
  request : ControlRequest,
  header : Header,
  storage? : StorageHeader,
) -> Message raise DltError {
  {
    storage,
    header: control_header(header, 1),
    payload: encode_control_request(request, header.endian),
  }
}

///|
pub fn control_response_message(
  response : ControlResponse,
  header : Header,
  storage? : StorageHeader,
) -> Message raise DltError {
  {
    storage,
    header: control_header(header, 2),
    payload: encode_control_response(response, header.endian),
  }
}
