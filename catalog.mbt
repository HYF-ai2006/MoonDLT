///|
/// Noncryptographic sampled identity detects accidental stale-sidecar reuse.
/// It is not an integrity proof; source callbacks must provide an immutable file.
pub(all) struct SourceSignature {
  size : UInt64
  sample_bytes : Int32
  head : UInt64
  tail : UInt64
} derive(Eq, @debug.Debug)

///|
fn sample_hash(bytes : BytesView) -> UInt64 {
  let mut hash = 14695981039346656037UL
  for byte in bytes {
    hash = (hash ^ byte.to_uint64()) * 1099511628211UL
  }
  hash
}

///|
pub fn Source::signature(
  self : Source,
  sample_bytes~ : Int32 = 4096,
) -> SourceSignature raise DltError {
  guard sample_bytes > 0 && sample_bytes <= 65536 else {
    raise Invalid(0, "signature sample size must be 1..65536")
  }
  let length = if self.size < sample_bytes.to_uint64() {
    self.size.to_int()
  } else {
    sample_bytes
  }
  let head = self.read_checked(0UL, length)
  let tail = if self.size <= sample_bytes.to_uint64() {
    head
  } else {
    self.read_checked(self.size - length.to_uint64(), length)
  }
  {
    size: self.size,
    sample_bytes,
    head: sample_hash(head[:]),
    tail: sample_hash(tail[:]),
  }
}

///|
pub struct SourceCatalog {
  signature : SourceSignature
  framing : Framing
  records : Array[SourceEntry]
}

///|
/// Materializes only a bounded metadata sidecar. Payload bytes are never retained.
pub fn SourceCatalog::build(
  source : Source,
  framing~ : Framing = Storage,
  limits~ : Limits = Limits::default(),
  max_entries~ : Int32 = 100000,
  sample_bytes~ : Int32 = 4096,
) -> SourceCatalog raise DltError {
  let signature = source.signature(sample_bytes~)
  let records = source.catalog(framing~, limits~, max_entries~)
  { signature, framing, records, }
}

///|
pub fn SourceCatalog::length(self : SourceCatalog) -> Int32 {
  self.records.length()
}

///|
pub fn SourceCatalog::source_signature(self : SourceCatalog) -> SourceSignature {
  self.signature
}

///|
pub fn SourceCatalog::entry(
  self : SourceCatalog,
  index : Int32,
) -> SourceEntry raise DltError {
  guard index >= 0 && index < self.records.length() else {
    raise Invalid(0, "catalog index outside range")
  }
  self.records[index]
}

///|
/// Returns the record whose framed byte range contains offset using binary search.
pub fn SourceCatalog::containing(
  self : SourceCatalog,
  offset : UInt64,
) -> Int32? {
  let mut low = 0
  let mut high = self.records.length()
  while low < high {
    let middle = low + (high - low) / 2
    let entry = self.records[middle]
    if offset < entry.offset {
      high = middle
    } else if offset - entry.offset >= entry.length.to_uint64() {
      low = middle + 1
    } else {
      return Some(middle)
    }
  }
  None
}

///|
pub fn SourceCatalog::query(
  self : SourceCatalog,
  filter : Filter,
  maximum~ : Int32 = 100000,
) -> Array[Int32] raise DltError {
  filter.validate()
  guard maximum >= 0 else { raise Invalid(0, "negative catalog result bound") }
  let result : Array[Int32] = []
  for i in 0..<self.records.length() {
    let entry = self.records[i]
    if filter_headers(filter, entry.storage, entry.header) {
      guard result.length() < maximum else {
        raise Limit(0, "catalog result count exceeds maximum")
      }
      result.push(i)
    }
  }
  result
}

///|
pub fn SourceCatalog::to_json(self : SourceCatalog) -> Json {
  {
    "format": "moondlt.catalog.v1",
    "framing": framing_name(self.framing),
    "source": {
      "size": self.signature.size.to_string(),
      "sample_bytes": self.signature.sample_bytes,
      "head": self.signature.head.to_string(),
      "tail": self.signature.tail.to_string(),
    },
    "records": Json::array(
      self.records.map(entry => {
        "offset": entry.offset.to_string(),
        "length": entry.length,
        "storage": storage_json(entry.storage),
        "header": entry.header.to_json(),
      }),
    ),
  }
}

