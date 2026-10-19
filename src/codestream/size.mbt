///|
/// Image size headers (the main `SizeHeader` and the smaller `PreviewHeader`).

pub struct Size {
  width : UInt
  height : UInt
}

/// The fixed aspect ratios 1..7 as (numerator, denominator).
fn fixed_ratio(ratio : UInt) -> (UInt, UInt) raise @error.JxlError {
  match ratio {
    1 => (1U, 1U)
    2 => (12U, 10U)
    3 => (4U, 3U)
    4 => (3U, 2U)
    5 => (16U, 9U)
    6 => (5U, 4U)
    7 => (2U, 1U)
    _ => raise @error.JxlError::InvalidValue("invalid aspect ratio")
  }
}

/// `floor(m * num / den)`.
fn mul_truncate(m : UInt, num : UInt, den : UInt) -> UInt {
  (m.to_uint64() * num.to_uint64() / den.to_uint64()).to_uint()
}

/// The U32 distribution used for the non-small dimension fields.
fn dim_u32(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.bits_offset(9U, 1U),
    @field.bits_offset(13U, 1U),
    @field.bits_offset(18U, 1U),
    @field.bits_offset(30U, 1U)
  )
}

/// Read the main size header.
pub fn read_size(reader : @bitio.BitReader) -> Size raise @error.JxlError {
  let small = @field.read_bool(reader)
  let ysize : UInt = if small {
    (@field.read_bits(reader, 5) + 1U) * 8U
  } else {
    dim_u32(reader)
  }
  let ratio = @field.read_bits(reader, 3)
  let xsize : UInt = if ratio == 0U {
    if small {
      (@field.read_bits(reader, 5) + 1U) * 8U
    } else {
      dim_u32(reader)
    }
  } else {
    let (num, den) = fixed_ratio(ratio)
    mul_truncate(ysize, num, den)
  }
  { width: xsize, height: ysize }
}

/// The U32 distribution for a preview dimension when it is not divisible by 8.
fn preview_dim(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.bits_offset(6U, 1U),
    @field.bits_offset(8U, 65U),
    @field.bits_offset(10U, 321U),
    @field.bits_offset(12U, 1345U)
  )
}

/// The U32 distribution for a preview dimension when it is divisible by 8.
fn preview_dim_div8(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.val(16U),
    @field.val(32U),
    @field.bits_offset(5U, 1U),
    @field.bits_offset(9U, 33U)
  )
}

/// Read a preview size header.
pub fn read_preview_size(reader : @bitio.BitReader) -> Size raise @error.JxlError {
  let div8 = @field.read_bool(reader)
  let ysize : UInt = if div8 {
    preview_dim_div8(reader) * 8U
  } else {
    preview_dim(reader)
  }
  let ratio = @field.read_bits(reader, 3)
  let xsize : UInt = if ratio == 0U {
    if div8 {
      preview_dim_div8(reader) * 8U
    } else {
      preview_dim(reader)
    }
  } else {
    let (num, den) = fixed_ratio(ratio)
    mul_truncate(ysize, num, den)
  }
  { width: xsize, height: ysize }
}
