///|
/// Inclusive wall-clock range, in microseconds since Unix epoch.
/// An absent criterion matches everything. An explicit empty list matches nothing.
pub(all) struct Filter {
  ecus : Array[String]?
  applications : Array[String]?
  contexts : Array[String]?
  message_types : Array[Int32]?
  maximum_log_level : Int32?
  minimum_time : UInt64?
  maximum_time : UInt64?
  verbose : Bool?
} derive(Eq, @debug.Debug)

///|
pub fn Filter::all() -> Filter {
  {
    ecus: None,
    applications: None,
    contexts: None,
    message_types: None,
    maximum_log_level: None,
    minimum_time: None,
    maximum_time: None,
    verbose: None,
  }
}

///|
pub fn Filter::validate(self : Filter) -> Unit raise DltError {
  match self.message_types {
    Some(types) =>
      for kind in types {
        guard kind >= 0 && kind <= 7 else {
          raise Invalid(0, "filter message type must fit three bits")
        }
      }
    None => ()
  }
  match self.maximum_log_level {
    Some(level) => {
      guard level >= 0 && level <= 6 else {
        raise Invalid(0, "filter maximum log level must be 0..6")
      }
    }
    None => ()
  }
  match (self.minimum_time, self.maximum_time) {
    (Some(low), Some(high)) => {
      guard low <= high else {
        raise Invalid(0, "filter time range is reversed")
      }
    }
    _ => ()
  }
  for ids in [self.ecus, self.applications, self.contexts] {
    match ids {
      Some(values) =>
        for id in values {
          let bytes = encode_text_checked(id, max_bytes=4)
          guard bytes.length() <= 4 else {
            raise Invalid(0, "filter identifier exceeds four bytes")
          }
          for b in bytes {
            guard b >= b' ' && b <= b'~' else {
              raise Invalid(0, "filter identifier must be printable ASCII")
            }
          }
        }
      None => ()
    }
  }
}

///|
fn filter_string(values : Array[String]?, actual : String?) -> Bool {
  match (values, actual) {
    (None, _) => true
    (Some(allowed), Some(value)) => allowed.contains(value)
    (Some(_), None) => false
  }
}

///|
pub fn StorageHeader::time_microseconds(
  self : StorageHeader,
) -> UInt64 raise DltError {
  guard self.microseconds < 1000000U else {
    raise Invalid(0, "storage microseconds must be less than one million")
  }
  self.seconds.to_uint64() * 1000000UL + self.microseconds.to_uint64()
}

///|
fn filter_headers(
  filter : Filter,
  storage : StorageHeader?,
  header : Header,
) -> Bool raise DltError {
  let ecu = match header.ecu {
    Some(value) => Some(value)
    None =>
      match storage {
        Some(s) => Some(s.ecu)
        None => None
      }
  }
  if !filter_string(filter.ecus, ecu) {
    return false
  }
  let ext = header.extended
  let application = match ext {
    Some(e) => Some(e.application)
    None => None
  }
  let context = match ext {
    Some(e) => Some(e.context)
    None => None
  }
  if !filter_string(filter.applications, application) ||
    !filter_string(filter.contexts, context) {
    return false
  }
  match filter.message_types {
    Some(kinds) =>
      match ext {
        Some(e) => if !kinds.contains(e.message_type) { return false }
        None => return false
      }
    None => ()
  }
  match filter.maximum_log_level {
    Some(maximum) =>
      match ext {
        Some(e) =>
          if e.message_type != 0 || e.subtype < 1 || e.subtype > maximum {
            return false
          }
        None => return false
      }
    None => ()
  }
  match filter.verbose {
    Some(required) =>
      match ext {
        Some(e) => if e.verbose != required { return false }
        None => if required { return false }
      }
    None => ()
  }
  if filter.minimum_time is Some(_) || filter.maximum_time is Some(_) {
    let time = match storage {
      Some(s) => s.time_microseconds()
      None => return false
    }
    match filter.minimum_time {
      Some(minimum) => if time < minimum { return false }
      None => ()
    }
    match filter.maximum_time {
      Some(maximum) => if time > maximum { return false }
      None => ()
    }
  }
  true
}