///|
/// Untrusted sidecars are checked for contiguous coverage, length arithmetic,
/// header validity, framing consistency, and caller-specified entry limits.
pub fn SourceCatalog::from_json(
  json : Json,
  limits~ : Limits = Limits::default(),
  max_entries~ : Int32 = 100000,
) -> SourceCatalog raise DltError {
  check_limits(limits)
  guard max_entries >= 0 else {
    raise Invalid(0, "negative catalog entry limit")
  }
  let object = verbose_object(json)
  verbose_fields(object, ["format", "framing", "source", "records"])
  guard verbose_string(verbose_field(object, "format")) == "moondlt.catalog.v1" else {
    raise Unsupported(0, "unknown catalog JSON format")
  }
  let framing = parse_framing(verbose_string(verbose_field(object, "framing")))
  let source = verbose_object(verbose_field(object, "source"))
  verbose_fields(source, ["size", "sample_bytes", "head", "tail"])
  let size = json_uint64(verbose_field(source, "size"), 0xFFFFFFFFFFFFFFFFUL)
  let sample_bytes = verbose_small_integer(
    verbose_field(source, "sample_bytes"),
    65536,
  )
  guard sample_bytes > 0 else {
    raise Invalid(0, "catalog sample size must be positive")
  }
  let signature = {
    size,
    sample_bytes,
    head: json_uint64(verbose_field(source, "head"), 0xFFFFFFFFFFFFFFFFUL),
    tail: json_uint64(verbose_field(source, "tail"), 0xFFFFFFFFFFFFFFFFUL),
  }
  let array = verbose_array(verbose_field(object, "records"))
  guard array.length() <= max_entries else {
    raise Limit(0, "catalog JSON entry limit exceeded")
  }
  let records : Array[SourceEntry] = []
  let mut expected_offset = 0UL
  for item in array {
    let record = verbose_object(item)
    verbose_fields(record, ["offset", "length", "storage", "header"])
    let offset = json_uint64(verbose_field(record, "offset"), size)
    guard offset == expected_offset else {
      raise Invalid(
        0, "catalog records must cover source in order without gaps",
      )
    }
    let length = verbose_small_integer(
      verbose_field(record, "length"),
      prefix_size(framing) + limits.message_bytes,
    )
    let header = Header::from_json(verbose_field(record, "header"), limits~)
    let storage = storage_from_json(verbose_field(record, "storage"))
    guard (framing == Storage) == (storage is Some(_)) else {
      raise Invalid(0, "catalog storage metadata disagrees with framing")
    }
    let header_length = prefix_size(framing) + header.wire_size()
    guard length >= header_length && length.to_uint64() <= size - offset else {
      raise Invalid(0, "catalog record range exceeds source")
    }
    records.push({
      offset,
      length,
      framing,
      storage,
      header,
      payload_offset: offset + header_length.to_uint64(),
      payload_length: length - header_length,
    })
    expected_offset += length.to_uint64()
  }
  guard expected_offset == size else {
    raise Invalid(0, "catalog does not cover complete source")
  }
  { signature, framing, records, }
}

///|
/// Verifies every indexed header against the source before trusting metadata
/// queries. Payload bytes are not scanned; each selected read validates again.
pub fn SourceCatalog::open(
  self : SourceCatalog,
  source : Source,
  limits~ : Limits = Limits::default(),
) -> IndexedSource raise DltError {
  check_limits(limits)
  let opened = self.open_trusted(source)
  let cursor = SourceCursor::new(
    source,
    framing=self.framing,
    limits~,
    max_entries=self.records.length().to_uint64(),
  )
  let mut index = 0
  while cursor.next_entry() is Some(actual) {
    guard index < self.records.length() && actual == self.records[index] else {
      raise Invalid(0, "catalog metadata does not match source header")
    }
    index += 1
  }
  guard index == self.records.length() else {
    raise Invalid(0, "catalog record count does not match source")
  }
  opened
}

///|
/// Fast path for caller-trusted, previously verified sidecars only. Sampled
/// identity cannot prove that sidecar headers describe the source correctly.
/// Queries can omit records if the caller supplies altered metadata here.
pub fn SourceCatalog::open_trusted(
  self : SourceCatalog,
  source : Source,
) -> IndexedSource raise DltError {
  let actual = source.signature(sample_bytes=self.signature.sample_bytes)
  guard actual == self.signature else {
    raise Invalid(0, "catalog signature does not match source")
  }
  { source, catalog: self, }
}

///|
pub struct IndexedSource {
  source : Source
  catalog : SourceCatalog
}

///|
pub fn IndexedSource::length(self : IndexedSource) -> Int32 {
  self.catalog.length()
}

///|
pub fn IndexedSource::read(
  self : IndexedSource,
  index : Int32,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  self.source.read_entry(self.catalog.entry(index), limits~)
}

///|
pub fn IndexedSource::query(
  self : IndexedSource,
  filter : Filter,
  maximum~ : Int32 = 100000,
) -> Array[Int32] raise DltError {
  self.catalog.query(filter, maximum~)
}

///|
/// Queries metadata first, then loads only matching payloads. Explicit maximum
/// and cumulative payload budgets bound the materialized result.
pub fn IndexedSource::select(
  self : IndexedSource,
  filter : Filter,
  maximum~ : Int32 = 1000,
  payload_budget~ : Int32 = 16777216,
  limits~ : Limits = Limits::default(),
) -> Array[Message] raise DltError {
  guard payload_budget >= 0 else {
    raise Invalid(0, "negative selection payload budget")
  }
  let indices = self.query(filter, maximum~)
  let result : Array[Message] = []
  let mut total = 0
  for index in indices {
    let entry = self.catalog.entry(index)
    guard entry.payload_length <= payload_budget - total else {
      raise Limit(0, "selection payload budget exceeded")
    }
    let message = self.source.read_entry(entry, limits~)
    result.push(message)
    total += entry.payload_length
  }
  result
}

///|
/// Reads an ordered half-open record interval without decoding unrelated records.
pub fn IndexedSource::visit_range(
  self : IndexedSource,
  start : Int32,
  end : Int32,
  visit : (Message) -> Bool raise DltError,
  limits~ : Limits = Limits::default(),
) -> Int32 raise DltError {
  guard start >= 0 && start <= end && end <= self.length() else {
    raise Invalid(0, "catalog interval outside range")
  }
  let mut count = 0
  for i in start..<end {
    count += 1
    if !visit(self.read(i, limits~)) {
      break
    }
  }
  count
}
