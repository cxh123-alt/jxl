///|
/// Inverse modular transforms: undo RCT, palette and squeeze steps in reverse
/// order to recover the original channels. Ports libjxl's
/// `modular/transform/{rct,palette,squeeze,transform}.cc` (lossless subset).
///
/// Pixel arithmetic follows the reference exactly: `pixel_type` is 32-bit
/// (`Int`) with wrapping unsigned adds where noted, and `pixel_type_w` is
/// 64-bit (`Int64`) for the wider squeeze / weighted intermediates.

// --- helpers ---------------------------------------------------------------

/// Wrapping 32-bit add (`PixelAdd`): a + b in uint32_t, reinterpreted.
fn pixel_add(a : Int, b : Int) -> Int {
  (a.reinterpret_as_uint() + b.reinterpret_as_uint()).reinterpret_as_int()
}

/// `SmoothTendency(B, a, n)`: the best estimate of the residual difference in a
/// Haar-like squeeze step, computed in 64-bit to avoid overflow.
fn smooth_tendency(b : Int64, a : Int64, n : Int64) -> Int64 {
  let mut diff : Int64 = 0L
  if b >= a && a >= n {
    diff = (4L * b - 3L * n - a + 6L) / 12L
    if diff - (diff & 1L) > 2L * (b - a) {
      diff = 2L * (b - a) + 1L
    }
    if diff + (diff & 1L) > 2L * (a - n) {
      diff = 2L * (a - n)
    }
  } else if b <= a && a <= n {
    diff = (4L * b - 3L * n - a - 6L) / 12L
    if diff + (diff & 1L) < 2L * (b - a) {
      diff = 2L * (b - a) - 1L
    }
    if diff - (diff & 1L) < 2L * (a - n) {
      diff = 2L * (a - n)
    }
  }
  diff
}

/// The 72-entry implicit delta-palette (72 rows x 3 channels), flattened
/// row-major (`palette_internal::kDeltaPalette`).
let k_delta_palette : Array[Int] = [
  0, 0, 0,         4, 4, 4,         11, 0, 0,        0, 0, -13,
  0, -12, 0,       -10, -10, -10,  -18, -18, -18,   -27, -27, -27,
  -18, -18, 0,     0, 0, -32,      -32, 0, 0,       -37, -37, -37,
  0, -32, -32,     24, 24, 45,     50, 50, 50,      -45, -24, -24,
  -24, -45, -45,   0, -24, -24,    -34, -34, 0,      -24, 0, -24,
  -45, -45, -24,   64, 64, 64,     -32, 0, -32,      0, -32, 0,
  -32, 0, 32,      -24, -45, -24,  45, 24, 45,       24, -24, -45,
  -45, -24, 24,    80, 80, 80,     64, 0, 0,         0, 0, -64,
  0, -64, -64,     -24, -24, 45,   96, 96, 96,       64, 64, 0,
  45, -24, -24,    34, -34, 0,     112, 112, 112,    24, -45, -45,
  45, 45, -24,     0, -32, 32,     24, -24, 45,      0, 96, 96,
  45, -24, 24,     24, -45, -24,   -24, -45, 24,     0, -64, 0,
  96, 0, 0,        128, 128, 128,  64, 0, 64,        144, 144, 144,
  96, 96, 0,       -36, -36, 36,   45, -24, -45,     45, -45, -24,
  0, 0, -96,       0, 128, 128,    0, 96, 0,         45, 24, -45,
  -128, 0, 0,      24, -45, 24,    -45, 24, -45,     64, 0, -64,
  64, -64, -64,    96, 0, 96,      45, -45, 24,      24, 45, -45,
  64, 64, -64,     128, 128, 0,    0, 0, -128,       -24, 45, -45,
]

const K_RGB_CHANNELS : Int = 3
const K_SMALL_CUBE : Int = 4
const K_SMALL_CUBE_BITS : Int = 2
const K_LARGE_CUBE : Int = 5
const K_LARGE_CUBE_OFFSET : Int = 64 // 4^3
const K_DELTA_PALETTE_PERIOD : Int = 1 + 2 * (72 - 1)

/// `Scale<4>(value, bit_depth)` from the palette lookup.
fn scale_palette(value : Int, bit_depth : Int) -> Int {
  ((value.to_int64() * ((1L << bit_depth) - 1L)) >> 2).to_int()
}

