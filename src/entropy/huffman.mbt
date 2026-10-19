///|
/// Prefix (Huffman) decoding used when a JPEG XL stream selects prefix coding
/// instead of rANS. The tables are canonical: code lengths are transmitted in
/// symbol order and expanded into a two-level lookup table with an 8-bit root.

pub struct HuffmanCode {
  mut bits : UInt
  mut value : UInt
}

pub struct HuffmanDecodingData {
  table : Array[HuffmanCode]
}

/// Construct a single code entry (used by degenerate single-symbol tables).
pub fn HuffmanCode::new(bits : UInt, value : UInt) -> HuffmanCode {
  { bits: bits, value: value }
}

/// Wrap a pre-built lookup table (used by `read_huffman_table` and tests).
pub fn HuffmanDecodingData::new(table : Array[HuffmanCode]) -> HuffmanDecodingData {
  { table: table }
}

/// Reverse the lowest `len` bits of `key` and add one (the next canonical code
/// key in the sort order used by `build_huffman_table`).
fn get_next_key(key : Int, len : Int) -> Int {
  let mut step : Int = 1 << (len - 1)
  while (key & step) != 0 {
    step = step >> 1
  }
  (key & (step - 1)) + step
}

/// Store `code` at `table[base]`, `table[base + step]`, `table[base + 2*step]`,
/// ... up to (but not including) `table[base + end]`.
fn replicate_value(table : Array[HuffmanCode], base : Int, step : Int, end : Int, code : HuffmanCode) -> Unit {
  let mut e = end
  while true {
    e = e - step
    table[base + e] = code
    if e == 0 {
      break
    }
  }
}

/// The width of the next second-level table, given the remaining code-length
/// histogram `counts` and the length `len` of the symbol being placed.
fn next_table_bit_size(counts : Array[Int], len : Int, root_bits : Int) -> Int {
  let mut l = len
  let mut left : Int = 1 << (l - root_bits)
  while l < PREFIX_MAX_BITS {
    if left <= counts[l] {
      break
    }
    left = left - counts[l]
    l = l + 1
    left = left << 1
  }
  l - root_bits
}

/// Build a canonical Huffman lookup table from code lengths given in symbol
/// order. `counts` is the histogram of code lengths (`counts[len]` = number of
/// symbols with length `len`, for `len` in `[0, PREFIX_MAX_BITS]`) and is
/// consumed (decremented) as symbols are placed.
pub fn build_huffman_table(root_bits : Int, code_lengths : Array[Int], counts : Array[Int]) -> Array[HuffmanCode] raise @error.JxlError {
  let code_lengths_size = code_lengths.length()
  if code_lengths_size > (1 << PREFIX_MAX_BITS) {
    raise @error.JxlError::InvalidValue("huffman code too large")
  }
  let offset : Array[Int] = []
  let mut i = 0
  while i <= PREFIX_MAX_BITS {
    offset.push(0)
    i = i + 1
  }
  let sorted : Array[Int] = []
  i = 0
  while i < code_lengths_size {
    sorted.push(0)
    i = i + 1
  }
  let mut max_length : Int = 1
  {
    let mut sum : Int = 0
    let mut len = 1
    while len <= PREFIX_MAX_BITS {
      offset[len] = sum
      if counts[len] != 0 {
        sum = sum + counts[len]
        max_length = len
      }
      len = len + 1
    }
  }
  let mut symbol = 0
  while symbol < code_lengths_size {
    let cl = code_lengths[symbol]
    if cl != 0 {
      sorted[offset[cl]] = symbol
      offset[cl] = offset[cl] + 1
    }
    symbol = symbol + 1
  }
  // A single-symbol code is degenerate: every entry maps to that symbol.
  if offset[PREFIX_MAX_BITS] == 1 {
    let table : Array[HuffmanCode] = []
    let code = { bits: 0U, value: sorted[0].reinterpret_as_uint() }
    let mut key = 0
    while key < (1 << root_bits) {
      table.push(code)
      key = key + 1
    }
    return table
  }

  let mut total_size : Int = 1 << root_bits
  let table : Array[HuffmanCode] = []
  let mut table_bits : Int = root_bits
  let mut table_size : Int = 1 << table_bits
  // A smaller root table suffices when the longest code fits in fewer bits.
  if table_bits > max_length {
    table_bits = max_length
    table_size = 1 << table_bits
  }
  let mut k = 0
  while k < table_size {
    table.push({ bits: 0U, value: 0U })
    k = k + 1
  }
  let mut key : Int = 0
  symbol = 0
  let mut code_bits : Int = 1
  let mut step : Int = 2
  while true {
    while counts[code_bits] != 0 {
      let code = { bits: code_bits.reinterpret_as_uint(), value: sorted[symbol].reinterpret_as_uint() }
      replicate_value(table, key, step, table_size, code)
      symbol = symbol + 1
      counts[code_bits] = counts[code_bits] - 1
      key = get_next_key(key, code_bits)
    }
    code_bits = code_bits + 1
    if code_bits > table_bits {
      break
    }
    step = step << 1
  }
  // Replicate the reduced root table up to its full size.
  while table_size < total_size {
    let mut j = 0
    while j < table_size {
      table.push(table[j])
      j = j + 1
    }
    table_size = table_size << 1
  }

  // Append second-level tables and point the root entries at them.
  let mask : Int = total_size - 1
  let mut low : Int = -1
  let mut len : Int = root_bits + 1
  step = 2
  let mut cur_offset : Int = 0
  while len <= max_length {
    while counts[len] != 0 {
      if (key & mask) != low {
        cur_offset = cur_offset + table_size
        let sub_bits = next_table_bit_size(counts, len, root_bits)
        table_size = 1 << sub_bits
        total_size = total_size + table_size
        low = key & mask
        table[low].bits = (sub_bits + root_bits).reinterpret_as_uint()
        table[low].value = (cur_offset - low).reinterpret_as_uint()
        let mut j = 0
        while j < table_size {
          table.push({ bits: 0U, value: 0U })
          j = j + 1
        }
      }
      let code = { bits: (len - root_bits).reinterpret_as_uint(), value: sorted[symbol].reinterpret_as_uint() }
      replicate_value(table, cur_offset + (key >> root_bits), step, table_size, code)
      symbol = symbol + 1
      counts[len] = counts[len] - 1
      key = get_next_key(key, len)
    }
    len = len + 1
    step = step << 1
  }
  table
}

