///|
/// Modular prediction: the weighted predictor, the gradient/select/neighbor
/// helpers, the property layout, and the reference-property precompute. Ports
/// `modular/encoding/context_predict.h` (weighted::Header, weighted::State,
/// ClampedGradient, Select, PredictOne, InitPropsRow, PrecomputeReferences).

/// Weighted-predictor coefficients, serialized as part of the group header.
pub struct WeightedHeader {
  p1C : Int
  p2C : Int
  p3Ca : Int
  p3Cb : Int
  p3Cc : Int
  p3Cd : Int
  p3Ce : Int
  w : Array[Int]
}

/// Read a `WeightedPredictorHeader` bundle (`weighted::Header::VisitFields`).
pub fn read_weighted_header(reader : @bitio.BitReader) -> WeightedHeader raise @error.JxlError {
  let all_default = @field.read_bool(reader)
  if all_default {
    return {
      p1C: 16,
      p2C: 10,
      p3Ca: 7,
      p3Cb: 7,
      p3Cc: 7,
      p3Cd: 0,
      p3Ce: 0,
      w: [0xd, 0xc, 0xc, 0xc],
    }
  }
  // Note: `Bits(n, default)` stores the raw n-bit value, not `default + value`;
  // the defaults only feed the `all_default` shortcut above.
  let p1C = reader.read_bits(5).reinterpret_as_int()
  let p2C = reader.read_bits(5).reinterpret_as_int()
  let p3Ca = reader.read_bits(5).reinterpret_as_int()
  let p3Cb = reader.read_bits(5).reinterpret_as_int()
  let p3Cc = reader.read_bits(5).reinterpret_as_int()
  let p3Cd = reader.read_bits(5).reinterpret_as_int()
  let p3Ce = reader.read_bits(5).reinterpret_as_int()
  let w0 = reader.read_bits(4).reinterpret_as_int()
  let w1 = reader.read_bits(4).reinterpret_as_int()
  let w2 = reader.read_bits(4).reinterpret_as_int()
  let w3 = reader.read_bits(4).reinterpret_as_int()
  {
    p1C: p1C,
    p2C: p2C,
    p3Ca: p3Ca,
    p3Cb: p3Cb,
    p3Cc: p3Cc,
    p3Cd: p3Cd,
    p3Ce: p3Ce,
    w: [w0, w1, w2, w3],
  }
}

/// `1 << 24 / (i + 1)` approximation table for division by 1..64.
let k_divlookup : Array[UInt] = [
  16777216U, 8388608U, 5592405U, 4194304U, 3355443U, 2796202U, 2396745U, 2097152U,
  1864135U, 1677721U, 1525201U, 1398101U, 1290555U, 1198372U, 1118481U, 1048576U,
  986895U, 932067U, 883011U, 838860U, 798915U, 762600U, 729444U, 699050U,
  671088U, 645277U, 621378U, 599186U, 578524U, 559240U, 541200U, 524288U,
  508400U, 493447U, 479349U, 466033U, 453438U, 441505U, 430185U, 419430U,
  409200U, 399457U, 390167U, 381300U, 372827U, 364722U, 356962U, 349525U,
  342392U, 335544U, 328965U, 322638U, 316551U, 310689U, 305040U, 299593U,
  294337U, 289262U, 284359U, 279620U, 275036U, 270600U, 266305U, 262144U,
]

fn abs_int(x : Int) -> Int {
  if x < 0 { -x } else { x }
}

fn abs_i64(x : Int64) -> Int64 {
  if x < 0L { -x } else { x }
}

fn max_i64(a : Int64, b : Int64) -> Int64 {
  if a > b { a } else { b }
}

fn min_i64(a : Int64, b : Int64) -> Int64 {
  if a < b { a } else { b }
}

fn floor_log2_nonzero(x : UInt) -> Int {
  let mut n = 0
  let mut v = x
  while v > 1U {
    v = v >> 1
    n = n + 1
  }
  n
}

fn add_bits(x : Int64) -> Int64 {
  x << 3
}

/// Approximate `4 + (maxweight << 24) / (x + 1)` without division.
fn error_weight(x : UInt, maxweight : UInt) -> UInt {
  let mut shift = floor_log2_nonzero(x + 1U) - 5
  if shift < 0 {
    shift = 0
  }
  4U + ((maxweight * k_divlookup[(x >> shift).reinterpret_as_int()]) >> shift)
}

/// The mutable weighted-predictor state (two rows of error history).
pub struct WeightedState {
  header : WeightedHeader
  prediction : Array[Int64]
  mut pred : Int64
  pred_errors : Array[UInt]
  error : Array[Int]
  row_stride : Int
}

/// Allocate a weighted-predictor state for a channel of width `xsize`.
pub fn WeightedState::new(header : WeightedHeader, xsize : Int) -> WeightedState {
  let row_stride = xsize + 2
  let total = 2 * row_stride
  let pred_errors : Array[UInt] = []
  let mut i = 0
  while i < 4 * total {
    pred_errors.push(0U)
    i = i + 1
  }
  let error : Array[Int] = []
  i = 0
  while i < total {
    error.push(0)
    i = i + 1
  }
  {
    header: header,
    prediction: [0L, 0L, 0L, 0L],
    pred: 0L,
    pred_errors: pred_errors,
    error: error,
    row_stride: row_stride,
  }
}