/// `GetPaletteValue`: map a palette index to a sample for channel `c`,
/// handling the implicit negative-index delta palette and the small/large
/// color cubes beyond the explicit palette (`palette_size` entries).
fn get_palette_value(
  palette : Array[Int],
  index : Int,
  c : Int,
  palette_size : Int,
  bit_depth : Int
) -> Int {
  if index < 0 {
    if c >= K_RGB_CHANNELS {
      return 0
    }
    let mut i = 0 - (index + 1)
    i = i % K_DELTA_PALETTE_PERIOD
    let row = (i + 1) >> 1
    let multiplier = if (i & 1) == 1 { -1 } else { 1 }
    let mut result = k_delta_palette[row * K_RGB_CHANNELS + c] * multiplier
    if bit_depth > 8 {
      result = result * (1 << (bit_depth - 8))
    }
    return result
  }
  if palette_size <= index && index < palette_size + K_LARGE_CUBE_OFFSET {
    if c >= K_RGB_CHANNELS {
      return 0
    }
    let mut i = index - palette_size
    i = i >> (c * K_SMALL_CUBE_BITS)
    return scale_palette(i % K_SMALL_CUBE, bit_depth) + (1 << max0(bit_depth - 3))
  }
  if palette_size + K_LARGE_CUBE_OFFSET <= index {
    if c >= K_RGB_CHANNELS {
      return 0
    }
    let mut i = index - palette_size - K_LARGE_CUBE_OFFSET
    if c == 1 {
      i = i / K_LARGE_CUBE
    } else if c == 2 {
      i = i / (K_LARGE_CUBE * K_LARGE_CUBE)
    }
    return scale_palette(i % K_LARGE_CUBE, bit_depth)
  }
  palette[c * palette_size + index]
}

fn max0(x : Int) -> Int {
  if x > 0 { x } else { 0 }
}

// --- RCT ----------------------------------------------------------------------

/// Undo an RCT (reversible color transform) step starting at channel `begin_c`.
pub fn inv_rct(image : Image, begin_c : Int, rct_type : Int) -> Unit raise @error.JxlError {
  let m = begin_c
  if rct_type == 0 {
    return
  }
  let permutation = rct_type / 7
  let custom = rct_type % 7
  let w = image.channel[m].w
  let h = image.channel[m].h
  if custom == 0 {
    // Permute-only: swap whole channels into the permutation's positions.
    let ch0 = image.channel[m]
    let ch1 = image.channel[m + 1]
    let ch2 = image.channel[m + 2]
    image.channel[m + (permutation % 3)] = ch0
    image.channel[m + ((permutation + 1 + permutation / 3) % 3)] = ch1
    image.channel[m + ((permutation + 2 - permutation / 3) % 3)] = ch2
    return
  }
  let second = custom >> 1
  let third = custom & 1
  let out0 = m + (permutation % 3)
  let out1 = m + ((permutation + 1 + permutation / 3) % 3)
  let out2 = m + ((permutation + 2 - permutation / 3) % 3)
  let mut y = 0
  while y < h {
    let mut x = 0
    while x < w {
      let first = image.channel[m].plane[y * w + x]
      let second_in = image.channel[m + 1].plane[y * w + x]
      let third_in = image.channel[m + 2].plane[y * w + x]
      let (r, g, b) = if custom == 6 {
        // YCoCg.
        let yc = first
        let co = second_in
        let cg = third_in
        let tmp = pixel_add(yc, 0 - (cg >> 1))
        let gg = pixel_add(cg, tmp)
        let bb = pixel_add(tmp, 0 - (co >> 1))
        let rr = pixel_add(bb, co)
        (rr, gg, bb)
      } else {
        let mut thirdv = third_in
        let mut secondv = second_in
        if third == 1 {
          thirdv = pixel_add(thirdv, first)
        }
        if second == 1 {
          secondv = pixel_add(secondv, first)
        } else if second == 2 {
          secondv = pixel_add(secondv, pixel_add(first, thirdv) >> 1)
        }
        (first, secondv, thirdv)
      }
      image.channel[out0].plane[y * w + x] = r
      image.channel[out1].plane[y * w + x] = g
      image.channel[out2].plane[y * w + x] = b
      x = x + 1
    }
    y = y + 1
  }
}

