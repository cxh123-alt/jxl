///|
/// Top-level Modular decode: read a single-group, single-pass lossless frame,
/// decode its global modular info, undo the transforms, and emit 8-bit RGBA.
/// Ports `DecodeGlobalInfo` + `FinalizeDecoding` from libjxl's `dec_modular.cc`,
/// restricted to the `ColorTransform::kNone` (direct RGB / grayscale) path.

/// Flat 8-bit RGBA pixel buffer (row-major, `width * height * 4` bytes).
pub struct RgbaImage {
  width : Int
  height : Int
  rgba : Array[Int]
}

/// Full-precision decoded image: RGBA samples at the codestream's native bit
/// depth, before any quantization to 8 bits.
///
/// This is the precision-preserving output of the lossless Modular decode:
/// for a 12-bit image every sample is an integer in `[0, 4095]`, recovered
/// bit-exactly. `RgbaImage` is then a well-defined quantization of this.
pub struct SampleImage {
  width : Int
  height : Int
  /// Bit depth of the color channels (R/G/B).
  bit_depth : Int
  /// Bit depth of the alpha channel (equals `bit_depth` for uniform-depth
  /// images; the alpha channel carries its own bit depth in JPEG XL).
  alpha_bit_depth : Int
  /// Row-major RGBA at native precision: R/G/B in
  /// `[0, (1 << bit_depth) - 1]`, A in `[0, (1 << alpha_bit_depth) - 1]`
  /// (A is `(1 << alpha_bit_depth) - 1` when the image has no alpha).
  rgba : Array[Int]
}

/// The alpha channel's own bit depth, or the image bit depth when absent.
fn alpha_bit_depth(metadata : @codestream.Metadata) -> Int {
  if metadata.extra_channels.length() > 0 {
    metadata.extra_channels[0].bit_depth.bits.reinterpret_as_int()
  } else {
    metadata.bit_depth.bits.reinterpret_as_int()
  }
}

/// The modular image model produced by channel decoding (re-exported so the
/// top-level `decode` API can hand the caller more than just RGBA).
pub struct DecodedModular {
  image : Image
  header : GroupHeader
}

fn is_gray(metadata : @codestream.Metadata) -> Bool {
  metadata.color.color_space == @codestream.COLOR_GRAY
}

/// Number of color channels for a Modular frame (`DecodeGlobalInfo`).
fn nb_color_chans(header : @frame.FrameHeader, metadata : @codestream.Metadata) -> Int {
  if is_gray(metadata) && header.color_transform == @frame.CT_NONE {
    1
  } else {
    3
  }
}

/// Decode the global modular info (`DecodeGlobalInfo`): the global MA tree, its
/// histograms, and every channel at full resolution. Returns the decoded image
/// (transforms still pending) and the group header carrying the
/// weighted-predictor coefficients needed to undo them.
fn decode_global_info(
  reader : @bitio.BitReader,
  header : @frame.FrameHeader,
  metadata : @codestream.Metadata,
  dims : @frame.FrameDimensions
) -> DecodedModular raise @error.JxlError {
  if header.color_transform != @frame.CT_NONE {
    raise @error.JxlError::InvalidValue(
      "unsupported color transform (only direct RGB / grayscale is decoded)"
    )
  }
  let nb_chans = nb_color_chans(header, metadata)
  let nb_extra = metadata.extra_channels.length()
  // The global dequantization matrices (`matrices.DecodeDC`) are read before
  // the modular global info even for Modular frames. Lossless frames always
  // carry the all-default encoding: a single `1` bit.
  if !@field.read_bool(reader) {
    raise @error.JxlError::InvalidValue(
      "non-default global quant matrices are not yet supported"
    )
  }
  let has_tree = @field.read_bool(reader)
  if !has_tree {
    raise @error.JxlError::InvalidValue("modular image without a global MA tree")
  }
  let tree = decode_tree(reader)
  let (code, context_map) = @entropy.decode_histograms(reader, (tree.length() + 1) / 2, false)
  let bitdepth = metadata.bit_depth.bits.reinterpret_as_int()
  let image = Image::new(
    dims.xsize.reinterpret_as_int(),
    dims.ysize.reinterpret_as_int(),
    bitdepth,
    nb_chans + nb_extra
  )
  // Lossless modular has no chroma subsampling and no upsampling, so the
  // color and extra channels stay at full resolution.
  let header2 = modular_decode(
    reader,
    image,
    0,
    dims.group_dim.reinterpret_as_int(),
    tree,
    code,
    context_map
  )
  { image: image, header: header2 }
}

/// Scale a sample in `[0, (1 << bitdepth) - 1]` to 8 bits with rounding.
fn scale_to_8(value : Int, bitdepth : Int) -> Int {
  if bitdepth == 8 {
    return value
  }
  if value <= 0 {
    return 0
  }
  let max = (1 << bitdepth) - 1
  let out = (value * 255 + max / 2) / max
  if out > 255 {
    255
  } else {
    out
  }
}

