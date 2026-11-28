///|
/// A resolved R19-11 DLT-ARGUMENT. Widths are in bits for numeric values and
/// bytes for text and octets.
pub(all) enum ArxmlFieldType {
  StaticText(String)
  NumberField(NumericType)
  FixedNumberField(NumericType, WireScaling)
  TextField(TextEncoding, Int32)
  OctetField(Int32)
} derive(Eq, @debug.Debug)

///|
pub(all) struct ArxmlField {
  name : String
  unit_ref : String?
  kind : ArxmlFieldType
} derive(Eq, @debug.Debug)

///|
/// Resolved DLT-MESSAGE plus its DLT-LOG-CHANNEL and optional ECU context.
pub(all) struct ArxmlDescription {
  ecu : String?
  application : String
  context : String
  message_id : UInt32
  message_type : Int32
  subtype : Int32
  source_file : String?
  source_line : UInt32?
  fields : Array[ArxmlField]
} derive(Eq, @debug.Debug)

///|
pub(all) struct ArxmlDecoded {
  description : ArxmlDescription
  arguments : Array[WireParameter]
} derive(Eq, @debug.Debug)

///|
pub struct ArxmlCatalog {
  by_id : Map[UInt32, Array[ArxmlDescription]]
  count : Int32
}

///|
fn ArxmlFieldType::width(self : ArxmlFieldType) -> Int32 raise DltError {
  match self {
    StaticText(_) => 0
    NumberField(kind) | FixedNumberField(kind, _) => {
      let (_, bits) = wire_number_word(kind)
      bits / 8
    }
    TextField(_, size) | OctetField(size) => {
      guard size > 0 && size <= 65531 else {
        raise Invalid(0, "invalid ARXML dynamic width")
      }
      size
    }
  }
}

///|
fn ArxmlDescription::packed_length(
  self : ArxmlDescription,
) -> Int32 raise DltError {
  let mut size = 4
  for field in self.fields {
    let width = field.kind.width()
    guard width <= 65535 - size else {
      raise Limit(0, "ARXML payload size exceeds DLT maximum")
    }
    size += width
  }
  size
}

///|
pub fn ArxmlCatalog::new(
  entries : Array[ArxmlDescription],
) -> ArxmlCatalog raise DltError {
  guard entries.length() <= 4096 else {
    raise Limit(0, "too many ARXML message bindings")
  }
  let by_id : Map[UInt32, Array[ArxmlDescription]] = Map([])
  let mut total_fields = 0
  for entry in entries {
    guard entry.fields.length() <= 255 &&
      entry.fields.length() <= 65535 - total_fields else {
      raise Limit(0, "ARXML argument count exceeds metadata budget")
    }
    total_fields += entry.fields.length()
    let max_subtype = match entry.message_type {
      0 => 6
      1 => 5
      2 => 15
      _ => 0
    }
    guard entry.subtype >= 1 && entry.subtype <= max_subtype else {
      raise Invalid(0, "invalid ARXML log/trace type")
    }
    let id = @buffer.Buffer::Buffer()
    guard entry.application != "" &&
      entry.context != "" &&
      entry.ecu != Some("") else {
      raise Invalid(0, "empty ARXML ECU/APID/CTID")
    }
    write_id(id, entry.application)
    write_id(id, entry.context)
    if entry.ecu is Some(ecu) {
      write_id(id, ecu)
    }
    if entry.source_file is Some(source) {
      ignore(encode_text_checked(source, max_bytes=4096))
    }
    for field in entry.fields {
      ignore(encode_text_checked(field.name, max_bytes=256))
      guard field.name != "" else {
        raise Invalid(0, "empty ARXML argument name")
      }
      if field.unit_ref is Some(unit) {
        ignore(encode_text_checked(unit, max_bytes=4096))
      }
      match field.kind {
        StaticText(value) => {
          guard field.unit_ref is None else {
            raise Invalid(0, "static description cannot have a unit")
          }
          ignore(encode_text_checked(value, max_bytes=65535))
        }
        FixedNumberField(kind, scaling) => {
          let (_, width) = wire_number_word(kind)
          guard kind is IntValue(_) || kind is UIntValue(_) else {
            raise Invalid(0, "ARXML fixed point requires an integer field")
          }
          guard (scaling.quantization_bits & 0x7F800000U) != 0x7F800000U &&
            scaling.offset_bits.fits(wire_offset_width(width)) else {
            raise Invalid(0, "invalid ARXML fixed-point parameters")
          }
        }
        _ => ()
      }
    }
    ignore(entry.packed_length())
    let group = match by_id.get(entry.message_id) {
      Some(group) => group
      None => {
        let group : Array[ArxmlDescription] = []
        by_id[entry.message_id] = group
        group
      }
    }
    for registered in group {
      guard (entry.ecu, entry.application, entry.context) !=
        (registered.ecu, registered.application, registered.context) else {
        raise Invalid(0, "duplicate ARXML ECU/APID/CTID/message ID binding")
      }
    }
    group.push({ ..entry, fields: entry.fields.copy(), })
  }
  { by_id, count: entries.length(), }
}