///|
pub fn Filter::matches(self : Filter, message : Message) -> Bool raise DltError {
  self.validate()
  filter_headers(self, message.storage, message.header)
}

///|
/// Index a complete framed input. No resynchronization or silent skipping occurs.
/// The input byte buffer must remain unchanged while the index is in use.
pub fn build_index(
  data : BytesView,
  framing~ : Framing = Storage,
  limits~ : Limits = Limits::default(),
  max_entries~ : Int32 = 1000000,
) -> Array[IndexEntry] raise DltError {
  check_limits(limits)
  guard max_entries >= 0 else {
    raise Invalid(0, "negative maximum index size")
  }
  let result : Array[IndexEntry] = []
  let mut offset = 0
  while offset < data.length() {
    guard result.length() < max_entries else {
      raise Limit(offset, "maximum index entries exceeded")
    }
    let decoded = decode(data[offset:], framing~, limits~)
    guard decoded.consumed > 0 && decoded.consumed <= data.length() - offset else {
      raise Invalid(offset, "decoder returned invalid message length")
    }
    result.push({
      offset,
      length: decoded.consumed,
      storage: decoded.message.storage,
      header: decoded.message.header,
    })
    offset = offset + decoded.consumed
  }
  result
}

///|
/// Results retain source order. A zero result limit performs no scan.
pub fn query_index(
  entries : ArrayView[IndexEntry],
  filter : Filter,
  limit~ : Int32 = 1000000,
) -> Array[IndexEntry] raise DltError {
  filter.validate()
  guard limit >= 0 else { raise Invalid(0, "negative result limit") }
  let result : Array[IndexEntry] = []
  for entry in entries {
    if result.length() == limit {
      break
    }
    if filter_headers(filter, entry.storage, entry.header) {
      result.push(entry)
    }
  }
  result
}

///|
/// Revalidate index entries against the source to catch stale metadata/ranges.
pub fn extract_indexed(
  data : BytesView,
  entries : ArrayView[IndexEntry],
  framing~ : Framing = Storage,
  limits~ : Limits = Limits::default(),
) -> Array[Message] raise DltError {
  check_limits(limits)
  let result : Array[Message] = []
  for entry in entries {
    require_range(data, entry.offset, entry.length)
    guard entry.length > 0 else {
      raise Invalid(entry.offset, "index entry has empty range")
    }
    let decoded = decode(
      data[entry.offset:entry.offset + entry.length],
      framing~,
      limits~,
    )
    guard decoded.consumed == entry.length &&
      decoded.message.header == entry.header &&
      decoded.message.storage == entry.storage else {
      raise Invalid(entry.offset, "index does not match source metadata")
    }
    result.push(decoded.message)
  }
  result
}

///|
/// Copy selected framed records without normalizing their binary representation.
pub fn copy_indexed(
  data : BytesView,
  entries : ArrayView[IndexEntry],
  framing~ : Framing = Storage,
  limits~ : Limits = Limits::default(),
  maximum_bytes~ : Int32 = 67108864,
) -> Bytes raise DltError {
  check_limits(limits)
  guard maximum_bytes >= 0 else { raise Invalid(0, "negative output bound") }
  let out = @buffer.Buffer::Buffer()
  for entry in entries {
    require_range(data, entry.offset, entry.length)
    guard entry.length > 0 && entry.length <= maximum_bytes - out.length() else {
      raise Limit(entry.offset, "selected records exceed output bound")
    }
    let decoded = decode(
      data[entry.offset:entry.offset + entry.length],
      framing~,
      limits~,
    )
    guard decoded.consumed == entry.length &&
      decoded.message.header == entry.header &&
      decoded.message.storage == entry.storage else {
      raise Invalid(entry.offset, "index does not match source metadata")
    }
    out.write_bytes(data[entry.offset:entry.offset + entry.length])
  }
  out.to_bytes()
}

