///|
/// Right-aligned wire bits in host-independent high/low order.
pub(all) struct WideBits {
  high : UInt64
  low : UInt64
} derive(Eq, @debug.Debug)

///|
fn bit_power(n : Int32) -> @bigint.BigInt {
  @bigint.BigInt::from_int(1).shl(n)
}

///|
fn wire_width_code(width : Int32) -> UInt32 {
  match width {
    8 => 1U
    16 => 2U
    32 => 3U
    64 => 4U
    128 => 5U
    _ => 0U
  }
}

///|
fn WideBits::fits(self : WideBits, width : Int32) -> Bool {
  width == 128 ||
  (
    self.high == 0UL &&
    (width == 64 || (width > 0 && width < 64 && self.low >> width == 0UL))
  )
}

///|
fn read_bits(
  data : BytesView,
  pos : Int32,
  width : Int32,
  endian : Endian,
) -> WideBits raise DltError {
  if width == 128 {
    require_range(data, pos, 16)
    let first = read_u64(data, pos, endian)
    let second = read_u64(data, pos + 8, endian)
    if endian == Big {
      { high: first, low: second, }
    } else {
      { high: second, low: first, }
    }
  } else {
    { high: 0UL, low: read_integer_bits(data, pos, width, endian), }
  }
}

///|
fn write_bits(
  out : @buffer.Buffer,
  bits : WideBits,
  width : Int32,
  endian : Endian,
) -> Unit {
  if width == 128 {
    if endian == Big {
      write_u64(out, bits.high, endian)
      write_u64(out, bits.low, endian)
    } else {
      write_u64(out, bits.low, endian)
      write_u64(out, bits.high, endian)
    }
  } else {
    write_integer_bits(out, width, bits.low, endian)
  }
}

///|
pub fn WideBits::integer(
  self : WideBits,
  width~ : Int32,
  signed~ : Bool,
) -> @bigint.BigInt raise DltError {
  guard wire_width_code(width) != 0U && self.fits(width) else {
    raise Invalid(0, "bits exceed integer width")
  }
  let v = @bigint.BigInt::from_uint64(self.high).shl(64) +
    @bigint.BigInt::from_uint64(self.low)
  if signed && v >= bit_power(width - 1) {
    v - bit_power(width)
  } else {
    v
  }
}

///|
pub fn WideBits::from_decimal(
  text : String,
  width~ : Int32 = 128,
  signed~ : Bool = false,
) -> WideBits raise DltError {
  guard wire_width_code(width) != 0U && text.length() > 0 && text.length() <= 40 else {
    raise Invalid(0, "invalid integer width or decimal length")
  }
  let v = @string.parse_bigint(text[:]) catch {
    _ => raise Invalid(0, "invalid decimal integer")
  }
  guard v.to_string() == text else {
    raise Invalid(0, "expected canonical decimal integer")
  }
  let bound = bit_power(if signed { width - 1 } else { width })
  let minimum = if signed { -bound } else { @bigint.BigInt::from_int(0) }
  guard v >= minimum && v < bound else {
    raise Invalid(0, "integer outside wire range")
  }
  let raw = if v < @bigint.BigInt::from_int(0) {
    v + bit_power(width)
  } else {
    v
  }
  {
    high: raw.shr(64).to_uint64(),
    low: (raw & @bigint.BigInt::from_uint64(0xFFFFFFFFFFFFFFFFUL)).to_uint64(),
  }
}

///|
/// For finite nonzero values, magnitude = significand * 2**exponent.
/// NaN retains its full fraction including the quiet/signaling bit.
pub(all) enum FloatParts {
  Zero(Bool)
  Subnormal(Bool, @bigint.BigInt, Int32)
  Normal(Bool, @bigint.BigInt, Int32)
  Infinity(Bool)
  Nan(Bool, @bigint.BigInt)
} derive(Eq, @debug.Debug)

///|
pub fn WideBits::float_parts(
  self : WideBits,
  width~ : Int32,
) -> FloatParts raise DltError {
  let (exp_len, frac_len) = match width {
    16 => (5, 10)
    32 => (8, 23)
    64 => (11, 52)
    128 => (15, 112)
    _ => raise Invalid(0, "expected binary16/32/64/128")
  }
  let v = self.integer(width~, signed=false)
  let one = @bigint.BigInt::from_int(1)
  let negative = v >= bit_power(width - 1)
  let frac = v & (bit_power(frac_len) - one)
  let exponent = (v.shr(frac_len) & (bit_power(exp_len) - one)).to_int()
  let bias = (1 << (exp_len - 1)) - 1
  if exponent == (1 << exp_len) - 1 {
    if frac.is_zero() {
      Infinity(negative)
    } else {
      Nan(negative, frac)
    }
  } else if exponent == 0 {
    if frac.is_zero() {
      Zero(negative)
    } else {
      Subnormal(negative, frac, 1 - bias - frac_len)
    }
  } else {
    Normal(negative, bit_power(frac_len) + frac, exponent - bias - frac_len)
  }
}

///|
/// Quantization is the exact binary32 bit pattern, offset the right-aligned
/// two's-complement signed integer of the prescribed wire width.
pub(all) struct WireScaling {
  quantization_bits : UInt32
  offset_bits : WideBits
} derive(Eq, @debug.Debug)

///|
fn wire_offset_width(width : Int32) -> Int32 {
  if width <= 32 {
    32
  } else {
    width
  }
}

///|
/// Exact finite logical value, returned as (signed coefficient, power of two).
pub fn WireScaling::logical(
  self : WireScaling,
  raw : WideBits,
  width~ : Int32,
  signed~ : Bool,
) -> (@bigint.BigInt, Int32) raise DltError {
  let physical = raw.integer(width~, signed~)
  let offset = self.offset_bits.integer(
    width=wire_offset_width(width),
    signed=true,
  )
  let quant : WideBits = { high: 0UL, low: self.quantization_bits.to_uint64(), }
  match quant.float_parts(width=32) {
    Zero(_) => (offset, 0)
    Normal(neg, sig, exp) | Subnormal(neg, sig, exp) => {
      let product = physical * (if neg { -sig } else { sig })
      if exp >= 0 {
        (product.shl(exp) + offset, 0)
      } else {
        (product + offset.shl(-exp), exp)
      }
    }
    _ => raise Invalid(0, "nonfinite quantization has no finite dyadic value")
  }
}
