///|
/// Tests for `read_histogram`: hand-built streams exercise the three histogram
/// representations — simple (one/two symbols), flat, and log-count.

/// The prefix code word (nbits, bits) that the static log-count table assigns
/// to `val`. Hard-coded from `logcount_huff` (the static table is internal, and
/// test files only see `pub` items): val 7 (logcount 6) is "010" and val 9
/// (logcount 8) is "110".
fn logcount_code_bits(val : Int) -> (Int, Int) {
  match val {
    7 => (3, 2)
    9 => (3, 6)
    _ => (0, 0)
  }
}

test "read_histogram decodes a single-symbol simple code" {
  let w = BitWriter::new()
  w.write_bits(1U, 1) // simple code
  w.write_bits(0U, 1) // num_symbols = 1
  w.write_bits(0U, 1) // symbol 0 = 0
  let hist = read_histogram(@bitio.BitReader::new(w.finish()), 8)
  assert_true(hist.length() == 1)
  assert_true(hist[0] == 256)
}

test "read_histogram decodes a two-symbol simple code" {
  let w = BitWriter::new()
  w.write_bits(1U, 1) // simple code
  w.write_bits(1U, 1) // num_symbols = 2
  w.write_bits(0U, 1) // symbol 0 = 0
  w.write_bits(1U, 1) // symbol 1: var-len flag
  w.write_bits(0U, 3) // symbol 1: nbits = 0 -> value 1
  w.write_bits(100U, 8) // counts[0] = 100
  let hist = read_histogram(@bitio.BitReader::new(w.finish()), 8)
  assert_true(hist.length() == 2)
  assert_true(hist[0] == 100)
  assert_true(hist[1] == 156)
}

test "read_histogram decodes a flat histogram" {
  let w = BitWriter::new()
  w.write_bits(0U, 1) // not simple
  w.write_bits(1U, 1) // flat
  w.write_bits(1U, 1) // var-len flag
  w.write_bits(1U, 3) // nbits = 1
  w.write_bits(0U, 1) // value = 2 -> alphabet_size = 3
  let hist = read_histogram(@bitio.BitReader::new(w.finish()), 8)
  assert_true(hist.length() == 3)
  assert_true(hist[0] == 86)
  assert_true(hist[1] == 85)
  assert_true(hist[2] == 85)
}

test "read_histogram decodes a log-count distribution" {
  let w = BitWriter::new()
  w.write_bits(0U, 1) // not simple
  w.write_bits(0U, 1) // not flat
  w.write_bits(0U, 1) // shift loop breaks immediately -> shift = 0
  w.write_bits(0U, 1) // var-len length = 0 -> length = 3
  // Log-counts [6, 6, 8] with the largest (8, position 2) omitted.
  let (n0, c0) = logcount_code_bits(7) // logcount 6
  let (n1, c1) = logcount_code_bits(7) // logcount 6
  let (n2, c2) = logcount_code_bits(9) // logcount 8
  w.write_bits(c0.reinterpret_as_uint(), n0)
  w.write_bits(c1.reinterpret_as_uint(), n1)
  w.write_bits(c2.reinterpret_as_uint(), n2)
  w.write_bits(0U, 8) // padding for the final 7-bit peek
  let hist = read_histogram(@bitio.BitReader::new(w.finish()), 8)
  assert_true(hist.length() == 3)
  assert_true(hist[0] == 64)
  assert_true(hist[1] == 64)
  assert_true(hist[2] == 128)
}
