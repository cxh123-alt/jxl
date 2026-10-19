///|
/// Container detection and unwrapping.
///
/// A JPEG XL file is either a raw codestream (starting with the two bytes
/// `0xFF 0x0A`) or an ISO-BMFF-style container whose boxes wrap the
/// codestream. The container begins with a 12-byte `JXL ` signature box,
/// followed by an `ftyp` box, and then one `jxlc` box or a sequence of `jxlp`
/// boxes holding the codestream payload.

pub(all) enum ContainerKind {
  /// A raw codestream with no container wrapper.
  Naked
  /// An ISO-BMFF-style container.
  Boxed
} derive(Eq)

/// A human-readable name for the container kind.
pub fn ContainerKind::label(self : ContainerKind) -> String {
  match self {
    Naked => "raw codestream"
    Boxed => "container"
  }
}

/// Classify the input as a raw codestream or a boxed container.
pub fn detect(data : Bytes) -> ContainerKind raise @error.JxlError {
  if data.length() >= 2 && data[0] == b'\xFF' && data[1] == b'\x0A' {
    return Naked
  }
  if data.length() >= 12 && data[0] == b'\x00' && data[1] == b'\x00' &&
    data[2] == b'\x00' && data[3] == b'\x0C' && data[4] == b'J' &&
    data[5] == b'X' && data[6] == b'L' && data[7] == b' ' &&
    data[8] == b'\x0D' && data[9] == b'\x0A' && data[10] == b'\x87' &&
    data[11] == b'\x0A' {
    return Boxed
  }
  raise @error.JxlError::BadSignature
}

/// Extract the raw codestream payload, unwrapping the container if present.
pub fn codestream(data : Bytes) -> Bytes raise @error.JxlError {
  match detect(data) {
    Naked => data
    Boxed => unwrap(data)
  }
}

/// Read a big-endian 32-bit unsigned integer.
fn be32(data : Bytes, i : Int) -> UInt {
  (data[i].to_uint() << 24) | (data[i + 1].to_uint() << 16) |
    (data[i + 2].to_uint() << 8) | data[i + 3].to_uint()
}

/// Read a big-endian 64-bit unsigned integer.
fn be64(data : Bytes, i : Int) -> UInt64 {
  (data[i].to_uint64() << 56) | (data[i + 1].to_uint64() << 48) |
    (data[i + 2].to_uint64() << 40) | (data[i + 3].to_uint64() << 32) |
    (data[i + 4].to_uint64() << 24) | (data[i + 5].to_uint64() << 16) |
    (data[i + 6].to_uint64() << 8) | data[i + 7].to_uint64()
}

/// True when the box type at `pos + 4` equals the four ASCII bytes of `t`.
fn type_is(data : Bytes, pos : Int, t : Bytes) -> Bool {
  data[pos + 4] == t[0] && data[pos + 5] == t[1] && data[pos + 6] == t[2] &&
    data[pos + 7] == t[3]
}

/// Copy the box content `[pos + header, ...)` into a fresh buffer.
fn slice(data : Bytes, begin : Int, end : Int) -> Bytes raise @error.JxlError {
  match data.get_view(start=begin, end=end) {
    Some(v) => v.to_owned()
    None => raise @error.JxlError::Truncated
  }
}

fn unwrap(data : Bytes) -> Bytes raise @error.JxlError {
  let len = data.length()
  let mut pos : Int = 12
  let chunks : Array[Bytes] = []
  while pos + 8 <= len {
    let size32 = be32(data, pos)
    let mut header : Int = 8
    let mut box_size : UInt64 = size32.to_uint64()
    if size32 == 1U {
      if pos + 16 > len {
        raise @error.JxlError::Truncated
      }
      box_size = be64(data, pos + 8)
      header = 16
    }
    if box_size != 0UL && box_size.to_uint() < header.reinterpret_as_uint() {
      raise @error.JxlError::InvalidValue("box size smaller than its header")
    }
    if type_is(data, pos, b"jxlc") {
      return box_content(data, pos, header, box_size)
    }
    if type_is(data, pos, b"jxlp") {
      let content = box_content(data, pos, header, box_size)
      if content.length() < 4 {
        raise @error.JxlError::Truncated
      }
      // Each jxlp box prefixes its chunk with a 4-byte index (bit 31 =
      // is_last, bits 0..30 = counter). Chunks are assumed to arrive in
      // order; out-of-order jxlp is not yet supported.
      chunks.push(slice(content, 4, content.length()))
    }
    if box_size == 0UL {
      break
    }
    let next = pos + box_size.to_int()
    if next < pos || next > len {
      raise @error.JxlError::InvalidValue("box extends past end of input")
    }
    pos = next
  }
  if chunks.length() == 0 {
    raise @error.JxlError::InvalidValue("container holds no codestream")
  }
  let mut result : Bytes = b""
  for c in chunks {
    result = result + c
  }
  result
}

/// The content bytes of the box at `pos`, given its `header` and total size.
fn box_content(data : Bytes, pos : Int, header : Int, box_size : UInt64) -> Bytes raise @error.JxlError {
  let begin = pos + header
  if box_size == 0UL {
    return slice(data, begin, data.length())
  }
  let end = begin + box_size.to_int() - header
  if end > data.length() {
    raise @error.JxlError::InvalidValue("box extends past end of input")
  }
  slice(data, begin, end)
}
