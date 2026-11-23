///|
/// This adapter owns no files; the Node host provides bounded range I/O.
#external
type Host

///|
extern "js" fn read_host(host : Host, offset : String, length : Int32) -> Bytes =
  #| (host, offset, length) => host.read(offset, length)

///|
extern "js" fn write_host(host : Host, bytes : Bytes) -> Int32 =
  #| (host, bytes) => host.write(bytes)

///|
fn source_for(host : Host, size : String) -> @dlt.Source raise @dlt.DltError {
  let size = @string.parse_uint64(size[:]) catch {
    _ => raise @dlt.Invalid(0, "source size is not an unsigned decimal")
  }
  @dlt.Source::new(size, (offset, length) => {
    read_host(host, offset.to_string(), length)
  })
}

///|
fn selector(input : String) -> @dlt.FilterExpr raise @dlt.DltError {
  @dlt.FilterExpr::parse(if input == "" { "true" } else { input })
}

///|
fn metadata_message(entry : @dlt.SourceEntry) -> @dlt.Message {
  { storage: entry.storage, header: entry.header, payload: b"", }
}

///|
fn inspect(
  host : Host,
  size : String,
  expression : String,
  maximum_messages : Int32,
) -> Json raise @dlt.DltError {
  guard maximum_messages >= 0 && maximum_messages <= 10000 else {
    raise @dlt.Limit(0, "summary limit must be 0..10000")
  }
  let source = source_for(host, size)
  let query = selector(expression)
  let cursor = @dlt.SourceCursor::new(source)
  let messages : Array[Json] = []
  let mut matched = 0UL
  while cursor.next_entry() is Some(entry) {
    if query.matches(metadata_message(entry)) {
      matched += 1UL
      if messages.length() < maximum_messages {
        messages.push({
          "offset": entry.offset.to_string(),
          "length": entry.length,
          "payload_bytes": entry.payload_length,
          "header": entry.header.to_json(),
        })
      }
    }
  }
  {
    "success": true,
    "operation": "inspect",
    "source_bytes": source.size().to_string(),
    "scanned": cursor.entry_count().to_string(),
    "matched": matched.to_string(),
    "shown": messages.length(),
    "header_bytes_read": cursor.header_bytes_read().to_string(),
    "metadata_only": true,
    "messages": Json::array(messages),
  }
}

///|
/// Scan Storage headers only, with at most maximum_messages metadata summaries.
pub fn inspect_file(
  host : Host,
  size : String,
  expression : String,
  maximum_messages : Int32,
) -> String {
  let result = inspect(host, size, expression, maximum_messages) catch {
    error =>
      return Json::object({ "success": false, "error": error.describe() }).stringify()
  }
  result.stringify()
}

///|
fn extract(
  host : Host,
  size : String,
  expression : String,
) -> Json raise @dlt.DltError {
  let source = source_for(host, size)
  let query = selector(expression)
  let cursor = @dlt.SourceCursor::new(source)
  let mut matched = 0UL
  let mut written = 0UL
  while cursor.next_entry() is Some(entry) {
    if query.matches(metadata_message(entry)) {
      // Recheck the selected record's declared boundary using the same core codec.
      let bytes = read_host(host, entry.offset.to_string(), entry.length)
      guard bytes.length() == entry.length else {
        raise @dlt.Truncated(0, "host returned a short extraction read")
      }
      let message = @dlt.decode_exact(bytes[:])
      guard message.header == entry.header && message.storage == entry.storage else {
        raise @dlt.Invalid(
          0, "source changed between metadata scan and extraction",
        )
      }
      guard write_host(host, bytes) == bytes.length() else {
        raise @dlt.Truncated(0, "host returned a short extraction write")
      }
      matched += 1UL
      written += bytes.length().to_uint64()
    }
  }
  {
    "success": true,
    "operation": "extract",
    "source_bytes": source.size().to_string(),
    "scanned": cursor.entry_count().to_string(),
    "matched": matched.to_string(),
    "written_bytes": written.to_string(),
    "exact_record_bytes": true,
  }
}

///|
/// Copy matching Storage records verbatim through the host's output callback.
pub fn extract_file(host : Host, size : String, expression : String) -> String {
  let result = extract(host, size, expression) catch {
    error =>
      return Json::object({ "success": false, "error": error.describe() }).stringify()
  }
  result.stringify()
}