/// Convert a decoded (transform-undone) image into full-precision RGBA
/// samples at the native bit depth, with no quantization.
fn to_samples(image : Image, header : @frame.FrameHeader, metadata : @codestream.Metadata) -> SampleImage {
  let nb_chans = nb_color_chans(header, metadata)
  let w = image.w
  let h = image.h
  let num_pixels = w * h
  let rgba : Array[Int] = []
  let mut i = 0
  while i < num_pixels * 4 {
    rgba.push(0)
    i = i + 1
  }
  let color_bits = metadata.bit_depth.bits.reinterpret_as_int()
  let alpha_bits = alpha_bit_depth(metadata)
  if nb_chans == 1 {
    // Grayscale: replicate the single color channel into R, G and B.
    let g = image.channel[0].plane
    let mut p = 0
    while p < num_pixels {
      let v = g[p]
      rgba[p * 4] = v
      rgba[p * 4 + 1] = v
      rgba[p * 4 + 2] = v
      p = p + 1
    }
  } else {
    let r = image.channel[0].plane
    let g = image.channel[1].plane
    let b = image.channel[2].plane
    let mut p = 0
    while p < num_pixels {
      rgba[p * 4] = r[p]
      rgba[p * 4 + 1] = g[p]
      rgba[p * 4 + 2] = b[p]
      p = p + 1
    }
  }
  // Alpha: the first extra channel, when present.
  if image.channel.length() > nb_chans {
    let a = image.channel[nb_chans].plane
    let mut p = 0
    while p < num_pixels {
      rgba[p * 4 + 3] = a[p]
      p = p + 1
    }
  } else {
    let full = (1 << alpha_bits) - 1
    let mut p = 0
    while p < num_pixels {
      rgba[p * 4 + 3] = full
      p = p + 1
    }
  }
  { width: w, height: h, bit_depth: color_bits, alpha_bit_depth: alpha_bits, rgba: rgba }
}

/// Quantize full-precision samples down to 8-bit RGBA, using each channel's
/// own bit depth (color vs alpha).
pub fn samples_to_rgba8(s : SampleImage) -> RgbaImage {
  let num_pixels = s.width * s.height
  let rgba : Array[Int] = []
  let mut i = 0
  while i < num_pixels * 4 {
    rgba.push(0)
    i = i + 1
  }
  let mut p = 0
  while p < num_pixels {
    rgba[p * 4] = scale_to_8(s.rgba[p * 4], s.bit_depth)
    rgba[p * 4 + 1] = scale_to_8(s.rgba[p * 4 + 1], s.bit_depth)
    rgba[p * 4 + 2] = scale_to_8(s.rgba[p * 4 + 2], s.bit_depth)
    rgba[p * 4 + 3] = scale_to_8(s.rgba[p * 4 + 3], s.alpha_bit_depth)
    p = p + 1
  }
  { width: s.width, height: s.height, rgba: rgba }
}

/// Decode a single-group, single-pass, lossless Modular codestream into
/// full-precision RGBA samples at the native bit depth. The stream is a naked
/// codestream (no container); wrap a container first if needed.
pub fn decode_codestream_samples(cs : Bytes) -> SampleImage raise @error.JxlError {
  let reader = @bitio.BitReader::new(cs)
  if @field.read_bits(reader, 16) != 0x0AFFU {
    raise @error.JxlError::BadSignature
  }
  let size = @codestream.read_size(reader)
  let metadata = @codestream.read_metadata(reader)
  @codestream.read_transform_data(reader, metadata.xyb_encoded)
  if metadata.color.want_icc {
    raise @error.JxlError::InvalidValue("ICC profiles are not yet supported")
  }
  // The frame header is byte-aligned: skip any remaining header bits.
  reader.align_to_byte()
  let header = @frame.read_frame_header(reader, metadata, size.width, size.height)
  let dims = @frame.from_frame_header(header, size.width, size.height)
  if dims.num_groups != 1U || header.num_passes != 1U {
    raise @error.JxlError::InvalidValue(
      "multi-group / multi-pass frames are not yet supported"
    )
  }
  let toc_entries = @frame.num_toc_entries(dims.num_groups, dims.num_dc_groups, header.num_passes)
  let _section_sizes = @frame.read_toc(reader, toc_entries)
  // The single TOC entry covers dc_global + ac_global + dc_group + ac_group,
  // read sequentially from one reader positioned at the section data.
  let decoded = decode_global_info(reader, header, metadata, dims)
  undo_transforms(decoded.image, decoded.header.wp_header)
  to_samples(decoded.image, header, metadata)
}

/// Decode a single-group, single-pass, lossless Modular codestream into 8-bit
/// RGBA. This is `samples_to_rgba8(decode_codestream_samples(cs))`: the
/// full-precision reconstruction quantized to 8 bits.
pub fn decode_codestream(cs : Bytes) -> RgbaImage raise @error.JxlError {
  samples_to_rgba8(decode_codestream_samples(cs))
}
