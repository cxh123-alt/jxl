///|
/// Frame-header, frame-dimension, and TOC tests build LSB-first bitstreams
/// bit by bit, mirroring the approach in the codestream package's parse tests.

struct BitWriter {
  out : Array[Byte]
  mut acc : UInt
  mut nbits : Int
}

fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0U, nbits: 0 }
}

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

/// A direct (Val) U32 distribution entry: selector only.
fn w_direct(w : BitWriter, sel : Int) -> Unit {
  write_bits(w, sel.reinterpret_as_uint(), 2)
}

fn finish(w : BitWriter) -> Bytes {
  if w.nbits > 0 {
    w.out.push(w.acc.to_byte())
    w.acc = 0U
    w.nbits = 0
  }
  Bytes::from_array(w.out)
}

/// Build a lossless-style metadata (xyb_encoded = false, no extra channels,
/// no animation) and read it back.
fn lossless_metadata() -> @codestream.Metadata raise @error.JxlError {
  let w = BitWriter::new()
  w_bool(w, false) // all_default = 0
  w_bool(w, false) // extra_fields = 0
  w_bool(w, false) // bit depth: integer
  w_direct(w, 0) // bit depth: 8 (Val(8))
  w_bool(w, true) // modular 16-bit
  w_direct(w, 0) // num_extra = 0
  w_bool(w, false) // xyb_encoded = 0
  w_bool(w, true) // color encoding all_default (sRGB)
  write_bits(w, 0U, 2) // extensions U64 = 0
  @codestream.read_metadata(@bitio.BitReader::new(finish(w)))
}

/// Build an 8-bit lossless-style metadata with one alpha channel and read it.
fn alpha_metadata() -> @codestream.Metadata raise @error.JxlError {
  let w = BitWriter::new()
  w_bool(w, false) // all_default = 0
  w_bool(w, true) // extra_fields
  write_bits(w, 1U, 3) // orientation = 2
  w_bool(w, false) // no intrinsic size
  w_bool(w, false) // no preview
  w_bool(w, false) // no animation
  w_bool(w, false) // bit depth: integer
  w_direct(w, 0) // bit depth: 8
  w_bool(w, true) // modular 16-bit
  w_direct(w, 1) // num_extra = 1 (Val(1))
  w_bool(w, false) // extra channel all_default = 0
  w_direct(w, 0) // type = alpha (Val(0))
  w_bool(w, false) // alpha bit depth: integer
  w_direct(w, 0) // alpha bits = 8
  w_direct(w, 0) // dim_shift = 0
  w_direct(w, 0) // name length = 0
  w_bool(w, false) // alpha_associated = 0
  w_bool(w, false) // xyb_encoded = 0
  w_bool(w, true) // color encoding all_default (sRGB)
  w_bool(w, true) // tone mapping all_default
  write_bits(w, 0U, 2) // extensions U64 = 0
  @codestream.read_metadata(@bitio.BitReader::new(finish(w)))
}

/// Write a minimal Modular lossless frame header (21 bits).
fn write_minimal_header(w : BitWriter) -> Unit {
  w_bool(w, false) // all_default = 0
  w_direct(w, 0) // frame_type = regular (Val(0))
  w_bool(w, true) // is_modular = 1
  write_bits(w, 0U, 2) // flags U64 = 0
  w_bool(w, false) // color transform alternate = 0 -> None
  w_direct(w, 0) // upsampling = 1 (Val(1))
  write_bits(w, 1U, 2) // group_size_shift = 1
  w_direct(w, 0) // num_passes = 1 (Val(1))
  w_bool(w, false) // custom_size_or_origin = 0
  w_direct(w, 0) // blend mode = replace (Val(0))
  w_bool(w, true) // is_last = 1
  w_direct(w, 0) // name length = 0
  w_bool(w, true) // loop filter all_default = 1
  write_bits(w, 0U, 2) // frame extensions U64 = 0
}

test "read_frame_header decodes a minimal Modular lossless header" {
  let metadata = lossless_metadata()
  let w = BitWriter::new()
  write_minimal_header(w)
  let reader = @bitio.BitReader::new(finish(w))
  let fh = read_frame_header(reader, metadata, 32U, 32U)
  assert_eq(fh.frame_type, FRAME_REGULAR)
  assert_eq(fh.color_transform, CT_NONE)
  assert_eq(fh.upsampling, 1U)
  assert_eq(fh.group_size_shift, 1U)
  assert_eq(fh.num_passes, 1U)
  assert_true(fh.is_last)
  assert_false(fh.custom_size_or_origin)
  assert_eq(fh.frame_xsize, 0U)
  assert_eq(fh.frame_ysize, 0U)
  assert_eq(fh.dc_level, 0U)
  assert_eq(fh.extra_channel_upsampling.length(), 0)
  // The header is 22 bits for this layout.
  assert_eq(reader.pos(), 22)
}

