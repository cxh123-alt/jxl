///|
/// rANS round-trip tests. A minimal encoder — the exact inverse of the decoder
/// state machine — produces a stream that `ANSSymbolReader` decodes back, ending
/// at the expected terminal state.

/// Encode `symbols` under `freqs` (summing to 4096) into `(initial_state, bits)`
/// where `bits` holds only the renormalization words (the 32-bit state is
/// returned separately).
fn rans_encode(freqs : Array[Int], symbols : Array[Int]) -> (UInt, Bytes) raise @error.JxlError {
  let n = freqs.length()
  let cum : Array[Int] = []
  let mut acc = 0
  let mut i = 0
  while i < n {
    cum.push(acc)
    acc = acc + freqs[i]
    i = i + 1
  }
  // Inverse alias mapping: cumulative position -> state residue.
  let table = init_alias_table(freqs, ANS_LOG_TAB_SIZE, 8)
  let inv : Array[Int] = []
  i = 0
  while i < ANS_TAB_SIZE.reinterpret_as_int() {
    inv.push(0)
    i = i + 1
  }
  i = 0
  while i < ANS_TAB_SIZE.reinterpret_as_int() {
    let sym = table.lookup(i.reinterpret_as_uint())
    inv[cum[sym.value.reinterpret_as_int()] + sym.offset.reinterpret_as_int()] = i
    i = i + 1
  }
  let words : Array[UInt] = []
  let mut state : UInt64 = ANS_SIGNATURE.to_uint64() << 16
  i = symbols.length() - 1
  while i >= 0 {
    let s = symbols[i]
    let f = freqs[s].to_uint64()
    // Renormalize when the top ANS_LOG_TAB_SIZE bits reach the symbol frequency
    // (the inverse of the decoder's `state < 1 << 16` refill).
    while (state >> 20) >= f {
      words.push((state & 0xFFFFUL).to_uint())
      state = state >> 16
    }
    let r = (state % f).to_uint().reinterpret_as_int()
    let q = state / f
    let res = inv[cum[s] + r]
    state = q * 4096UL + res.to_uint64()
    i = i - 1
  }
  let w = BitWriter::new()
  i = words.length() - 1
  while i >= 0 {
    w.write_bits(words[i], 16)
    i = i - 1
  }
  (state.to_uint(), w.finish())
}

/// Encode `symbols` under `freqs`, then decode them back through a single-context
/// `ANSSymbolReader` and confirm both the symbols and the terminal state.
fn rans_roundtrip(freqs : Array[Int], symbols : Array[Int]) -> Bool raise @error.JxlError {
  let (init_state, stream) = rans_encode(freqs, symbols)
  let code = ANSCode::new(
    [init_alias_table(freqs, ANS_LOG_TAB_SIZE, 8)],
    [],
    [HybridUintConfig::new(4U, 2U, 0U)],
    false,
    8,
    LZ77Params::disabled(),
  )
  let reader = ANSSymbolReader::new(code, init_state, 0)
  let br = @bitio.BitReader::new(stream)
  let mut i = 0
  while i < symbols.length() {
    if reader.read_symbol(0, br).reinterpret_as_int() != symbols[i] {
      return false
    }
    i = i + 1
  }
  reader.check_ans_final_state()
}

test "rANS round-trips a balanced two-symbol stream" {
  let freqs : Array[Int] = [2048, 2048]
  assert_true(rans_roundtrip(freqs, [0, 1, 0, 0, 1, 1, 0, 1, 0, 1]))
}

test "rANS round-trips a skewed distribution" {
  let freqs : Array[Int] = [1, 100, 1000, 2995]
  assert_true(rans_roundtrip(freqs, [3, 3, 2, 1, 0, 3, 2, 2, 1, 3, 3, 0, 2, 1, 3]))
}

test "rANS round-trips a degenerate single-symbol stream" {
  let freqs : Array[Int] = [4096]
  assert_true(rans_roundtrip(freqs, [0, 0, 0, 0, 0, 0]))
}

test "read_hybrid_uint_clustered decodes beyond the split token" {
  // A degenerate single-symbol table that always yields token 4.
  let freqs : Array[Int] = [0, 0, 0, 0, 4096]
  let code = ANSCode::new(
    [init_alias_table(freqs, ANS_LOG_TAB_SIZE, 8)],
    [],
    [HybridUintConfig::new(2U, 0U, 0U)],
    false,
    8,
    LZ77Params::disabled(),
  )
  let reader = ANSSymbolReader::new(code, 0x130000U, 0)
  let w = BitWriter::new()
  w.write_bits(1U, 2) // low bits "01" -> value 4 + 1 = 5
  assert_true(reader.read_hybrid_uint_clustered(0, @bitio.BitReader::new(w.finish())) == 5U)
}

test "read_ans_codes reads an rANS histogram" {
  let w = BitWriter::new()
  w.write_bits(1U, 1) // simple histogram
  w.write_bits(1U, 1) // two symbols
  w.write_bits(0U, 1) // symbol 0 = 0
  w.write_bits(1U, 1) // symbol 1 = 1 (var-len flag)
  w.write_bits(0U, 3) // nbits = 0 -> value 1
  w.write_bits(1024U, 12) // counts[0] = 1024
  let code = read_ans_codes(
    @bitio.BitReader::new(w.finish()),
    1,
    256,
    false,
    8,
    [HybridUintConfig::new(4U, 2U, 0U)],
  )
  let table = code.alias_tables[0]
  // The alias table does not map states contiguously by symbol, so verify the
  // distribution by counting the states each symbol claims (1024 vs 3072) and
  // checking the frequency reported at each state.
  let mut count0 = 0
  let mut count1 = 0
  let mut bad = false
  let mut r = 0
  while r < ANS_TAB_SIZE.reinterpret_as_int() {
    let s = table.lookup(r.reinterpret_as_uint())
    if s.value == 0U {
      count0 = count0 + 1
      if s.freq != 1024U {
        bad = true
      }
    } else if s.value == 1U {
      count1 = count1 + 1
      if s.freq != 3072U {
        bad = true
      }
    } else {
      bad = true
    }
    r = r + 1
  }
  assert_true(count0 == 1024)
  assert_true(count1 == 3072)
  assert_true(!bad)
}
