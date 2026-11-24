///|
/// An application-owned nonverbose layout. These are fixed-width wire fields;
/// there is no inference from bytes and no claim of FIBEX XML compatibility.
pub(all) enum FieldKind {
  Flag
  SignedInteger(Int32)
  UnsignedInteger(Int32)
  FloatNumber(Int32)
  FixedText(TextEncoding, Int32)
  FixedBytes(Int32)
} derive(Eq, @debug.Debug)

///|
pub(all) struct SchemaField {
  name : String
  kind : FieldKind
  unit : String?
} derive(Eq, @debug.Debug)

///|
pub(all) struct SchemaKey {
  application : String
  context : String
  message_id : UInt32
} derive(Eq, @debug.Debug)

///|
pub(all) struct NonVerboseSchema {
  key : SchemaKey
  fields : Array[SchemaField]
} derive(Eq, @debug.Debug)

///|
pub(all) struct NamedValue {
  name : String
  unit : String?
  value : Argument
} derive(Eq, @debug.Debug)

///|
/// Registration and lookups are bounded linear scans, appropriate for small
/// embedded application dictionaries. Registered field lists are copied.
pub struct Dictionary {
  schemas : Array[NonVerboseSchema]
  capacity : Int32
  maximum_fields : Int32
}

///|
pub fn Dictionary::new(
  capacity~ : Int32 = 1024,
  maximum_fields~ : Int32 = 255,
) -> Dictionary raise DltError {
  guard capacity >= 0 && maximum_fields >= 0 && maximum_fields <= 255 else {
    raise Invalid(0, "invalid dictionary bounds")
  }
  { schemas: [], capacity, maximum_fields, }
}

///|
pub fn FieldKind::byte_width(self : FieldKind) -> Int32 raise DltError {
  match self {
    Flag => 1
    SignedInteger(bits) | UnsignedInteger(bits) => {
      guard bits == 8 || bits == 16 || bits == 32 || bits == 64 else {
        raise Invalid(0, "schema integer width must be 8, 16, 32 or 64")
      }
      bits / 8
    }
    FloatNumber(bits) => {
      guard bits == 32 || bits == 64 else {
        raise Invalid(0, "schema floating width must be 32 or 64")
      }
      bits / 8
    }
    FixedText(_, width) | FixedBytes(width) => {
      guard width >= 0 && width <= 65531 else {
        raise Invalid(0, "fixed schema field width must be 0..65531")
      }
      width
    }
  }
}

///|
pub fn NonVerboseSchema::payload_length(
  self : NonVerboseSchema,
) -> Int32 raise DltError {
  let mut length = 4
  for field in self.fields {
    let width = field.kind.byte_width()
    guard width <= 65535 - length else {
      raise Limit(0, "schema payload exceeds maximum DLT wire length")
    }
    length = length + width
  }
  length
}

///|
fn validate_schema(
  schema : NonVerboseSchema,
  maximum_fields : Int32,
) -> Unit raise DltError {
  let id_buffer = @buffer.Buffer::Buffer()
  write_id(id_buffer, schema.key.application)
  write_id(id_buffer, schema.key.context)
  guard schema.fields.length() <= maximum_fields else {
    raise Limit(0, "too many dictionary fields")
  }
  let names : Array[String] = []
  for field in schema.fields {
    guard field.name.length() > 0 && field.name.length() <= 256 else {
      raise Invalid(0, "schema field name must contain 1..256 characters")
    }
    guard !names.contains(field.name) else {
      raise Invalid(0, "duplicate schema field name: " + field.name)
    }
    names.push(field.name)
    ignore(field.kind.byte_width())
  }
  ignore(schema.payload_length())
}

///|
pub fn Dictionary::register(
  self : Dictionary,
  schema : NonVerboseSchema,
) -> Unit raise DltError {
  validate_schema(schema, self.maximum_fields)
  for registered in self.schemas {
    guard registered.key != schema.key else {
      raise Invalid(0, "dictionary key is already registered")
    }
  }
  guard self.schemas.length() < self.capacity else {
    raise Limit(0, "dictionary capacity exceeded")
  }
  self.schemas.push({ key: schema.key, fields: schema.fields.copy(), })
}

