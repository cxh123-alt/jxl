///|
/// Modular group header and per-channel sample decoding. Ports `GroupHeader`
/// and `DecodeModularChannelMAANS` / `ModularDecode` from libjxl's
/// `modular/transform/transform.h` and `modular/encoding/encoding.cc`.

/// One group's header: whether it reuses the global MA tree, the
/// weighted-predictor coefficients, and the list of transforms.
pub struct GroupHeader {
  use_global_tree : Bool
  wp_header : WeightedHeader
  transforms : Array[Transform]
}

/// Read a `GroupHeader` bundle (`GroupHeader::VisitFields`).
pub fn read_group_header(reader : @bitio.BitReader) -> GroupHeader raise @error.JxlError {
  let use_global_tree = @field.read_bool(reader)
  let wp_header = read_weighted_header(reader)
  let num_transforms = @field.read_u32(
    reader,
    @field.val(0U),
    @field.val(1U),
    @field.bits_offset(4U, 2U),
    @field.bits_offset(8U, 18U)
  ).reinterpret_as_int()
  let transforms : Array[Transform] = []
  let mut i = 0
  while i < num_transforms {
    transforms.push(read_transform(reader))
    i = i + 1
  }
  {
    use_global_tree: use_global_tree,
    wp_header: wp_header,
    transforms: transforms,
  }
}

/// Absolute value of a sample, computed in 64 bits so that `-Int::min_value`
/// (which cannot be represented in 32 bits) still matches the reference.
fn abs_sample(x : Int) -> Int {
  if x < 0 {
    (0L - x.to_int64()).to_int()
  } else {
    x
  }
}

/// Decode one channel's samples with the meta-adaptive tree (`MAANS`).
///
/// This is the general (`PredictTreeWP` / `PredictTreeNoWP`) path: it computes
/// the full property set per pixel, runs the weighted predictor when the tree
/// uses it, looks up the leaf in the flattened tree, decodes the hybrid-uint
/// residual, and adds the prediction.
fn decode_channel_maans(
  reader : @bitio.BitReader,
  ans_reader : @entropy.ANSSymbolReader,
  context_map : Array[Int],
  global_tree : Array[TreeNode],
  wp_header : WeightedHeader,
  chan : Int,
  group_id : Int,
  image : Image
) -> Unit raise @error.JxlError {
  let channel = image.channel[chan]
  if channel.w == 0 || channel.h == 0 {
    return
  }
  let static_props = [chan, group_id]
  let (flat_tree, num_props, use_wp, _wp_only, _gradient_only) =
    filter_tree(global_tree, static_props)
  // From here on, tree lookup returns a *clustered* context ID, so map each
  // leaf's childID (a 0-based leaf index) through the context map.
  let mut ni = 0
  while ni < flat_tree.length() {
    let node = flat_tree[ni]
    if node.property0 == -1 {
      flat_tree[ni] = {
        property0: node.property0,
        splitval0: node.splitval0,
        splitvals0: node.splitvals0,
        splitvals1: node.splitvals1,
        properties0: node.properties0,
        properties1: node.properties1,
        childID: context_map[node.childID],
      }
    }
    ni = ni + 1
  }
  let properties : Array[Int] = []
  let mut pi = 0
  while pi < num_props {
    properties.push(0)
    pi = pi + 1
  }
  let refw = num_props - K_NUM_NONREF_PROPERTIES
  let references = Channel::create(refw, channel.w, 0, 0)
  let wp_state = WeightedState::new(wp_header, channel.w)
  let plane = channel.plane
  let w = channel.w
  let h = channel.h
  let mut y = 0
  while y < h {
    init_props_row(properties, chan, group_id, y)
    if refw > 0 {
      precompute_references(image.channel, chan, y, w, references)
    }
    let mut x = 0
    while x < w {
      let idx = y * w + x
      let left = if x != 0 { plane[idx - 1] } else if y != 0 { plane[idx - w] } else { 0 }
      let top = if y != 0 { plane[idx - w] } else { left }
      let topleft = if x != 0 && y != 0 { plane[idx - w - 1] } else { left }
      let topright = if x + 1 < w && y != 0 { plane[idx - w + 1] } else { top }
      let leftleft = if x > 1 { plane[idx - 2] } else { left }
      let toptop = if y > 1 { plane[idx - 2 * w] } else { top }
      let toprightright = if x + 2 < w && y != 0 { plane[idx - w + 2] } else { topright }
      properties[3] = x
      properties[4] = abs_sample(top)
      properties[5] = abs_sample(left)
      properties[6] = top
      properties[7] = left
      // Local gradient: [8] is `left` minus the *previous* pixel's gradient
      // (still held in [9]), then [9] is overwritten with the current gradient.
      properties[8] = (left.to_int64() - properties[9].to_int64()).to_int()
      properties[9] = (left.to_int64() + top.to_int64() - topleft.to_int64()).to_int()
      properties[10] = (left.to_int64() - topleft.to_int64()).to_int()
      properties[11] = (topleft.to_int64() - top.to_int64()).to_int()
      properties[12] = (top.to_int64() - topright.to_int64()).to_int()
      properties[13] = (top.to_int64() - toptop.to_int64()).to_int()
      properties[14] = (left.to_int64() - leftleft.to_int64()).to_int()
      let mut wp_pred = 0L
      if use_wp {
        wp_pred = wp_state.predict(x, y, w, top, left, topright, topleft, toptop, properties, K_WP_PROP)
      }
      let mut ri = 0
      while ri < refw {
        properties[K_NUM_NONREF_PROPERTIES + ri] = references.plane[x * refw + ri]
        ri = ri + 1
      }
      let res = mat_lookup(flat_tree, properties)
      let guess = res.offset.to_int64() +
        predict_one(res.predictor, left, top, toptop, topleft, topright, leftleft, toprightright, wp_pred)
      let v = ans_reader.read_hybrid_uint_clustered(res.context, reader)
      let val = (unpack_signed(v).to_int64() * res.multiplier.to_int64() + guess).to_int()
      plane[idx] = val
      if use_wp {
        wp_state.update_errors(val, x, y)
      }
      x = x + 1
    }
    y = y + 1
  }
}

