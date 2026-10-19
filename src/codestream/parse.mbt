///|
/// Top-level header parsing: signature, size, and image metadata.

/// A parsed JPEG XL header (size header plus image metadata).
pub struct Header {
  width : UInt
  height : UInt
  metadata : Metadata
}

/// Parse a raw codestream header (signature, size header, metadata).
pub fn parse(codestream : Bytes) -> Header raise @error.JxlError {
  let reader = @bitio.BitReader::new(codestream)
  // The 16-bit signature is 0x0AFF (bytes FF 0A in file order).
  if @field.read_bits(reader, 16) != 0x0AFFU {
    raise @error.JxlError::BadSignature
  }
  let size = read_size(reader)
  let metadata = read_metadata(reader)
  { width: size.width, height: size.height, metadata: metadata }
}