///|
pub fn Dictionary::length(self : Dictionary) -> Int32 {
  self.schemas.length()
}

///|
pub fn Dictionary::contains(self : Dictionary, key : SchemaKey) -> Bool {
  self.schemas.any(schema => schema.key == key)
}

///|
pub fn Dictionary::lookup(
  self : Dictionary,
  key : SchemaKey,
) -> NonVerboseSchema? {
  for schema in self.schemas {
    if schema.key == key {
      return Some({ key: schema.key, fields: schema.fields.copy(), })
    }
  }
  None
}

///|
pub fn Dictionary::remove(self : Dictionary, key : SchemaKey) -> Bool {
  for i in 0..<self.schemas.length() {
    if self.schemas[i].key == key {
      ignore(self.schemas.remove(i))
      return true
    }
  }
  false
}

///|
fn Dictionary::require_schema(
  self : Dictionary,
  key : SchemaKey,
) -> NonVerboseSchema raise DltError {
  match self.lookup(key) {
    Some(schema) => schema
    None =>
      raise Unsupported(0, "nonverbose message key has no registered schema")
  }
}

///|
pub fn Message::nonverbose_id(self : Message) -> UInt32 raise DltError {
  match self.header.extended {
    Some(ext) => {
      guard !ext.verbose && ext.message_type != 3 else {
        raise Invalid(0, "expected nonverbose application message")
      }
    }
    None => ()
  }
  read_u32(self.payload[:], 0, self.header.endian)
}

///|
pub fn Message::schema_key(self : Message) -> SchemaKey raise DltError {
  let ext = match self.header.extended {
    Some(ext) => ext
    None => raise Invalid(0, "dictionary lookup requires APID and CTID")
  }
  {
    application: ext.application,
    context: ext.context,
    message_id: self.nonverbose_id(),
  }
}

///|
fn dictionary_read_unsigned(
  data : BytesView,
  offset : Int32,
  bits : Int32,
  endian : Endian,
) -> UInt64 raise DltError {
  require_range(data, offset, bits / 8)
  match bits {
    8 => data[offset].to_uint64()
    16 => read_u16(data, offset, endian).to_uint64()
    32 => read_u32(data, offset, endian).to_uint64()
    64 => read_u64(data, offset, endian)
    _ => raise Invalid(offset, "unsupported schema integer width")
  }
}

///|
fn dictionary_read_text(
  data : BytesView,
  offset : Int32,
  width : Int32,
  encoding : TextEncoding,
) -> String raise DltError {
  require_range(data, offset, width)
  let mut length = width
  for i in 0..<width {
    if data[offset + i] == b'\x00' {
      length = i
      break
    }
  }
  for i in length..<width {
    guard data[offset + i] == b'\x00' else {
      raise Invalid(offset + i, "fixed text has nonzero bytes after NUL")
    }
  }
  if encoding == Ascii {
    for i in 0..<length {
      guard data[offset + i] < b'\x80' else {
        raise Invalid(offset + i, "ASCII field contains a non-ASCII byte")
      }
    }
  }
  @utf8.decode(data[offset:offset + length]) catch {
    _ => raise Invalid(offset, "fixed text contains invalid UTF-8")
  }
}

///|
fn dictionary_read_field(
  data : BytesView,
  offset : Int32,
  field : FieldKind,
  endian : Endian,
) -> Argument raise DltError {
  require_range(data, offset, field.byte_width())
  match field {
    Flag => {
      guard data[offset] == b'\x00' || data[offset] == b'\x01' else {
        raise Invalid(offset, "schema boolean must be zero or one")
      }
      Boolean(data[offset] == b'\x01')
    }
    SignedInteger(bits) => {
      let raw = dictionary_read_unsigned(data, offset, bits, endian)
      let shift = 64 - bits
      let signed = (raw << shift).reinterpret_as_int64() >> shift
      Signed(bits, signed)
    }
    UnsignedInteger(bits) =>
      Unsigned(bits, dictionary_read_unsigned(data, offset, bits, endian))
    FloatNumber(32) =>
      Floating(
        32,
        Float::reinterpret_from_uint(read_u32(data, offset, endian)).to_double(),
      )
    FloatNumber(64) =>
      Floating(64, read_u64(data, offset, endian).reinterpret_as_double())
    FloatNumber(_) => raise Invalid(offset, "unsupported floating width")
    FixedText(encoding, width) =>
      Text(encoding, dictionary_read_text(data, offset, width, encoding))
    FixedBytes(width) => Raw(data[offset:offset + width].to_owned())
  }
}

