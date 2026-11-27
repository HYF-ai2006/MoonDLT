///|
/// Empty dimensions denote one scalar. Array values are flat in C subscript order.
pub(all) struct WireNumeric {
  kind : NumericType
  dimensions : Array[Int32]
  elements : Array[WideBits]
  variable : VariableInfo?
  scaling : WireScaling?
} derive(Eq, @debug.Debug)

///|
pub(all) enum WireParameter {
  Numeric(WireNumeric)
  StringParameter(TextEncoding, String, String?)
  RawValue(Bytes, String?)
  TraceInfo(TextEncoding, String)
  Structure(String?, Array[WireParameter])
} derive(Eq, @debug.Debug)

///|
/// Limits on tree traversal are separate from the one-byte top-level NOAR.
pub(all) struct TreeBudget {
  depth : Int32
  nodes : Int32
} derive(Eq, @debug.Debug)

///|
pub fn TreeBudget::default() -> TreeBudget {
  { depth: 128, nodes: 16384, }
}

///|
fn check_tree_budget(b : TreeBudget) -> Unit raise DltError {
  guard b.depth >= 0 && b.nodes >= 0 else {
    raise Invalid(0, "negative parameter tree budget")
  }
}

///|
fn wire_number_word(kind : NumericType) -> (UInt32, Int32) raise DltError {
  let (base, width) = match kind {
    Bool8 => (0x10U, 8)
    IntValue(w) => (0x20U, w)
    UIntValue(w) => (0x40U, w)
    FloatValue(w) => (0x80U, w)
  }
  let code = wire_width_code(width)
  guard code != 0U && !(base == 0x80U && width == 8) else {
    raise Invalid(0, "illegal numeric type width")
  }
  (base | code, width)
}

///|
fn wire_shape_count(
  dims : Array[Int32],
  bytes : Int32,
  limits : Limits,
  at : Int32,
) -> Int32 raise DltError {
  guard dims.length() <= 65535 && dims.length() <= limits.message_bytes / 2 else {
    raise Limit(at, "rank exceeds message budget")
  }
  let mut count = 1
  for dim in dims {
    guard dim > 0 && dim <= 65535 else {
      raise Invalid(at, "invalid array dimension")
    }
    guard count <= limits.message_bytes / bytes / dim else {
      raise Limit(at, "array exceeds byte budget")
    }
    count *= dim
  }
  count
}

///|
fn wire_scalable(kind : NumericType) -> Bool {
  match kind {
    IntValue(_) | UIntValue(_) => true
    _ => false
  }
}

///|
fn wire_encoding(info : UInt32, at : Int32) -> TextEncoding raise DltError {
  match info & 0x38000U {
    0U => Ascii
    0x8000U => Utf8
    _ => raise Unsupported(at, "reserved SCOD")
  }
}

///|
fn wire_name(info : VariableInfo?) -> String? {
  match info {
    Some(v) => Some(v.name)
    None => None
  }
}

///|
priv struct ReadLevel {
  children : Array[WireParameter]
  count : Int32
}

///|
fn read_wire_numeric(
  data : BytesView,
  at : Int32,
  info : UInt32,
  endian : Endian,
  limits : Limits,
) -> (WireParameter, Int32) raise DltError {
  guard (info & 0x38000U) == 0U else {
    raise Invalid(at, "SCOD on numeric value")
  }
  let width = match info & 0xFU {
    1U => 8
    2U => 16
    3U => 32
    4U => 64
    5U => 128
    _ => raise Invalid(at, "reserved numeric width")
  }
  let kind : NumericType = match info & 0x66F0U {
    0x10U if width == 8 => Bool8
    0x20U => IntValue(width)
    0x40U => UIntValue(width)
    0x80U if width != 8 => FloatValue(width)
    _ => raise Invalid(at, "incompatible numeric type flags")
  }
  let mut pos = at + 4
  let dims : Array[Int32] = []
  let is_array = (info & 0x100U) != 0U
  if is_array {
    let rank = read_u16(data, pos, endian)
    guard rank > 0 else { raise Invalid(pos, "zero array rank") }
    pos += 2
    require_range(data, pos, 2 * rank)
    for _ in 0..<rank {
      dims.push(read_u16(data, pos, endian))
      pos += 2
    }
  }
  let count = wire_shape_count(dims, width / 8, limits, at)
  let variable = if (info & 0x800U) != 0U {
    let (v, next) = read_metadata(
      data,
      pos,
      is_array || kind != Bool8,
      endian,
      limits,
    )
    pos = next
    Some(v)
  } else {
    None
  }
  let scaling = if (info & 0x1000U) != 0U {
    guard wire_scalable(kind) else { raise Invalid(at, "FIXP on noninteger") }
    let ow = wire_offset_width(width)
    let q = read_u32(data, pos, endian)
    let offset = read_bits(data, pos + 4, ow, endian)
    pos += 4 + ow / 8
    Some({ quantization_bits: q, offset_bits: offset, })
  } else {
    None
  }
  require_range(data, pos, count * (width / 8))
  let elements = []
  for _ in 0..<count {
    let bits = read_bits(data, pos, width, endian)
    guard kind != Bool8 || bits.low <= 1UL else {
      raise Invalid(pos, "invalid BOOL value")
    }
    elements.push(bits)
    pos += width / 8
  }
  (Numeric({ kind, dimensions: dims, elements, variable, scaling, }), pos)
}

