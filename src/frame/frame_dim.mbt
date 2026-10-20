///|
/// Frame geometry: the `FrameDimensions::Set` port from libjxl's
/// `frame_dimensions.h`. Computes group and DC-group counts from the frame
/// header and the decoded image size.

const K_BLOCK_DIM : UInt = 8U
const K_GROUP_DIM : UInt = 256U

pub struct FrameDimensions {
  xsize : UInt
  ysize : UInt
  xsize_padded : UInt
  ysize_padded : UInt
  xsize_groups : UInt
  ysize_groups : UInt
  num_groups : UInt
  num_dc_groups : UInt
  group_dim : UInt
  dc_group_dim : UInt
}

/// Ceiling division of two unsigned integers.
pub fn div_ceil(a : UInt, b : UInt) -> UInt {
  (a + b - 1U) / b
}

/// Compute the frame dimensions from the frame header and image size.
pub fn from_frame_header(
  fh : FrameHeader,
  image_xsize : UInt,
  image_ysize : UInt
) -> FrameDimensions {
  let mut xsize = if fh.frame_xsize != 0U { fh.frame_xsize } else { image_xsize }
  let mut ysize = if fh.frame_ysize != 0U { fh.frame_ysize } else { image_ysize }
  if fh.dc_level != 0U {
    let shift = (3U * fh.dc_level).reinterpret_as_int()
    xsize = div_ceil(xsize, 1U << shift)
    ysize = div_ceil(ysize, 1U << shift)
  }
  // Lossless Modular frames have no chroma subsampling, so max h/v shift is 0.
  compute(xsize, ysize, fh.group_size_shift, 0U, 0U, true, fh.upsampling)
}

/// Build the derived dimensions (`Set` in the reference implementation).
pub fn compute(
  xsize_px : UInt,
  ysize_px : UInt,
  group_size_shift : UInt,
  max_hshift : UInt,
  max_vshift : UInt,
  modular_mode : Bool,
  upsampling : UInt
) -> FrameDimensions {
  let group_dim = (K_GROUP_DIM >> 1) << group_size_shift.reinterpret_as_int()
  let dc_group_dim = group_dim * K_BLOCK_DIM
  let xsize = div_ceil(xsize_px, upsampling)
  let ysize = div_ceil(ysize_px, upsampling)
  let xsize_blocks = div_ceil(xsize, K_BLOCK_DIM << max_hshift.reinterpret_as_int()) << max_hshift.reinterpret_as_int()
  let ysize_blocks = div_ceil(ysize, K_BLOCK_DIM << max_vshift.reinterpret_as_int()) << max_vshift.reinterpret_as_int()
  let mut xsize_padded = xsize_blocks * K_BLOCK_DIM
  let mut ysize_padded = ysize_blocks * K_BLOCK_DIM
  if modular_mode {
    // Modular mode has no padding.
    xsize_padded = xsize
    ysize_padded = ysize
  }
  let xsize_groups = div_ceil(xsize, group_dim)
  let ysize_groups = div_ceil(ysize, group_dim)
  let xsize_dc_groups = div_ceil(xsize_blocks, group_dim)
  let ysize_dc_groups = div_ceil(ysize_blocks, group_dim)
  {
    xsize: xsize,
    ysize: ysize,
    xsize_padded: xsize_padded,
    ysize_padded: ysize_padded,
    xsize_groups: xsize_groups,
    ysize_groups: ysize_groups,
    num_groups: xsize_groups * ysize_groups,
    num_dc_groups: xsize_dc_groups * ysize_dc_groups,
    group_dim: group_dim,
    dc_group_dim: dc_group_dim,
  }
}