// --- palette -----------------------------------------------------------------

/// Apply a palette transform's structural change (`MetaPalette`): replace the
/// `nb = end_c - begin_c + 1` channels with a single index channel plus an
/// inserted palette channel at the front.
pub fn meta_palette(
  image : Image,
  begin_c : Int,
  end_c : Int,
  nb_colors : Int,
  nb_deltas : Int
) -> Unit raise @error.JxlError {
  let nb = end_c - begin_c + 1
  if begin_c >= image.nb_meta_channels {
    image.nb_meta_channels = image.nb_meta_channels + 1
  } else {
    image.nb_meta_channels = image.nb_meta_channels + 2 - nb
  }
  // Erase the nb - 1 trailing channels (keep the first as the index channel).
  let mut k = begin_c + 1
  while k <= end_c {
    let _ = image.channel.remove(begin_c + 1)
    k = k + 1
  }
  let pch = Channel::create(nb_colors + nb_deltas, nb, -1, -1)
  image.channel.insert(0, pch)
}

/// Undo a palette transform (`InvPalette`): expand the index channel into the
/// `nb` color channels using the palette, then drop the palette channel.
pub fn inv_palette(
  image : Image,
  begin_c : Int,
  nb_colors : Int,
  nb_deltas : Int,
  predictor : Int,
  wp_header : WeightedHeader
) -> Unit raise @error.JxlError {
  if image.nb_meta_channels < 1 {
    raise @error.JxlError::InvalidValue("palette transform without palette")
  }
  let nb = image.channel[0].h
  let c0 = begin_c + 1
  let w = image.channel[c0].w
  let h = image.channel[c0].h
  if nb < 1 {
    raise @error.JxlError::InvalidValue("corrupted palette transform")
  }
  // Insert the nb - 1 output channels after the index channel.
  let mut i = 1
  while i < nb {
    let ch = Channel::create(w, h, image.channel[c0].hshift, image.channel[c0].vshift)
    image.channel.insert(c0 + 1, ch)
    i = i + 1
  }
  let palette = image.channel[0]
  let bit_depth = min(image.bitdepth, 24)

  if w != 0 {
    if nb_deltas != 0 || predictor != PRED_ZERO {
      raise @error.JxlError::InvalidValue(
        "delta palette unsupported (lossless-only decode)"
      )
    }
    let mut y = 0
    while y < h {
      let mut x = 0
      while x < w {
        let index = image.channel[c0].plane[y * w + x]
        let mut c = 0
        while c < nb {
          let v = get_palette_value(palette.plane, index, c, palette.w, bit_depth)
          image.channel[c0 + c].plane[y * w + x] = v
          c = c + 1
        }
        x = x + 1
      }
      y = y + 1
    }
  }
  // The palette channel is a meta-channel; drop it (and its meta count).
  if c0 >= image.nb_meta_channels {
    image.nb_meta_channels = image.nb_meta_channels - 1
  } else {
    image.nb_meta_channels = image.nb_meta_channels - (2 - nb)
  }
  let _ = image.channel.remove(0)
}

// --- squeeze ------------------------------------------------------------------

/// Undo a horizontal squeeze of channel `c` using residual channel `rc`.
fn inv_h_squeeze(image : Image, c : Int, rc : Int) -> Unit {
  let chin = image.channel[c]
  let residual = image.channel[rc]
  if residual.w == 0 {
    let cur = image.channel[c]
    image.channel[c] = Channel::create(cur.w, cur.h, cur.hshift - 1, cur.vshift)
    return
  }
  let chout = Channel::create(
    chin.w + residual.w, chin.h, chin.hshift - 1, chin.vshift
  )
  if residual.h == 0 {
    image.channel[c] = chout
    return
  }
  let mut y = 0
  while y < chin.h {
    let mut x = 0
    while x < residual.w {
      let diff_minus_tendency = residual.plane[y * residual.w + x].to_int64()
      let avg = chin.plane[y * chin.w + x].to_int64()
      let next_avg = if x + 1 < chin.w {
        chin.plane[y * chin.w + x + 1].to_int64()
      } else {
        avg
      }
      let left = if x != 0 {
        chout.plane[y * chout.w + 2 * x - 1].to_int64()
      } else {
        avg
      }
      let tendency = smooth_tendency(left, avg, next_avg)
      let diff = diff_minus_tendency + tendency
      let a = avg + (diff / 2L)
      chout.plane[y * chout.w + 2 * x] = a.to_int()
      chout.plane[y * chout.w + 2 * x + 1] = (a - diff).to_int()
      x = x + 1
    }
    if (chout.w & 1) == 1 {
      chout.plane[y * chout.w + chout.w - 1] = chin.plane[y * chin.w + chin.w - 1]
    }
    y = y + 1
  }
  image.channel[c] = chout
}

