///|
/// Frame header: the per-frame bundle that immediately follows the image
/// metadata. This is the `FrameHeader::VisitFields` read order from libjxl's
/// `frame_header.cc`, restricted to the Modular (lossless) branch.
///
/// A VarDCT frame, or a Modular frame that requires noise / patches / splines /
/// a DC frame, is rejected with `InvalidValue` because those decoders are out
/// of scope. Every field is still read in wire order, so that after a Modular
/// header the reader is positioned exactly at the start of the TOC.

pub const FRAME_REGULAR : UInt = 0U
pub const FRAME_DC : UInt = 1U
pub const FRAME_REFERENCE_ONLY : UInt = 2U
pub const FRAME_SKIP_PROGRESSIVE : UInt = 3U

/// Frame-level color transform (not to be confused with the color *space*
/// enums in the codestream package).
pub const CT_XYB : UInt = 0U
pub const CT_NONE : UInt = 1U
pub const CT_YCBCR : UInt = 2U

/// Frame flags requiring decoders that are out of scope: noise, patches,
/// splines, and the DC frame.
const UNSUPPORTED_FLAGS : UInt64 = (1UL | 2UL | 16UL | 32UL)

pub struct FrameHeader {
  frame_type : UInt
  flags : UInt64
  color_transform : UInt
  group_size_shift : UInt
  upsampling : UInt
  extra_channel_upsampling : Array[UInt]
  num_passes : UInt
  custom_size_or_origin : Bool
  frame_x0 : Int
  frame_y0 : Int
  frame_xsize : UInt
  frame_ysize : UInt
  is_last : Bool
  dc_level : UInt
}

/// Unpack a PackSigned value back to its signed 32-bit value.
fn unpack_signed(v : UInt) -> Int {
  if v % 2U == 0U {
    (v / 2U).reinterpret_as_int()
  } else {
    0 - ((v + 1U) / 2U).reinterpret_as_int()
  }
}

/// The U32 distribution for a frame origin / size field.
fn frame_size_u32(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.bits(8U),
    @field.bits_offset(11U, 256U),
    @field.bits_offset(14U, 2304U),
    @field.bits_offset(30U, 18688U)
  )
}

/// Read one `BlendingInfo` bundle (color or extra-channel), discarding its
/// values: blending is out of scope for lossless single-frame decode.
fn read_blending_info(
  reader : @bitio.BitReader,
  num_extra_channels : Int,
  is_partial : Bool
) -> Unit raise @error.JxlError {
  let mode = @field.read_u32(
    reader,
    @field.val(0U),
    @field.val(1U),
    @field.val(2U),
    @field.bits_offset(2U, 3U)
  )
  if num_extra_channels > 0 && (mode == 2U || mode == 3U) {
    let _alpha = @field.read_u32(
      reader,
      @field.val(0U),
      @field.val(1U),
      @field.val(2U),
      @field.bits_offset(3U, 3U)
    )
  }
  if (num_extra_channels > 0 && (mode == 2U || mode == 3U)) || mode == 4U {
    let _clamp = @field.read_bool(reader)
  }
  if mode != 0U || is_partial {
    let _source = @field.read_u32(
      reader,
      @field.val(0U),
      @field.val(1U),
      @field.val(2U),
      @field.val(3U)
    )
  }
}

/// Read the loop-filter bundle (always modular here), discarding its values.
fn read_loop_filter(reader : @bitio.BitReader) -> Unit raise @error.JxlError {
  let all_default = @field.read_bool(reader)
  if all_default {
    return
  }
  let gab = @field.read_bool(reader)
  if gab {
    let gab_custom = @field.read_bool(reader)
    if gab_custom {
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
    }
  }
  let epf_iters = @field.read_bits(reader, 2)
  if epf_iters > 0U {
    // epf_sharp_custom is only read for non-modular frames.
    let epf_weight_custom = @field.read_bool(reader)
    if epf_weight_custom {
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
    }
    let epf_sigma_custom = @field.read_bool(reader)
    if epf_sigma_custom {
      // epf_quant_mul is only read for non-modular frames.
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
      let _ = @field.read_f16(reader)
    }
    // epf_sigma_for_modular is always present for modular frames.
    let _ = @field.read_f16(reader)
  }
  let _extensions = @field.read_u64(reader)
}