///|
pub fn Dictionary::decode(
  self : Dictionary,
  message : Message,
) -> Array[NamedValue] raise DltError {
  let schema = self.require_schema(message.schema_key())
  guard message.payload.length() == schema.payload_length() else {
    raise Invalid(4, "nonverbose payload length does not match explicit schema")
  }
  let values : Array[NamedValue] = []
  let mut offset = 4
  for field in schema.fields {
    values.push({
      name: field.name,
      unit: field.unit,
      value: dictionary_read_field(
        message.payload[:],
        offset,
        field.kind,
        message.header.endian,
      ),
    })
    offset = offset + field.kind.byte_width()
  }
  values
}

///|
fn dictionary_write_unsigned(
  out : @buffer.Buffer,
  value : UInt64,
  bits : Int32,
  endian : Endian,
) -> Unit raise DltError {
  match bits {
    8 => out.write_byte(value.to_byte())
    16 => write_u16(out, value.to_int(), endian)
    32 => write_u32(out, value.to_uint(), endian)
    64 => write_u64(out, value, endian)
    _ => raise Invalid(0, "unsupported integer width")
  }
}

///|
fn dictionary_write_field(
  out : @buffer.Buffer,
  kind : FieldKind,
  value : Argument,
  endian : Endian,
) -> Unit raise DltError {
  match (kind, value) {
    (Flag, Boolean(flag)) =>
      out.write_byte(if flag { b'\x01' } else { b'\x00' })
    (SignedInteger(bits), Signed(actual_bits, number)) => {
      guard bits == actual_bits else {
        raise Invalid(out.length(), "signed field width does not match schema")
      }
      if bits < 64 {
        let bound = 1L << (bits - 1)
        guard number >= -bound && number < bound else {
          raise Invalid(
            out.length(),
            "signed field value is outside wire range",
          )
        }
      }
      dictionary_write_unsigned(
        out,
        number.reinterpret_as_uint64(),
        bits,
        endian,
      )
    }
    (UnsignedInteger(bits), Unsigned(actual_bits, number)) => {
      guard bits == actual_bits else {
        raise Invalid(
          out.length(),
          "unsigned field width does not match schema",
        )
      }
      if bits < 64 {
        guard number < 1UL << bits else {
          raise Invalid(
            out.length(),
            "unsigned field value is outside wire range",
          )
        }
      }
      dictionary_write_unsigned(out, number, bits, endian)
    }
    (FloatNumber(32), Floating(32, number)) =>
      write_u32(out, Float::from_double(number).reinterpret_as_uint(), endian)
    (FloatNumber(64), Floating(64, number)) =>
      write_u64(out, number.reinterpret_as_uint64(), endian)
    (FixedText(encoding, width), Text(actual_encoding, text)) => {
      guard actual_encoding == encoding else {
        raise Invalid(out.length(), "text encoding does not match schema")
      }
      let bytes = encode_text_checked(text, max_bytes=width)
      guard bytes.length() <= width else {
        raise Invalid(out.length(), "text exceeds fixed field width")
      }
      for b in bytes {
        guard b != b'\x00' else {
          raise Invalid(out.length(), "text contains embedded NUL")
        }
        if encoding == Ascii {
          guard b < b'\x80' else {
            raise Invalid(out.length(), "ASCII field contains non-ASCII text")
          }
        }
      }
      out.write_bytes(bytes[:])
      for _ in bytes.length()..<width {
        out.write_byte(b'\x00')
      }
    }
    (FixedBytes(width), Raw(bytes)) => {
      guard bytes.length() == width else {
        raise Invalid(out.length(), "raw field length does not match schema")
      }
      out.write_bytes(bytes[:])
    }
    _ =>
      raise Invalid(out.length(), "value type does not match dictionary field")
  }
}

