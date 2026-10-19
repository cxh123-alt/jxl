///|
/// Image metadata: bit depth, extra channels, animation, and tone mapping.

pub struct BitDepth {
  floating_point : Bool
  bits : UInt
}

pub struct ExtraChannel {
  ec_type : UInt
  bit_depth : BitDepth
  dim_shift : UInt
  name : String
  alpha_associated : Bool
  spot_color : Array[Float]
  cfa_channel : UInt
}

pub struct Animation {
  tps_numerator : UInt
  tps_denominator : UInt
  num_loops : UInt
  have_timecodes : Bool
}

pub struct ToneMapping {
  all_default : Bool
  intensity_target : Float
  min_nits : Float
  relative_to_max_display : Bool
  linear_below : Float
}

pub struct Metadata {
  orientation : UInt
  intrinsic_size : Size
  preview_size : Size
  have_preview : Bool
  animation : Animation
  bit_depth : BitDepth
  modular_16 : Bool
  extra_channels : Array[ExtraChannel]
  xyb_encoded : Bool
  color : ColorEncoding
  tone_mapping : ToneMapping
  extra_fields : Bool
}

/// Extra-channel type enum values (per ISO/IEC 18181-2).
pub const EC_ALPHA : UInt = 0U
pub const EC_DEPTH : UInt = 1U
pub const EC_SPOT : UInt = 2U
pub const EC_SELECTION_MASK : UInt = 3U
pub const EC_BLACK : UInt = 4U
pub const EC_CFA : UInt = 5U
pub const EC_THERMAL : UInt = 6U

fn default_bit_depth() -> BitDepth {
  { floating_point: false, bits: 8U }
}

fn default_animation() -> Animation {
  { tps_numerator: 10U, tps_denominator: 1U, num_loops: 0U, have_timecodes: false }
}

fn default_tone_mapping() -> ToneMapping {
  {
    all_default: true,
    intensity_target: 0.0,
    min_nits: 0.0,
    relative_to_max_display: false,
    linear_below: 0.0,
  }
}

/// The default image metadata (8-bit RGB, no extra channels).
pub fn default_metadata() -> Metadata {
  {
    orientation: 1U,
    intrinsic_size: { width: 0U, height: 0U },
    preview_size: { width: 0U, height: 0U },
    have_preview: false,
    animation: default_animation(),
    bit_depth: default_bit_depth(),
    modular_16: true,
    extra_channels: [],
    xyb_encoded: true,
    color: default_color(),
    tone_mapping: default_tone_mapping(),
    extra_fields: false,
  }
}

/// The U32 distribution for a single extra-channel count.
fn num_extra(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.val(0U),
    @field.val(1U),
    @field.bits_offset(4U, 2U),
    @field.bits_offset(12U, 1U)
  )
}

fn read_bit_depth(reader : @bitio.BitReader) -> BitDepth raise @error.JxlError {
  let floating_point = @field.read_bool(reader)
  let bits = @field.read_u32(
    reader,
    @field.val(8U),
    @field.val(10U),
    @field.val(12U),
    @field.bits_offset(6U, 1U)
  )
  { floating_point: floating_point, bits: bits }
}

/// The U32 distribution for a name length.
fn name_length(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.val(0U),
    @field.bits(4U),
    @field.bits_offset(5U, 16U),
    @field.bits_offset(10U, 48U)
  )
}

/// The U32 distribution for an extra-channel dimension shift.
fn dim_shift(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(reader, @field.val(0U), @field.val(3U), @field.val(4U), @field.bits_offset(3U, 1U))
}

/// The U32 distribution for a CFA (Bayer) channel index.
fn cfa_channel(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(reader, @field.val(1U), @field.bits(2U), @field.bits_offset(4U, 3U), @field.bits_offset(8U, 19U))
}

fn read_name(reader : @bitio.BitReader) -> String raise @error.JxlError {
  let len = name_length(reader).reinterpret_as_int()
  if len == 0 {
    return ""
  }
  let chars : Array[Char] = []
  let mut i = 0
  while i < len {
    let code = @field.read_bits(reader, 8).reinterpret_as_int()
    chars.push(code.unsafe_to_char())
    i = i + 1
  }
  String::from_array(chars)
}

