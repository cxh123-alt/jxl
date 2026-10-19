///|
/// `BitReader` reads LSB-first, so the byte `0x05` yields `1, 0, 1, 0, ...`
/// and a whole byte round-trips back to the same value.

test "read_bits of a whole byte returns the byte value" {
  let r = BitReader::new(b"\x8B")
  assert_true(r.read_bits(8) == 0x8BU)
}

test "read_bit yields the least-significant bits first" {
  // 0x05 = 0b0000_0101: LSB-first gives 1, 0, 1, then zeros.
  let r = BitReader::new(b"\x05")
  assert_true(r.read_bit() == 1)
  assert_true(r.read_bit() == 0)
  assert_true(r.read_bit() == 1)
  assert_true(r.read_bits(5) == 0U)
}

test "reads span byte boundaries" {
  // 0x01 0x02: 9 bits LSB-first = 1, then the top 7 bits of the remainder.
  let r = BitReader::new(b"\x01\x02")
  assert_true(r.read_bits(9) == 1U)
  assert_true(r.read_bits(7) == 1U)
}

test "read_bits_u64 spans several bytes" {
  let r = BitReader::new(b"\xEF\xCD\xAB\x90\x78\x56\x34\x12")
  assert_true(r.read_bits_u64(56) == 0x3456_7890_ABCDEFUL)
}

test "read_bits rejects widths outside 0..32" {
  let r = BitReader::new(b"\x00")
  let outcome = try {
    let _ = r.read_bits(33)
    "no-error"
  } catch {
    @error.JxlError::InvalidBitCount(_) => "bad-count"
    _ => "other"
  }
  assert_true(outcome == "bad-count")
}

test "reading past the end raises Truncated" {
  let r = BitReader::new(b"\x00")
  let outcome = try {
    let _ = r.read_bits(9)
    "no-error"
  } catch {
    @error.JxlError::Truncated => "truncated"
    _ => "other"
  }
  assert_true(outcome == "truncated")
}

test "skip advances the cursor and preserves alignment" {
  let r = BitReader::new(b"\x01\x02")
  r.skip(9)
  assert_true(r.pos() == 9)
  assert_true(r.read_bits(7) == 1U)
}

test "align_to_byte pads to the next byte boundary" {
  let r = BitReader::new(b"\x00\xFF")
  r.skip(3)
  r.align_to_byte()
  assert_true(r.pos() == 8)
  assert_true(r.read_bits(8) == 0xFFU)
}
