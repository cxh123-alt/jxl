///|
/// The rANS alias table. Each entry covers a range of `entry_size` states in
/// the `[0, ANS_TAB_SIZE)` state space and maps the first `cutoff` states to
/// symbol `i` (the entry index) and the rest to `right_value`, so that a table
/// lookup resolves a symbol, its frequency, and its running offset in constant
/// time.

pub struct AliasEntry {
  mut cutoff : UInt
  mut right_value : UInt
  mut freq0 : UInt
  mut offsets1 : UInt
  mut freq1_xor_freq0 : UInt
}

pub struct AliasSymbol {
  value : UInt
  offset : UInt
  freq : UInt
}

pub struct AliasTable {
  entries : Array[AliasEntry]
  log_alpha_size : Int
  log_entry_size : Int
  entry_size_minus_1 : UInt
}

/// Pop the last element, raising on an empty stack (an invariant violation).
fn pop_or_fail(stack : Array[Int], what : String) -> Int raise @error.JxlError {
  match stack.pop() {
    Some(v) => v
    None => raise @error.JxlError::InvalidValue("alias table: \{what} stack empty")
  }
}

/// Build an alias table for a distribution over `range = 1 << log_range`
/// states, holding `1 << log_alpha_size` entries.
pub fn init_alias_table(distribution : Array[Int], log_range : Int, log_alpha_size : Int) -> AliasTable raise @error.JxlError {
  let range : UInt = 1U << log_range
  let table_size : Int = 1 << log_alpha_size
  let dist : Array[Int] = []
  for d in distribution {
    dist.push(d)
  }
  while dist.length() > 0 && dist[dist.length() - 1] == 0 {
    let _ = dist.pop()
  }
  if dist.length() == 0 {
    dist.push(range.reinterpret_as_int())
  }
  if dist.length() > table_size {
    raise @error.JxlError::InvalidValue("alias table distribution too large")
  }
  let entry_size : UInt = range >> log_alpha_size
  let entries : Array[AliasEntry] = []
  let mut i = 0
  while i < table_size {
    entries.push({ cutoff: 0U, right_value: 0U, freq0: 0U, offsets1: 0U, freq1_xor_freq0: 0U })
    i = i + 1
  }

  // A distribution with a single symbol keeps the state unchanged: the table
  // is degenerate and every lookup returns that symbol with full frequency.
  let mut single_symbol : Int = -1
  let mut sum : Int = 0
  i = 0
  while i < dist.length() {
    let v = dist[i]
    sum = sum + v
    if v == ANS_TAB_SIZE.reinterpret_as_int() {
      single_symbol = i
    }
    i = i + 1
  }
  if sum != range.reinterpret_as_int() {
    raise @error.JxlError::InvalidValue("alias table distribution does not sum to range")
  }
  if single_symbol != -1 {
    let sym : UInt = single_symbol.reinterpret_as_uint()
    i = 0
    while i < table_size {
      entries[i].cutoff = 0U
      entries[i].right_value = sym
      entries[i].freq0 = 0U
      entries[i].offsets1 = entry_size * i.reinterpret_as_uint()
      entries[i].freq1_xor_freq0 = ANS_TAB_SIZE
      i = i + 1
    }
    return {
      entries: entries,
      log_alpha_size: log_alpha_size,
      log_entry_size: log_range - log_alpha_size,
      entry_size_minus_1: (1U << (log_range - log_alpha_size)) - 1U,
    }
  }

  // General case: initialize each entry with its own symbol, then reassign
  // overflow from overfull entries into the free slots of underfull ones.
  let cutoffs : Array[UInt] = []
  i = 0
  while i < table_size {
    cutoffs.push(0U)
    i = i + 1
  }
  let underfull_posn : Array[Int] = []
  let overfull_posn : Array[Int] = []
  i = 0
  while i < dist.length() {
    cutoffs[i] = dist[i].reinterpret_as_uint()
    if cutoffs[i] > entry_size {
      overfull_posn.push(i)
    } else if cutoffs[i] < entry_size {
      underfull_posn.push(i)
    }
    i = i + 1
  }
  i = dist.length()
  while i < table_size {
    cutoffs[i] = 0U
    underfull_posn.push(i)
    i = i + 1
  }
  while overfull_posn.length() > 0 {
    let overfull_i = pop_or_fail(overfull_posn, "overfull")
    let underfull_i = pop_or_fail(underfull_posn, "underfull")
    let underfull_by = entry_size - cutoffs[underfull_i]
    cutoffs[overfull_i] = cutoffs[overfull_i] - underfull_by
    entries[underfull_i].right_value = overfull_i.reinterpret_as_uint()
    entries[underfull_i].offsets1 = cutoffs[overfull_i]
    if cutoffs[overfull_i] < entry_size {
      underfull_posn.push(overfull_i)
    } else if cutoffs[overfull_i] > entry_size {
      overfull_posn.push(overfull_i)
    }
  }
  i = 0
  while i < table_size {
    if cutoffs[i] == entry_size {
      entries[i].right_value = i.reinterpret_as_uint()
      entries[i].offsets1 = 0U
      entries[i].cutoff = 0U
    } else {
      entries[i].offsets1 = entries[i].offsets1 - cutoffs[i]
      entries[i].cutoff = cutoffs[i]
    }
    let freq0 : UInt = if i < dist.length() { dist[i].reinterpret_as_uint() } else { 0U }
    let i1 = entries[i].right_value.reinterpret_as_int()
    let freq1 : UInt = if i1 < dist.length() { dist[i1].reinterpret_as_uint() } else { 0U }
    entries[i].freq0 = freq0
    entries[i].freq1_xor_freq0 = freq1 ^ freq0
    i = i + 1
  }
  {
    entries: entries,
    log_alpha_size: log_alpha_size,
    log_entry_size: log_range - log_alpha_size,
    entry_size_minus_1: (1U << (log_range - log_alpha_size)) - 1U,
  }
}

/// Look up the symbol, offset, and frequency for a state in `[0, ANS_TAB_SIZE)`.
pub fn AliasTable::lookup(self : AliasTable, value : UInt) -> AliasSymbol {
  let i = (value >> self.log_entry_size).reinterpret_as_int()
  let pos = value & self.entry_size_minus_1
  let entry = self.entries[i]
  let greater = pos >= entry.cutoff
  let offsets1_or_0 = if greater { entry.offsets1 } else { 0U }
  let freq1_xor_freq0_or_0 = if greater { entry.freq1_xor_freq0 } else { 0U }
  {
    value: if greater { entry.right_value } else { i.reinterpret_as_uint() },
    offset: offsets1_or_0 + pos,
    freq: entry.freq0 ^ freq1_xor_freq0_or_0,
  }
}
