///|
/// rANS histogram decoding: read a distribution of symbol frequencies (summing
/// to `1 << precision_bits`) from the bit stream. ISO/IEC 18181-2 offers three
/// representations — a one/two-symbol simple code, a flat histogram, and a
/// per-symbol log-count code with run-length encoding.

/// Decode a number in [0, 255] using 1..11 bits.
fn decode_var_len_uint8(reader : @bitio.BitReader) -> Int raise @error.JxlError {
  if reader.read_bits(1) == 1U {
    let nbits = reader.read_bits(3).reinterpret_as_int()
    if nbits == 0 {
      return 1
    }
    return reader.read_bits(nbits).reinterpret_as_int() + (1 << nbits)
  }
  0
}

/// Decode a number in [0, 65535] using 1..21 bits.
fn decode_var_len_uint16(reader : @bitio.BitReader) -> Int raise @error.JxlError {
  if reader.read_bits(1) == 1U {
    let nbits = reader.read_bits(4).reinterpret_as_int()
    if nbits == 0 {
      return 1
    }
    return reader.read_bits(nbits).reinterpret_as_int() + (1 << nbits)
  }
  0
}

/// The number of extra precision bits carried for a log-count `logcount` given
/// the population-count shift.
fn population_count_precision(logcount : Int, shift : Int) -> Int {
  let a = shift - ((ANS_LOG_TAB_SIZE - logcount) >> 1)
  let r = if logcount < a { logcount } else { a }
  if r < 0 { 0 } else { r }
}

/// The static 7-bit code used to read log-counts. Each 16-entry block shares
/// the same tail; only the second entry differs per block.
fn logcount_huff(bits : Int) -> (Int, Int) {
  let block = bits >> 4
  let within = bits & 15
  if within == 0 {
    return (3, 10)
  }
  if within == 1 {
    match block {
      0 => return (7, 12)
      1 => return (5, 0)
      2 => return (6, 11)
      3 => return (5, 0)
      4 => return (7, 13)
      5 => return (5, 0)
      6 => return (6, 11)
      _ => return (5, 0)
    }
  }
  match within {
    2 => (3, 7)
    3 => (4, 3)
    4 => (3, 6)
    5 => (3, 8)
    6 => (3, 9)
    7 => (4, 5)
    8 => (3, 10)
    9 => (4, 4)
    10 => (3, 7)
    11 => (4, 1)
    12 => (3, 6)
    13 => (3, 8)
    14 => (3, 9)
    _ => (4, 2)
  }
}

/// Read a histogram of symbol counts summing to `1 << precision_bits`.
pub fn read_histogram(reader : @bitio.BitReader, precision_bits : Int) -> Array[Int] raise @error.JxlError {
  let range : Int = 1 << precision_bits
  // Simple code: one or two explicit symbols.
  if reader.read_bits(1) == 1U {
    let num_symbols = reader.read_bits(1).reinterpret_as_int() + 1
    let mut max_symbol = 0
    let symbols : Array[Int] = []
    let mut i = 0
    while i < num_symbols {
      let s = decode_var_len_uint8(reader)
      symbols.push(s)
      if s > max_symbol {
        max_symbol = s
      }
      i = i + 1
    }
    let counts : Array[Int] = []
    i = 0
    while i <= max_symbol {
      counts.push(0)
      i = i + 1
    }
    if num_symbols == 1 {
      counts[symbols[0]] = range
    } else {
      if symbols[0] == symbols[1] {
        raise @error.JxlError::InvalidValue("histogram simple code has duplicate symbols")
      }
      counts[symbols[0]] = reader.read_bits(precision_bits).reinterpret_as_int()
      counts[symbols[1]] = range - counts[symbols[0]]
    }
    return counts
  }
  // Flat histogram: every symbol shares the count nearly equally.
  if reader.read_bits(1) == 1U {
    let alphabet_size = decode_var_len_uint8(reader) + 1
    if alphabet_size > range {
      raise @error.JxlError::InvalidValue("flat histogram alphabet too large")
    }
    let count = range / alphabet_size
    let rem = range % alphabet_size
    let counts : Array[Int] = []
    let mut i = 0
    while i < alphabet_size {
      counts.push(if i < rem { count + 1 } else { count })
      i = i + 1
    }
    return counts
  }
  // Log-count coding with an omitted (implied) count and optional RLE.
  let upper_bound_log = 3 // floor(log2(ANS_LOG_TAB_SIZE + 1)) = floor(log2(13))
  let mut log = 0
  while log < upper_bound_log {
    if reader.read_bits(1) == 0U {
      break
    }
    log = log + 1
  }
  let shift = (reader.read_bits(log).reinterpret_as_int() | (1 << log)) - 1
  if shift > ANS_LOG_TAB_SIZE + 1 {
    raise @error.JxlError::InvalidValue("histogram invalid shift")
  }
  let length = decode_var_len_uint8(reader) + 3
  let counts : Array[Int] = []
  let logcounts : Array[Int] = []
  let same : Array[Int] = []
  let mut i = 0
  while i < length {
    counts.push(0)
    logcounts.push(0)
    same.push(0)
    i = i + 1
  }
  let mut omit_log = -1
  let mut omit_pos = -1
  i = 0
  while i < length {
    let idx = reader.peek_bits(7).reinterpret_as_int()
    let (nbits, val) = logcount_huff(idx)
    reader.consume(nbits)
    logcounts[i] = val - 1
    if logcounts[i] == ANS_LOG_TAB_SIZE {
      let rle_length = decode_var_len_uint8(reader)
      same[i] = rle_length + 5
      i = i + rle_length + 3
      continue
    }
    if logcounts[i] > omit_log {
      omit_log = logcounts[i]
      omit_pos = i
    }
    i = i + 1
  }
  if omit_pos < 0 {
    raise @error.JxlError::InvalidValue("histogram has no omitted value")
  }
  if omit_pos + 1 < length && logcounts[omit_pos + 1] == ANS_LOG_TAB_SIZE {
    raise @error.JxlError::InvalidValue("histogram RLE after omitted value")
  }
  let mut total_count = 0
  let mut prev = 0
  let mut numsame = 0
  i = 0
  while i < length {
    if same[i] != 0 {
      numsame = same[i] - 1
      prev = if i > 0 { counts[i - 1] } else { 0 }
    }
    if numsame > 0 {
      counts[i] = prev
      numsame = numsame - 1
    } else {
      let code = logcounts[i]
      if i == omit_pos || code < 0 {
        // Left at zero; the omitted count is filled in below.
      } else if shift == 0 || code == 0 {
        counts[i] = 1 << code
      } else {
        let bitcount = population_count_precision(code, shift)
        counts[i] = (1 << code) + (reader.read_bits(bitcount).reinterpret_as_int() << (code - bitcount))
      }
    }
    total_count = total_count + counts[i]
    i = i + 1
  }
  counts[omit_pos] = range - total_count
  if counts[omit_pos] <= 0 {
    raise @error.JxlError::InvalidValue("histogram count does not sum to range")
  }
  counts
}