/// Decode a modular image's group header, apply its transforms' structural
/// changes, and entropy-decode every channel (`ModularDecode`). Returns the
/// group header so the caller can later undo the transforms with its
/// weighted-predictor coefficients.
///
/// `max_chan_size` is the group dimension (256 for a single group): channels
/// larger than it belong to later groups and are left untouched here.
pub fn modular_decode(
  reader : @bitio.BitReader,
  image : Image,
  group_id : Int,
  max_chan_size : Int,
  global_tree : Array[TreeNode],
  global_code : @entropy.ANSCode,
  global_ctx_map : Array[Int]
) -> GroupHeader raise @error.JxlError {
  let header = read_group_header(reader)
  image.transform = header.transforms
  let mut ti = 0
  while ti < header.transforms.length() {
    meta_apply(image, header.transforms[ti])
    ti = ti + 1
  }
  let nb_channels = image.channel.length()
  let mut num_chans = 0
  let mut distance_multiplier = 0
  let mut i = 0
  while i < nb_channels {
    let channel = image.channel[i]
    if i >= image.nb_meta_channels && (channel.w > max_chan_size || channel.h > max_chan_size) {
      break
    }
    if channel.w != 0 && channel.h != 0 {
      if channel.w > distance_multiplier {
        distance_multiplier = channel.w
      }
      num_chans = num_chans + 1
    }
    i = i + 1
  }
  if num_chans != 0 {
    let (tree, code, ctx_map) = if !header.use_global_tree {
      let t = decode_tree(reader)
      let (c, cm) = @entropy.decode_histograms(reader, (t.length() + 1) / 2, false)
      (t, c, cm)
    } else {
      (global_tree, global_code, global_ctx_map)
    }
    let initial_state = if code.uses_prefix_code() {
      0U
    } else {
      reader.read_bits(32)
    }
    let ans_reader = @entropy.ANSSymbolReader::new(code, initial_state, distance_multiplier)
    let mut ci = 0
    while ci < nb_channels {
      let channel = image.channel[ci]
      if ci >= image.nb_meta_channels && (channel.w > max_chan_size || channel.h > max_chan_size) {
        break
      }
      if channel.w != 0 && channel.h != 0 {
        decode_channel_maans(reader, ans_reader, ctx_map, tree, header.wp_header, ci, group_id, image)
      }
      ci = ci + 1
    }
    if !ans_reader.check_ans_final_state() {
      raise @error.JxlError::InvalidValue("ANS decode final state failed")
    }
  }
  header
}
