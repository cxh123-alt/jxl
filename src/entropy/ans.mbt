///|
/// rANS symbol decoding. An `ANSCode` bundles the per-context decoding tables
/// (alias tables for rANS or Huffman tables for prefix coding) with their
/// hybrid-uint configurations; an `ANSSymbolReader` owns the mutable state and
/// produces symbols from those tables, including LZ77 copy support for the
/// lossless modes.

/// The LZ77 sliding-window size and mask used by the lossless modes.
const K_WINDOW_SIZE : Int = 1 << 20
const K_WINDOW_MASK : UInt = (1U << 20) - 1U
const K_NUM_SPECIAL_DISTANCES : Int = 120

/// The 120 special LZ77 distance codes from WebP lossless, stored as
/// `(a, b)` pairs where `distance = a + multiplier * b`.
let k_special_distances : Array[(Int, Int)] = [
  (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2),
  (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3),
  (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0),
  (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4),
  (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
  (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2),
  (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
  (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2),
  (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
  (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
  (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2),
  (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
  (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6),
  (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
  (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7),
]

/// Resolve a special distance code to an actual distance (>= 1).
fn special_distance(index : Int, multiplier : Int) -> UInt {
  let (a, b) = k_special_distances[index]
  let dist = a + multiplier * b
  if dist > 1 { dist.reinterpret_as_uint() } else { 1U }
}

/// LZ77 parameters attached to an entropy code.
pub struct LZ77Params {
  enabled : Bool
  min_symbol : UInt
  min_length : UInt
  length_uint_config : HybridUintConfig
  distance_context : Int
}

/// A default (disabled) LZ77 configuration.
pub fn LZ77Params::disabled() -> LZ77Params {
  {
    enabled: false,
    min_symbol: 0U,
    min_length: 0U,
    length_uint_config: HybridUintConfig::new(0U, 0U, 0U),
    distance_context: 0,
  }
}

/// The static entropy tables shared by all symbols decoded from one stream.
pub struct ANSCode {
  alias_tables : Array[AliasTable]
  huffman_data : Array[HuffmanDecodingData]
  uint_config : Array[HybridUintConfig]
  use_prefix_code : Bool
  log_alpha_size : Int
  lz77 : LZ77Params
}

/// Assemble an entropy code from its pre-decoded tables.
pub fn ANSCode::new(
  alias_tables : Array[AliasTable],
  huffman_data : Array[HuffmanDecodingData],
  uint_config : Array[HybridUintConfig],
  use_prefix_code : Bool,
  log_alpha_size : Int,
  lz77 : LZ77Params
) -> ANSCode {
  {
    alias_tables: alias_tables,
    huffman_data: huffman_data,
    uint_config: uint_config,
    use_prefix_code: use_prefix_code,
    log_alpha_size: log_alpha_size,
    lz77: lz77,
  }
}

/// The mutable rANS decoder state.
pub struct ANSSymbolReader {
  code : ANSCode
  mut state : UInt
  log_entry_size : Int
  entry_size_minus_1 : UInt
  lz77_window : Array[UInt]
  mut num_decoded : UInt
  mut num_to_copy : UInt
  mut copy_pos : UInt
  special_distances : Array[UInt]
  num_special_distances : Int
}

fn make_uint_array(size : Int, value : UInt) -> Array[UInt] {
  let a : Array[UInt] = []
  let mut i = 0
  while i < size {
    a.push(value)
    i = i + 1
  }
  a
}

/// Create a symbol reader over `code`. `initial_state` is the 32-bit rANS state
/// read from the stream (ignored for prefix coding). `distance_multiplier` is a
/// frame-level scale for the LZ77 special distances (0 disables them).
pub fn ANSSymbolReader::new(code : ANSCode, initial_state : UInt, distance_multiplier : Int) -> ANSSymbolReader {
  let log_entry_size = if code.use_prefix_code { 0 } else { ANS_LOG_TAB_SIZE - code.log_alpha_size }
  let entry_size_minus_1 = if code.use_prefix_code { 0U } else { (1U << log_entry_size) - 1U }
  let num_special_distances = if code.lz77.enabled && distance_multiplier != 0 {
    K_NUM_SPECIAL_DISTANCES
  } else {
    0
  }
  let special_distances : Array[UInt] = []
  let mut i = 0
  while i < num_special_distances {
    special_distances.push(special_distance(i, distance_multiplier))
    i = i + 1
  }
  let lz77_window = if code.lz77.enabled { make_uint_array(K_WINDOW_SIZE, 0U) } else { ([] : Array[UInt]) }
  {
    code: code,
    state: if code.use_prefix_code { ANS_SIGNATURE << 16 } else { initial_state },
    log_entry_size: log_entry_size,
    entry_size_minus_1: entry_size_minus_1,
    lz77_window: lz77_window,
    num_decoded: 0U,
    num_to_copy: 0U,
    copy_pos: 0U,
    special_distances: special_distances,
    num_special_distances: num_special_distances,
  }
}

/// Decode one rANS symbol: look the low `ANS_LOG_TAB_SIZE` bits up in the alias
/// table, update the state, and renormalize by reading 16 bits when the state
/// drops below `1 << 16`.
fn ANSSymbolReader::read_symbol_ans(self : ANSSymbolReader, histo_idx : Int, reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  let res = self.state & ANS_TAB_MASK
  let symbol = self.code.alias_tables[histo_idx].lookup(res)
  let s = self.state.to_uint64()
  self.state = (symbol.freq.to_uint64() * (s >> ANS_LOG_TAB_SIZE) + symbol.offset.to_uint64()).to_uint()
  if self.state < (1U << 16) {
    self.state = (self.state << 16) | reader.read_bits(16)
  }
  symbol.value
}

fn ANSSymbolReader::read_symbol_huff(self : ANSSymbolReader, histo_idx : Int, reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  self.code.huffman_data[histo_idx].read_symbol(reader)
}

/// Decode one symbol from the given context (histogram index).
pub fn ANSSymbolReader::read_symbol(self : ANSSymbolReader, histo_idx : Int, reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  if self.code.use_prefix_code {
    return self.read_symbol_huff(histo_idx, reader)
  }
  self.read_symbol_ans(histo_idx, reader)
}

/// Decode a hybrid-uint value for clustered context `ctx`, applying LZ77 copy
/// semantics when the code uses them.
pub fn ANSSymbolReader::read_hybrid_uint_clustered(self : ANSSymbolReader, ctx : Int, reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  if self.code.lz77.enabled {
    if self.num_to_copy > 0U {
      let ret = self.lz77_window[(self.copy_pos & K_WINDOW_MASK).reinterpret_as_int()]
      self.copy_pos = self.copy_pos + 1U
      self.num_to_copy = self.num_to_copy - 1U
      self.lz77_window[(self.num_decoded & K_WINDOW_MASK).reinterpret_as_int()] = ret
      self.num_decoded = self.num_decoded + 1U
      return ret
    }
  }
  let token = self.read_symbol(ctx, reader)
  if self.code.lz77.enabled {
    if token >= self.code.lz77.min_symbol {
      self.num_to_copy = read_hybrid_uint(self.code.lz77.length_uint_config, token - self.code.lz77.min_symbol, reader) + self.code.lz77.min_length
      let d_token = self.read_symbol(self.code.lz77.distance_context, reader)
      let mut distance = read_hybrid_uint(self.code.uint_config[self.code.lz77.distance_context], d_token, reader)
      if distance.reinterpret_as_int() < self.num_special_distances {
        distance = self.special_distances[distance.reinterpret_as_int()]
      } else {
        distance = distance + 1U - self.num_special_distances.reinterpret_as_uint()
      }
      if distance > self.num_decoded {
        distance = self.num_decoded
      }
      if distance > K_WINDOW_SIZE.reinterpret_as_uint() {
        distance = K_WINDOW_SIZE.reinterpret_as_uint()
      }
      self.copy_pos = self.num_decoded - distance
      if distance == 0U {
        let to_fill = if self.num_to_copy < K_WINDOW_SIZE.reinterpret_as_uint() {
          self.num_to_copy
        } else {
          K_WINDOW_SIZE.reinterpret_as_uint()
        }
        let mut j = 0
        while j < to_fill.reinterpret_as_int() {
          self.lz77_window[j] = 0U
          j = j + 1
        }
      }
      if self.num_to_copy < self.code.lz77.min_length {
        self.num_to_copy = 0U
        return 0U
      }
      let ret = self.lz77_window[(self.copy_pos & K_WINDOW_MASK).reinterpret_as_int()]
      self.copy_pos = self.copy_pos + 1U
      self.num_to_copy = self.num_to_copy - 1U
      self.lz77_window[(self.num_decoded & K_WINDOW_MASK).reinterpret_as_int()] = ret
      self.num_decoded = self.num_decoded + 1U
      return ret
    }
  }
  let ret = read_hybrid_uint(self.code.uint_config[ctx], token, reader)
  if self.code.lz77.enabled {
    self.lz77_window[(self.num_decoded & K_WINDOW_MASK).reinterpret_as_int()] = ret
    self.num_decoded = self.num_decoded + 1U
  }
  ret
}

/// True when the rANS state has reached its expected terminal value.
pub fn ANSSymbolReader::check_ans_final_state(self : ANSSymbolReader) -> Bool {
  self.state == (ANS_SIGNATURE << 16)
}

/// Read `num_histograms` hybrid-uint configurations (`DecodeUintConfigs`).
pub fn read_uint_configs(reader : @bitio.BitReader, log_alpha_size : UInt, num_histograms : Int) -> Array[HybridUintConfig] raise @error.JxlError {
  let configs : Array[HybridUintConfig] = []
  let mut i = 0
  while i < num_histograms {
    configs.push(read_uint_config(reader, log_alpha_size))
    i = i + 1
  }
  configs
}

/// Read `num_histograms` entropy tables (histograms for rANS or prefix-code
/// tables) and bundle them into an `ANSCode` (`DecodeANSCodes`).
pub fn read_ans_codes(
  reader : @bitio.BitReader,
  num_histograms : Int,
  max_alphabet_size : Int,
  use_prefix_code : Bool,
  log_alpha_size : Int,
  uint_config : Array[HybridUintConfig]
) -> ANSCode raise @error.JxlError {
  if use_prefix_code {
    if max_alphabet_size > (1 << PREFIX_MAX_BITS) {
      raise @error.JxlError::InvalidValue("prefix alphabet too large")
    }
    let alphabet_sizes : Array[Int] = []
    let mut c = 0
    while c < num_histograms {
      let size = decode_var_len_uint16(reader) + 1
      if size > max_alphabet_size {
        raise @error.JxlError::InvalidValue("alphabet size too large")
      }
      alphabet_sizes.push(size)
      c = c + 1
    }
    let huffman_data : Array[HuffmanDecodingData] = []
    c = 0
    while c < num_histograms {
      if alphabet_sizes[c] > 1 {
        huffman_data.push(read_huffman_table(reader, alphabet_sizes[c].reinterpret_as_uint()))
      } else {
        let table : Array[HuffmanCode] = []
        let code = HuffmanCode::new(0U, 0U)
        let mut i = 0
        while i < (1 << HUFFMAN_TABLE_BITS) {
          table.push(code)
          i = i + 1
        }
        huffman_data.push(HuffmanDecodingData::new(table))
      }
      c = c + 1
    }
    return ANSCode::new([], huffman_data, uint_config, true, log_alpha_size, LZ77Params::disabled())
  }
  if max_alphabet_size > ANS_MAX_ALPHABET_SIZE {
    raise @error.JxlError::InvalidValue("ans alphabet too large")
  }
  let alias_tables : Array[AliasTable] = []
  let mut c = 0
  while c < num_histograms {
    let counts = read_histogram(reader, ANS_LOG_TAB_SIZE)
    if counts.length() > max_alphabet_size {
      raise @error.JxlError::InvalidValue("ans alphabet too large")
    }
    alias_tables.push(init_alias_table(counts, ANS_LOG_TAB_SIZE, log_alpha_size))
    c = c + 1
  }
  ANSCode::new(alias_tables, [], uint_config, false, log_alpha_size, LZ77Params::disabled())
}
