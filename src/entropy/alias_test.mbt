///|
/// Alias-table invariants: every state in `[0, ANS_TAB_SIZE)` maps to a symbol
/// whose reported frequency matches the distribution, and each symbol occurs
/// exactly `distribution[symbol]` times.

fn lookup_distribution_ok(dist : Array[Int], log_alpha_size : Int) -> Bool raise @error.JxlError {
  let table = init_alias_table(dist, ANS_LOG_TAB_SIZE, log_alpha_size)
  let n = dist.length()
  let counts : Array[Int] = []
  let mut i = 0
  while i < n {
    counts.push(0)
    i = i + 1
  }
  let mut v = 0
  while v < ANS_TAB_SIZE.reinterpret_as_int() {
    let s = table.lookup(v.reinterpret_as_uint())
    let sym = s.value.reinterpret_as_int()
    if sym >= n {
      return false
    }
    if s.freq != dist[sym].reinterpret_as_uint() {
      return false
    }
    if s.offset >= s.freq {
      return false
    }
    counts[sym] = counts[sym] + 1
    v = v + 1
  }
  i = 0
  while i < n {
    if counts[i] != dist[i] {
      return false
    }
    i = i + 1
  }
  true
}

test "alias table for a single symbol is degenerate" {
  assert_true(lookup_distribution_ok([4096], 8))
}

test "alias table for a flat distribution" {
  let dist : Array[Int] = []
  let mut i = 0
  while i < 16 {
    dist.push(256)
    i = i + 1
  }
  assert_true(lookup_distribution_ok(dist, 4))
}

test "alias table for a skewed distribution" {
  assert_true(lookup_distribution_ok([1000, 1000, 1096, 1000], 3))
}

test "alias table strips trailing zero symbols" {
  assert_true(lookup_distribution_ok([2048, 2048, 0, 0, 0], 3))
}

test "alias table for an empty distribution defaults to one symbol" {
  let table = init_alias_table([], ANS_LOG_TAB_SIZE, 8)
  let mut v = 0
  while v < ANS_TAB_SIZE.reinterpret_as_int() {
    let s = table.lookup(v.reinterpret_as_uint())
    assert_true(s.value == 0U)
    assert_true(s.freq == ANS_TAB_SIZE)
    v = v + 1
  }
}
