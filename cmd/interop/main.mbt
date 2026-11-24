///|
fn argument_json(argument : @dlt.Argument) -> Json {
  match argument {
    Boolean(value) => { "kind": "bool", "value": value }
    Signed(width, value) =>
      { "kind": "signed", "width": width, "value": value.to_string() }
    Unsigned(width, value) =>
      { "kind": "unsigned", "width": width, "value": value.to_string() }
    Floating(width, value) =>
      { "kind": "float", "width": width, "value": value }
    Text(encoding, value) =>
      {
        "kind": "string",
        "encoding": match encoding {
          Ascii => "ascii"
          Utf8 => "utf8"
        },
        "value": value,
      }
    Raw(value) => { "kind": "raw", "value": @dlt.hex_encode(value[:]) }
  }
}

///|
fn message_json(message : @dlt.Message) -> Json raise @dlt.DltError {
  let header = message.header
  let storage : Json = match message.storage {
    None => Json::null()
    Some(value) =>
      {
        "seconds": value.seconds.to_string(),
        "microseconds": value.microseconds.to_string(),
        "ecu": value.ecu,
      }
  }
  let extended : Json = match header.extended {
    None => Json::null()
    Some(value) =>
      {
        "verbose": value.verbose,
        "message_type": value.message_type,
        "subtype": value.subtype,
        "argument_count": value.argument_count,
        "application": value.application,
        "context": value.context,
      }
  }
  let arguments : Json = match header.extended {
    Some({ verbose: true, .. }) =>
      Json::array(message.arguments().map(argument_json))
    _ => Json::null()
  }
  {
    "storage": storage,
    "endian": match header.endian {
      Little => "little"
      Big => "big"
    },
    "counter": header.counter,
    "ecu": match header.ecu {
      Some(value) => Json::string(value)
      None => Json::null()
    },
    "session": match header.session {
      Some(value) => Json::string(value.to_string())
      None => Json::null()
    },
    "timestamp": match header.timestamp {
      Some(value) => Json::string(value.to_string())
      None => Json::null()
    },
    "extended": extended,
    "payload_hex": @dlt.hex_encode(message.payload[:]),
    "arguments": arguments,
  }
}

///|
fn rich_arguments() -> Array[@dlt.Argument] {
  [
    Boolean(true),
    Boolean(false),
    Signed(8, -128L),
    Signed(16, -32768L),
    Signed(32, -2147483648L),
    Signed(64, -9223372036854775807L - 1L),
    Unsigned(8, 255UL),
    Unsigned(16, 65535UL),
    Unsigned(32, 4294967295UL),
    Unsigned(64, 18446744073709551615UL),
    Floating(32, -13.25),
    Floating(64, 0.125),
    Text(Ascii, "temperature"),
    Text(Utf8, "发动机🙂"),
    Text(Ascii, ""),
    Raw(b"\x00\xff\x44\x4c\x54\x01"),
    Raw(b""),
  ]
}

///|
// Case definitions deliberately contain values, not a second wire codec.
// The independent Python producer uses its own pydlt serializer.
fn vector_message(case_id : Int32) -> @dlt.Message raise @dlt.DltError {
  let storage : @dlt.StorageHeader = {
    seconds: 1700000000U,
    microseconds: 123456U,
    ecu: "ECU1",
  }
  let endian : @dlt.Endian = if case_id % 2 == 0 { Little } else { Big }
  let flags = if case_id < 2 { 15 } else { case_id - 2 }
  let extended : @dlt.ExtendedHeader? = if (flags & 8) != 0 {
    Some({
      verbose: true,
      message_type: 0,
      subtype: 4,
      argument_count: 0,
      application: "APP",
      context: "CTX1",
    })
  } else {
    None
  }
  let header : @dlt.Header = {
    endian,
    counter: if case_id == 1 {
      255
    } else {
      case_id
    },
    ecu: if (flags & 1) != 0 {
      Some("ECU2")
    } else {
      None
    },
    session: if (flags & 2) != 0 {
      Some(4294967295U)
    } else {
      None
    },
    timestamp: if (flags & 4) != 0 {
      Some(305419896U)
    } else {
      None
    },
    extended,
  }
  match extended {
    Some(_) => {
      let arguments : Array[@dlt.Argument] = if case_id < 2 {
        rich_arguments()
      } else {
        [Signed(32, -42L), Text(Ascii, "header-combination")]
      }
      @dlt.Message::with_arguments(header, arguments, storage~)
    }
    None => {
      let payload = match endian {
        Little => b"\x78\x56\x34\x12\x00\xff\x7f"
        Big => b"\x12\x34\x56\x78\x00\xff\x7f"
      }
      @dlt.Message::new(header, payload, storage~)
    }
  }
}

