///|
fn payload_samples() -> Array[Argument] {
  [
    Boolean(false),
    Boolean(true),
    Signed(8, -128L),
    Signed(8, 127L),
    Signed(16, -32768L),
    Signed(16, 32767L),
    Signed(32, -2147483648L),
    Signed(32, 2147483647L),
    Signed(64, -9223372036854775807L - 1L),
    Signed(64, 9223372036854775807L),
    Unsigned(8, 255UL),
    Unsigned(16, 65535UL),
    Unsigned(32, 4294967295UL),
    Unsigned(64, 18446744073709551615UL),
    Floating(32, -13.25),
    Floating(64, 0.125),
    Text(Ascii, ""),
    Text(Ascii, "speed"),
    Text(Utf8, "发动机🙂"),
    Raw(b"\x00\xff\x01"),
    Raw(b""),
  ]
}

///|
test "scalar payload golden endian and strict full consumption" {
  let args = [Boolean(true), Signed(16, -2L), Text(Ascii, "A"), Raw(b"\xff")]
  let little = encode_arguments(args, Little)
  let big = encode_arguments(args, Big)
  assert_eq(
    hex_encode(little[:]),
    "110000000122000000feff0002000002004100000400000100ff",
  )
  assert_eq(
    hex_encode(big[:]),
    "000000110100000022fffe0000020000024100000004000001ff",
  )
  assert_eq(decode_arguments(little[:], 4, Little), args)
  assert_eq(decode_arguments(big[:], 4, Big), args)
  assert_true(
    try {
      ignore(decode_arguments(little[:], 3, Little))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(decode_arguments(little[:], 5, Little))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "scalar widths and every truncation boundary" {
  let args = payload_samples()
  for endian in [Little, Big] {
    let bytes = encode_arguments(args, endian)
    assert_eq(decode_arguments(bytes[:], args.length(), endian), args)
    for prefix in 0..<bytes.length() {
      assert_true(
        try {
          ignore(decode_arguments(bytes[:prefix], args.length(), endian))
          false
        } catch {
          _ => true
        },
      )
    }
    for argument in args {
      let json = argument.to_json()
      assert_eq(Argument::from_json(json), argument)
    }
  }
}

///|
test "payload rejects incompatible masks and malformed text without dropping raw bytes" {
  for
    hex in [
      "1100000002", "1200000000", "3000000000", "4100080000", "000200000000", "00020000010041",
      "000200000300410042", "008200000200ff00", "000200000200ff00", "00020200010000",
      "2310000000000000", "2301000000000000", "2308000000000000",
    ] {
    let data = hex_decode(hex)
    assert_true(
      try {
        ignore(decode_arguments(data[:], 1, Little))
        false
      } catch {
        _ => true
      },
    )
    let message = Message::new(Header::new(), data)
    assert_eq(hex_encode(message.payload[:]), hex)
  }
  for
    argument in [
      Signed(8, 128L),
      Signed(16, -32769L),
      Unsigned(8, 256UL),
      Unsigned(32, 4294967296UL),
      Floating(16, 1.0),
      Text(Ascii, "中文"),
      Text(Utf8, "embedded\u0000zero"),
    ] {
    assert_true(
      try {
        ignore(encode_arguments([argument], Little))
        false
      } catch {
        _ => true
      },
    )
  }
  let small = { ..Limits::default(), string_bytes: 2, }
  assert_true(
    try {
      ignore(encode_arguments([Text(Ascii, "ab")], Little, limits=small))
      false
    } catch {
      _ => true
    },
  )
}

///|
fn advanced_samples() -> Array[VerboseParameter] {
  [
    VerboseParameter::scalar(Boolean(true), variable={
      name: "active",
      unit: None,
    }),
    VerboseParameter::scalar(Text(Utf8, "温度"), variable={
      name: "status",
      unit: None,
    }),
    VerboseParameter::scalar(Raw(b"\x00\xff"), variable={
      name: "packet",
      unit: None,
    }),
    VerboseParameter::scalar(
      Signed(16, -42L),
      variable={ name: "temperature", unit: Some("C"), },
      scaling={ quantization: Float::from_double(0.25), offset: -10L, },
    ),
    VerboseParameter::scalar(Unsigned(64, 18446744073709551615UL), scaling={
      quantization: Float::from_double(2.0),
      offset: -9223372036854775807L - 1L,
    }),
    VerboseParameter::array(
      IntValue(16),
      [2, 3],
      [
        Signed(16, -3L),
        Signed(16, -2L),
        Signed(16, -1L),
        Signed(16, 0L),
        Signed(16, 1L),
        Signed(16, 2L),
      ],
      variable={ name: "accel", unit: Some("m/s2"), },
      scaling={ quantization: Float::from_double(0.5), offset: 1L, },
    ),
    VerboseParameter::array(Bool8, [2], [Boolean(false), Boolean(true)], variable={
      name: "flags",
      unit: Some(""),
    }),
    VerboseParameter::array(FloatValue(32), [1], [Floating(32, -3.5)]),
  ]
}

///|
test "advanced VARI arrays and fixed point consume exact wire data" {
  let samples = advanced_samples()
  for endian in [Little, Big] {
    let bytes = encode_parameters(samples, endian)
    assert_eq(decode_parameters(bytes[:], samples.length(), endian), samples)
    for prefix in 0..<bytes.length() {
      assert_true(
        try {
          ignore(decode_parameters(bytes[:prefix], samples.length(), endian))
          false
        } catch {
          _ => true
        },
      )
    }
    for parameter in samples {
      assert_eq(VerboseParameter::from_json(parameter.to_json()), parameter)
    }
  }
  let array = VerboseParameter::array(IntValue(16), [2, 2], [
    Signed(16, -1L),
    Signed(16, 0L),
    Signed(16, 1L),
    Signed(16, 2L),
  ])
  assert_eq(
    hex_encode(encode_parameters([array], Little)[:]),
    "22010000020002000200ffff000001000200",
  )
  assert_eq(
    hex_encode(encode_parameters([array], Big)[:]),
    "00000122000200020002ffff000000010002",
  )
  let scale = VerboseParameter::scalar(Signed(8, -2L), scaling={
    quantization: Float::from_double(0.5),
    offset: -10L,
  })
  assert_eq(
    hex_encode(encode_parameters([scale], Little)[:]),
    "211000000000003ff6fffffffe",
  )
  assert_eq(scale.logical_values(), [-11.0])
}

///|
test "advanced metadata and shape validators" {
  for
    bad in [
      VerboseParameter::array(IntValue(8), [2, 2], [Signed(8, 1L)]),
      VerboseParameter::array(IntValue(8), [1], [Unsigned(8, 1UL)]),
      VerboseParameter::array(IntValue(64), [65535, 65535], []),
      VerboseParameter::array(IntValue(8), [], []),
      VerboseParameter::array(IntValue(8), [0], []),
      VerboseParameter::scalar(Signed(8, 1L), variable={
        name: "值",
        unit: Some(""),
      }),
      VerboseParameter::scalar(Signed(8, 1L), variable={
        name: "x",
        unit: None,
      }),
      VerboseParameter::scalar(Boolean(true), variable={
        name: "x",
        unit: Some("bad"),
      }),
      VerboseParameter::scalar(Floating(64, 1.0), scaling={
        quantization: Float::from_double(1.0),
        offset: 0L,
      }),
      VerboseParameter::scalar(Signed(8, 1L), scaling={
        quantization: Float::from_double(1.0),
        offset: 2147483648L,
      }),
    ] {
    assert_true(
      try {
        ignore(encode_parameters([bad], Little))
        false
      } catch {
        _ => true
      },
    )
  }
  for
    hex in [
      "1100000002", "1110000000", "220100000000", "2201000001000000", "236000000000",
    ] {
    let bytes = hex_decode(hex)
    assert_true(
      try {
        ignore(decode_parameters(bytes[:], 1, Little))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "tagged JSON rejects lossy integer numbers and noncanonical decimals" {
  let bad : Array[Json] = [
    { "kind": "unsigned", "width": 64, "value": 9007199254740992.0 },
    { "kind": "unsigned", "width": 64, "value": "18446744073709551616" },
    { "kind": "signed", "width": 64, "value": "-9223372036854775809" },
    { "kind": "signed", "width": 8, "value": "128" },
    { "kind": "unsigned", "width": 8, "value": "01" },
    { "kind": "signed", "width": 8, "value": "-0" },
    { "kind": "float", "width": 32, "bits": "00" },
    { "kind": "bool", "value": 1 },
    { "kind": "raw", "hex": "xx" },
    { "kind": "bool", "value": true, "extra": 1 },
  ]
  for item in bad {
    assert_true(
      try {
        ignore(Argument::from_json(item))
        false
      } catch {
        _ => true
      },
    )
  }
  for bits in [0x8000000000000000UL, 0x7FF0000000000000UL, 0x7FF800000000002AUL] {
    let argument = Floating(64, bits.reinterpret_as_double())
    let decoded = Argument::from_json(argument.to_json())
    match decoded {
      Floating(64, value) => assert_eq(value.reinterpret_as_uint64(), bits)
      _ => fail("wrong floating representation")
    }
  }
}

///|
test "numeric array access sections reshapes and safe extraction" {
  let parameter = VerboseParameter::array(
    IntValue(16),
    [2, 3],
    [
      Signed(16, 0L),
      Signed(16, 1L),
      Signed(16, 2L),
      Signed(16, 3L),
      Signed(16, 4L),
      Signed(16, 5L),
    ],
    variable={ name: "grid", unit: Some(""), },
    scaling={ quantization: Float::from_double(0.5), offset: 1L, },
  )
  assert_eq(parameter.at([1, 2]).as_int64(), 5L)
  let section = parameter.section([0, 0], [2, 2], steps=[1, 2])
  assert_eq(section.at([1, 1]).as_int64(), 5L)
  assert_eq(section.logical_values(), [1.0, 2.0, 2.5, 3.5])
  let reshaped = parameter.reshape([3, 2])
  assert_eq(reshaped.at([2, 1]).as_int64(), 5L)
  assert_eq(reshaped.variable, parameter.variable)
  assert_eq(reshaped.scaling, parameter.scaling)
  assert_true(
    try {
      ignore(parameter.at([2, 0]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parameter.section([0, 0], [2, 2], steps=[1, 3]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parameter.section([0, 0], [2, 2], steps=[1, 0]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(parameter.reshape([5]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(Signed(64, -1L).as_uint64())
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(Unsigned(64, 0xFFFFFFFFFFFFFFFFUL).as_int64())
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(Unsigned(64, 9007199254740992UL).as_double())
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    Unsigned(64, 9007199254740992UL).as_double(allow_lossy=true),
    9007199254740992.0,
  )
  assert_eq(Text(Ascii, "ok").as_text(), "ok")
  assert_eq(Boolean(true).as_bool(), true)
  assert_eq(Raw(b"x").as_raw(), b"x")
}
