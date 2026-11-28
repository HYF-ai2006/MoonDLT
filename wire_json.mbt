///|
fn opt_text_json(s : String?) -> Json {
  match s {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
fn wire_optional_text(j : Json) -> String? raise DltError {
  match j {
    Null => None
    String(s) => Some(s)
    _ => raise Invalid(0, "expected string or null")
  }
}

///|
fn wire_bits_hex(bits : WideBits, width : Int32) -> String {
  let buf = @buffer.Buffer::Buffer()
  write_bits(buf, bits, width, Big)
  hex_encode(buf.to_bytes()[:])
}

///|
fn wire_json_bits(j : Json, width : Int32) -> WideBits raise DltError {
  let s = verbose_string(j)
  guard s.length() == width / 4 else {
    raise Invalid(0, "wrong floating bit width")
  }
  read_bits(hex_decode(s)[:], 0, width, Big)
}

///|
fn number_value_json(n : WireNumeric) -> Json raise DltError {
  let (_, width) = wire_number_word(n.kind)
  let kind = match n.kind {
    Bool8 => "bool"
    IntValue(_) => "signed"
    UIntValue(_) => "unsigned"
    FloatValue(_) => "float"
  }
  let values : Array[Json] = []
  for b in n.elements {
    values.push(
      match n.kind {
        Bool8 => Json::boolean(b.low != 0UL)
        FloatValue(_) => Json::string(wire_bits_hex(b, width))
        _ =>
          Json::string(
            b.integer(width~, signed=n.kind is IntValue(_)).to_string(),
          )
      },
    )
  }
  let variable : Json = match n.variable {
    None => Json::null()
    Some(v) => { "name": v.name, "unit": opt_text_json(v.unit) }
  }
  let scaling : Json = match n.scaling {
    None => Json::null()
    Some(s) => {
      let q : WideBits = { high: 0UL, low: s.quantization_bits.to_uint64(), }
      {
        "quantization_bits": wire_bits_hex(q, 32),
        "offset": s.offset_bits
        .integer(width=wire_offset_width(width), signed=true)
        .to_string(),
      }
    }
  }
  {
    "type": kind,
    "width": width,
    "dimensions": Json::array(
      n.dimensions.map(d => Json::number(d.to_double())),
    ),
    "values": Json::array(values),
    "variable": variable,
    "scaling": scaling,
  }
}

///|
priv struct ToJsonLevel {
  input : Array[WireParameter]
  output : Array[Json]
}

///|
/// The portable interchange keeps structure order, distinct TRAI and SCOD,
/// decimal integers and exact IEEE bits. The byte encoder validates first.
pub fn wire_parameters_to_json(
  items : Array[WireParameter],
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Json raise DltError {
  ignore(encode_wire_parameters(items, Little, limits~, budget~))
  let roots : Array[Json] = []
  let stack : Array[ToJsonLevel] = [{ input: items, output: roots, }]
  while !stack.is_empty() {
    let group = stack[stack.length() - 1]
    if group.input.length() == group.output.length() {
      ignore(stack.pop())
      continue
    }
    let item = group.input[group.output.length()]
    match item {
      Structure(name, fields) => {
        let children : Array[Json] = []
        group.output.push({
          "type": "struct",
          "name": opt_text_json(name),
          "members": Json::array(children),
        })
        stack.push({ input: fields, output: children, })
      }
      Numeric(n) => group.output.push(number_value_json(n))
      TraceInfo(enc, s) =>
        group.output.push({
          "type": "trace-info",
          "encoding": if enc == Ascii {
            "ascii"
          } else {
            "utf8"
          },
          "text": s,
        })
      StringParameter(enc, s, name) =>
        group.output.push({
          "type": "text",
          "encoding": if enc == Ascii {
            "ascii"
          } else {
            "utf8"
          },
          "text": s,
          "name": opt_text_json(name),
        })
      RawValue(bytes, name) =>
        group.output.push({
          "type": "raw",
          "name": opt_text_json(name),
          "hex": hex_encode(bytes[:]),
        })
    }
  }
  Json::array(roots)
}

///|
fn json_number_value(
  o : Map[String, Json],
  tag : String,
  remaining : Int32,
  offset : Int32,
) -> WireNumeric raise DltError {
  verbose_fields(o, [
    "type", "width", "dimensions", "values", "variable", "scaling",
  ])
  let width = verbose_small_integer(verbose_field(o, "width"), 128)
  let kind : NumericType = match tag {
    "bool" if width == 8 => Bool8
    "signed" => IntValue(width)
    "unsigned" => UIntValue(width)
    "float" => FloatValue(width)
    _ => raise Invalid(0, "unknown numeric kind/width")
  }
  ignore(wire_number_word(kind))
  let sizes = verbose_array(verbose_field(o, "dimensions"))
  guard remaining >= 4 && sizes.length() <= (remaining - 4) / 2 else {
    raise Limit(offset, "array rank exceeds remaining payload")
  }
  let dimensions = []
  for d in sizes {
    dimensions.push(verbose_small_integer(d, 65535))
  }
  let shape_bytes = if dimensions.is_empty() {
    4
  } else {
    6 + 2 * dimensions.length()
  }
  guard shape_bytes <= remaining else {
    raise Limit(offset, "numeric shape exceeds remaining payload")
  }
  let count = wire_shape_count(dimensions, width / 8, remaining, offset)
  guard count <= (remaining - shape_bytes) / (width / 8) else {
    raise Limit(offset, "numeric data exceeds remaining payload")
  }
  let values = verbose_array(verbose_field(o, "values"))
  guard values.length() == count else {
    raise Invalid(0, "JSON number count disagrees with dimensions")
  }
  let elements = []
  for j in values {
    let b : WideBits = match kind {
      Bool8 =>
        match j {
          True => { high: 0UL, low: 1UL, }
          False => { high: 0UL, low: 0UL, }
          _ => raise Invalid(0, "expected boolean")
        }
      FloatValue(_) => wire_json_bits(j, width)
      _ =>
        WideBits::from_decimal(
          verbose_string(j),
          width~,
          signed=kind is IntValue(_),
        )
    }
    elements.push(b)
  }
  let variable : VariableInfo? = match verbose_field(o, "variable") {
    Null => None
    v => {
      let obj = verbose_object(v)
      verbose_fields(obj, ["name", "unit"])
      Some({
        name: verbose_string(verbose_field(obj, "name")),
        unit: wire_optional_text(verbose_field(obj, "unit")),
      })
    }
  }
  let scaling : WireScaling? = match verbose_field(o, "scaling") {
    Null => None
    v => {
      let obj = verbose_object(v)
      verbose_fields(obj, ["quantization_bits", "offset"])
      Some({
        quantization_bits: wire_json_bits(
          verbose_field(obj, "quantization_bits"),
          32,
        ).low.to_uint(),
        offset_bits: WideBits::from_decimal(
          verbose_string(verbose_field(obj, "offset")),
          width=wire_offset_width(width),
          signed=true,
        ),
      })
    }
  }
  { kind, dimensions, elements, variable, scaling, }
}

///|
priv struct FromJsonLevel {
  input : Array[Json]
  output : Array[WireParameter]
}

///|
pub fn wire_parameters_from_json(
  json : Json,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Array[WireParameter] raise DltError {
  wire_parameters_from_json_bounded(json, limits, budget, limits.message_bytes)
}

///|
fn wire_parameters_from_json_bounded(
  json : Json,
  limits : Limits,
  budget : TreeBudget,
  maximum : Int32,
) -> Array[WireParameter] raise DltError {
  check_limits(limits)
  check_tree_budget(budget)
  guard maximum >= 0 else { raise Limit(2, "no room for verbose payload") }
  let input = verbose_array(json)
  guard input.length() <= limits.arguments && input.length() <= budget.nodes else {
    raise Limit(0, "JSON top-level count exceeded")
  }
  let roots : Array[WireParameter] = []
  let stack : Array[FromJsonLevel] = [{ input, output: roots, }]
  let mut nodes = 0
  let mut bytes = 0
  while !stack.is_empty() {
    let group = stack[stack.length() - 1]
    if group.input.length() == group.output.length() {
      ignore(stack.pop())
      continue
    }
    guard nodes < budget.nodes else {
      raise Limit(bytes, "JSON node budget exceeded")
    }
    nodes += 1
    let o = verbose_object(group.input[group.output.length()])
    let tag = verbose_string(verbose_field(o, "type"))
    if tag == "struct" {
      verbose_fields(o, ["type", "name", "members"])
      guard stack.length() <= budget.depth else {
        raise Limit(bytes, "JSON structure depth exceeded")
      }
      let name = wire_optional_text(verbose_field(o, "name"))
      let members = verbose_array(verbose_field(o, "members"))
      guard !members.is_empty() && members.length() <= 65535 else {
        raise Invalid(bytes, "invalid structure member count")
      }
      guard members.length() <= budget.nodes - nodes else {
        raise Limit(bytes, "JSON member budget exceeded")
      }
      bytes += match wire_var(name) {
        Some(v) => 6 + metadata_wire_length(v, false, limits)
        None => 6
      }
      let output : Array[WireParameter] = []
      group.output.push(Structure(name, output))
      stack.push({ input: members, output, })
    } else {
      let item : WireParameter = match tag {
        "text" | "trace-info" => {
          if tag == "text" {
            verbose_fields(o, ["type", "encoding", "text", "name"])
          } else {
            verbose_fields(o, ["type", "encoding", "text"])
          }
          let enc : TextEncoding = match
            verbose_string(verbose_field(o, "encoding")) {
            "ascii" => Ascii
            "utf8" => Utf8
            _ => raise Invalid(bytes, "unknown text encoding")
          }
          let text = verbose_string(verbose_field(o, "text"))
          if tag == "text" {
            StringParameter(
              enc,
              text,
              wire_optional_text(verbose_field(o, "name")),
            )
          } else {
            TraceInfo(enc, text)
          }
        }
        "raw" => {
          verbose_fields(o, ["type", "hex", "name"])
          let s = verbose_string(verbose_field(o, "hex"))
          guard s.length() <= limits.string_bytes * 2 &&
            s.length() <= 2 * (maximum - bytes) else {
            raise Limit(bytes, "JSON raw data exceeds budget")
          }
          RawValue(hex_decode(s), wire_optional_text(verbose_field(o, "name")))
        }
        _ => Numeric(json_number_value(o, tag, maximum - bytes, bytes))
      }
      // Per-leaf preflight bounds construction even if many huge JSON siblings
      // are supplied to an otherwise tiny wire budget.
      bytes += encode_wire_parameters_bounded(
        [item],
        Little,
        limits,
        budget,
        maximum - bytes,
      ).length()
      group.output.push(item)
    }
    guard bytes <= maximum else {
      raise Limit(bytes, "JSON exceeds complete wire budget")
    }
  }
  roots
}

///|
pub fn Message::to_typed_json(
  self : Message,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Json raise DltError {
  check_limits(limits)
  ignore(
    finish_verbose_message(self.header, self.payload, self.storage, limits),
  )
  {
    "format": "moondlt.verbose.v1",
    "storage": storage_json(self.storage),
    "header": self.header.to_json(),
    "parameters": wire_parameters_to_json(
      self.wire_parameters(limits~, budget~),
      limits~,
      budget~,
    ),
  }
}

///|
/// Top-level NOAR and encoded lengths are derived from the edited model.
pub fn Message::from_typed_json(
  json : Json,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Message raise DltError {
  check_limits(limits)
  let o = verbose_object(json)
  verbose_fields(o, ["format", "storage", "header", "parameters"])
  guard verbose_string(verbose_field(o, "format")) == "moondlt.verbose.v1" else {
    raise Unsupported(0, "unknown verbose JSON format")
  }
  // The original NOAR is display metadata. The edited list determines the
  // outgoing count and must satisfy the caller's limit even if the old one did not.
  let header = Header::from_json(verbose_field(o, "header"), limits={
    ..limits,
    arguments: 255,
  })
  ignore(verbose_data_header(header))
  let parameters = wire_parameters_from_json_bounded(
    verbose_field(o, "parameters"),
    limits,
    budget,
    limits.message_bytes - header.wire_size(),
  )
  match storage_from_json(verbose_field(o, "storage")) {
    Some(storage) =>
      Message::with_wire_parameters(
        header,
        parameters,
        storage~,
        limits~,
        budget~,
      )
    None => Message::with_wire_parameters(header, parameters, limits~, budget~)
  }
}