/// Compute the weighted prediction for sample `(x, y)`. `N`/`W`/`NE`/`NW`/`NN`
/// are the top, left, top-right, top-left and top-top neighbors. When
/// `properties` is non-empty, writes the weighted error property at `offset`.
pub fn WeightedState::predict(
  self : WeightedState,
  x : Int,
  y : Int,
  xsize : Int,
  top : Int,
  left : Int,
  topright : Int,
  topleft : Int,
  toptop : Int,
  properties : Array[Int],
  offset : Int
) -> Int64 {
  let cur_row = if (y & 1) != 0 { 0 } else { self.row_stride }
  let prev_row = if (y & 1) != 0 { self.row_stride } else { 0 }
  let pos_n = prev_row + x
  let pos_ne = if x < xsize - 1 { pos_n + 1 } else { pos_n }
  let pos_nw = if x > 0 { pos_n - 1 } else { pos_n }
  let weights : Array[UInt] = []
  let mut i = 0
  while i < 4 {
    let base = i * 2 * self.row_stride
    let wsum = self.pred_errors[base + pos_n] + self.pred_errors[base + pos_ne] +
      self.pred_errors[base + pos_nw]
    weights.push(error_weight(wsum, self.header.w[i].reinterpret_as_uint()))
    i = i + 1
  }
  let n = add_bits(top.to_int64())
  let w = add_bits(left.to_int64())
  let ne = add_bits(topright.to_int64())
  let nw = add_bits(topleft.to_int64())
  let nn = add_bits(toptop.to_int64())

  let te_w = if x == 0 { 0L } else { self.error[cur_row + x - 1].to_int64() }
  let te_n = self.error[pos_n].to_int64()
  let te_nw = self.error[pos_nw].to_int64()
  let sum_wn = te_n + te_w
  let te_ne = self.error[pos_ne].to_int64()

  let mut p : Int64 = te_w
  if abs_i64(te_n) > abs_i64(p) {
    p = te_n
  }
  if abs_i64(te_nw) > abs_i64(p) {
    p = te_nw
  }
  if abs_i64(te_ne) > abs_i64(p) {
    p = te_ne
  }
  properties[offset] = p.to_int()

  self.prediction[0] = w + ne - n
  self.prediction[1] = n - (((sum_wn + te_ne) * self.header.p1C.to_int64()) >> 5)
  self.prediction[2] = w - (((sum_wn + te_nw) * self.header.p2C.to_int64()) >> 5)
  self.prediction[3] = n -
    ((te_nw * self.header.p3Ca.to_int64() + te_n * self.header.p3Cb.to_int64() +
      te_ne * self.header.p3Cc.to_int64() + (nn - n) * self.header.p3Cd.to_int64() +
      (nw - w) * self.header.p3Ce.to_int64()) >>
     5)

  self.pred = weighted_average(self.prediction, weights)

  // If all three errors share a sign, skip clamping.
  let same_sign = ((te_n ^ te_w) | (te_n ^ te_nw)) > 0L
  if same_sign {
    return (self.pred + 3L) >> 3
  }
  let mx = max_i64(w, max_i64(ne, n))
  let mn = min_i64(w, min_i64(ne, n))
  let clamped = max_i64(mn, min_i64(mx, self.pred))
  (clamped + 3L) >> 3
}

fn weighted_average(p : Array[Int64], w : Array[UInt]) -> Int64 {
  let mut weight_sum : UInt = 0U
  let mut i = 0
  while i < 4 {
    weight_sum = weight_sum + w[i]
    i = i + 1
  }
  let log_weight = floor_log2_nonzero(weight_sum)
  let shifted : Array[UInt] = []
  let mut ws : UInt = 0U
  i = 0
  while i < 4 {
    let sw = w[i] >> (log_weight - 4)
    shifted.push(sw)
    ws = ws + sw
    i = i + 1
  }
  let mut sum : Int64 = ((ws >> 1) - 1U).to_int64()
  i = 0
  while i < 4 {
    sum = sum + p[i] * shifted[i].to_int64()
    i = i + 1
  }
  (sum * k_divlookup[(ws - 1U).reinterpret_as_int()].to_int64()) >> 24
}

/// Update the weighted-predictor error history with the decoded value `val`.
pub fn WeightedState::update_errors(self : WeightedState, val : Int, x : Int, y : Int) -> Unit {
  let cur_row = if (y & 1) != 0 { 0 } else { self.row_stride }
  let prev_row = if (y & 1) != 0 { self.row_stride } else { 0 }
  let val64 = add_bits(val.to_int64())
  self.error[cur_row + x] = (self.pred - val64).to_int()
  let mut i = 0
  while i < 4 {
    let base = i * 2 * self.row_stride
    let diff = self.prediction[i] - val64
    let err = ((abs_i64(diff) + 3L) >> 3).to_int().reinterpret_as_uint()
    self.pred_errors[base + cur_row + x] = err
    self.pred_errors[base + prev_row + x + 1] = self.pred_errors[base + prev_row + x + 1] + err
    i = i + 1
  }
}