///|
pub fn filter_messages(
  messages : ArrayView[Message],
  filter : Filter,
  limit~ : Int32 = 1000000,
) -> Array[Message] raise DltError {
  filter.validate()
  guard limit >= 0 else { raise Invalid(0, "negative result limit") }
  let result : Array[Message] = []
  for message in messages {
    if result.length() == limit {
      break
    }
    if filter_headers(filter, message.storage, message.header) {
      result.push(message)
    }
  }
  result
}

///|
pub fn encode_messages(
  messages : ArrayView[Message],
  framing~ : Framing = Storage,
  limits~ : Limits = Limits::default(),
  maximum_bytes~ : Int32 = 67108864,
) -> Bytes raise DltError {
  encode_all(messages, framing~, limits~, max_bytes=maximum_bytes)
}

///|
priv struct OrderedMessage {
  time : UInt64
  order : Int32
  message : Message
}

///|
/// Sort a bounded collection by storage time, retaining input order on ties.
/// ECU uptime is deliberately never compared with Unix wall-clock timestamps.
pub fn merge_messages(
  streams : ArrayView[Array[Message]],
  maximum_messages~ : Int32 = 1000000,
) -> Array[Message] raise DltError {
  guard maximum_messages >= 0 else { raise Invalid(0, "negative merge bound") }
  let ordered : Array[OrderedMessage] = []
  for stream in streams {
    for message in stream {
      guard ordered.length() < maximum_messages else {
        raise Limit(0, "merge bound exceeded")
      }
      let time = match message.storage {
        Some(storage) => storage.time_microseconds()
        None => raise Invalid(0, "merge requires storage wall-clock timestamps")
      }
      ordered.push({ time, order: ordered.length(), message, })
    }
  }
  ordered.sort_by((a, b) => {
    if a.time < b.time {
      -1
    } else if a.time > b.time {
      1
    } else if a.order < b.order {
      -1
    } else if a.order > b.order {
      1
    } else {
      0
    }
  })
  ordered.map(item => item.message)
}

///|
/// Header-only selectors. WallTime is storage Unix microseconds; Timestamp is
/// the ECU's 0.1-ms uptime field, a different clock domain.
pub(all) enum HeaderField {
  Ecu
  StorageEcu
  Application
  Context
  MessageType
  LogLevel
  Counter
  Session
  Timestamp
  WallTime
  Verbosity
} derive(Eq, @debug.Debug)

///|
pub(all) enum Relation {
  EqualTo
  NotEqualTo
  LessThan
  LessOrEqual
  GreaterThan
  GreaterOrEqual
} derive(Eq, @debug.Debug)

///|
pub(all) enum HeaderValue {
  TextValue(String)
  NumberValue(UInt64)
  BoolValue(Bool)
} derive(Eq, @debug.Debug)

///|
/// A small header query language, not a general-purpose expression evaluator.
/// Missing fields make comparisons false, including !=; ! negates that result.
pub(all) enum FilterExpr {
  Constant(Bool)
  Compare(HeaderField, Relation, HeaderValue)
  Conjunction(FilterExpr, FilterExpr)
  Disjunction(FilterExpr, FilterExpr)
  Negation(FilterExpr)
} derive(Eq, @debug.Debug)

///|
pub(all) struct ExpressionLimits {
  input_bytes : Int32
  tokens : Int32
  depth : Int32
  nodes : Int32
} derive(Eq, @debug.Debug)

///|
pub fn ExpressionLimits::default() -> ExpressionLimits {
  { input_bytes: 4096, tokens: 1024, depth: 32, nodes: 1024, }
}

///|
fn check_expression_limits(limits : ExpressionLimits) -> Unit raise DltError {
  guard limits.input_bytes >= 0 &&
    limits.tokens >= 1 &&
    limits.depth >= 1 &&
    limits.depth <= 128 &&
    limits.nodes >= 1 else {
    raise Invalid(0, "invalid header expression bounds")
  }
}