///|
/// Encode only the nonverbose payload, including its four-byte message ID.
/// Field order, names and units must match the registered schema exactly.
pub fn Dictionary::encode(
  self : Dictionary,
  key : SchemaKey,
  values : ArrayView[NamedValue],
  endian : Endian,
) -> Bytes raise DltError {
  let schema = self.require_schema(key)
  guard values.length() == schema.fields.length() else {
    raise Invalid(0, "dictionary value count does not match schema")
  }
  let out = @buffer.Buffer::Buffer()
  write_u32(out, key.message_id, endian)
  for i in 0..<values.length() {
    let field = schema.fields[i]
    let value = values[i]
    guard value.name == field.name && value.unit == field.unit else {
      raise Invalid(
        out.length(),
        "dictionary value name/unit does not match schema",
      )
    }
    dictionary_write_field(out, field.kind, value.value, endian)
  }
  out.to_bytes()
}

///|
fn dictionary_json_object(
  value : Json,
  allowed : ArrayView[String],
) -> Map[String, Json] raise DltError {
  guard value is Object(fields) else {
    raise Invalid(0, "dictionary JSON expected an object")
  }
  for name, _ in fields {
    guard allowed.contains(name) else {
      raise Invalid(0, "unknown dictionary JSON property: " + name)
    }
  }
  fields
}

///|
fn dictionary_json_string(
  fields : Map[String, Json],
  name : String,
) -> String raise DltError {
  match fields.get(name) {
    Some(String(value)) => value
    _ => raise Invalid(0, "dictionary JSON requires string property: " + name)
  }
}

///|
fn dictionary_json_integer(
  fields : Map[String, Json],
  name : String,
  maximum : Double,
) -> UInt32 raise DltError {
  match fields.get(name) {
    Some(Number(value, ..)) => {
      guard !value.is_nan() && value >= 0.0 && value <= maximum else {
        raise Invalid(0, "dictionary JSON integer is out of range: " + name)
      }
      let number = value.to_uint()
      guard number.to_double() == value else {
        raise Invalid(0, "dictionary JSON requires an exact integer: " + name)
      }
      number
    }
    _ => raise Invalid(0, "dictionary JSON requires integer property: " + name)
  }
}

///|
fn field_kind_json(kind : FieldKind) -> Json {
  let fields : Map[String, Json] = Map([])
  match kind {
    Flag => fields["type"] = Json::string("bool")
    SignedInteger(width) => {
      fields["type"] = Json::string("signed")
      fields["width"] = Json::number(width.to_double())
    }
    UnsignedInteger(width) => {
      fields["type"] = Json::string("unsigned")
      fields["width"] = Json::number(width.to_double())
    }
    FloatNumber(width) => {
      fields["type"] = Json::string("float")
      fields["width"] = Json::number(width.to_double())
    }
    FixedText(encoding, length) => {
      fields["type"] = Json::string("text")
      fields["length"] = Json::number(length.to_double())
      fields["encoding"] = Json::string(
        if encoding == Ascii {
          "ascii"
        } else {
          "utf8"
        },
      )
    }
    FixedBytes(length) => {
      fields["type"] = Json::string("bytes")
      fields["length"] = Json::number(length.to_double())
    }
  }
  Json::object(fields)
}

///|
fn field_kind_from_json(value : Json) -> FieldKind raise DltError {
  let fields = dictionary_json_object(
    value,
    ["type", "width", "length", "encoding"][:],
  )
  let kind = dictionary_json_string(fields, "type")
  let result = match kind {
    "bool" => {
      guard fields.length() == 1 else {
        raise Invalid(0, "boolean field cannot contain width/length/encoding")
      }
      Flag
    }
    "signed" | "unsigned" | "float" => {
      guard fields.length() == 2 && fields.contains("width") else {
        raise Invalid(0, "numeric field requires only type and width")
      }
      let width = dictionary_json_integer(fields, "width", 64.0).reinterpret_as_int()
      if kind == "signed" {
        SignedInteger(width)
      } else if kind == "unsigned" {
        UnsignedInteger(width)
      } else {
        FloatNumber(width)
      }
    }
    "bytes" => {
      guard fields.length() == 2 && fields.contains("length") else {
        raise Invalid(0, "bytes field requires only type and length")
      }
      FixedBytes(
        dictionary_json_integer(fields, "length", 65531.0).reinterpret_as_int(),
      )
    }
    "text" => {
      guard fields.length() == 3 &&
        fields.contains("length") &&
        fields.contains("encoding") else {
        raise Invalid(0, "text field requires type, length and encoding")
      }
      let encoding = match dictionary_json_string(fields, "encoding") {
        "ascii" => Ascii
        "utf8" => Utf8
        _ => raise Invalid(0, "unsupported dictionary text encoding")
      }
      FixedText(
        encoding,
        dictionary_json_integer(fields, "length", 65531.0).reinterpret_as_int(),
      )
    }
    _ => raise Invalid(0, "unknown dictionary field type: " + kind)
  }
  ignore(result.byte_width())
  result
}

