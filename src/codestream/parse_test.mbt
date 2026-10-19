///|
/// Header-parsing tests build LSB-first codestreams bit by bit.

struct BitWriter {
  out : Array[Byte]
  mut acc : UInt
  mut nbits : Int
}

fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0U, nbits: 0 }
}

/// Append the low `n` bits of `value`, least-significant bit first.
fn write_bits(w : BitWriter, value : UInt, n : Int) -> Unit {
  let mut v = value
  let mut left = n
  while left > 0 {
    w.acc = w.acc | ((v & 1U) << w.nbits)
    v = v >> 1
    w.nbits = w.nbits + 1
    left = left - 1
    if w.nbits == 8 {
      w.out.push(w.acc.to_byte())
      w.acc = 0U
      w.nbits = 0
    }
  }
}

fn w_bool(w : BitWriter, b : Bool) -> Unit {
  write_bits(w, if b { 1U } else { 0U }, 1)
}

/// A direct U32 distribution entry: selector only (no extra bits).
fn w_direct(w : BitWriter, sel : Int) -> Unit {
  write_bits(w, sel.reinterpret_as_uint(), 2)
}

/// An offset U32 distribution entry: selector + `extra` bits of `value-offset`.
fn w_u32(w : BitWriter, sel : Int, offset : UInt, extra : Int, value : UInt) -> Unit {
  write_bits(w, sel.reinterpret_as_uint(), 2)
  write_bits(w, value - offset, extra)
}

fn finish(w : BitWriter) -> Bytes {
  if w.nbits > 0 {
    w.out.push(w.acc.to_byte())
    w.acc = 0U
    w.nbits = 0
  }
  Bytes::from_array(w.out)
}

test "parse decodes a minimal 32x32 codestream" {
  let h = parse(b"\xFF\x0A\x47\x02")
  assert_true(h.width == 32U)
  assert_true(h.height == 32U)
  assert_true(h.metadata.bit_depth.bits == 8U)
  assert_true(h.metadata.color.color_space == COLOR_RGB)
  assert_true(h.metadata.extra_channels.length() == 0)
}

test "parse decodes a non-small 4:3 size" {
  let w = BitWriter::new()
  write_bits(w, 0x0AFFU, 16) // signature (bytes FF 0A in file order)
  w_bool(w, false) // small = 0
  w_u32(w, 1, 1U, 13, 600U) // ysize = 600 via BitsOffset(13, 1)
  write_bits(w, 3U, 3) // ratio = 3 (4:3)
  w_bool(w, true) // metadata all_default
  let h = parse(finish(w))
  assert_true(h.width == 800U)
  assert_true(h.height == 600U)
}

test "parse decodes 16-bit with an alpha channel and orientation" {
  let w = BitWriter::new()
  // Size header: 64x64, small (divisible by 8), square ratio.
  write_bits(w, 0x0AFFU, 16)
  w_bool(w, true) // small
  write_bits(w, 7U, 5) // ydiv = 64/8 - 1
  write_bits(w, 1U, 3) // ratio = 1 (square)
  // Metadata: non-default, with extra fields.
  w_bool(w, false) // all_default = 0
  w_bool(w, true) // extra_fields
  write_bits(w, 1U, 3) // orientation = 2 (encoded as 2 - 1)
  w_bool(w, false) // no intrinsic size
  w_bool(w, false) // no preview
  w_bool(w, false) // no animation
  // Bit depth: 16-bit integer (BitsOffset(6, 1), selector 3).
  w_bool(w, false) // floating_point = 0
  w_u32(w, 3, 1U, 6, 16U)
  w_bool(w, true) // modular 16-bit
  // One extra channel.
  w_direct(w, 1) // num_extra = 1 (Val(1), selector 1)
  w_bool(w, false) // extra channel all_default = 0
  w_direct(w, 0) // type = alpha (kAlpha = 0, Val(0), selector 0)
  w_bool(w, false) // alpha bit depth: integer
  w_direct(w, 0) // alpha bits = 8 (Val(8), selector 0)
  w_direct(w, 0) // dim_shift = 0 (Val(0), selector 0)
  w_direct(w, 0) // name length = 0 (Val(0), selector 0)
  w_bool(w, false) // alpha_associated = 0
  w_bool(w, false) // xyb_encoded = 0
  w_bool(w, true) // color encoding all_default (sRGB)
  w_bool(w, true) // tone mapping all_default
  write_bits(w, 0U, 2) // extensions U64 = 0 (selector 0)

  let h = parse(finish(w))
  assert_true(h.width == 64U)
  assert_true(h.height == 64U)
  assert_true(h.metadata.orientation == 2U)
  assert_true(h.metadata.bit_depth.bits == 16U)
  assert_true(h.metadata.extra_channels.length() == 1)
  let ec = h.metadata.extra_channels[0]
  assert_true(ec.ec_type == EC_ALPHA)
  assert_true(ec.bit_depth.bits == 8U)
  assert_true(ec.alpha_associated == false)
  assert_true(h.metadata.xyb_encoded == false)
}
