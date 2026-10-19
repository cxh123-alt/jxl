///|
/// Container tests use hand-assembled ISO-BMFF boxes (all big-endian).

test "detect classifies naked and boxed input" {
  assert_true(detect(b"\xFF\x0A") == Naked)
  assert_true(detect(b"\x00\x00\x00\x0C\x4A\x58\x4C\x20\x0D\x0A\x87\x0A") == Boxed)
  let bad = try {
    let _ = detect(b"\x00\x01\x02")
    "no-error"
  } catch {
    @error.JxlError::BadSignature => "bad"
    _ => "other"
  }
  assert_true(bad == "bad")
}

test "codestream unwraps a jxlc box" {
  let data = b"\x00\x00\x00\x0C\x4A\x58\x4C\x20\x0D\x0A\x87\x0A" +
    b"\x00\x00\x00\x0C\x6A\x78\x6C\x63\x11\x22\x33\x44"
  assert_true(codestream(data) == b"\x11\x22\x33\x44")
}

test "codestream reassembles jxlp chunks in order" {
  let data = b"\x00\x00\x00\x0C\x4A\x58\x4C\x20\x0D\x0A\x87\x0A" +
    b"\x00\x00\x00\x0E\x6A\x78\x6C\x70\x00\x00\x00\x00\xAA\xBB" +
    b"\x00\x00\x00\x0E\x6A\x78\x6C\x70\x00\x00\x00\x01\xCC\xDD"
  assert_true(codestream(data) == b"\xAA\xBB\xCC\xDD")
}

test "container without a codestream is an error" {
  let data = b"\x00\x00\x00\x0C\x4A\x58\x4C\x20\x0D\x0A\x87\x0A" +
    b"\x00\x00\x00\x0C\x66\x74\x79\x70\x00\x00\x00\x00"
  let outcome = try {
    let _ = codestream(data)
    "no-error"
  } catch {
    @error.JxlError::InvalidValue(_) => "invalid"
    _ => "other"
  }
  assert_true(outcome == "invalid")
}