test "read_frame_header reads extra-channel upsampling for alpha" {
  let metadata = alpha_metadata()
  let w = BitWriter::new()
  w_bool(w, false) // all_default = 0
  w_direct(w, 0) // frame_type = regular
  w_bool(w, true) // is_modular = 1
  write_bits(w, 0U, 2) // flags U64 = 0
  w_bool(w, false) // color transform alternate = 0 -> None
  w_direct(w, 0) // upsampling = 1 (Val(1))
  w_direct(w, 0) // extra channel upsampling = 1 (Val(1), dim_shift 0)
  write_bits(w, 1U, 2) // group_size_shift = 1
  w_direct(w, 0) // num_passes = 1 (Val(1))
  w_bool(w, false) // custom_size_or_origin = 0
  w_direct(w, 0) // color blend mode = replace (Val(0))
  w_direct(w, 0) // alpha blend mode = replace (Val(0))
  w_bool(w, true) // is_last = 1
  w_direct(w, 0) // name length = 0
  w_bool(w, true) // loop filter all_default = 1
  write_bits(w, 0U, 2) // frame extensions U64 = 0
  let reader = @bitio.BitReader::new(finish(w))
  let fh = read_frame_header(reader, metadata, 32U, 32U)
  assert_eq(fh.extra_channel_upsampling.length(), 1)
  assert_eq(fh.extra_channel_upsampling[0], 1U)
  assert_eq(fh.frame_type, FRAME_REGULAR)
  assert_true(fh.is_last)
}

test "read_frame_header rejects a VarDCT frame" {
  let metadata = lossless_metadata()
  let w = BitWriter::new()
  w_bool(w, false) // all_default = 0
  w_direct(w, 0) // frame_type = regular
  w_bool(w, false) // is_modular = 0 (VarDCT)
  let reader = @bitio.BitReader::new(finish(w))
  let outcome = try {
    let _fh = read_frame_header(reader, metadata, 32U, 32U)
    "no-error"
  } catch {
    @error.JxlError::InvalidValue(_) => "invalid"
    _ => "other"
  }
  assert_true(outcome == "invalid")
}

test "frame dimensions are derived from a 32x32 frame" {
  let metadata = lossless_metadata()
  let w = BitWriter::new()
  write_minimal_header(w)
  let reader = @bitio.BitReader::new(finish(w))
  let fh = read_frame_header(reader, metadata, 32U, 32U)
  let dims = from_frame_header(fh, 32U, 32U)
  assert_eq(dims.xsize, 32U)
  assert_eq(dims.ysize, 32U)
  assert_eq(dims.group_dim, 256U)
  assert_eq(dims.xsize_groups, 1U)
  assert_eq(dims.ysize_groups, 1U)
  assert_eq(dims.num_groups, 1U)
}

test "num_toc_entries is 1 for a single group and pass" {
  assert_eq(num_toc_entries(1U, 1U, 1U), 1U)
  assert_eq(num_toc_entries(2U, 1U, 1U), 5U)
  assert_eq(num_toc_entries(1U, 1U, 2U), 5U)
}

test "read_toc reads a single entry and re-aligns" {
  let w = BitWriter::new()
  w_bool(w, false) // permutation = 0
  write_bits(w, 0U, 7) // pad to byte boundary
  w_direct(w, 0) // TOC dist selector 0 (Bits(10))
  write_bits(w, 100U, 10) // size = 100
  let reader = @bitio.BitReader::new(finish(w))
  let sizes = read_toc(reader, 1U)
  assert_eq(sizes.length(), 1)
  assert_eq(sizes[0], 100U)
  assert_eq(reader.pos() % 8, 0)
}

test "read_frame parses a real 8x8 solid lossless codestream" {
  let cs = b"\xff\x0a\x41\x40\x40\x71\x21\x08\x02\x01\x00\xa8\x02\x4b\x18\x9b\x9c\x71\x84\x03\x38\x80\x03\x38\x20\x4a\xc0\x39\x05\x01\x00\x20\x44\x80\x08\x10\x01\x22\x40\xe4\xff\x91\x7b\xfa\x1e\x5a\x67\x57\x55\x55\x55\x25\x49\x92\x10\x50\x77\x77\x77\x77\x77\xff\xff\xff\xbf\x55\x6f\x66\x66\x66\x86\xe7\xbf\xbf\xe7\xff\x0b\x1a\x6b\xae\xb5\xf6\x3e\xf7\x46\x44\x44\x44\x10\x50\x66\x66\x66\x66\x66\x56\x55\xd5\x7d\xef\x77\x77\x77\x77\xc3\xff\xfb\xf7\xfc\xf7\xd0\x98\x73\xce\xb5\xf6\xb9\x37\x49\x92\x84\x80\xaa\xaa\xaa\xaa\xaa\xea\xff\xff\xff\xb9\xf7\x75\x77\x77\x77\xc3\xff\xfb\xf7\xfc\xf7\xd0\x98\x73\xce\xb5\xf6\xb9\x37\x49\x92\x84\x80\xaa\xaa\xaa\xaa\xaa\xea\xff\xff\xff\xb9\xf7\x75\x77\x77\x77\x5f\x20\x04\x00\x0f\x48\x8f\x29\x17\x0a\x80\x2f\x08"
  let f = read_frame(cs)
  assert_eq(f.width, 8U)
  assert_eq(f.height, 8U)
  assert_eq(f.header.frame_type, FRAME_REGULAR)
  assert_eq(f.header.num_passes, 1U)
  assert_eq(f.dims.num_groups, 1U)
  assert_eq(f.section_sizes.length(), 1)
}
