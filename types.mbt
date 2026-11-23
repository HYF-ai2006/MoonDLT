///|
/// Stable categories, with byte offsets relative to the current message/input.
pub(all) suberror DltError {
  Invalid(Int, String)
  Truncated(Int, String)
  Unsupported(Int, String)
  Limit(Int, String)
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
  message_bytes : Int
  buffered_bytes : Int
  arguments : Int
  string_bytes : Int
  resync_bytes : Int
} derive(Eq, @debug.Debug)

///|
pub fn Limits::default() -> Limits {
  { message_bytes: 65535, buffered_bytes: 262144, arguments: 255,
    string_bytes: 65535, resync_bytes: 1048576 }
}

///|
pub(all) struct StorageHeader {
  seconds : UInt
  microseconds : UInt
  ecu : String
} derive(Eq, @debug.Debug)

///|
/// message_type: 0 log, 1 application trace, 2 network trace, 3 control.
/// subtype is the corresponding four-bit log level/trace/control code.
pub(all) struct ExtendedHeader {
  verbose : Bool
  message_type : Int
  subtype : Int
  argument_count : Int
  application : String
  context : String
} derive(Eq, @debug.Debug)

///|
/// Header numeric optional fields always use network byte order on the wire.
/// endian applies only to the payload type words and values.
pub(all) struct Header {
  endian : Endian
  counter : Int
  ecu : String?
  session : UInt?
  timestamp : UInt?
  extended : ExtendedHeader?
} derive(Eq, @debug.Debug)

///|
pub fn Header::new(counter? : Int = 0, endian? : Endian = Little) -> Header {
  { endian, counter, ecu: None, session: None, timestamp: None, extended: None }
}

///|
/// Payload is preserved exactly; decoding verbose arguments is an explicit step.
pub(all) struct Message {
  storage : StorageHeader?
  header : Header
  payload : Bytes
} derive(Eq, @debug.Debug)

///|
pub fn Message::new(header : Header, payload : Bytes,
  storage? : StorageHeader) -> Message {
  { storage, header, payload }
}

///|
pub(all) struct Decoded {
  message : Message
  consumed : Int
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
  Signed(Int, Int64)
  Unsigned(Int, UInt64)
  Floating(Int, Double)
  Text(TextEncoding, String)
  Raw(Bytes)
} derive(Eq, @debug.Debug)

///|
pub(all) struct StreamBatch {
  messages : Array[Message]
  skipped : Int
} derive(Eq, @debug.Debug)

///|
pub(all) struct IndexEntry {
  offset : Int
  length : Int
  storage : StorageHeader?
  header : Header
} derive(Eq, @debug.Debug)
