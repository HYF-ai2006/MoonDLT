///|
test "ARXML packer changes only a selected dynamic field in either byte order" {
  let scaling = {
    quantization_bits: 0x3f000000U,
    offset_bits: WideBits::from_decimal(
      "-79228162514264337593543950336",
      signed=true,
    ),
  }
  let catalog = ArxmlCatalog::new([
    {
      ecu: None,
      application: "APP",
      context: "CTX",
      message_id: 0x11223344U,
      message_type: 2,
      subtype: 15,
      source_file: None,
      source_line: None,
      fields: [
        { name: "name", unit_ref: None, kind: StaticText("sample"), },
        {
          name: "count",
          unit_ref: None,
          kind: FixedNumberField(UIntValue(128), scaling),
        },
        { name: "text", unit_ref: None, kind: TextField(Utf8, 4), },
        { name: "raw", unit_ref: None, kind: OctetField(2), },
      ],
    },
  ])
  for
    (endian, before, after) in [
      (
        Big,
        "1122334400000001000000000000000000000001e5bc80001234",
        "1122334400000001000000000000000000000002e5bc80001234",
      ),
      (
        Little,
        "4433221101000000000000000000000001000000e5bc80001234",
        "4433221102000000000000000000000001000000e5bc80001234",
      ),
    ] {
    let capture = Message::new(Header::new(endian~), hex_decode(before))
    let decoded = catalog.decode(capture)
    assert_eq(decoded.description.subtype, 15)
    assert_eq(catalog.encode(capture, decoded.arguments[:]), capture)
    let revised = decoded.arguments.copy()
    guard revised[1] is Numeric(n) else { fail("missing scaled integer") }
    let updated = WideBits::from_decimal("79228162514264337593543950338")
    revised[1] = Numeric({ ..n, elements: [updated], })
    let packed = catalog.encode(capture, revised[:])
    assert_eq(hex_encode(packed.payload[:]), after)
    assert_eq(catalog.decode(packed).arguments, revised)
    revised[0] = StringParameter(Utf8, "different", Some("name"))
    assert_true(
      try {
        ignore(catalog.encode(capture, revised[:]))
        false
      } catch {
        Invalid(_, _) => true
        _ => false
      },
    )
  }
}