///|
pub fn ArxmlCatalog::length(self : ArxmlCatalog) -> Int32 {
  self.count
}

///|
fn arxml_uint(j : Json) -> UInt32 raise DltError {
  let s = verbose_string(j)
  guard s.length() > 0 && s.length() <= 10 else {
    raise Invalid(0, "invalid ARXML UInt32 decimal length")
  }
  let value = @string.parse_uint(s[:]) catch {
    _ => raise Invalid(0, "invalid ARXML UInt32")
  }
  guard value.to_string() == s else {
    raise Invalid(0, "noncanonical ARXML UInt32 decimal")
  }
  value
}

///|
fn arxml_field_json(j : Json) -> ArxmlField raise DltError {
  let o = verbose_object(j)
  let name = verbose_string(verbose_field(o, "name"))
  let unit_ref = wire_optional_text(verbose_field(o, "unit_ref"))
  let kind : ArxmlFieldType = if verbose_string(verbose_field(o, "kind")) ==
    "static" {
    verbose_fields(o, ["name", "unit_ref", "kind", "text"])
    guard unit_ref is None else {
      raise Invalid(0, "static description cannot have a unit")
    }
    StaticText(verbose_string(verbose_field(o, "text")))
  } else {
    let scaling = match o.get("scaling") {
      None => {
        verbose_fields(o, ["name", "unit_ref", "kind", "bits"])
        None
      }
      Some(j) => {
        verbose_fields(o, ["name", "unit_ref", "kind", "bits", "scaling"])
        Some(verbose_object(j))
      }
    }
    let bits = verbose_small_integer(verbose_field(o, "bits"), 65531 * 8)
    guard bits > 0 && bits % 8 == 0 else {
      raise Invalid(0, "ARXML dynamic field needs a byte-aligned length")
    }
    let plain : ArxmlFieldType = match
      verbose_string(verbose_field(o, "kind")) {
      "bool" if bits == 8 => NumberField(Bool8)
      "signed" => NumberField(IntValue(bits))
      "unsigned" => NumberField(UIntValue(bits))
      "float" => NumberField(FloatValue(bits))
      "ascii" => TextField(Ascii, bits / 8)
      "utf8" => TextField(Utf8, bits / 8)
      "raw" => OctetField(bits / 8)
      _ => raise Unsupported(0, "unsupported ARXML field type")
    }
    match scaling {
      None => plain
      Some(v) => {
        verbose_fields(v, ["quantization_bits", "offset"])
        guard plain is NumberField(kind) else {
          raise Invalid(0, "ARXML scaling requires a numeric field")
        }
        let quantization_bits = wire_json_bits(
          verbose_field(v, "quantization_bits"),
          32,
        ).low.to_uint()
        let offset_bits = WideBits::from_decimal(
          verbose_string(verbose_field(v, "offset")),
          width=wire_offset_width(bits),
          signed=true,
        )
        FixedNumberField(kind, { quantization_bits, offset_bits, })
      }
    }
  }
  { name, unit_ref, kind, }
}

///|
/// Load the resolved JSON emitted by scripts/import_arxml.py.
pub fn ArxmlCatalog::from_json(json : Json) -> ArxmlCatalog raise DltError {
  let root = verbose_object(json)
  verbose_fields(root, ["format", "messages"])
  guard verbose_string(verbose_field(root, "format")) == "moondlt.arxml.v1" else {
    raise Unsupported(0, "unknown ARXML catalogue version")
  }
  let entries = verbose_array(verbose_field(root, "messages"))
  guard entries.length() <= 4096 else {
    raise Limit(0, "too many ARXML message bindings")
  }
  let decoded : Array[ArxmlDescription] = []
  let mut total_fields = 0
  for entry in entries {
    let o = verbose_object(entry)
    verbose_fields(o, [
      "ecu", "application", "context", "message_id", "message_type", "subtype", "source_file",
      "source_line", "fields",
    ])
    let source_line = match verbose_field(o, "source_line") {
      Null => None
      j => Some(arxml_uint(j))
    }
    let fields = verbose_array(verbose_field(o, "fields"))
    guard fields.length() <= 255 && fields.length() <= 65535 - total_fields else {
      raise Limit(0, "ARXML field count exceeds metadata budget")
    }
    total_fields += fields.length()
    let parsed = []
    for field in fields {
      parsed.push(arxml_field_json(field))
    }
    decoded.push({
      ecu: wire_optional_text(verbose_field(o, "ecu")),
      application: verbose_string(verbose_field(o, "application")),
      context: verbose_string(verbose_field(o, "context")),
      message_id: arxml_uint(verbose_field(o, "message_id")),
      message_type: verbose_small_integer(verbose_field(o, "message_type"), 2),
      subtype: verbose_small_integer(verbose_field(o, "subtype"), 15),
      source_file: wire_optional_text(verbose_field(o, "source_file")),
      source_line,
      fields: parsed,
    })
  }
  ArxmlCatalog::new(decoded)
}