///|
priv enum ExpressionToken {
  Identifier(String)
  Quoted(String)
  Integer(UInt64)
  Truth(Bool)
  Operator(Relation)
  AndToken
  OrToken
  NotToken
  OpenToken
  CloseToken
  EndToken
}

///|
priv struct ExpressionLexeme {
  value : ExpressionToken
  position : Int32
}

///|
fn expression_push(
  lexemes : Array[ExpressionLexeme],
  token : ExpressionToken,
  position : Int32,
  maximum : Int32,
) -> Unit raise DltError {
  guard lexemes.length() < maximum else {
    raise Limit(position, "header expression token bound exceeded")
  }
  lexemes.push({ value: token, position, })
}

///|
fn expression_letter(byte : Byte) -> Bool {
  (byte >= b'a' && byte <= b'z') ||
  (byte >= b'A' && byte <= b'Z') ||
  byte == b'_'
}

///|
fn expression_digit(byte : Byte) -> Bool {
  byte >= b'0' && byte <= b'9'
}

///|
fn expression_lex(
  input : String,
  limits : ExpressionLimits,
) -> Array[ExpressionLexeme] raise DltError {
  check_expression_limits(limits)
  let data = encode_text_checked(input, max_bytes=limits.input_bytes)
  guard data.length() <= limits.input_bytes else {
    raise Limit(0, "header expression input bound exceeded")
  }
  let lexemes : Array[ExpressionLexeme] = []
  let mut cursor = 0
  while cursor < data.length() {
    let start = cursor
    let byte = data[cursor]
    if byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r' {
      cursor = cursor + 1
      continue
    }
    let token = if expression_letter(byte) {
      cursor = cursor + 1
      while cursor < data.length() &&
            (expression_letter(data[cursor]) || expression_digit(data[cursor])) {
        cursor = cursor + 1
      }
      let name = @utf8.decode_lossy(data[start:cursor])
      match name {
        "true" => Truth(true)
        "false" => Truth(false)
        _ => Identifier(name)
      }
    } else if expression_digit(byte) {
      let mut number = 0UL
      while cursor < data.length() && expression_digit(data[cursor]) {
        let digit = (data[cursor].to_int() - 48).to_uint64()
        guard number <= (18446744073709551615UL - digit) / 10UL else {
          raise Invalid(cursor, "integer literal overflows UInt64")
        }
        number = number * 10UL + digit
        cursor = cursor + 1
      }
      Integer(number)
    } else if byte == b'"' {
      cursor = cursor + 1
      let buffer = @buffer.Buffer::Buffer()
      let mut closed = false
      while cursor < data.length() {
        let current = data[cursor]
        cursor = cursor + 1
        if current == b'"' {
          closed = true
          break
        }
        if current == b'\\' {
          guard cursor < data.length() else {
            raise Invalid(cursor, "unterminated quoted escape")
          }
          let escaped = data[cursor]
          cursor = cursor + 1
          match escaped {
            b'"' | b'\\' => buffer.write_byte(escaped)
            b'n' => buffer.write_byte(b'\n')
            b'r' => buffer.write_byte(b'\r')
            b't' => buffer.write_byte(b'\t')
            _ => raise Invalid(cursor - 1, "unsupported quoted escape")
          }
        } else {
          guard current >= b' ' else {
            raise Invalid(cursor - 1, "unescaped control byte in quoted string")
          }
          buffer.write_byte(current)
        }
      }
      guard closed else { raise Invalid(start, "unterminated quoted string") }
      let text = @utf8.decode(buffer.to_bytes()[:]) catch {
        _ => raise Invalid(start, "quoted string is not UTF-8")
      }
      Quoted(text)
    } else {
      cursor = cursor + 1
      match byte {
        b'(' => OpenToken
        b')' => CloseToken
        b'!' =>
          if cursor < data.length() && data[cursor] == b'=' {
            cursor = cursor + 1
            Operator(NotEqualTo)
          } else {
            NotToken
          }
        b'=' => {
          guard cursor < data.length() && data[cursor] == b'=' else {
            raise Invalid(start, "comparison equality requires ==")
          }
          cursor = cursor + 1
          Operator(EqualTo)
        }
        b'<' =>
          if cursor < data.length() && data[cursor] == b'=' {
            cursor = cursor + 1
            Operator(LessOrEqual)
          } else {
            Operator(LessThan)
          }
        b'>' =>
          if cursor < data.length() && data[cursor] == b'=' {
            cursor = cursor + 1
            Operator(GreaterOrEqual)
          } else {
            Operator(GreaterThan)
          }
        b'&' => {
          guard cursor < data.length() && data[cursor] == b'&' else {
            raise Invalid(start, "logical conjunction requires &&")
          }
          cursor = cursor + 1
          AndToken
        }
        b'|' => {
          guard cursor < data.length() && data[cursor] == b'|' else {
            raise Invalid(start, "logical disjunction requires ||")
          }
          cursor = cursor + 1
          OrToken
        }
        _ => raise Invalid(start, "unexpected byte in header expression")
      }
    }
    expression_push(lexemes, token, start, limits.tokens)
  }
  expression_push(lexemes, EndToken, data.length(), limits.tokens)
  lexemes
}

