///|
/// Huffman table tests: build a canonical prefix-code table and round-trip a
/// stream of symbols through `read_symbol`. The reference encoder assigns
/// standard canonical codes (shortest first, symbol order within a length),
/// which `build_huffman_table` consumes in its bit-reversed stream order.

fn reverse_bits(v : UInt, n : Int) -> UInt {
  let mut r : UInt = 0U
  let mut x = v
  let mut i = 0
  while i < n {
    r = (r << 1) | (x & 1U)
    x = x >> 1
    i = i + 1
  }
  r
}

/// Build a table from `code_lengths`, encode `symbols_to_encode` with the
/// matching canonical codes, and check `read_symbol` recovers them in order.
fn canonical_roundtrip(code_lengths : Array[Int], symbols_to_encode : Array[Int]) -> Bool raise @error.JxlError {
  let n = code_lengths.length()
  let counts : Array[Int] = []
  let mut i = 0
  while i < 16 {
    counts.push(0)
    i = i + 1
  }
  i = 0
  while i < n {
    counts[code_lengths[i]] = counts[code_lengths[i]] + 1
    i = i + 1
  }
  let table = HuffmanDecodingData::new(build_huffman_table(HUFFMAN_TABLE_BITS, code_lengths, counts))

  // Assign canonical codes (most-significant-bit-first) by (length, symbol).
  let codes : Array[UInt] = []
  let lens : Array[Int] = []
  i = 0
  while i < n {
    codes.push(0U)
    lens.push(0)
    i = i + 1
  }
  let mut code : UInt = 0U
  let mut prev_len : Int = 0
  let mut len = 1
  while len <= PREFIX_MAX_BITS {
    let mut sym = 0
    while sym < n {
      if code_lengths[sym] == len {
        code = code << (len - prev_len)
        codes[sym] = code
        lens[sym] = len
        code = code + 1U
        prev_len = len
      }
      sym = sym + 1
    }
    len = len + 1
  }

  let w = BitWriter::new()
  for s in symbols_to_encode {
    w.write_bits(reverse_bits(codes[s], lens[s]), lens[s])
  }
  // `read_symbol` peeks a full root-table width (8 bits) even for the last
  // symbol, so pad the stream with trailing zeros for the final peek.
  w.write_bits(0U, 8)
  let reader = @bitio.BitReader::new(w.finish())
  for s in symbols_to_encode {
    let got = table.read_symbol(reader).reinterpret_as_int()
    if got != s {
      return false
    }
  }
  true
}

test "huffman table decodes a small single-level code" {
  let code_lengths : Array[Int] = [1, 2, 3, 3]
  assert_true(canonical_roundtrip(code_lengths, [0, 1, 2, 3, 0, 3, 2, 1, 0, 0]))
}

test "huffman table decodes a two-level code" {
  // Kraft-complete code with two 9-bit symbols, forcing a second-level table.
  let code_lengths : Array[Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 9]
  assert_true(canonical_roundtrip(code_lengths, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 8, 0]))
}

test "huffman table handles a degenerate single-symbol code" {
  let code_lengths : Array[Int] = [0, 0, 0, 1]
  assert_true(canonical_roundtrip(code_lengths, [3, 3, 3, 3]))
}

test "read_huffman_table decodes a simple code" {
  // 4-symbol alphabet, simple code with two symbols {0, 3}.
  let w = BitWriter::new()
  w.write_bits(1U, 2) // simple_code_or_skip = 1
  w.write_bits(1U, 2) // num_symbols - 1 = 1
  w.write_bits(0U, 2) // symbol 0
  w.write_bits(3U, 2) // symbol 3
  let table = read_huffman_table(@bitio.BitReader::new(w.finish()), 4U)
  // The simple code gives symbol 0 code "0" and symbol 3 code "1".
  let r0 = @bitio.BitReader::new(b"\x00")
  assert_true(table.read_symbol(r0) == 0U)
  let r1 = @bitio.BitReader::new(b"\x01")
  assert_true(table.read_symbol(r1) == 3U)
}
