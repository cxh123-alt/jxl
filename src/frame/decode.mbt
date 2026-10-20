///|
/// Decode entry skeleton: read a raw codestream up to and including the TOC,
/// producing the frame header, derived dimensions, and the byte sizes of the
/// group-data sections. Pixel reconstruction (the entropy + modular layers) is
/// layered on top of this in later milestones.

pub struct FrameSections {
  width : UInt
  height : UInt
  metadata : @codestream.Metadata
  header : FrameHeader
  dims : FrameDimensions
  section_sizes : Array[UInt]
}

/// Parse the header portion of a raw codestream: signature, size header,
/// metadata, frame header, and TOC.
pub fn read_frame(cs : Bytes) -> FrameSections raise @error.JxlError {
  let reader = @bitio.BitReader::new(cs)
  if @field.read_bits(reader, 16) != 0x0AFFU {
    raise @error.JxlError::BadSignature
  }
  let size = @codestream.read_size(reader)
  let metadata = @codestream.read_metadata(reader)
  let header = read_frame_header(reader, metadata, size.width, size.height)
  let dims = from_frame_header(header, size.width, size.height)
  let toc_entries = num_toc_entries(dims.num_groups, dims.num_dc_groups, header.num_passes)
  let section_sizes = read_toc(reader, toc_entries)
  {
    width: size.width,
    height: size.height,
    metadata: metadata,
    header: header,
    dims: dims,
    section_sizes: section_sizes,
  }
}
