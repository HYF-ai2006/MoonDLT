///|
fn sample_message() -> Message {
  { storage: Some({ seconds: 1U, microseconds: 2U, ecu: "ECU" }),
    header: { endian: Little, counter: 255, ecu: Some("ECU"),
      session: Some(0x12345678U), timestamp: Some(0xABCDEF01U),
      extended: Some({ verbose: false, message_type: 0, subtype: 4,
        argument_count: 0, application: "APP", context: "CTX" }) },
    payload: b"\x78\x56\x34\x12hi" }
}

///|
test "headers golden layout, endian flags never change network header fields" {
  let msg = sample_message()
  let bytes = encode(msg)
  assert_eq(hex_encode(bytes[:]), "444c54010100000002000000454355003dff00204543550012345678abcdef0140004150500043545800785634126869")
  assert_eq(decode_exact(bytes[:]), msg)
  let big = { ..msg, header: { ..msg.header, endian: Big } }
  let bigbytes = encode(big)
  assert_eq(bigbytes[16], b'\x3f')
  assert_eq(bigbytes[20:32], bytes[20:32])
}

///|
test "all header flag combinations and framing boundaries" {
  for flags in 0..<16 {
    let base = sample_message()
    let header = { ..base.header,
      ecu: if (flags & 1) != 0 { Some("E") } else { None },
      session: if (flags & 2) != 0 { Some(0U) } else { None },
      timestamp: if (flags & 4) != 0 { Some(0xFFFFFFFFU) } else { None },
      extended: if (flags & 8) != 0 { base.header.extended } else { None } }
    let msg = { ..base, header }
    for framing in [Storage, Network, Serial] {
      let data = encode(msg, framing~)
      let decoded = decode_exact(data[:], framing~)
      assert_eq(decoded.header, msg.header)
      assert_eq(decoded.payload, msg.payload)
      assert_eq(decoded.storage, if framing == Storage { msg.storage } else { None })
      for n in 0..<data.length() {
        let rejected = try { ignore(decode(data[:n], framing~)); false } catch { _ => true }
        assert_true(rejected)
      }
    }
  }
}

///|
test "length, version, timestamp and trailing byte rejection" {
  for value in ["20000003", "40000004", "3f000004", "20000005"] {
    let bytes = hex_decode(value)
    let rejected = try { ignore(decode(bytes[:], framing=Network)); false } catch { _ => true }
    assert_true(rejected)
  }
  let invalid = { ..sample_message(), storage: Some({ seconds: 1U, microseconds: 1000000U, ecu: "E" }) }
  assert_true(try { ignore(encode(invalid)); false } catch { _ => true })
  let wire = encode(sample_message())
  let joined = @buffer.Buffer::Buffer()
  joined.write_bytes(wire[:])
  joined.write_byte(b'\x00')
  assert_true(try { ignore(decode_exact(joined.to_bytes()[:])); false } catch { _ => true })
  assert_eq(decode(joined.to_bytes()[:]).consumed, wire.length())
}

///|
test "incremental splits at every possible boundary" {
  let msg = sample_message()
  for framing in [Storage, Network, Serial] {
    let bytes = encode(msg, framing~)
    for split in 0..=bytes.length() {
      let decoder = StreamDecoder::new(framing~)
      let a = decoder.feed(bytes[:split])
      let b = decoder.feed(bytes[split:])
      assert_eq(a.messages.length() + b.messages.length(), 1)
      decoder.finish()
      assert_eq(decoder.message_count(), 1UL)
      assert_eq(decoder.input_bytes(), bytes.length().to_uint64())
      assert_eq(decoder.buffered_bytes(), 0)
    }
  }
}

///|
test "recovery split marker false candidate and strict tail" {
  let wire = encode(sample_message())
  let decoder = StreamDecoder::new(recover=true)
  let a = decoder.feed(b"garbageDL"[:])
  assert_eq(a.skipped, 7)
  let joined = @buffer.Buffer::Buffer()
  joined.write_bytes(b"T\x01"[:])
  joined.write_bytes(wire[4:])
  joined.write_bytes(b"D"[:])
  let b = decoder.feed(joined.to_bytes()[:])
  assert_eq(b.messages.length(), 1)
  assert_eq(decoder.skipped_bytes(), 7UL)
  assert_eq(decoder.discard_tail(), 1)
  let strict = StreamDecoder::new()
  ignore(strict.feed(wire[:10]))
  assert_true(try { strict.finish(); false } catch { _ => true })
  assert_true(strict.is_failed())
  strict.reset()
  assert_eq(strict.feed(wire[:]).messages.length(), 1)
}

///|
test "transcoder emits filtered network frames from chunked storage" {
  let collected : Array[Bytes] = []
  let transcoder = StreamTranscoder::new(Storage, Network, bytes => collected.push(bytes))
  let wire = encode(sample_message())
  for byte in wire { ignore(transcoder.feed(Bytes::from_array([byte])[:])) }
  transcoder.finish()
  assert_eq(collected.length(), 1)
  assert_eq(decode_exact(collected[0][:], framing=Network).header, sample_message().header)
}
