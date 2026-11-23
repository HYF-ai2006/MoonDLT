///|
/// Stable categories, with byte offsets relative to the current message/input.
pub(all) suberror DltError {
  Invalid(Int32, String)
  Truncated(Int32, String)
  Unsupported(Int32, String)
  Limit(Int32, String)
}

///|
pub fn DltError::describe(self : DltError) -> String {
  match self {
    Invalid(p, s) => "invalid DLT at \{p}: \{s}"
    Truncated(p, s) => "truncated DLT at \{p}: \{s}"
    Unsupported(p, s) => "unsupported DLT at \{p}: \{s}"
    Limit(p, s) => "DLT limit at \{p}: \{s}"
  }
}

///|
pub(all) enum Endian {
  Little
  Big
} derive(Eq, @debug.Debug)

///|
pub(all) enum Framing {
  Network
  Storage
  Serial
} derive(Eq, @debug.Debug)

///|
pub(all) struct Limits {
  message_bytes : Int32
  buffered_bytes : Int32
  arguments : Int32
  string_bytes : Int32
  resync_bytes : Int32
} derive(Eq, @debug.Debug)

///|
pub fn Limits::default() -> Limits {
  {
    message_bytes: 65535,
    buffered_bytes: 262144,
    arguments: 255,
    string_bytes: 65535,
    resync_bytes: 1048576,
  }
}

///|
pub(all) struct StorageHeader {
  seconds : UInt32
  microseconds : UInt32
  ecu : String
} derive(Eq, @debug.Debug)

///|
/// message_type: 0 log, 1 application trace, 2 network trace, 3 control.
/// subtype is the corresponding four-bit log level/trace/control code.
pub(all) struct ExtendedHeader {
  verbose : Bool
  message_type : Int32
  subtype : Int32
  argument_count : Int32
  application : String
  context : String
} derive(Eq, @debug.Debug)

///|
/// Header numeric optional fields always use network byte order on the wire.
/// endian applies only to the payload type words and values.
pub(all) struct Header {
  endian : Endian
  counter : Int32
  ecu : String?
  session : UInt32?
  timestamp : UInt32?
  extended : ExtendedHeader?
} derive(Eq, @debug.Debug)

///|
pub fn Header::new(counter~ : Int32 = 0, endian~ : Endian = Little) -> Header {
  {
    endian,
    counter,
    ecu: None,
    session: None,
    timestamp: None,
    extended: None,
  }
}

///|
/// Payload is preserved exactly; decoding verbose arguments is an explicit step.
pub(all) struct Message {
  storage : StorageHeader?
  header : Header
  payload : Bytes
} derive(Eq, @debug.Debug)

///|
pub fn Message::new(
  header : Header,
  payload : Bytes,
  storage? : StorageHeader,
) -> Message {
  { storage, header, payload, }
}

///|
pub(all) struct Decoded {
  message : Message
  consumed : Int32
} derive(Eq, @debug.Debug)

///|
/// Character encoding of a verbose DLT string (SCOD field).
pub(all) enum TextEncoding {
  Ascii
  Utf8
} derive(Eq, @debug.Debug)

///|
/// Scalar verbose parameters supported by the v1 common profile.
/// Widths are bits, integers accept 8/16/32/64, floating accepts 32/64.
pub(all) enum Argument {
  Boolean(Bool)
  Signed(Int32, Int64)
  Unsigned(Int32, UInt64)
  Floating(Int32, Double)
  Text(TextEncoding, String)
  Raw(Bytes)
} derive(Eq, @debug.Debug)

///|
pub(all) struct StreamBatch {
  messages : Array[Message]
  skipped : Int32
} derive(Eq, @debug.Debug)

///|
pub(all) struct IndexEntry {
  offset : Int32
  length : Int32
  storage : StorageHeader?
  header : Header
} derive(Eq, @debug.Debug)
