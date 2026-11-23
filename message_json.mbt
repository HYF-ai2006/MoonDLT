///|
/// Portable message envelope: wire payload bytes remain hexadecimal so unknown
/// types and signaling-NaN payload bits survive a JSON round trip unchanged.
pub fn Message::to_json(self : Message) -> Json {
  {
    "format": "moondlt.message.v1",
    "storage": storage_json(self.storage),
    "header": self.header.to_json(),
    "payload_hex": hex_encode(self.payload[:]),
  }
}

///|
pub fn Message::from_json(
  json : Json,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  check_limits(limits)
  let object = verbose_object(json)
  verbose_fields(object, ["format", "storage", "header", "payload_hex"])
  guard verbose_string(verbose_field(object, "format")) == "moondlt.message.v1" else {
    raise Unsupported(0, "unknown message JSON format")
  }
  let text = verbose_string(verbose_field(object, "payload_hex"))
  guard text.length() <= limits.message_bytes * 2 else {
    raise Limit(0, "message JSON payload exceeds byte budget")
  }
  let message = {
    storage: storage_from_json(verbose_field(object, "storage")),
    header: Header::from_json(verbose_field(object, "header"), limits~),
    payload: hex_decode(text),
  }
  ignore(
    encode(
      message,
      framing=if message.storage is Some(_) { Storage } else { Network },
      limits~,
    ),
  )
  message
}

///|
pub fn Header::to_json(self : Header) -> Json {
  {
    "endian": if self.endian == Big {
      "big"
    } else {
      "little"
    },
    "counter": self.counter,
    "ecu": json_optional_string(self.ecu),
    "session": json_optional_uint(self.session),
    "timestamp": json_optional_uint(self.timestamp),
    "extended": match self.extended {
      None => Json::null()
      Some(ext) =>
        {
          "verbose": ext.verbose,
          "type": ext.message_type,
          "subtype": ext.subtype,
          "count": ext.argument_count,
          "application": ext.application,
          "context": ext.context,
        }
    },
  }
}

///|
pub fn Header::from_json(
  json : Json,
  limits~ : Limits = Limits::default(),
) -> Header raise DltError {
  check_limits(limits)
  let object = verbose_object(json)
  verbose_fields(object, [
    "endian", "counter", "ecu", "session", "timestamp", "extended",
  ])
  let endian = match verbose_string(verbose_field(object, "endian")) {
    "big" => Big
    "little" => Little
    _ => raise Invalid(0, "message JSON endian must be big or little")
  }
  let extended = match verbose_field(object, "extended") {
    Null => None
    value => {
      let ext = verbose_object(value)
      verbose_fields(ext, [
        "verbose", "type", "subtype", "count", "application", "context",
      ])
      let verbose = match verbose_field(ext, "verbose") {
        True => true
        False => false
        _ => raise Invalid(0, "extended JSON verbose must be a Boolean")
      }
      Some({
        verbose,
        message_type: verbose_small_integer(verbose_field(ext, "type"), 7),
        subtype: verbose_small_integer(verbose_field(ext, "subtype"), 15),
        argument_count: verbose_small_integer(
          verbose_field(ext, "count"),
          limits.arguments,
        ),
        application: verbose_string(verbose_field(ext, "application")),
        context: verbose_string(verbose_field(ext, "context")),
      })
    }
  }
  let header = {
    endian,
    counter: verbose_small_integer(verbose_field(object, "counter"), 255),
    ecu: json_read_optional_string(verbose_field(object, "ecu")),
    session: json_read_optional_uint(verbose_field(object, "session")),
    timestamp: json_read_optional_uint(verbose_field(object, "timestamp")),
    extended,
  }
  write_header(@buffer.Buffer::Buffer(), header, 0, limits)
  header
}

///|
fn storage_json(storage : StorageHeader?) -> Json {
  match storage {
    None => Json::null()
    Some(s) =>
      {
        "seconds": s.seconds.to_string(),
        "microseconds": s.microseconds.to_string(),
        "ecu": s.ecu,
      }
  }
}

///|
fn storage_from_json(json : Json) -> StorageHeader? raise DltError {
  match json {
    Null => None
    value => {
      let object = verbose_object(value)
      verbose_fields(object, ["seconds", "microseconds", "ecu"])
      let seconds = json_uint64(verbose_field(object, "seconds"), 0xFFFFFFFFUL).to_uint()
      let microseconds = json_uint64(
        verbose_field(object, "microseconds"),
        999999UL,
      ).to_uint()
      let ecu = verbose_string(verbose_field(object, "ecu"))
      write_id(@buffer.Buffer::Buffer(), ecu)
      Some({ seconds, microseconds, ecu, })
    }
  }
}

///|
fn json_uint64(json : Json, maximum : UInt64) -> UInt64 raise DltError {
  let text = verbose_string(json)
  guard text.length() >= 1 && text.length() <= 20 else {
    raise Invalid(0, "JSON unsigned integer decimal length invalid")
  }
  let value = @string.parse_uint64(text[:]) catch {
    _ => raise Invalid(0, "invalid JSON unsigned decimal")
  }
  guard value <= maximum && text == value.to_string() else {
    raise Invalid(0, "JSON unsigned integer exceeds range or is noncanonical")
  }
  value
}

///|
fn json_optional_string(value : String?) -> Json {
  match value {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
fn json_optional_uint(value : UInt32?) -> Json {
  match value {
    Some(v) => Json::string(v.to_string())
    None => Json::null()
  }
}

///|
fn json_read_optional_string(json : Json) -> String? raise DltError {
  match json {
    Null => None
    value => Some(verbose_string(value))
  }
}

///|
fn json_read_optional_uint(json : Json) -> UInt32? raise DltError {
  match json {
    Null => None
    value => Some(json_uint64(value, 0xFFFFFFFFUL).to_uint())
  }
}

///|
pub fn framing_name(framing : Framing) -> String {
  match framing {
    Storage => "storage"
    Network => "network"
    Serial => "serial"
  }
}

///|
pub fn parse_framing(name : String) -> Framing raise DltError {
  match name {
    "storage" => Storage
    "network" => Network
    "serial" => Serial
    _ => raise Invalid(0, "framing must be storage, network or serial")
  }
}