///|
fn ArxmlCatalog::find(
  self : ArxmlCatalog,
  msg : Message,
) -> ArxmlDescription raise DltError {
  let id = msg.nonverbose_id()
  let ecu = match (msg.header.ecu, msg.storage) {
    (Some(id), _) if id != "" => Some(id)
    (_, Some(s)) if s.ecu != "" => Some(s.ecu)
    _ => None
  }
  guard self.by_id.get(id) is Some(candidates) else {
    raise Unsupported(0, "unknown ARXML message ID")
  }
  let mut selected : ArxmlDescription? = None
  let mut selected_specificity = -1
  let mut tied = false
  for candidate in candidates {
    if (ecu, candidate.ecu) is (Some(a), Some(b)) && a != b {
      continue
    }
    if msg.header.extended is Some(ext) {
      if ext.application != candidate.application ||
        ext.context != candidate.context {
        continue
      }
    }
    let specificity = if (ecu, candidate.ecu) is (Some(_), Some(_)) {
      1
    } else {
      0
    }
    if specificity > selected_specificity {
      selected = Some(candidate)
      selected_specificity = specificity
      tied = false
    } else if specificity == selected_specificity {
      tied = true
    }
  }
  guard selected is Some(description) else {
    raise Unsupported(0, "no ARXML binding matches this ECU/APID/CTID")
  }
  guard !tied else { raise Invalid(0, "ambiguous ARXML message binding") }
  if msg.header.extended is Some(ext) {
    guard ext.message_type == description.message_type &&
      ext.subtype == description.subtype else {
      raise Invalid(0, "ARXML MSIN differs from extended header")
    }
    guard ext.argument_count == 0 else {
      raise Invalid(0, "nonverbose NOAR must be zero")
    }
  }
  description
}

///|
pub fn ArxmlCatalog::decode(
  self : ArxmlCatalog,
  message : Message,
  limits~ : Limits = Limits::default(),
) -> ArxmlDecoded raise DltError {
  check_limits(limits)
  let payload = message.payload[:]
  guard payload.length() <= limits.message_bytes - message.header.wire_size() else {
    raise Limit(0, "ARXML message exceeds byte budget")
  }
  let description = self.find(message)
  guard description.fields.length() <= limits.arguments else {
    raise Limit(0, "ARXML argument budget exceeded")
  }
  let expected = description.packed_length()
  require_range(payload, 0, expected)
  guard payload.length() == expected else {
    raise Invalid(expected, "trailing bytes after ARXML fields")
  }
  let mut offset = 4
  let arguments : Array[WireParameter] = []
  for field in description.fields {
    let width = field.kind.width()
    let item : WireParameter = match field.kind {
      StaticText(value) => {
        ignore(encode_text_checked(value, max_bytes=limits.string_bytes))
        StringParameter(Utf8, value, Some(field.name))
      }
      NumberField(kind) | FixedNumberField(kind, _) => {
        let bits = read_bits(payload, offset, width * 8, message.header.endian)
        guard kind != Bool8 || bits.low <= 1UL else {
          raise Invalid(offset, "ARXML boolean must be zero or one")
        }
        let scaling = match field.kind {
          FixedNumberField(_, scaling) => Some(scaling)
          _ => None
        }
        Numeric({
          kind,
          dimensions: [],
          elements: [bits],
          variable: None,
          scaling,
        })
      }
      TextField(encoding, _) => {
        guard width <= limits.string_bytes else {
          raise Limit(offset, "ARXML text exceeds byte budget")
        }
        StringParameter(
          encoding,
          dictionary_read_text(payload, offset, width, encoding),
          Some(field.name),
        )
      }
      OctetField(_) => {
        guard width <= limits.string_bytes else {
          raise Limit(offset, "ARXML octets exceed byte budget")
        }
        RawValue(payload[offset:offset + width].to_owned(), Some(field.name))
      }
    }
    arguments.push(item)
    offset += width
  }
  {
    description: { ..description, fields: description.fields.copy(), },
    arguments,
  }
}