///|
/// Decode a full verbose tree. Every active group shares the same byte cursor.
/// Members consume their own Type Info and never count toward top-level NOAR.
pub fn decode_wire_parameters(
  data : BytesView,
  count : Int32,
  endian : Endian,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Array[WireParameter] raise DltError {
  check_limits(limits)
  check_tree_budget(budget)
  guard count >= 0 else { raise Invalid(0, "negative NOAR") }
  guard count <= limits.arguments &&
    count <= budget.nodes &&
    data.length() <= limits.message_bytes else {
    raise Limit(0, "verbose message budget exceeded")
  }
  let roots : Array[WireParameter] = []
  let levels : Array[ReadLevel] = [{ children: roots, count, }]
  let mut pos = 0
  let mut visited = 0
  while levels.length() > 0 {
    let group = levels[levels.length() - 1]
    if group.children.length() == group.count {
      ignore(levels.pop())
      continue
    }
    guard visited < budget.nodes else {
      raise Limit(pos, "parameter node budget exceeded")
    }
    visited += 1
    let at = pos
    let info = read_u32(data, at, endian)
    guard (info & 0xFFFC0000U) == 0U else {
      raise Unsupported(at, "reserved type bits")
    }
    match info & 0x66F0U {
      0x4000U => {
        guard info == 0x4000U || info == 0x4800U else {
          raise Invalid(at, "illegal STRU modifiers")
        }
        guard levels.length() <= budget.depth else {
          raise Limit(at, "structure depth exceeded")
        }
        let members = read_u16(data, at + 4, endian)
        guard members > 0 else { raise Invalid(at + 4, "empty structure") }
        guard members <= budget.nodes - visited else {
          raise Limit(at + 4, "structure member budget exceeded")
        }
        pos += 6
        let name = if info == 0x4800U {
          let (varinfo, end) = read_metadata(data, pos, false, endian, limits)
          pos = end
          Some(varinfo.name)
        } else {
          None
        }
        require_range(data, pos, members * 4)
        let children : Array[WireParameter] = []
        group.children.push(Structure(name, children))
        levels.push({ children, count: members, })
      }
      0x2000U => {
        guard (info & 0xFFFC7FFFU) == 0x2000U else {
          raise Invalid(at, "illegal TRAI modifiers")
        }
        let coding = wire_encoding(info, at)
        let size = read_u16(data, at + 4, endian)
        group.children.push(
          TraceInfo(coding, read_text_value(data, at + 6, size, coding, limits)),
        )
        pos = at + 6 + size
      }
      0x200U | 0x400U => {
        guard (info & 0x1100U) == 0U else {
          raise Invalid(at, "array or FIXP on text/raw")
        }
        let (p, end) = decode_one_parameter(data, pos, endian, limits)
        match p.value {
          Scalar(Text(enc, s)) =>
            group.children.push(StringParameter(enc, s, wire_name(p.variable)))
          Scalar(Raw(bytes)) =>
            group.children.push(RawValue(bytes, wire_name(p.variable)))
          _ => raise Invalid(at, "invalid text/raw type")
        }
        pos = end
      }
      _ => {
        let (node, end) = read_wire_numeric(data, at, info, endian, limits)
        group.children.push(node)
        pos = end
      }
    }
  }
  guard pos == data.length() else {
    raise Invalid(pos, "trailing data after NOAR")
  }
  roots
}

///|
fn write_wire_numeric(
  out : @buffer.Buffer,
  n : WireNumeric,
  endian : Endian,
  limits : Limits,
) -> Unit raise DltError {
  let (base, width) = wire_number_word(n.kind)
  let count = wire_shape_count(n.dimensions, width / 8, limits, out.length())
  guard count == n.elements.length() else {
    raise Invalid(out.length(), "element count disagrees with shape")
  }
  let array = !n.dimensions.is_empty()
  let mut word = if array { base | 0x100U } else { base }
  let has_unit = array || n.kind != Bool8
  let mut size = 4 + count * (width / 8)
  if array {
    size += 2 + 2 * n.dimensions.length()
  }
  if n.variable is Some(v) {
    size += metadata_wire_length(v, has_unit, limits)
    word = word | 0x800U
  }
  let ow = wire_offset_width(width)
  if n.scaling is Some(s) {
    guard wire_scalable(n.kind) && s.offset_bits.fits(ow) else {
      raise Invalid(out.length(), "invalid integer scaling")
    }
    word = word | 0x1000U
    size += 4 + ow / 8
  }
  guard size <= limits.message_bytes - out.length() else {
    raise Limit(out.length(), "numeric payload exceeds byte budget")
  }
  write_u32(out, word, endian)
  if array {
    write_u16(out, n.dimensions.length(), endian)
    for d in n.dimensions {
      write_u16(out, d, endian)
    }
  }
  if n.variable is Some(v) {
    write_metadata(out, v, has_unit, endian, limits)
  }
  if n.scaling is Some(s) {
    write_u32(out, s.quantization_bits, endian)
    write_bits(out, s.offset_bits, ow, endian)
  }
  for bits in n.elements {
    guard bits.fits(width) && (n.kind != Bool8 || bits.low <= 1UL) else {
      raise Invalid(out.length(), "element bits exceed numeric type")
    }
    write_bits(out, bits, width, endian)
  }
}

///|
fn wire_var(name : String?) -> VariableInfo? {
  match name {
    None => None
    Some(s) => Some({ name: s, unit: None, })
  }
}

///|
priv struct WriteLevel {
  items : Array[WireParameter]
  mut index : Int32
}

///|
pub fn encode_wire_parameters(
  items : Array[WireParameter],
  endian : Endian,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Bytes raise DltError {
  check_limits(limits)
  check_tree_budget(budget)
  guard items.length() <= limits.arguments && items.length() <= budget.nodes else {
    raise Limit(0, "top-level parameter budget exceeded")
  }
  let out = @buffer.Buffer::Buffer()
  let stack : Array[WriteLevel] = [{ items, index: 0, }]
  let mut visited = 0
  while stack.length() > 0 {
    let group = stack[stack.length() - 1]
    if group.index == group.items.length() {
      ignore(stack.pop())
      continue
    }
    let item = group.items[group.index]
    group.index += 1
    guard visited < budget.nodes else {
      raise Limit(out.length(), "parameter node budget exceeded")
    }
    visited += 1
    match item {
      Numeric(n) => write_wire_numeric(out, n, endian, limits)
      Structure(name, children) => {
        guard stack.length() <= budget.depth else {
          raise Limit(out.length(), "structure depth exceeded")
        }
        guard !children.is_empty() && children.length() <= 65535 else {
          raise Invalid(out.length(), "invalid structure member count")
        }
        guard children.length() <= budget.nodes - visited else {
          raise Limit(out.length(), "structure member budget exceeded")
        }
        let v = wire_var(name)
        let size = match v {
          Some(v) => 6 + metadata_wire_length(v, false, limits)
          None => 6
        }
        guard size <= limits.message_bytes - out.length() else {
          raise Limit(out.length(), "structure exceeds byte budget")
        }
        write_u32(out, if name is Some(_) { 0x4800U } else { 0x4000U }, endian)
        write_u16(out, children.length(), endian)
        if v is Some(v) {
          write_metadata(out, v, false, endian, limits)
        }
        stack.push({ items: children, index: 0, })
      }
      TraceInfo(coding, s) => {
        let bytes = argument_text_bytes(coding, s, limits)
        guard 7 + bytes.length() <= limits.message_bytes - out.length() else {
          raise Limit(out.length(), "trace info exceeds byte budget")
        }
        write_u32(out, if coding == Utf8 { 0xA000U } else { 0x2000U }, endian)
        write_u16(out, bytes.length() + 1, endian)
        out.write_bytes(bytes[:])
        out.write_byte(b'\x00')
      }
      StringParameter(coding, text, name) => {
        let p : VerboseParameter = {
          value: Scalar(Text(coding, text)),
          variable: wire_var(name),
          scaling: None,
        }
        let bytes = encode_one_parameter(p, endian, limits)
        guard bytes.length() <= limits.message_bytes - out.length() else {
          raise Limit(out.length(), "text exceeds byte budget")
        }
        out.write_bytes(bytes[:])
      }
      RawValue(value, name) => {
        let p : VerboseParameter = {
          value: Scalar(Raw(value)),
          variable: wire_var(name),
          scaling: None,
        }
        let bytes = encode_one_parameter(p, endian, limits)
        guard bytes.length() <= limits.message_bytes - out.length() else {
          raise Limit(out.length(), "raw data exceeds byte budget")
        }
        out.write_bytes(bytes[:])
      }
    }
  }
  out.to_bytes()
}

///|
pub fn Message::wire_parameters(
  self : Message,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Array[WireParameter] raise DltError {
  guard self.header.extended is Some(ext) && ext.verbose else {
    raise Invalid(0, "expected verbose message")
  }
  decode_wire_parameters(
    self.payload[:],
    ext.argument_count,
    self.header.endian,
    limits~,
    budget~,
  )
}

///|
pub fn Message::with_wire_parameters(
  header : Header,
  items : Array[WireParameter],
  storage? : StorageHeader,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Message raise DltError {
  guard header.extended is Some(ext) && ext.verbose else {
    raise Invalid(0, "expected verbose header")
  }
  let payload = encode_wire_parameters(items, header.endian, limits~, budget~)
  let extended = Some({ ..ext, argument_count: items.length(), })
  finish_verbose_message({ ..header, extended, }, payload, storage, limits)
}
