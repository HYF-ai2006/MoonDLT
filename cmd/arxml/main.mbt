///|
pub fn decode_arxml_record(
  metadata : String,
  frame : Bytes,
  framing : String,
) -> String {
  let result = try {
    let framing : @dlt.Framing = match framing {
      "storage" => Storage
      "network" => Network
      "serial" => Serial
      _ => raise @dlt.Invalid(0, "unknown DLT framing")
    }
    let parsed = @json.parse(metadata) catch {
      _ => raise @dlt.Invalid(0, "malformed ARXML catalogue JSON")
    }
    let catalog = @dlt.ArxmlCatalog::from_json(parsed)
    let message = @dlt.decode_exact(frame[:], framing~)
    let values = catalog.decode(message).to_json()
    Json::object({ "success": true, "value": values })
  } catch {
    e => Json::object({ "success": false, "error": e.describe() })
  }
  result.stringify()
}