///|
/// Reconstruct the packed payload from typed arguments. The template supplies
/// the message ID, channel, framing metadata and byte order. Static arguments
/// must still agree with the catalogue and do not consume payload bytes.
pub fn ArxmlCatalog::encode(
  self : ArxmlCatalog,
  template : Message,
  arguments : ArrayView[WireParameter],
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  check_limits(limits)
  let description = self.find(template)
  guard description.fields.length() <= limits.arguments else {
    raise Limit(0, "ARXML argument budget exceeded")
  }
  guard arguments.length() == description.fields.length() else {
    raise Invalid(0, "ARXML argument count does not match catalogue")
  }
  let size = description.packed_length()
  guard size <= limits.message_bytes - template.header.wire_size() else {
    raise Limit(0, "ARXML message exceeds byte budget")
  }
  let out = @buffer.Buffer::Buffer()
  write_u32(out, description.message_id, template.header.endian)
  for i in 0..<arguments.length() {
    let field = description.fields[i]
    let endian = template.header.endian
    match (field.kind, arguments[i]) {
      (StaticText(value), StringParameter(Utf8, text, Some(name))) => {
        guard text == value && name == field.name else {
          raise Invalid(
            out.length(),
            "static ARXML argument differs from catalogue",
          )
        }
        ignore(encode_text_checked(value, max_bytes=limits.string_bytes))
      }
      (NumberField(kind) | FixedNumberField(kind, _), Numeric(n)) => {
        let (_, width) = wire_number_word(kind)
        let scaling = match field.kind {
          FixedNumberField(_, scaling) => Some(scaling)
          _ => None
        }
        guard n.kind == kind &&
          n.dimensions.is_empty() &&
          n.elements.length() == 1 &&
          n.variable is None &&
          n.scaling == scaling else {
          raise Invalid(
            out.length(),
            "numeric ARXML metadata differs from catalogue",
          )
        }
        let bits = n.elements[0]
        guard bits.fits(width) && (kind != Bool8 || bits.low <= 1UL) else {
          raise Invalid(out.length(), "invalid ARXML numeric value")
        }
        write_bits(out, bits, width, endian)
      }
      (TextField(coding, width), StringParameter(actual, text, Some(name))) if name ==
        field.name => {
        guard width <= limits.string_bytes else {
          raise Limit(out.length(), "ARXML text exceeds byte budget")
        }
        dictionary_write_field(
          out,
          FixedText(coding, width),
          Text(actual, text),
          endian,
        )
      }
      (OctetField(width), RawValue(bytes, Some(name))) if name == field.name => {
        guard width <= limits.string_bytes else {
          raise Limit(out.length(), "ARXML octets exceed byte budget")
        }
        dictionary_write_field(out, FixedBytes(width), Raw(bytes), endian)
      }
      _ =>
        raise Invalid(out.length(), "ARXML argument does not match catalogue")
    }
  }
  { ..template, payload: out.to_bytes(), }
}

///|
/// Present restored source metadata and the ordered static/dynamic arguments.
pub fn ArxmlDecoded::to_json(self : ArxmlDecoded) -> Json raise DltError {
  let d = self.description
  guard self.arguments.length() == d.fields.length() else {
    raise Invalid(0, "inconsistent ARXML decoded object")
  }
  let entries : Array[Json] = []
  let mut dynamic_count = 0
  for i in 0..<d.fields.length() {
    let field = d.fields[i]
    let v : Json = match self.arguments[i] {
      Numeric(n) => number_value_json(n)
      StringParameter(enc, s, _) =>
        {
          "type": "text",
          "encoding": if enc == Ascii {
            "ascii"
          } else {
            "utf8"
          },
          "text": s,
        }
      RawValue(bytes, _) => { "type": "raw", "hex": hex_encode(bytes[:]) }
      _ => raise Invalid(0, "invalid ARXML decoded argument kind")
    }
    let is_static = field.kind is StaticText(_)
    if !is_static {
      dynamic_count += 1
    }
    entries.push({
      "name": field.name,
      "unit_ref": opt_text_json(field.unit_ref),
      "static": is_static,
      "value": v,
    })
  }
  {
    "ecu": opt_text_json(d.ecu),
    "application": d.application,
    "context": d.context,
    "message_id": d.message_id.to_string(),
    "message_type": d.message_type,
    "subtype": d.subtype,
    "source_file": opt_text_json(d.source_file),
    "source_line": match d.source_line {
      Some(n) => Json::string(n.to_string())
      None => Json::null()
    },
    "argument_count": d.fields.length(),
    "dynamic_argument_count": dynamic_count,
    "arguments": Json::array(entries),
  }
}
