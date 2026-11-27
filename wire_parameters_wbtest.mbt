///|
fn review_header(endian : Endian) -> Header {
  {
    ..Header::new(endian~),
    extended: Some({
      verbose: true,
      message_type: 0,
      subtype: 4,
      argument_count: 0,
      application: "APP1",
      context: "CORE",
    }),
  }
}

///|
fn wire_leaf(kind : NumericType, bits : WideBits) -> WireParameter {
  Numeric({
    kind,
    elements: [bits],
    dimensions: [],
    variable: None,
    scaling: None,
  })
}

///|
test "R19 review vector edits a Storage record from its typed members in both orders" {
  let storage : StorageHeader = {
    seconds: 7U,
    microseconds: 123U,
    ecu: "ECU1",
  }
  let decimal = "79228162514264337593543950337"
  let bits = WideBits::from_decimal(decimal)
  assert_eq(bits, { high: 4294967296UL, low: 1UL, })
  for
    (endian, golden) in [
      (
        Little,
        "004000000200002000000500626f6f74004500000001000000000000000000000001000000",
      ),
      (
        Big,
        "000040000002000020000005626f6f74000000004500000001000000000000000000000001",
      ),
    ] {
    let msg = Message::with_wire_parameters(
      review_header(endian),
      [
        Structure(None, [
          TraceInfo(Ascii, "boot"),
          wire_leaf(UIntValue(128), bits),
        ]),
      ],
      storage~,
    )
    assert_eq(hex_encode(msg.payload[:]), golden)
    let frame = encode(msg)
    assert_eq(frame.length(), 67)
    let stream = StreamDecoder::new()
    let received = []
    for i in 0..<frame.length() {
      for m in stream.feed(frame[i:i + 1]).messages {
        received.push(m)
      }
    }
    stream.finish()
    assert_eq(received.length(), 1)
    let typed = received[0].wire_parameters()
    guard typed is [Structure(None, children)] &&
      children is [TraceInfo(Ascii, "boot"), Numeric(n)] else {
      fail("lost struct/trace/number type")
    }
    assert_eq(
      n.elements[0].integer(width=128, signed=false).to_string(),
      decimal,
    )
    children[0] = TraceInfo(Ascii, "ready")
    let edited = Message::with_wire_parameters(
      received[0].header,
      typed,
      storage~,
    )
    let bytes = encode(edited)
    assert_eq(bytes.length(), 68)
    assert_eq(edited.payload.length(), 38)
    assert_eq(decode_exact(bytes[:]).wire_parameters(), typed)
    assert_true(
      try {
        ignore(decode_wire_parameters(msg.payload[:36], 1, endian))
        false
      } catch {
        Truncated(21, _) => true
        _ => false
      },
    )
  }
}

///|
test "R19 trace coding and nested counts are independent of NOAR" {
  let tree : Array[WireParameter] = [
    Structure(Some("outer"), [
      Structure(None, [TraceInfo(Utf8, "温🙂")]),
      TraceInfo(Ascii, ""),
    ]),
    StringParameter(Ascii, "boot", Some("name")),
  ]
  for endian in [Big, Little] {
    let b = encode_wire_parameters(tree, endian)
    assert_eq(decode_wire_parameters(b[:], 2, endian), tree)
    for end in 0..<b.length() {
      assert_true(
        try {
          ignore(decode_wire_parameters(b[:end], 2, endian))
          false
        } catch {
          _ => true
        },
      )
    }
    assert_true(
      try {
        ignore(
          decode_wire_parameters(b[:], 2, endian, budget={
            nodes: 10,
            depth: 1,
          }),
        )
        false
      } catch {
        Limit(_, _) => true
        _ => false
      },
    )
    assert_true(
      try {
        ignore(
          encode_wire_parameters(tree, endian, budget={ nodes: 3, depth: 2, }),
        )
        false
      } catch {
        Limit(_, _) => true
        _ => false
      },
    )
  }
  for
    hex in [
      "004000000000", "0020000002004142", "002000000000", "00200100010000", "00280000010000",
      "006000000100", "002000000200ff00",
    ] {
    let b = hex_decode(hex)
    assert_true(
      try {
        ignore(decode_wire_parameters(b[:], 1, Little))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "signed and unsigned 128-bit extremes and IEEE classification are exact" {
  for
    (s, signed) in [
      ("0", false),
      ("340282366920938463463374607431768211455", false),
      ("-170141183460469231731687303715884105728", true),
      ("170141183460469231731687303715884105727", true),
    ] {
    let v = WideBits::from_decimal(s, signed~)
    assert_eq(v.integer(width=128, signed~).to_string(), s)
  }
  for
    (s, signed) in [
      ("340282366920938463463374607431768211456", false),
      ("-170141183460469231731687303715884105729", true),
      ("-1", false),
      ("-0", true),
      ("01", false),
    ] {
    assert_true(
      try {
        ignore(WideBits::from_decimal(s, signed~))
        false
      } catch {
        Invalid(_, _) => true
        _ => false
      },
    )
  }
  let negative_zero : WideBits = { high: 0UL, low: 0x8000UL, }
  assert_eq(negative_zero.float_parts(width=16), Zero(true))
  let sub : WideBits = { high: 0UL, low: 1UL, }
  assert_eq(
    sub.float_parts(width=128),
    Subnormal(false, @bigint.BigInt::from_int(1), -16494),
  )
  let one : WideBits = { high: 0x3fff000000000000UL, low: 0UL, }
  let next = { ..one, low: 1UL, }
  assert_eq(
    next.float_parts(width=128),
    Normal(false, bit_power(112) + @bigint.BigInt::from_int(1), -112),
  )
  let inf : WideBits = { high: 0x7fff000000000000UL, low: 0UL, }
  assert_eq(inf.float_parts(width=128), Infinity(false))
  assert_eq(
    ({ ..inf, low: 1UL, } : WideBits).float_parts(width=128),
    Nan(false, @bigint.BigInt::from_int(1)),
  )
}

///|
test "wide FIXP and multidimensional float arrays preserve types and bit patterns" {
  let offset = WideBits::from_decimal(
    "-79228162514264337593543950336",
    signed=true,
  )
  let raw = WideBits::from_decimal("158456325028528675187087900674")
  let scale : WireScaling = {
    quantization_bits: 0x3f000000U,
    offset_bits: offset,
  }
  let (coeff, exp) = scale.logical(raw, width=128, signed=false)
  assert_eq(coeff, bit_power(-exp))
  let tree : Array[WireParameter] = [
    Numeric({
      kind: UIntValue(128),
      dimensions: [],
      elements: [raw],
      variable: Some({ name: "t", unit: Some("us"), }),
      scaling: Some(scale),
    }),
    Numeric({
      kind: FloatValue(128),
      dimensions: [2, 3],
      elements: Array::make(6, { high: 0x7fff000000000000UL, low: 9UL, }),
      variable: None,
      scaling: None,
    }),
    Numeric({
      kind: FloatValue(16),
      dimensions: [2],
      elements: [{ high: 0UL, low: 0x8000UL, }, { high: 0UL, low: 1UL, }],
      variable: None,
      scaling: None,
    }),
  ]
  for endian in [Little, Big] {
    let b = encode_wire_parameters(tree, endian)
    assert_eq(decode_wire_parameters(b[:], 3, endian), tree)
  }
}
