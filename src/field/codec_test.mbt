///|
/// Field-codec tests use hand-computed LSB-first bit streams.

test "val encodes a direct value" {
  assert_true(val(8U) == 0x8000_0008U)
}

test "bits and bits_offset pack extra-bits and offset" {
  assert_true(bits(4U) == 3U)
  assert_true(bits_offset(4U, 2U) == 67U)
}

test "read_u32 selects the direct distribution" {
  // selector 00 -> d0 = Val(7): value 7, no extra bits.
  let r = @bitio.BitReader::new(b"\x00")
  assert_true(read_u32(r, val(7U), val(1U), bits_offset(4U, 2U), bits_offset(6U, 18U)) == 7U)
}

test "read_u32 reads offset distribution extra bits" {
  // selector 00 -> bits_offset(4, 2): 4 extra bits + offset 2.
  // byte 0x28: bits 2..5 = 0,1,0,1 LSB-first = 10 -> value 10 + 2 = 12.
  let r = @bitio.BitReader::new(b"\x28")
  assert_true(read_u32(r, bits_offset(4U, 2U), val(1U), val(2U), val(3U)) == 12U)
}

test "read_enum decodes a small value directly" {
  // selector 00 -> Val(0).
  let r = @bitio.BitReader::new(b"\x00")
  assert_true(read_enum(r) == 0U)
}

test "read_u64 decodes each selector form" {
  // selector 00 -> 0.
  let r0 = @bitio.BitReader::new(b"\x00")
  assert_true(read_u64(r0) == 0UL)
  // selector 01 -> 1 + 4 bits (0b1001 = 9) -> 10.
  let r1 = @bitio.BitReader::new(b"\x25")
  assert_true(read_u64(r1) == 10UL)
  // selector 10 -> 17 + 8 bits (0b0000_0010 = 2) -> 19.
  let r2 = @bitio.BitReader::new(b"\x0A\x00")
  assert_true(read_u64(r2) == 19UL)
}

test "read_u64 decodes the varint form" {
  // selector 11, 12 low bits = 0, continuation 1, then 8 bits = 1 at shift 12.
  let r = @bitio.BitReader::new(b"\x03\xC0\x00")
  assert_true(read_u64(r) == 0x1000UL)
}

test "read_f16 decodes 1.0" {
  // binary16 1.0 = 0x3C00 -> binary32 1.0 = 0x3F80_0000.
  let r = @bitio.BitReader::new(b"\x00\x3C")
  let f = read_f16(r)
  assert_true(f.reinterpret_as_uint() == 0x3F80_0000U)
}