///|
fn expression_field(
  name : String,
  position : Int32,
) -> HeaderField raise DltError {
  match name {
    "ecu" => Ecu
    "storage_ecu" => StorageEcu
    "apid" => Application
    "ctid" => Context
    "type" => MessageType
    "level" => LogLevel
    "counter" => Counter
    "session" => Session
    "timestamp" => Timestamp
    "time_us" => WallTime
    "verbose" => Verbosity
    _ => raise Invalid(position, "unknown header field: " + name)
  }
}

///|
fn expression_validate_comparison(
  field : HeaderField,
  relation : Relation,
  value : HeaderValue,
  position : Int32,
) -> Unit raise DltError {
  match (field, value) {
    (Ecu | StorageEcu | Application | Context, TextValue(text)) => {
      guard relation == EqualTo || relation == NotEqualTo else {
        raise Invalid(position, "identifier comparisons support only == and !=")
      }
      let out = @buffer.Buffer::Buffer()
      write_id(out, text)
    }
    (Verbosity, BoolValue(_)) => {
      guard relation == EqualTo || relation == NotEqualTo else {
        raise Invalid(position, "Boolean comparisons support only == and !=")
      }
    }
    (
      MessageType
      | LogLevel
      | Counter
      | Session
      | Timestamp
      | WallTime,
      NumberValue(number),
    ) => {
      let maximum = match field {
        MessageType => 7UL
        LogLevel => 6UL
        Counter => 255UL
        Session | Timestamp => 4294967295UL
        WallTime => 4294967295999999UL
        _ => 0UL
      }
      guard number <= maximum else {
        raise Invalid(position, "comparison literal exceeds header field range")
      }
    }
    _ => raise Invalid(position, "literal type does not match header field")
  }
}

///|
priv struct ExpressionNode {
  expression : FilterExpr
  height : Int32
}

///|
priv struct ExpressionParser {
  tokens : Array[ExpressionLexeme]
  mut cursor : Int32
  depth_bound : Int32
  mut nodes_remaining : Int32
}

///|
fn ExpressionParser::peek(self : ExpressionParser) -> ExpressionLexeme {
  self.tokens[self.cursor]
}

///|
fn ExpressionParser::take(self : ExpressionParser) -> ExpressionLexeme {
  let value = self.peek()
  if self.cursor < self.tokens.length() - 1 {
    self.cursor = self.cursor + 1
  }
  value
}

///|
fn ExpressionParser::node(
  self : ExpressionParser,
  expression : FilterExpr,
  height : Int32,
) -> ExpressionNode raise DltError {
  guard height <= self.depth_bound else {
    raise Limit(self.peek().position, "header expression depth bound exceeded")
  }
  guard self.nodes_remaining > 0 else {
    raise Limit(self.peek().position, "header expression node bound exceeded")
  }
  self.nodes_remaining = self.nodes_remaining - 1
  { expression, height, }
}