/// Undo a vertical squeeze of channel `c` using residual channel `rc`.
fn inv_v_squeeze(image : Image, c : Int, rc : Int) -> Unit {
  let chin = image.channel[c]
  let residual = image.channel[rc]
  if residual.h == 0 {
    let cur = image.channel[c]
    image.channel[c] = Channel::create(cur.w, cur.h, cur.hshift, cur.vshift - 1)
    return
  }
  let chout = Channel::create(
    chin.w, chin.h + residual.h, chin.hshift, chin.vshift - 1
  )
  if residual.w == 0 {
    image.channel[c] = chout
    return
  }
  let mut y = 0
  while y < residual.h {
    let mut x = 0
    while x < chin.w {
      let avg = chin.plane[y * chin.w + x].to_int64()
      let next_avg = if y + 1 < chin.h {
        chin.plane[(y + 1) * chin.w + x].to_int64()
      } else {
        avg
      }
      let top = if y > 0 {
        chout.plane[(2 * y - 1) * chout.w + x].to_int64()
      } else {
        avg
      }
      let diff_minus_tendency = residual.plane[y * residual.w + x].to_int64()
      let tendency = smooth_tendency(top, avg, next_avg)
      let diff = diff_minus_tendency + tendency
      let out = avg + (diff / 2L)
      chout.plane[2 * y * chout.w + x] = out.to_int()
      chout.plane[(2 * y + 1) * chout.w + x] = (out - diff).to_int()
      x = x + 1
    }
    y = y + 1
  }
  if (chout.h & 1) == 1 {
    let y = chin.h - 1
    let mut x = 0
    while x < chin.w {
      chout.plane[2 * y * chout.w + x] = chin.plane[y * chin.w + x]
      x = x + 1
    }
  }
  image.channel[c] = chout
}

/// Undo a squeeze transform (`InvSqueeze`): reverse each squeeze step and drop
/// the residual channels.
pub fn inv_squeeze(image : Image, params : Array[SqueezeParams]) -> Unit raise @error.JxlError {
  let mut i = params.length() - 1
  while i >= 0 {
    let p = params[i]
    let horizontal = p.horizontal
    let in_place = p.in_place
    let beginc = p.begin_c
    let endc = p.begin_c + p.num_c - 1
    let offset = if in_place {
      endc + 1
    } else {
      image.channel.length() + beginc - endc - 1
    }
    if beginc < image.nb_meta_channels {
      image.nb_meta_channels = image.nb_meta_channels - p.num_c
    }
    let mut c = beginc
    while c <= endc {
      let rc = offset + c - beginc
      if horizontal {
        inv_h_squeeze(image, c, rc)
      } else {
        inv_v_squeeze(image, c, rc)
      }
      c = c + 1
    }
    let mut k = 0
    while k < p.num_c {
      let _ = image.channel.remove(offset)
      k = k + 1
    }
    i = i - 1
  }
}

/// Compute the default squeeze parameter list (`DefaultSqueezeParameters`).
fn default_squeeze_parameters(image : Image) -> Array[SqueezeParams] {
  let nb_channels = image.channel.length() - image.nb_meta_channels
  let params : Array[SqueezeParams] = []
  let mut w = image.channel[image.nb_meta_channels].w
  let mut h = image.channel[image.nb_meta_channels].h
  let wide = w > h
  if nb_channels > 2 && image.channel[image.nb_meta_channels + 1].w == w &&
    image.channel[image.nb_meta_channels + 1].h == h {
    // Assume channels +1/+2 are chroma: squeeze them first for 4:2:0 previews.
    params.push({ horizontal: true, in_place: false, begin_c: image.nb_meta_channels + 1, num_c: 2 })
    params.push({ horizontal: false, in_place: false, begin_c: image.nb_meta_channels + 1, num_c: 2 })
  }
  if !wide {
    if h > 8 {
      params.push({ horizontal: false, in_place: true, begin_c: image.nb_meta_channels, num_c: nb_channels })
      h = (h + 1) / 2
    }
  }
  while w > 8 || h > 8 {
    if w > 8 {
      params.push({ horizontal: true, in_place: true, begin_c: image.nb_meta_channels, num_c: nb_channels })
      w = (w + 1) / 2
    }
    if h > 8 {
      params.push({ horizontal: false, in_place: true, begin_c: image.nb_meta_channels, num_c: nb_channels })
      h = (h + 1) / 2
    }
  }
  params
}

