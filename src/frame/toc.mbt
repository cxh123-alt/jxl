///|
/// Table of contents: the byte sizes of the group data sections that follow
/// the frame header. Ported from libjxl's `toc.cc` / `toc.h`.
///
/// Only the permutation-bit == 0 path is decoded; a permuted TOC (Lehmer code)
/// is rejected as unsupported, which matches the single-group, single-pass
/// lossless fixtures targeted here.

/// Number of TOC entries for the given group layout and pass count.
pub fn num_toc_entries(num_groups : UInt, num_dc_groups : UInt, num_passes : UInt) -> UInt {
  if num_groups == 1U && num_passes == 1U {
    return 1U
  }
  2U + num_dc_groups + num_groups * num_passes
}

/// Read `toc_entries` section sizes. The reader must be positioned at the TOC
/// (immediately after the frame header); afterwards it is byte-aligned at the
/// start of the first section.
pub fn read_toc(
  reader : @bitio.BitReader,
  toc_entries : UInt
) -> Array[UInt] raise @error.JxlError {
  let sizes : Array[UInt] = []
  let permuted = @field.read_bool(reader)
  if permuted {
    raise @error.JxlError::InvalidValue("unsupported TOC permutation")
  }
  reader.align_to_byte()
  let mut i : UInt = 0U
  while i < toc_entries {
    sizes.push(@field.read_u32(
      reader,
      @field.bits(10U),
      @field.bits_offset(14U, 1024U),
      @field.bits_offset(22U, 17408U),
      @field.bits_offset(30U, 4211712U)
    ))
    i = i + 1U
  }
  reader.align_to_byte()
  sizes
}