/// Decode the next Huffman-coded symbol.
pub fn HuffmanDecodingData::read_symbol(self : HuffmanDecodingData, reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  let mut idx = reader.peek_bits(HUFFMAN_TABLE_BITS).reinterpret_as_int()
  let mut entry = self.table[idx]
  let mut n_bits = entry.bits.reinterpret_as_int()
  if n_bits > HUFFMAN_TABLE_BITS {
    reader.consume(HUFFMAN_TABLE_BITS)
    n_bits = n_bits - HUFFMAN_TABLE_BITS
    idx = idx + entry.value.reinterpret_as_int()
    idx = idx + reader.peek_bits(n_bits).reinterpret_as_int()
    entry = self.table[idx]
  }
  reader.consume(entry.bits.reinterpret_as_int())
  entry.value
}

fn swap_symbols(a : Array[UInt], i : Int, j : Int) -> Unit {
  let t = a[i]
  a[i] = a[j]
  a[j] = t
}

/// The static 4-bit code used to transmit the code-length code lengths.
fn code_length_huff(bits : Int) -> (Int, Int) {
  match bits {
    0 => (2, 0)
    1 => (2, 4)
    2 => (2, 3)
    3 => (3, 2)
    4 => (2, 0)
    5 => (2, 4)
    6 => (2, 3)
    7 => (4, 1)
    8 => (2, 0)
    9 => (2, 4)
    10 => (2, 3)
    11 => (3, 2)
    12 => (2, 0)
    13 => (2, 4)
    14 => (2, 3)
    _ => (4, 5)
  }
}

fn read_simple_code(reader : @bitio.BitReader, alphabet_size : UInt) -> Array[HuffmanCode] raise @error.JxlError {
  let max_bits : Int = if alphabet_size > 1U {
    floor_log2_nonzero(alphabet_size - 1U).reinterpret_as_int() + 1
  } else {
    0
  }
  let mut num_symbols = reader.read_bits(2).reinterpret_as_int() + 1
  let symbols : Array[UInt] = []
  let mut i = 0
  while i < num_symbols {
    let s = reader.read_bits(max_bits)
    if s >= alphabet_size {
      raise @error.JxlError::InvalidValue("simple code symbol out of range")
    }
    symbols.push(s)
    i = i + 1
  }
  let mut a = 0
  while a < num_symbols - 1 {
    let mut b = a + 1
    while b < num_symbols {
      if symbols[a] == symbols[b] {
        raise @error.JxlError::InvalidValue("simple code duplicate symbol")
      }
      b = b + 1
    }
    a = a + 1
  }
  if num_symbols == 4 {
    num_symbols = num_symbols + reader.read_bits(1).reinterpret_as_int()
  }
  let table : Array[HuffmanCode] = []
  match num_symbols {
    1 => table.push({ bits: 0U, value: symbols[0] })
    2 => {
      if symbols[0] > symbols[1] {
        swap_symbols(symbols, 0, 1)
      }
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 1U, value: symbols[1] })
    }
    3 => {
      if symbols[1] > symbols[2] {
        swap_symbols(symbols, 1, 2)
      }
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 2U, value: symbols[1] })
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 2U, value: symbols[2] })
    }
    4 => {
      let mut x = 0
      while x < 3 {
        let mut y = x + 1
        while y < 4 {
          if symbols[x] > symbols[y] {
            swap_symbols(symbols, x, y)
          }
          y = y + 1
        }
        x = x + 1
      }
      table.push({ bits: 2U, value: symbols[0] })
      table.push({ bits: 2U, value: symbols[2] })
      table.push({ bits: 2U, value: symbols[1] })
      table.push({ bits: 2U, value: symbols[3] })
    }
    5 => {
      if symbols[2] > symbols[3] {
        swap_symbols(symbols, 2, 3)
      }
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 2U, value: symbols[1] })
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 3U, value: symbols[2] })
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 2U, value: symbols[1] })
      table.push({ bits: 1U, value: symbols[0] })
      table.push({ bits: 3U, value: symbols[3] })
    }
    _ => raise @error.JxlError::InvalidValue("invalid simple code symbol count")
  }
  while table.length() < (1 << HUFFMAN_TABLE_BITS) {
    let n = table.length()
    let mut k = 0
    while k < n {
      table.push(table[k])
      k = k + 1
    }
  }
  table
}

