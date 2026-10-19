///|
/// Public entry point: inspect a JPEG XL file and summarize its header.
///
/// A JPEG XL file is either a raw codestream or an ISO-BMFF-style container.
/// This module accepts either form, unwraps the container when present, and
/// decodes the size header and image metadata (bit depth, color encoding,
/// extra channels, orientation) without decoding pixel data.

/// Flat, user-facing summary of a JPEG XL header.
pub struct ImageInfo {
  width : UInt
  height : UInt
  bits : UInt
  floating_point : Bool
  color_space : UInt
  color_space_name : String
  extra_channels : Int
  xyb_encoded : Bool
  orientation : UInt
  container_label : String
}

/// Parse the header of a JPEG XL file (naked codestream or container).
pub fn info(data : Bytes) -> ImageInfo raise @error.JxlError {
  let kind = @codestream.detect(data)
  let cs = @codestream.codestream(data)
  let h = @codestream.parse(cs)
  {
    width: h.width,
    height: h.height,
    bits: h.metadata.bit_depth.bits,
    floating_point: h.metadata.bit_depth.floating_point,
    color_space: h.metadata.color.color_space,
    color_space_name: @codestream.color_space_name(h.metadata.color.color_space),
    extra_channels: h.metadata.extra_channels.length(),
    xyb_encoded: h.metadata.xyb_encoded,
    orientation: h.metadata.orientation,
    container_label: kind.label(),
  }
}

/// A one-line human-readable description of a JPEG XL file.
pub fn summary(data : Bytes) -> String raise @error.JxlError {
  let i = info(data)
  "JPEG XL \{i.width}x\{i.height}, \{i.bits}-bit \{i.color_space_name}, \{i.extra_channels} extra channel(s), \{i.container_label}"
}