fn read_extra_channel(reader : @bitio.BitReader) -> ExtraChannel raise @error.JxlError {
  if @field.read_bool(reader) {
    return {
      ec_type: 0U,
      bit_depth: default_bit_depth(),
      dim_shift: 0U,
      name: "",
      alpha_associated: false,
      spot_color: [],
      cfa_channel: 1U,
    }
  }
  let ec_type = @field.read_enum(reader)
  let bit_depth = read_bit_depth(reader)
  let dim_shift = dim_shift(reader)
  let name = read_name(reader)
  let alpha_associated = if ec_type == EC_ALPHA {
    @field.read_bool(reader)
  } else {
    false
  }
  let spot_color : Array[Float] = []
  if ec_type == EC_SPOT {
    spot_color.push(@field.read_f16(reader))
    spot_color.push(@field.read_f16(reader))
    spot_color.push(@field.read_f16(reader))
    spot_color.push(@field.read_f16(reader))
  }
  let cfa : UInt = if ec_type == EC_CFA {
    cfa_channel(reader)
  } else {
    1U
  }
  {
    ec_type: ec_type,
    bit_depth: bit_depth,
    dim_shift: dim_shift,
    name: name,
    alpha_associated: alpha_associated,
    spot_color: spot_color,
    cfa_channel: cfa,
  }
}

fn read_animation(reader : @bitio.BitReader) -> Animation raise @error.JxlError {
  if @field.read_bool(reader) {
    return default_animation()
  }
  let tps_numerator = @field.read_u32(
    reader,
    @field.bits(10U),
    @field.bits(12U),
    @field.bits(16U),
    @field.bits(30U)
  )
  let tps_denominator = @field.read_u32(
    reader,
    @field.bits(8U),
    @field.bits(10U),
    @field.bits(12U),
    @field.bits(30U)
  )
  let num_loops = @field.read_u32(
    reader,
    @field.val(0U),
    @field.val(1U),
    @field.bits(8U),
    @field.bits(32U)
  )
  let have_timecodes = @field.read_bool(reader)
  { tps_numerator: tps_numerator, tps_denominator: tps_denominator, num_loops: num_loops, have_timecodes: have_timecodes }
}

fn read_tone_mapping(reader : @bitio.BitReader) -> ToneMapping raise @error.JxlError {
  if @field.read_bool(reader) {
    return default_tone_mapping()
  }
  let intensity_target = @field.read_f16(reader)
  let min_nits = @field.read_f16(reader)
  let relative_to_max_display = @field.read_bool(reader)
  let linear_below = @field.read_f16(reader)
  {
    all_default: false,
    intensity_target: intensity_target,
    min_nits: min_nits,
    relative_to_max_display: relative_to_max_display,
    linear_below: linear_below,
  }
}

/// Read the image metadata bundle.
pub fn read_metadata(reader : @bitio.BitReader) -> Metadata raise @error.JxlError {
  if @field.read_bool(reader) {
    return default_metadata()
  }
  let extra_fields = @field.read_bool(reader)
  let mut orientation : UInt = 1U
  let mut intrinsic_size = { width: 0U, height: 0U }
  let mut preview_size = { width: 0U, height: 0U }
  let mut have_preview = false
  let mut animation = default_animation()
  if extra_fields {
    orientation = @field.read_bits(reader, 3) + 1U
    if @field.read_bool(reader) {
      intrinsic_size = read_size(reader)
    }
    have_preview = @field.read_bool(reader)
    if have_preview {
      preview_size = read_preview_size(reader)
    }
    if @field.read_bool(reader) {
      animation = read_animation(reader)
    }
  }
  let bit_depth = read_bit_depth(reader)
  let modular_16 = @field.read_bool(reader)
  let count = num_extra(reader).reinterpret_as_int()
  let extra_channels : Array[ExtraChannel] = []
  let mut i = 0
  while i < count {
    extra_channels.push(read_extra_channel(reader))
    i = i + 1
  }
  let xyb_encoded = @field.read_bool(reader)
  let color = read_color_encoding(reader)
  let tone_mapping = if extra_fields { read_tone_mapping(reader) } else { default_tone_mapping() }
  // Future extensions: read the extensions U64 (currently always 0) and
  // ignore it. Unknown extension payloads are not yet skipped.
  let _extensions = @field.read_u64(reader)
  {
    orientation: orientation,
    intrinsic_size: intrinsic_size,
    preview_size: preview_size,
    have_preview: have_preview,
    animation: animation,
    bit_depth: bit_depth,
    modular_16: modular_16,
    extra_channels: extra_channels,
    xyb_encoded: xyb_encoded,
    color: color,
    tone_mapping: tone_mapping,
    extra_fields: extra_fields,
  }
}
