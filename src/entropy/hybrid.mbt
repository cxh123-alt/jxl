///|
/// Hybrid integer ("hybrid-uint") coding, used for every entropy-coded integer
/// in JPEG XL. Values below `split_token = 2^split_exponent` are represented by
/// the token itself; larger values pack their bit-length and the leading
/// `msb_in_token` + `lsb_in_token` bits into the token, and emit the remaining
/// low bits as raw data.

pub struct HybridUintConfig {
  split_exponent : UInt
  split_token : UInt
  msb_in_token : UInt
  lsb_in_token : UInt
}

pub fn HybridUintConfig::new(split_exponent : UInt, msb_in_token : UInt, lsb_in_token : UInt) -> HybridUintConfig {
  {
    split_exponent: split_exponent,
    split_token: 1U << split_exponent.reinterpret_as_int(),
    msb_in_token: msb_in_token,
    lsb_in_token: lsb_in_token,
  }
}

pub fn HybridUintConfig::lsb_mask(self : HybridUintConfig) -> UInt {
  (1U << self.lsb_in_token.reinterpret_as_int()) - 1U
}

/// Floor(log2) of a nonzero 32-bit value.
fn floor_log2_nonzero(x : UInt) -> UInt {
  let mut n : UInt = 0U
  let mut v = x
  while v > 1U {
    v = v >> 1
    n = n + 1U
  }
  n
}

/// Ceil(log2) of a nonzero value: the number of bits needed to represent any
/// value in the half-open range `[0, n)`.
fn ceil_log2_nonzero(n : UInt) -> UInt {
  if n <= 1U {
    return 0U
  }
  floor_log2_nonzero(n - 1U) + 1U
}

/// Split `value` into the `(token, nbits, bits)` triple emitted by hybrid-uint
/// coding. `bits` holds the low `nbits` bits that follow the token in the
/// stream.
pub fn HybridUintConfig::encode(self : HybridUintConfig, value : UInt) -> (UInt, Int, UInt) {
  if value < self.split_token {
    return (value, 0, 0U)
  }
  let n = floor_log2_nonzero(value)
  let m = value - (1U << n.reinterpret_as_int())
  let token = self.split_token +
    ((n - self.split_exponent) << (self.msb_in_token + self.lsb_in_token).reinterpret_as_int()) +
    ((m >> (n - self.msb_in_token).reinterpret_as_int()) << self.lsb_in_token.reinterpret_as_int()) +
    (m & self.lsb_mask())
  let nbits = (n - self.msb_in_token - self.lsb_in_token).reinterpret_as_int()
  let bits = (value >> self.lsb_in_token.reinterpret_as_int()) & ((1U << nbits) - 1U)
  (token, nbits, bits)
}

/// Reconstruct a hybrid-uint value from its `token` and the `nbits` raw bits
/// that follow in the stream.
pub fn read_hybrid_uint(config : HybridUintConfig, token : UInt, reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  if token < config.split_token {
    return token
  }
  let split_token = config.split_token.to_uint64()
  let msb = config.msb_in_token.to_uint64()
  let lsb = config.lsb_in_token.to_uint64()
  let split_exponent = config.split_exponent.to_uint64()
  let t = token.to_uint64()
  let nbits = (split_exponent - (msb + lsb) + ((t - split_token) >> (msb + lsb).to_int())) & 31UL
  let low = t & ((1UL << lsb.to_int()) - 1UL)
  let token_shifted = t >> lsb.to_int()
  let bits = reader.read_bits(nbits.to_int()).to_uint64()
  let ret = (((((1UL << msb.to_int()) | (token_shifted & ((1UL << msb.to_int()) - 1UL))) <<
    nbits.to_int()) | bits) << lsb.to_int()) | low
  ret.to_uint()
}

/// Read one hybrid-uint configuration from the stream (`DecodeUintConfig`).
pub fn read_uint_config(reader : @bitio.BitReader, log_alpha_size : UInt) -> HybridUintConfig raise @error.JxlError {
  let split_exponent = reader.read_bits(ceil_log2_nonzero(log_alpha_size + 1U).reinterpret_as_int())
  let mut msb : UInt = 0U
  let mut lsb : UInt = 0U
  if split_exponent != log_alpha_size {
    msb = reader.read_bits(ceil_log2_nonzero(split_exponent + 1U).reinterpret_as_int())
    if msb > split_exponent {
      raise @error.JxlError::InvalidValue("invalid hybrid uint config: msb")
    }
    lsb = reader.read_bits(ceil_log2_nonzero(split_exponent - msb + 1U).reinterpret_as_int())
  }
  if lsb + msb > split_exponent {
    raise @error.JxlError::InvalidValue("invalid hybrid uint config: msb + lsb")
  }
  HybridUintConfig::new(split_exponent, msb, lsb)
}