///|
/// Portable schema representation, with explicit version and 32-bit numeric IDs.
/// Field order and schema registration order are preserved in arrays.
pub fn Dictionary::to_json(self : Dictionary) -> Json {
  let schemas = self.schemas.map(schema => {
    let fields = schema.fields.map(field => {
      Json::object(
        Map([
          ("name", Json::string(field.name)),
          (
            "unit",
            match field.unit {
              Some(unit) => Json::string(unit)
              None => Json::null()
            },
          ),
          ("kind", field_kind_json(field.kind)),
        ]),
      )
    })
    Json::object(
      Map([
        ("application", Json::string(schema.key.application)),
        ("context", Json::string(schema.key.context)),
        ("message_id", Json::number(schema.key.message_id.to_double())),
        ("fields", Json::array(fields)),
      ]),
    )
  })
  Json::object(
    Map([
      ("format", Json::string("moondlt-nonverbose")),
      ("version", Json::number(1.0)),
      ("schemas", Json::array(schemas)),
    ]),
  )
}

///|
/// Decode a parsed JSON value. Callers may choose their JSON parser and I/O.
/// Unknown properties, duplicate keys at registration, invalid widths and
/// ambiguous layouts fail explicitly rather than changing interpretation.
pub fn Dictionary::from_json(
  value : Json,
  capacity~ : Int32 = 1024,
  maximum_fields~ : Int32 = 255,
) -> Dictionary raise DltError {
  let object = dictionary_json_object(
    value,
    ["format", "version", "schemas"][:],
  )
  guard dictionary_json_string(object, "format") == "moondlt-nonverbose" &&
    dictionary_json_integer(object, "version", 1.0) == 1U else {
    raise Unsupported(0, "unsupported dictionary JSON format/version")
  }
  let schemas = match object.get("schemas") {
    Some(Array(items)) => items
    _ => raise Invalid(0, "dictionary JSON requires schemas array")
  }
  let result = Dictionary::new(capacity~, maximum_fields~)
  guard schemas.length() <= capacity else {
    raise Limit(0, "dictionary JSON exceeds schema capacity")
  }
  for item in schemas {
    let schema = dictionary_json_object(
      item,
      ["application", "context", "message_id", "fields"][:],
    )
    let key : SchemaKey = {
      application: dictionary_json_string(schema, "application"),
      context: dictionary_json_string(schema, "context"),
      message_id: dictionary_json_integer(schema, "message_id", 4294967295.0),
    }
    let source_fields = match schema.get("fields") {
      Some(Array(fields)) => fields
      _ => raise Invalid(0, "dictionary schema requires fields array")
    }
    guard source_fields.length() <= maximum_fields else {
      raise Limit(0, "dictionary JSON exceeds field capacity")
    }
    let fields : Array[SchemaField] = []
    for source in source_fields {
      let field = dictionary_json_object(source, ["name", "unit", "kind"][:])
      let unit = match field.get("unit") {
        Some(Null) => None
        Some(String(value)) => Some(value)
        _ => raise Invalid(0, "dictionary field unit must be string or null")
      }
      let kind = match field.get("kind") {
        Some(value) => field_kind_from_json(value)
        None => raise Invalid(0, "dictionary field kind is missing")
      }
      fields.push({ name: dictionary_json_string(field, "name"), unit, kind, })
    }
    result.register({ key, fields, })
  }
  result
}