///|
fn ExpressionParser::parse_or(
  self : ExpressionParser,
  depth : Int32,
) -> ExpressionNode raise DltError {
  let mut left = self.parse_and(depth)
  while self.peek().value is OrToken {
    ignore(self.take())
    let right = self.parse_and(depth)
    left = self.node(
      Disjunction(left.expression, right.expression),
      left.height.max(right.height) + 1,
    )
  }
  left
}

///|
fn ExpressionParser::parse_and(
  self : ExpressionParser,
  depth : Int32,
) -> ExpressionNode raise DltError {
  let mut left = self.parse_unary(depth)
  while self.peek().value is AndToken {
    ignore(self.take())
    let right = self.parse_unary(depth)
    left = self.node(
      Conjunction(left.expression, right.expression),
      left.height.max(right.height) + 1,
    )
  }
  left
}

///|
fn ExpressionParser::parse_unary(
  self : ExpressionParser,
  depth : Int32,
) -> ExpressionNode raise DltError {
  guard depth <= self.depth_bound else {
    raise Limit(
      self.peek().position,
      "header expression nesting bound exceeded",
    )
  }
  if self.peek().value is NotToken {
    ignore(self.take())
    let inner = self.parse_unary(depth + 1)
    return self.node(Negation(inner.expression), inner.height + 1)
  }
  if self.peek().value is OpenToken {
    ignore(self.take())
    let inner = self.parse_or(depth + 1)
    let close = self.take()
    guard close.value is CloseToken else {
      raise Invalid(close.position, "expected closing parenthesis")
    }
    return inner
  }
  let first = self.take()
  match first.value {
    Truth(value) => self.node(Constant(value), 1)
    Identifier(name) => {
      let field = expression_field(name, first.position)
      let op = self.take()
      let relation = match op.value {
        Operator(value) => value
        _ => raise Invalid(op.position, "expected comparison operator")
      }
      let literal = self.take()
      let value = match literal.value {
        Quoted(value) => TextValue(value)
        Integer(value) => NumberValue(value)
        Truth(value) => BoolValue(value)
        _ =>
          raise Invalid(
            literal.position,
            "expected quoted string, integer or Boolean",
          )
      }
      expression_validate_comparison(field, relation, value, first.position)
      self.node(Compare(field, relation, value), 1)
    }
    _ =>
      raise Invalid(first.position, "expected header comparison or parenthesis")
  }
}

///|
/// Grammar: || (lowest), &&, !, parentheses, comparisons, true and false.
/// Example: apid == "APP" && level <= 4 && !(counter == 0).
pub fn FilterExpr::parse(
  input : String,
  limits~ : ExpressionLimits = ExpressionLimits::default(),
) -> FilterExpr raise DltError {
  let tokens = expression_lex(input, limits)
  let parser : ExpressionParser = {
    tokens,
    cursor: 0,
    depth_bound: limits.depth,
    nodes_remaining: limits.nodes,
  }
  let result = parser.parse_or(1)
  let tail = parser.peek()
  guard tail.value is EndToken else {
    raise Invalid(tail.position, "unexpected token after header expression")
  }
  result.expression
}