fn read_huffman_code_lengths(reader : @bitio.BitReader, code_length_code_lengths : Array[Int], num_symbols : Int) -> Array[Int] raise @error.JxlError {
  let code_lengths : Array[Int] = []
  let mut i = 0
  while i < num_symbols {
    code_lengths.push(0)
    i = i + 1
  }
  let counts : Array[Int] = []
  i = 0
  while i < 16 {
    counts.push(0)
    i = i + 1
  }
  i = 0
  while i < 18 {
    counts[code_length_code_lengths[i]] = counts[code_length_code_lengths[i]] + 1
    i = i + 1
  }
  let table = build_huffman_table(5, code_length_code_lengths, counts)
  let mut symbol = 0
  let mut prev_code_len = 8
  let mut repeat = 0
  let mut repeat_code_len = 0
  let mut space = 32768
  while symbol < num_symbols && space > 0 {
    let peek = reader.peek_bits(5).reinterpret_as_int()
    let p = table[peek]
    reader.consume(p.bits.reinterpret_as_int())
    let code_len = p.value.reinterpret_as_int()
    if code_len < 16 {
      repeat = 0
      code_lengths[symbol] = code_len
      symbol = symbol + 1
      if code_len != 0 {
        prev_code_len = code_len
        space = space - (32768 >> code_len)
      }
    } else {
      let extra_bits = code_len - 14
      let mut new_len = 0
      if code_len == 16 {
        new_len = prev_code_len
      }
      if repeat_code_len != new_len {
        repeat = 0
        repeat_code_len = new_len
      }
      let old_repeat = repeat
      if repeat > 0 {
        repeat = repeat - 2
        repeat = repeat << extra_bits
      }
      repeat = repeat + reader.read_bits(extra_bits).reinterpret_as_int() + 3
      let repeat_delta = repeat - old_repeat
      if symbol + repeat_delta > num_symbols {
        raise @error.JxlError::InvalidValue("huffman code length repeat overflows")
      }
      let mut j = 0
      while j < repeat_delta {
        code_lengths[symbol] = repeat_code_len
        symbol = symbol + 1
        j = j + 1
      }
      if repeat_code_len != 0 {
        space = space - (repeat_delta << (15 - repeat_code_len))
      }
    }
  }
  if space != 0 {
    raise @error.JxlError::InvalidValue("incomplete huffman code")
  }
  code_lengths
}

/// Read a prefix-code table for an alphabet of `alphabet_size` symbols.
pub fn read_huffman_table(reader : @bitio.BitReader, alphabet_size : UInt) -> HuffmanDecodingData raise @error.JxlError {
  if alphabet_size > (1U << PREFIX_MAX_BITS) {
    raise @error.JxlError::InvalidValue("huffman alphabet too large")
  }
  let simple_code_or_skip = reader.read_bits(2)
  if simple_code_or_skip == 1U {
    return { table: read_simple_code(reader, alphabet_size) }
  }
  let code_length_code_lengths : Array[Int] = []
  let mut i = 0
  while i < 18 {
    code_length_code_lengths.push(0)
    i = i + 1
  }
  let order : Array[Int] = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  let mut space = 32
  let mut num_codes = 0
  i = simple_code_or_skip.reinterpret_as_int()
  while i < 18 && space > 0 {
    let code_len_idx = order[i]
    let peek = reader.peek_bits(4).reinterpret_as_int()
    let (bits, v) = code_length_huff(peek)
    reader.consume(bits)
    code_length_code_lengths[code_len_idx] = v
    if v != 0 {
      space = space - (32 >> v)
      num_codes = num_codes + 1
    }
    i = i + 1
  }
  if !(num_codes == 1 || space == 0) {
    raise @error.JxlError::InvalidValue("invalid huffman code length code")
  }
  let code_lengths = read_huffman_code_lengths(reader, code_length_code_lengths, alphabet_size.reinterpret_as_int())
  let counts : Array[Int] = []
  i = 0
  while i < 16 {
    counts.push(0)
    i = i + 1
  }
  i = 0
  while i < code_lengths.length() {
    counts[code_lengths[i]] = counts[code_lengths[i]] + 1
    i = i + 1
  }
  { table: build_huffman_table(HUFFMAN_TABLE_BITS, code_lengths, counts) }
}
