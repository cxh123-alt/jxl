///|
/// Errors raised while reading or parsing a JPEG XL codestream.
///
/// Every parsing function in this crate raises `JxlError`; callers can either
/// let it propagate or convert it to a `Result` with
/// `try ... catch { e => Err(e) }`.

pub(all) suberror JxlError {
  /// The input ended before a complete value could be read.
  Truncated

  /// The codestream signature (`0xFF 0x0A`) or container signature box was not
  /// found at the start of the input.
  BadSignature

  /// A `read_bits` call asked for a width outside the supported range.
  InvalidBitCount(Int)

  /// A well-formed but invalid value was encountered (bad enum, NaN, ...).
  InvalidValue(String)
}

/// A human-readable description of the error, suitable for diagnostics.
pub fn JxlError::message(self : JxlError) -> String {
  match self {
    Truncated => "input ended before a complete value could be read"
    BadSignature => "not a JPEG XL file (missing 0xFF 0x0A signature or JXL container box)"
    InvalidBitCount(n) => "invalid bit count: \{n}"
    InvalidValue(what) => "invalid value: \{what}"
  }
}