/// Apply a squeeze transform's structural change (`MetaSqueeze`): halve each
/// affected channel and insert a residual channel per step.
pub fn meta_squeeze(image : Image, params_in : Array[SqueezeParams]) -> Unit raise @error.JxlError {
  let params = if params_in.length() == 0 {
    default_squeeze_parameters(image)
  } else {
    params_in
  }
  let mut pi = 0
  while pi < params.length() {
    let p = params[pi]
    let horizontal = p.horizontal
    let in_place = p.in_place
    let beginc = p.begin_c
    let endc = p.begin_c + p.num_c - 1
    let offset = if in_place {
      endc + 1
    } else {
      image.channel.length()
    }
    if beginc < image.nb_meta_channels {
      image.nb_meta_channels = image.nb_meta_channels + p.num_c
    }
    let mut c = beginc
    while c <= endc {
      let ch = image.channel[c]
      let mut new_w = ch.w
      let mut new_h = ch.h
      let mut new_hshift = ch.hshift
      let mut new_vshift = ch.vshift
      if horizontal {
        new_w = (new_w + 1) / 2
        if new_hshift >= 0 {
          new_hshift = new_hshift + 1
        }
      } else {
        new_h = (new_h + 1) / 2
        if new_vshift >= 0 {
          new_vshift = new_vshift + 1
        }
      }
      let residual_w = ch.w - new_w
      let residual_h = ch.h - new_h
      image.channel[c] = Channel::create(new_w, new_h, new_hshift, new_vshift)
      let residual = Channel::create(residual_w, residual_h, new_hshift, new_vshift)
      image.channel.insert(offset + (c - beginc), residual)
      c = c + 1
    }
    pi = pi + 1
  }
}

// --- dispatch ------------------------------------------------------------------

/// Undo one transform in place (`Transform::Inverse`).
fn inverse_transform(image : Image, t : Transform, wp_header : WeightedHeader) -> Unit raise @error.JxlError {
  if t.id == TRANSFORM_RCT {
    inv_rct(image, t.begin_c, t.rct_type)
  } else if t.id == TRANSFORM_SQUEEZE {
    inv_squeeze(image, t.squeezes)
  } else if t.id == TRANSFORM_PALETTE {
    inv_palette(image, t.begin_c, t.nb_colors, t.nb_deltas, t.predictor, wp_header)
  } else {
    raise @error.JxlError::InvalidValue("unknown transform id")
  }
}

/// Apply one transform's structural change (`Transform::MetaApply`).
pub fn meta_apply(image : Image, t : Transform) -> Unit raise @error.JxlError {
  if t.id == TRANSFORM_RCT {
    return
  } else if t.id == TRANSFORM_SQUEEZE {
    meta_squeeze(image, t.squeezes)
  } else if t.id == TRANSFORM_PALETTE {
    meta_palette(image, t.begin_c, t.begin_c + t.num_c - 1, t.nb_colors, t.nb_deltas)
  } else {
    raise @error.JxlError::InvalidValue("unknown transform id")
  }
}

/// Undo every pending transform in reverse order (`Image::undo_transforms`).
pub fn undo_transforms(image : Image, wp_header : WeightedHeader) -> Unit raise @error.JxlError {
  while image.transform.length() > 0 {
    let t = image.transform[image.transform.length() - 1]
    inverse_transform(image, t, wp_header)
    let _ = image.transform.remove(image.transform.length() - 1)
  }
}

fn min(a : Int, b : Int) -> Int {
  if a < b { a } else { b }
}
