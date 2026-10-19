///|
/// Color encoding: color space, white point, primaries, and transfer function.

/// Color-space enum values (non-contiguous, per ISO/IEC 18181-2).
pub const COLOR_RGB : UInt = 0U
pub const COLOR_GRAY : UInt = 1U
pub const COLOR_XYB : UInt = 2U
pub const COLOR_UNKNOWN : UInt = 3U

/// White-point enum values.
pub const WHITE_D65 : UInt = 1U
pub const WHITE_CUSTOM : UInt = 2U
pub const WHITE_E : UInt = 10U
pub const WHITE_DCI : UInt = 11U

/// Primaries enum values.
pub const PRIMARIES_SRGB : UInt = 1U
pub const PRIMARIES_CUSTOM : UInt = 2U
pub const PRIMARIES_2100 : UInt = 9U
pub const PRIMARIES_P3 : UInt = 11U

/// Transfer-function enum values.
pub const TRANSFER_709 : UInt = 1U
pub const TRANSFER_UNKNOWN : UInt = 2U
pub const TRANSFER_LINEAR : UInt = 8U
pub const TRANSFER_SRGB : UInt = 13U
pub const TRANSFER_PQ : UInt = 16U
pub const TRANSFER_DCI : UInt = 17U
pub const TRANSFER_HLG : UInt = 18U

/// Rendering-intent enum values.
pub const INTENT_PERCEPTUAL : UInt = 0U
pub const INTENT_RELATIVE : UInt = 1U
pub const INTENT_SATURATION : UInt = 2U
pub const INTENT_ABSOLUTE : UInt = 3U

/// The gamma value `round(1/3 * 1e7)` used implicitly by XYB.
const IMPLICIT_XYB_GAMMA : UInt = 3333333U

/// A human-readable name for a color-space enum value.
pub fn color_space_name(cs : UInt) -> String {
  if cs == COLOR_RGB {
    "RGB"
  } else if cs == COLOR_GRAY {
    "grayscale"
  } else if cs == COLOR_XYB {
    "XYB"
  } else {
    "unknown"
  }
}

/// A CIE xy chromaticity coordinate (the luminance Y is implicit).
pub struct CIExy {
  x : Double
  y : Double
}

pub struct ColorEncoding {
  want_icc : Bool
  color_space : UInt
  white_point : UInt
  white_xy : CIExy
  primaries : UInt
  red_xy : CIExy
  green_xy : CIExy
  blue_xy : CIExy
  have_gamma : Bool
  gamma : UInt
  transfer_function : UInt
  rendering_intent : UInt
}

fn zero_xy() -> CIExy {
  { x: 0.0, y: 0.0 }
}

/// The default color encoding: sRGB, D65 white point, relative intent.
pub fn default_color() -> ColorEncoding {
  {
    want_icc: false,
    color_space: COLOR_RGB,
    white_point: WHITE_D65,
    white_xy: zero_xy(),
    primaries: PRIMARIES_SRGB,
    red_xy: zero_xy(),
    green_xy: zero_xy(),
    blue_xy: zero_xy(),
    have_gamma: false,
    gamma: 0U,
    transfer_function: TRANSFER_SRGB,
    rendering_intent: INTENT_RELATIVE,
  }
}

/// Unpack a PackSigned value back to its signed 32-bit value.
fn unpack_signed(v : UInt) -> Int {
  if v % 2U == 0U {
    (v / 2U).reinterpret_as_int()
  } else {
    0 - ((v + 1U) / 2U).reinterpret_as_int()
  }
}

fn read_custom_xy(reader : @bitio.BitReader) -> CIExy raise @error.JxlError {
  let ux = @field.read_u32(
    reader,
    @field.bits(19U),
    @field.bits_offset(19U, 524288U),
    @field.bits_offset(20U, 1048576U),
    @field.bits_offset(21U, 2097152U)
  )
  let uy = @field.read_u32(
    reader,
    @field.bits(19U),
    @field.bits_offset(19U, 524288U),
    @field.bits_offset(20U, 1048576U),
    @field.bits_offset(21U, 2097152U)
  )
  let x = unpack_signed(ux).to_double() * (1.0 / 1000000.0)
  let y = unpack_signed(uy).to_double() * (1.0 / 1000000.0)
  { x: x, y: y }
}

/// Read a `ColorEncoding` bundle.
pub fn read_color_encoding(reader : @bitio.BitReader) -> ColorEncoding raise @error.JxlError {
  if @field.read_bool(reader) {
    return default_color()
  }
  let want_icc = @field.read_bool(reader)
  let color_space = @field.read_enum(reader)
  if want_icc {
    // The ICC profile bytes are carried out-of-band; the direct fields are
    // not serialized when an ICC profile is present.
    return {
      want_icc: true,
      color_space: color_space,
      white_point: WHITE_D65,
      white_xy: zero_xy(),
      primaries: PRIMARIES_SRGB,
      red_xy: zero_xy(),
      green_xy: zero_xy(),
      blue_xy: zero_xy(),
      have_gamma: false,
      gamma: 0U,
      transfer_function: TRANSFER_UNKNOWN,
      rendering_intent: INTENT_RELATIVE,
    }
  }
  let white_point : UInt = if color_space == COLOR_XYB {
    WHITE_D65
  } else {
    @field.read_enum(reader)
  }
  let white_xy = if white_point == WHITE_CUSTOM {
    read_custom_xy(reader)
  } else {
    zero_xy()
  }
  let has_primaries = color_space != COLOR_GRAY && color_space != COLOR_XYB
  let primaries : UInt = if has_primaries {
    @field.read_enum(reader)
  } else {
    PRIMARIES_SRGB
  }
  let mut red_xy = zero_xy()
  let mut green_xy = zero_xy()
  let mut blue_xy = zero_xy()
  if primaries == PRIMARIES_CUSTOM {
    red_xy = read_custom_xy(reader)
    green_xy = read_custom_xy(reader)
    blue_xy = read_custom_xy(reader)
  }
  let mut have_gamma = false
  let mut gamma : UInt = 0U
  let mut transfer_function : UInt = TRANSFER_UNKNOWN
  if color_space == COLOR_XYB {
    have_gamma = true
    gamma = IMPLICIT_XYB_GAMMA
  } else {
    let hg = @field.read_bool(reader)
    if hg {
      have_gamma = true
      gamma = @field.read_bits(reader, 24)
    } else {
      transfer_function = @field.read_enum(reader)
    }
  }
  let rendering_intent = @field.read_enum(reader)
  {
    want_icc: false,
    color_space: color_space,
    white_point: white_point,
    white_xy: white_xy,
    primaries: primaries,
    red_xy: red_xy,
    green_xy: green_xy,
    blue_xy: blue_xy,
    have_gamma: have_gamma,
    gamma: gamma,
    transfer_function: transfer_function,
    rendering_intent: rendering_intent,
  }
}