/// Gradient predictor clamped to `[min(n, w), max(n, w)]` against `l`
/// (`ClampedGradient`), computed with wrapping 32-bit arithmetic for the
/// intermediate `n + w - l`.
pub fn clamped_gradient(n : Int, w : Int, l : Int) -> Int {
  let m = if n < w { n } else { w }
  let m2 = if n > w { n } else { w }
  let grad = (n.reinterpret_as_uint() + w.reinterpret_as_uint() - l.reinterpret_as_uint()).reinterpret_as_int()
  let grad_clamp_m = if l < m { m2 } else { grad }
  if l > m2 { m } else { grad_clamp_m }
}

/// The `Select` predictor: pick whichever of `a`/`b` is closer to `a + b - c`.
fn select(a : Int64, b : Int64, c : Int64) -> Int64 {
  let p = a + b - c
  let pa = abs_i64(p - a)
  let pb = abs_i64(p - b)
  if pa < pb { a } else { b }
}

/// Evaluate one predictor (`PredictOne`).
pub fn predict_one(
  predictor : Int,
  left : Int,
  top : Int,
  toptop : Int,
  topleft : Int,
  topright : Int,
  leftleft : Int,
  toprightright : Int,
  wp_pred : Int64
) -> Int64 {
  let l = left.to_int64()
  let t = top.to_int64()
  let tt = toptop.to_int64()
  let tl = topleft.to_int64()
  let tr = topright.to_int64()
  let ll = leftleft.to_int64()
  let trr = toprightright.to_int64()
  if predictor == PRED_ZERO {
    return 0L
  } else if predictor == PRED_LEFT {
    return l
  } else if predictor == PRED_TOP {
    return t
  } else if predictor == PRED_SELECT {
    return select(l, t, tl)
  } else if predictor == PRED_WEIGHTED {
    return wp_pred
  } else if predictor == PRED_GRADIENT {
    return clamped_gradient(left, top, topleft).to_int64()
  } else if predictor == PRED_TOP_LEFT {
    return tl
  } else if predictor == PRED_TOP_RIGHT {
    return tr
  } else if predictor == PRED_LEFT_LEFT {
    return ll
  } else if predictor == PRED_AVERAGE0 {
    return (l + t) / 2L
  } else if predictor == PRED_AVERAGE1 {
    return (l + tl) / 2L
  } else if predictor == PRED_AVERAGE2 {
    return (tl + t) / 2L
  } else if predictor == PRED_AVERAGE3 {
    return (t + tr) / 2L
  } else if predictor == PRED_AVERAGE4 {
    return (6L * t - 2L * tt + 7L * l + ll + trr + 3L * tr + 8L) / 16L
  } else {
    return 0L
  }
}

/// Set the per-row static properties (`InitPropsRow`).
pub fn init_props_row(properties : Array[Int], chan : Int, group_id : Int, y : Int) -> Unit {
  properties[0] = chan
  properties[1] = group_id
  properties[2] = y
  properties[9] = 0
}

/// Fill the `references` channel (w = num_extra_props, h = current channel
/// width) for the current row `y` from the prior, already-decoded channels of
/// matching dimensions (`PrecomputeReferences`).
pub fn precompute_references(
  channels : Array[Channel],
  chan : Int,
  y : Int,
  ch_w : Int,
  references : Channel
) -> Unit {
  let num_extra_props = references.w
  let mut zi = 0
  while zi < references.plane.length() {
    references.plane[zi] = 0
    zi = zi + 1
  }
  let cur = channels[chan]
  let mut offset = 0
  let mut j = chan - 1
  while j >= 0 && offset < num_extra_props {
    let cj = channels[j]
    if cj.w != ch_w || cj.h != cur.h || cj.hshift != cur.hshift || cj.vshift != cur.vshift {
      j = j - 1
      continue
    }
    let mut x = 0
    while x < ch_w {
      let v = cj.plane[y * cj.w + x]
      references.plane[x * num_extra_props + offset] = abs_int(v)
      references.plane[x * num_extra_props + offset + 1] = v
      let vleft = if x != 0 { cj.plane[y * cj.w + x - 1] } else { 0 }
      let vtop = if y != 0 { cj.plane[(y - 1) * cj.w + x] } else { vleft }
      let vtopleft = if x != 0 && y != 0 { cj.plane[(y - 1) * cj.w + x - 1] } else { vleft }
      let vpredicted = clamped_gradient(vleft, vtop, vtopleft)
      references.plane[x * num_extra_props + offset + 2] = abs_int(v - vpredicted)
      references.plane[x * num_extra_props + offset + 3] = v - vpredicted
      x = x + 1
    }
    offset = offset + 4
    j = j - 1
  }
}
