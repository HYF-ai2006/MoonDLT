///|
// A host-independent ingestion example: arbitrary chunk boundaries, typed
// payload decoding, then an index-based byte-preserving extraction.
fn demonstration() -> Unit raise @dlt.DltError {
  let header : @dlt.Header = {
    endian: Little,
    counter: 7,
    ecu: Some("ECU1"),
    session: Some(1U),
    timestamp: Some(12500U),
    extended: Some({
      verbose: true,
      message_type: 0,
      subtype: 4,
      argument_count: 0,
      application: "PWR",
      context: "TEMP",
    }),
  }
  let storage : @dlt.StorageHeader = {
    seconds: 1700000000U,
    microseconds: 123456U,
    ecu: "ECU1",
  }
  let message = @dlt.Message::with_arguments(
    header,
    [Text(Utf8, "发动机温度"), Signed(16, 87L), Text(Ascii, "C")],
    storage~,
  )
  let bytes = @dlt.encode(message)
  println("DLT v1 storage record: \{bytes.length()} bytes")
  let decoder = @dlt.StreamDecoder::new()
  let mut chunks = 0
  let mut recovered = 0
  for offset = 0; offset < bytes.length(); offset = offset + 7 {
    let end = if offset + 7 < bytes.length() {
      offset + 7
    } else {
      bytes.length()
    }
    let batch = decoder.feed(bytes[offset:end])
    chunks = chunks + 1
    for decoded in batch.messages {
      recovered = recovered + 1
      let parameters = Json::array(
        decoded.arguments().map(value => value.to_json()),
      )
      println("decoded parameters: \{parameters.stringify()}")
    }
  }
  decoder.finish()
  println(
    "\{chunks} input chunks, \{recovered} complete messages, \{decoder.buffered_bytes()} pending bytes",
  )
  let entries = @dlt.build_index(bytes[:])
  let filter : @dlt.Filter = { ..@dlt.Filter::all(), contexts: Some(["TEMP"]), }
  let selected = @dlt.query_index(entries[:], filter)
  let copied = @dlt.copy_indexed(bytes[:], selected[:])
  println(
    "index selected \{selected.length()} record(s), preserved bytes: \{copied == bytes}",
  )
}

///|
fn main {
  demonstration() catch {
    error => println(error.describe())
  }
}