///|
fn expression_actual(
  field : HeaderField,
  message : Message,
) -> HeaderValue? raise DltError {
  let extended = message.header.extended
  match field {
    Ecu =>
      match message.header.ecu {
        Some(ecu) => Some(TextValue(ecu))
        None =>
          match message.storage {
            Some(storage) => Some(TextValue(storage.ecu))
            None => None
          }
      }
    StorageEcu =>
      match message.storage {
        Some(storage) => Some(TextValue(storage.ecu))
        None => None
      }
    Application =>
      match extended {
        Some(e) => Some(TextValue(e.application))
        None => None
      }
    Context =>
      match extended {
        Some(e) => Some(TextValue(e.context))
        None => None
      }
    MessageType =>
      match extended {
        Some(e) => Some(NumberValue(e.message_type.to_uint64()))
        None => None
      }
    LogLevel =>
      match extended {
        Some(e) =>
          if e.message_type == 0 {
            Some(NumberValue(e.subtype.to_uint64()))
          } else {
            None
          }
        None => None
      }
    Counter => Some(NumberValue(message.header.counter.to_uint64()))
    Session =>
      match message.header.session {
        Some(session) => Some(NumberValue(session.to_uint64()))
        None => None
      }
    Timestamp =>
      match message.header.timestamp {
        Some(timestamp) => Some(NumberValue(timestamp.to_uint64()))
        None => None
      }
    WallTime =>
      match message.storage {
        Some(storage) => Some(NumberValue(storage.time_microseconds()))
        None => None
      }
    Verbosity =>
      Some(
        BoolValue(
          match extended {
            Some(e) => e.verbose
            None => false
          },
        ),
      )
  }
}

///|
fn expression_compare(
  actual : HeaderValue,
  relation : Relation,
  expected : HeaderValue,
) -> Bool {
  match (actual, expected) {
    (NumberValue(a), NumberValue(b)) =>
      match relation {
        EqualTo => a == b
        NotEqualTo => a != b
        LessThan => a < b
        LessOrEqual => a <= b
        GreaterThan => a > b
        GreaterOrEqual => a >= b
      }
    (TextValue(a), TextValue(b)) =>
      match relation {
        EqualTo => a == b
        NotEqualTo => a != b
        _ => false
      }
    (BoolValue(a), BoolValue(b)) =>
      match relation {
        EqualTo => a == b
        NotEqualTo => a != b
        _ => false
      }
    _ => false
  }
}

///|
priv struct ExpressionBudget {
  mut remaining : Int32
  maximum_depth : Int32
}

///|
fn evaluate_expression(
  expression : FilterExpr,
  message : Message,
  depth : Int32,
  budget : ExpressionBudget,
) -> Bool raise DltError {
  guard depth <= budget.maximum_depth && budget.remaining > 0 else {
    raise Limit(0, "header expression evaluation bound exceeded")
  }
  budget.remaining = budget.remaining - 1
  match expression {
    Constant(value) => value
    Compare(field, relation, value) => {
      expression_validate_comparison(field, relation, value, 0)
      match expression_actual(field, message) {
        Some(actual) => expression_compare(actual, relation, value)
        None => false
      }
    }
    Conjunction(a, b) =>
      evaluate_expression(a, message, depth + 1, budget) &&
      evaluate_expression(b, message, depth + 1, budget)
    Disjunction(a, b) =>
      evaluate_expression(a, message, depth + 1, budget) ||
      evaluate_expression(b, message, depth + 1, budget)
    Negation(value) => !evaluate_expression(value, message, depth + 1, budget)
  }
}

///|
/// Evaluation also bounds manually constructed ASTs, not just parsed input.
pub fn FilterExpr::matches(
  self : FilterExpr,
  message : Message,
  limits~ : ExpressionLimits = ExpressionLimits::default(),
) -> Bool raise DltError {
  check_expression_limits(limits)
  let budget : ExpressionBudget = {
    remaining: limits.nodes,
    maximum_depth: limits.depth,
  }
  evaluate_expression(self, message, 1, budget)
}

///|
pub fn query_expression(
  entries : ArrayView[IndexEntry],
  expression : FilterExpr,
  limit~ : Int32 = 1000000,
  expression_limits~ : ExpressionLimits = ExpressionLimits::default(),
) -> Array[IndexEntry] raise DltError {
  guard limit >= 0 else { raise Invalid(0, "negative query result bound") }
  check_expression_limits(expression_limits)
  let result : Array[IndexEntry] = []
  for entry in entries {
    if result.length() == limit {
      break
    }
    let message : Message = {
      storage: entry.storage,
      header: entry.header,
      payload: b"",
    }
    if expression.matches(message, limits=expression_limits) {
      result.push(entry)
    }
  }
  result
}
