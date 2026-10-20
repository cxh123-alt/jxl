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

/// Convert a decoded (transform-undone) image into 8-bit RGBA.
fn to_rgba(image : Image, header : @frame.FrameHeader, metadata : @codestream.Metadata) -> RgbaImage {
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
  if nb_chans == 1 {
    // Grayscale: replicate the single color channel into R, G and B.
    let g = image.channel[0].plane
    let mut p = 0
    while p < num_pixels {
      let v = scale_to_8(g[p], color_bits)
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
      rgba[p * 4] = scale_to_8(r[p], color_bits)
      rgba[p * 4 + 1] = scale_to_8(g[p], color_bits)
      rgba[p * 4 + 2] = scale_to_8(b[p], color_bits)
      p = p + 1
    }
  }
  // Alpha: the first extra channel, when present.
  if image.channel.length() > nb_chans {
    let a = image.channel[nb_chans].plane
    let mut p = 0
    while p < num_pixels {
      rgba[p * 4 + 3] = scale_to_8(a[p], color_bits)
      p = p + 1
    }
  } else {
    let mut p = 0
    while p < num_pixels {
      rgba[p * 4 + 3] = 255
      p = p + 1
    }
  }
  { width: w, height: h, rgba: rgba }
}

/// Decode a single-group, single-pass, lossless Modular codestream into 8-bit
/// RGBA. The stream is a naked codestream (no container); wrap a container
/// first if needed.
pub fn decode_codestream(cs : Bytes) -> RgbaImage raise @error.JxlError {
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
  to_rgba(decoded.image, header, metadata)
}