/// Read the frame header after the image metadata.
///
/// `image_xsize` / `image_ysize` are the decoded image dimensions from the
/// size header (used as the default frame size and for partial-frame checks).
pub fn read_frame_header(
  reader : @bitio.BitReader,
  metadata : @codestream.Metadata,
  image_xsize : UInt,
  image_ysize : UInt
) -> FrameHeader raise @error.JxlError {
  let all_default = @field.read_bool(reader)
  if all_default {
    // Default frame: Modular, regular, single-pass, full-size, last frame,
    // XYB color transform (the bundle default).
    return {
      frame_type: FRAME_REGULAR,
      flags: 0UL,
      color_transform: CT_XYB,
      group_size_shift: 1U,
      upsampling: 1U,
      extra_channel_upsampling: [],
      num_passes: 1U,
      custom_size_or_origin: false,
      frame_x0: 0,
      frame_y0: 0,
      frame_xsize: 0U,
      frame_ysize: 0U,
      is_last: true,
      dc_level: 0U,
    }
  }

  let frame_type = @field.read_u32(
    reader,
    @field.val(0U),
    @field.val(1U),
    @field.val(2U),
    @field.val(3U)
  )

  // Frame encoding: a 0 bit selects VarDCT, a 1 bit selects Modular.
  let modular = @field.read_bool(reader)
  if !modular {
    raise @error.JxlError::InvalidValue("unsupported VarDCT frame")
  }

  // Flags.
  let flags = @field.read_u64(reader)
  if (flags & UNSUPPORTED_FLAGS) != 0UL {
    raise @error.JxlError::InvalidValue(
      "unsupported frame flags (noise/patches/splines/DC frame)"
    )
  }

  // Color transform.
  let mut color_transform : UInt = CT_XYB
  if !metadata.xyb_encoded {
    let alternate = @field.read_bool(reader)
    color_transform = if alternate { CT_YCBCR } else { CT_NONE }
  }

  // Chroma subsampling for YCbCr (no DC frame: flags & kUseDcFrame == 0).
  if color_transform == CT_YCBCR {
    let _c0 = @field.read_bits(reader, 2)
    let _c1 = @field.read_bits(reader, 2)
    let _c2 = @field.read_bits(reader, 2)
  }

  // Upsampling (no DC frame, so always present).
  let upsampling = @field.read_u32(
    reader,
    @field.val(1U),
    @field.val(2U),
    @field.val(4U),
    @field.val(8U)
  )
  let extra_channel_upsampling : Array[UInt] = []
  let num_extra = metadata.extra_channels.length()
  if num_extra != 0 {
    let mut i = 0
    while i < num_extra {
      let dim_shift = metadata.extra_channels[i].dim_shift
      let ec = @field.read_u32(
        reader,
        @field.val(1U),
        @field.val(2U),
        @field.val(4U),
        @field.val(8U)
      ) << dim_shift.reinterpret_as_int()
      extra_channel_upsampling.push(ec)
      i = i + 1
    }
  }

  // Group size shift (Modular only).
  let group_size_shift = @field.read_bits(reader, 2)

  // Passes (skipped for reference-only frames).
  let mut num_passes : UInt = 1U
  if frame_type != FRAME_REFERENCE_ONLY {
    num_passes = @field.read_u32(
      reader,
      @field.val(1U),
      @field.val(2U),
      @field.val(3U),
      @field.bits_offset(3U, 4U)
    )
    if num_passes != 1U {
      let num_downsample = @field.read_u32(
        reader,
        @field.val(0U),
        @field.val(1U),
        @field.val(2U),
        @field.bits_offset(1U, 3U)
      )
      let mut i : UInt = 0U
      while i < num_passes - 1U {
        let _shift = @field.read_bits(reader, 2)
        i = i + 1U
      }
      let mut j : UInt = 0U
      while j < num_downsample {
        let _downsample = @field.read_u32(
          reader,
          @field.val(1U),
          @field.val(2U),
          @field.val(4U),
          @field.val(8U)
        )
        j = j + 1U
      }
      let mut k : UInt = 0U
      while k < num_downsample {
        let _last_pass = @field.read_u32(
          reader,
          @field.val(0U),
          @field.val(1U),
          @field.val(2U),
          @field.bits(3U)
        )
        k = k + 1U
      }
    }
  }

  // DC level.
  let mut dc_level : UInt = 0U
  if frame_type == FRAME_DC {
    dc_level = @field.read_u32(
      reader,
      @field.val(1U),
      @field.val(2U),
      @field.val(3U),
      @field.val(4U)
    )
  }

  // Custom size / origin.
  let mut custom_size_or_origin = false
  let mut frame_x0 : Int = 0
  let mut frame_y0 : Int = 0
  let mut frame_xsize : UInt = 0U
  let mut frame_ysize : UInt = 0U
  let mut is_partial = false
  if frame_type != FRAME_DC {
    custom_size_or_origin = @field.read_bool(reader)
    if custom_size_or_origin {
      let regular_or_skip =
        frame_type == FRAME_REGULAR || frame_type == FRAME_SKIP_PROGRESSIVE
      if regular_or_skip {
        frame_x0 = unpack_signed(frame_size_u32(reader))
        frame_y0 = unpack_signed(frame_size_u32(reader))
      }
      frame_xsize = frame_size_u32(reader)
      frame_ysize = frame_size_u32(reader)
      if frame_xsize == 0U || frame_ysize == 0U {
        raise @error.JxlError::InvalidValue("invalid crop dimensions: zero width or height")
      }
      if regular_or_skip {
        is_partial = frame_x0 > 0 || frame_y0 > 0 ||
          (frame_xsize.reinterpret_as_int() + frame_x0) < image_xsize.reinterpret_as_int() ||
          (frame_ysize.reinterpret_as_int() + frame_y0) < image_ysize.reinterpret_as_int()
      }
    }
  }

  // Blending info, animation info, and whether this is the last frame.
  let mut is_last = false
  let mut duration : UInt = 0U
  let mut save_as_reference : UInt = 0U
  let regular_or_skip =
    frame_type == FRAME_REGULAR || frame_type == FRAME_SKIP_PROGRESSIVE
  if regular_or_skip {
    read_blending_info(reader, num_extra, is_partial)
    // Extra-channel blending info, one bundle per extra channel.
    let mut e = 0
    while e < num_extra {
      read_blending_info(reader, num_extra, is_partial)
      e = e + 1
    }
    if metadata.have_animation {
      duration = @field.read_u32(
        reader,
        @field.val(0U),
        @field.val(1U),
        @field.bits(8U),
        @field.bits(32U)
      )
      if metadata.animation.have_timecodes {
        let _timecode = @field.read_bits(reader, 32)
      }
    }
    is_last = @field.read_bool(reader)
  }

  // Reference id (not for DC frames, not for the last frame).
  if frame_type != FRAME_DC && !is_last {
    save_as_reference = @field.read_u32(
      reader,
      @field.val(0U),
      @field.val(1U),
      @field.val(2U),
      @field.val(3U)
    )
  }

  // Save-before-color-transform.
  if frame_type != FRAME_DC {
    let can_be_referenced = !is_last && frame_type != FRAME_DC &&
      (duration == 0U || save_as_reference != 0U)
    let replace_and_full = can_be_referenced && !is_partial &&
      regular_or_skip
    if replace_and_full {
      let _save_before = @field.read_bool(reader)
    } else if frame_type == FRAME_REFERENCE_ONLY {
      let _save_before = @field.read_bool(reader)
    }
  }

  // Frame name.
  let name_len = @field.read_u32(
    reader,
    @field.val(0U),
    @field.bits(4U),
    @field.bits_offset(5U, 16U),
    @field.bits_offset(10U, 48U)
  ).reinterpret_as_int()
  let mut n = 0
  while n < name_len {
    let _c = @field.read_bits(reader, 8)
    n = n + 1
  }

  // Loop filter, then the frame header's own extension field.
  read_loop_filter(reader)
  let _extensions = @field.read_u64(reader)

  {
    frame_type: frame_type,
    flags: flags,
    color_transform: color_transform,
    group_size_shift: group_size_shift,
    upsampling: upsampling,
    extra_channel_upsampling: extra_channel_upsampling,
    num_passes: num_passes,
    custom_size_or_origin: custom_size_or_origin,
    frame_x0: frame_x0,
    frame_y0: frame_y0,
    frame_xsize: frame_xsize,
    frame_ysize: frame_ysize,
    is_last: is_last,
    dc_level: dc_level,
  }
}
