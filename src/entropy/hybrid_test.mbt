///|
/// Round-trip tests for hybrid-uint coding: encode a value, then feed the
/// emitted raw bits to `read_hybrid_uint` and check the value is recovered.

/// A tiny LSB-first bit writer for building test streams.
struct BitWriter {
  out : Array[Byte]
  mut acc : UInt
  mut nbits : Int
}

fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0U, nbits: 0 }
}

fn BitWriter::write_bits(self : BitWriter, value : UInt, n : Int) -> Unit {
  let mut v = value
  let mut left = n
  while left > 0 {
    self.acc = self.acc | ((v & 1U) << self.nbits)
    v = v >> 1
    self.nbits = self.nbits + 1
    left = left - 1
    if self.nbits == 8 {
      self.out.push(self.acc.to_byte())
      self.acc = 0U
      self.nbits = 0
    }
  }
}

fn BitWriter::finish(self : BitWriter) -> Bytes {
  if self.nbits > 0 {
    self.out.push(self.acc.to_byte())
    self.acc = 0U
    self.nbits = 0
  }
  Bytes::from_array(self.out)
}

/// Pack the low `nbits` bits of `value` into bytes, least-significant bit first.
fn bits_bytes(value : UInt, nbits : Int) -> Bytes {
  let w = BitWriter::new()
  w.write_bits(value, nbits)
  w.finish()
}

fn roundtrip(config : HybridUintConfig, value : UInt) -> Bool raise @error.JxlError {
  let (token, nbits, bits) = config.encode(value)
  let reader = @bitio.BitReader::new(bits_bytes(bits, nbits))
  read_hybrid_uint(config, token, reader) == value
}

/// Ceil(log2) of a nonzero value (mirrors the helper in hybrid.mbt).
fn ceil_bits(n : UInt) -> Int {
  if n <= 1U {
    return 0
  }
  let mut v = n - 1U
  let mut bits : Int = 0
  while v > 0U {
    bits = bits + 1
    v = v >> 1
  }
  bits
}

test "hybrid uint round-trips a dense range" {
  let config = HybridUintConfig::new(4U, 2U, 0U)
  let mut v = 0
  while v < 4096 {
    assert_true(roundtrip(config, v.reinterpret_as_uint()))
    v = v + 1
  }
}

test "hybrid uint round-trips large values" {
  let config = HybridUintConfig::new(4U, 2U, 0U)
  let values : Array[UInt] = [65535U, 65536U, 1000000U, 16777216U, 1073741823U]
  for v in values {
    assert_true(roundtrip(config, v))
  }
}

test "hybrid uint round-trips with lsb bits in the token" {
  let configs : Array[HybridUintConfig] = [
    HybridUintConfig::new(8U, 0U, 0U),
    HybridUintConfig::new(8U, 2U, 2U),
    HybridUintConfig::new(12U, 2U, 3U),
  ]
  let values : Array[UInt] = [0U, 1U, 255U, 256U, 4095U, 4096U, 65535U, 1048575U, 1073741823U]
  for config in configs {
    for value in values {
      assert_true(roundtrip(config, value))
    }
  }
}

test "read_uint_config recovers the encoded configuration" {
  let log_alpha_size : UInt = 4U
  // When split_exponent == log_alpha_size, msb/lsb are not serialized and
  // default to zero.
  let w0 = BitWriter::new()
  w0.write_bits(4U, ceil_bits(log_alpha_size + 1U))
  let got0 = read_uint_config(@bitio.BitReader::new(w0.finish()), log_alpha_size)
  assert_true(got0.split_exponent == 4U)
  assert_true(got0.msb_in_token == 0U)
  assert_true(got0.lsb_in_token == 0U)

  // Otherwise msb and lsb round-trip with their exact serialized widths.
  let cases : Array[(UInt, UInt, UInt)] = [(3U, 2U, 1U), (3U, 0U, 0U), (2U, 1U, 1U), (1U, 0U, 0U)]
  for (se, msb, lsb) in cases {
    let w = BitWriter::new()
    w.write_bits(se, ceil_bits(log_alpha_size + 1U))
    w.write_bits(msb, ceil_bits(se + 1U))
    w.write_bits(lsb, ceil_bits(se - msb + 1U))
    let got = read_uint_config(@bitio.BitReader::new(w.finish()), log_alpha_size)
    assert_true(got.split_exponent == se)
    assert_true(got.msb_in_token == msb)
    assert_true(got.lsb_in_token == lsb)
  }
}
