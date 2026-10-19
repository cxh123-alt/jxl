///|
/// A forward-only, least-significant-bit-first bit reader over a byte buffer.
///
/// JPEG XL stores bit fields with the least-significant bit first — the
/// opposite of the big-endian convention used by, say, FLAC. The reader keeps
/// a 64-bit window into the stream and is mutated in place: every read
/// advances the cursor by exactly the number of bits consumed.

pub struct BitReader {
  data : Bytes
  mut buf : UInt64
  mut bits_in_buf : Int
  mut next_byte : Int
}

/// Wrap a byte buffer for LSB-first bit reading.
pub fn BitReader::new(data : Bytes) -> BitReader {
  { data: data, buf: 0UL, bits_in_buf: 0, next_byte: 0 }
}

/// The number of bits consumed so far.
pub fn BitReader::pos(self : BitReader) -> Int {
  self.next_byte * 8 - self.bits_in_buf
}

/// The number of bits still available (unconsumed bytes plus the window).
pub fn BitReader::remaining(self : BitReader) -> Int {
  (self.data.length() - self.next_byte) * 8 + self.bits_in_buf
}

/// True when at least `n` more bits are available.
pub fn BitReader::has(self : BitReader, n : Int) -> Bool {
  self.remaining() >= n
}

/// The underlying source buffer.
pub fn BitReader::data(self : BitReader) -> Bytes {
  self.data
}

/// Pull more bytes into the window while there is room (up to 64 bits).
fn BitReader::refill(self : BitReader) -> Unit {
  while self.bits_in_buf <= 56 && self.next_byte < self.data.length() {
    let byte = self.data[self.next_byte].to_uint64()
    self.buf = self.buf | (byte << self.bits_in_buf)
    self.bits_in_buf = self.bits_in_buf + 8
    self.next_byte = self.next_byte + 1
  }
}

/// Read `n` bits (`0 <= n <= 32`) as an unsigned integer, LSB first.
pub fn BitReader::read_bits(self : BitReader, n : Int) -> UInt raise @error.JxlError {
  if n < 0 || n > 32 {
    raise @error.JxlError::InvalidBitCount(n)
  }
  if n == 0 {
    return 0U
  }
  self.refill()
  if self.bits_in_buf < n {
    raise @error.JxlError::Truncated
  }
  let mask : UInt64 = (1UL << n) - 1UL
  let value = (self.buf & mask).to_uint()
  self.buf = self.buf >> n
  self.bits_in_buf = self.bits_in_buf - n
  value
}

/// Read `n` bits (`0 <= n <= 56`) as an unsigned 64-bit integer, LSB first.
pub fn BitReader::read_bits_u64(self : BitReader, n : Int) -> UInt64 raise @error.JxlError {
  if n < 0 || n > 56 {
    raise @error.JxlError::InvalidBitCount(n)
  }
  if n == 0 {
    return 0UL
  }
  self.refill()
  if self.bits_in_buf < n {
    raise @error.JxlError::Truncated
  }
  let mask : UInt64 = (1UL << n) - 1UL
  let value = self.buf & mask
  self.buf = self.buf >> n
  self.bits_in_buf = self.bits_in_buf - n
  value
}

/// Read a single bit as `0` or `1`.
pub fn BitReader::read_bit(self : BitReader) -> Int raise @error.JxlError {
  self.read_bits(1).reinterpret_as_int()
}

/// Peek at the next `n` bits (`0 <= n <= 32`) without advancing the cursor.
/// A later `consume` (or `read_bits`) advances past them.
pub fn BitReader::peek_bits(self : BitReader, n : Int) -> UInt raise @error.JxlError {
  if n < 0 || n > 32 {
    raise @error.JxlError::InvalidBitCount(n)
  }
  if n == 0 {
    return 0U
  }
  self.refill()
  if self.bits_in_buf < n {
    raise @error.JxlError::Truncated
  }
  let mask : UInt64 = (1UL << n) - 1UL
  (self.buf & mask).to_uint()
}

/// Advance the cursor by `n` bits that are already in the window (for example
/// after a `peek_bits`).
pub fn BitReader::consume(self : BitReader, n : Int) -> Unit raise @error.JxlError {
  if n < 0 {
    raise @error.JxlError::InvalidBitCount(n)
  }
  if n > self.bits_in_buf {
    raise @error.JxlError::Truncated
  }
  self.buf = self.buf >> n
  self.bits_in_buf = self.bits_in_buf - n
}

/// Skip `n` bits without reading them.
pub fn BitReader::skip(self : BitReader, n : Int) -> Unit raise @error.JxlError {
  if n < 0 {
    raise @error.JxlError::InvalidBitCount(n)
  }
  if self.remaining() < n {
    raise @error.JxlError::Truncated
  }
  let mut left = n
  // Drop buffered bits first.
  let from_buf = if left < self.bits_in_buf { left } else { self.bits_in_buf }
  self.buf = self.buf >> from_buf
  self.bits_in_buf = self.bits_in_buf - from_buf
  left = left - from_buf
  // Drop whole bytes without touching the window.
  self.next_byte = self.next_byte + left / 8
  left = left % 8
  // Drop the final few bits from the refilled window.
  self.refill()
  self.buf = self.buf >> left
  self.bits_in_buf = self.bits_in_buf - left
}

/// Advance to the next byte boundary (a no-op when already aligned).
pub fn BitReader::align_to_byte(self : BitReader) -> Unit raise @error.JxlError {
  let rem = self.pos() % 8
  if rem != 0 {
    self.skip(8 - rem)
  }
}