///|
fn parse_framing(text : String) -> @dlt.Framing raise @dlt.DltError {
  match text {
    "storage" => Storage
    "network" => Network
    "serial" => Serial
    _ => raise @dlt.DltError::Invalid(0, "unknown framing")
  }
}

///|
fn perform(
  arguments : Array[String],
  start : Int32,
) -> Json raise @dlt.DltError {
  let operation = arguments[start]
  guard start + 2 < arguments.length() else {
    raise @dlt.DltError::Invalid(0, "expected operation framing argument")
  }
  let framing = parse_framing(arguments[start + 1])
  let value = arguments[start + 2]
  match operation {
    "decode" => {
      let bytes = @dlt.hex_decode(value)
      let decoded = @dlt.decode(bytes[:], framing~)
      guard decoded.consumed == bytes.length() else {
        raise @dlt.DltError::Invalid(decoded.consumed, "trailing bytes")
      }
      message_json(decoded.message)
    }
    "roundtrip" => {
      let bytes = @dlt.hex_decode(value)
      let message = @dlt.decode_exact(bytes[:], framing~)
      // Rebuild the typed values rather than merely copying the original bytes.
      let rebuilt = match message.header.extended {
        Some({ verbose: true, .. }) =>
          match message.storage {
            Some(storage) =>
              @dlt.Message::with_arguments(
                message.header,
                message.arguments(),
                storage~,
              )
            None =>
              @dlt.Message::with_arguments(message.header, message.arguments())
          }
        _ => message
      }
      let encoded = @dlt.encode(rebuilt, framing~)
      { "hex": @dlt.hex_encode(encoded[:]), "message": message_json(rebuilt) }
    }
    "encode" => {
      guard value.length() >= 1 && value.length() <= 2 else {
        raise @dlt.DltError::Invalid(0, "case id outside 0..17")
      }
      let mut case_id = 0
      for character in value {
        guard character >= '0' && character <= '9' else {
          raise @dlt.DltError::Invalid(0, "case id must be decimal")
        }
        case_id = case_id * 10 + character.to_int() - 48
      }
      guard case_id >= 0 && case_id < 18 else {
        raise @dlt.DltError::Invalid(0, "case id outside 0..17")
      }
      let message = vector_message(case_id)
      let encoded = @dlt.encode(message, framing~)
      { "hex": @dlt.hex_encode(encoded[:]) }
    }
    _ => raise @dlt.DltError::Invalid(0, "unknown operation")
  }
}

///|
fn main {
  let arguments = @env.args()
  let mut start = -1
  for i in 0..<arguments.length() {
    if arguments[i] == "decode" ||
      arguments[i] == "encode" ||
      arguments[i] == "roundtrip" {
      start = i
      break
    }
  }
  if start < 0 {
    println(
      "Usage: interop decode|encode|roundtrip storage|network|serial HEX|CASE_ID",
    )
  } else {
    let result = perform(arguments, start) catch {
      error => {
        let failure : Json = { "error": error.describe() }
        println(failure.stringify())
        return
      }
    }
    println(result.stringify())
  }
}
