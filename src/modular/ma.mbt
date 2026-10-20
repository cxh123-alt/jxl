///|
/// Meta-adaptive (MA) trees: the predictor enum, the decision-tree node model,
/// and the `DecodeTree` port from `modular/encoding/dec_ma.cc`. Also holds
/// `FilterTree` and the flattened tree lookup used during channel decoding.

// Predictor enum values (decoder-only subset; Best/Variable never serialized).
pub const PRED_ZERO : Int = 0
pub const PRED_LEFT : Int = 1
pub const PRED_TOP : Int = 2
pub const PRED_AVERAGE0 : Int = 3
pub const PRED_SELECT : Int = 4
pub const PRED_GRADIENT : Int = 5
pub const PRED_WEIGHTED : Int = 6
pub const PRED_TOP_RIGHT : Int = 7
pub const PRED_TOP_LEFT : Int = 8
pub const PRED_LEFT_LEFT : Int = 9
pub const PRED_AVERAGE1 : Int = 10
pub const PRED_AVERAGE2 : Int = 11
pub const PRED_AVERAGE3 : Int = 12
pub const PRED_AVERAGE4 : Int = 13
pub const K_NUM_MODULAR_PREDICTORS : Int = 14

// MA tree context indices (`ma_common.h`).
const K_PROPERTY_CONTEXT : Int = 0
const K_PREDICTOR_CONTEXT : Int = 1
const K_OFFSET_CONTEXT : Int = 2
const K_MULTIPLIER_LOG_CONTEXT : Int = 3
const K_MULTIPLIER_BITS_CONTEXT : Int = 4
const K_SPLITVAL_CONTEXT : Int = 5
const K_NUM_TREE_CONTEXTS : Int = 6
const K_MAX_TREE_SIZE : Int = 1 << 22

// Static property count and property slots (`options.h` / `context_predict.h`).
pub const K_NUM_STATIC_PROPERTIES : Int = 2
pub const K_NUM_NONREF_PROPERTIES : Int = 16
pub const K_EXTRA_PROPS_PER_CHANNEL : Int = 4
pub const K_WP_PROP : Int = 15
pub const K_GRADIENT_PROP : Int = 9

/// Unpack a PackSigned value back to its signed 32-bit value.
pub fn unpack_signed(v : UInt) -> Int {
  if v % 2U == 0U {
    (v / 2U).reinterpret_as_int()
  } else {
    0 - ((v + 1U) / 2U).reinterpret_as_int()
  }
}

/// One node of the decoded MA tree: a leaf (`property == -1`) or a split.
pub struct TreeNode {
  property : Int
  splitval : Int
  lchild : Int
  rchild : Int
  predictor : Int
  predictor_offset : Int
  multiplier : Int
}

fn leaf_node(predictor : Int, offset : Int, multiplier : Int, leaf_id : Int) -> TreeNode {
  {
    property: -1,
    splitval: 0,
    lchild: leaf_id,
    rchild: 0,
    predictor: predictor,
    predictor_offset: offset,
    multiplier: multiplier,
  }
}

fn split_node(property : Int, splitval : Int, lchild : Int, rchild : Int) -> TreeNode {
  {
    property: property,
    splitval: splitval,
    lchild: lchild,
    rchild: rchild,
    predictor: PRED_ZERO,
    predictor_offset: 0,
    multiplier: 1,
  }
}

/// Decode the MA tree body from its ANS stream (inner `DecodeTree` overload).
fn decode_tree_body(
  reader : @bitio.BitReader,
  ans_reader : @entropy.ANSSymbolReader,
  context_map : Array[Int],
  tree : Array[TreeNode],
  tree_size_limit : Int
) -> Unit raise @error.JxlError {
  let mut leaf_id = 0
  let mut to_decode = 1
  while to_decode > 0 {
    if tree.length() > tree_size_limit {
      raise @error.JxlError::InvalidValue("tree is too large")
    }
    to_decode = to_decode - 1
    let prop1 = ans_reader.read_hybrid_uint_clustered(
      context_map[K_PROPERTY_CONTEXT], reader
    ).reinterpret_as_int()
    let property = prop1 - 1
    if property == -1 {
      let predictor = ans_reader.read_hybrid_uint_clustered(
        context_map[K_PREDICTOR_CONTEXT], reader
      ).reinterpret_as_int()
      if predictor >= K_NUM_MODULAR_PREDICTORS {
        raise @error.JxlError::InvalidValue("invalid predictor")
      }
      let predictor_offset = unpack_signed(ans_reader.read_hybrid_uint_clustered(
        context_map[K_OFFSET_CONTEXT], reader
      ))
      let mul_log = ans_reader.read_hybrid_uint_clustered(
        context_map[K_MULTIPLIER_LOG_CONTEXT], reader
      )
      if mul_log >= 31U {
        raise @error.JxlError::InvalidValue("invalid multiplier logarithm")
      }
      let mul_bits = ans_reader.read_hybrid_uint_clustered(
        context_map[K_MULTIPLIER_BITS_CONTEXT], reader
      )
      if mul_bits >= ((1U << (31 - mul_log.reinterpret_as_int())) - 1U) {
        raise @error.JxlError::InvalidValue("invalid multiplier")
      }
      let multiplier = ((mul_bits + 1U) << mul_log.reinterpret_as_int()).reinterpret_as_int()
      tree.push(leaf_node(predictor, predictor_offset, multiplier, leaf_id))
      leaf_id = leaf_id + 1
      continue
    }
    let splitval = unpack_signed(ans_reader.read_hybrid_uint_clustered(
      context_map[K_SPLITVAL_CONTEXT], reader
    ))
    let l = tree.length() + to_decode + 1
    let r = tree.length() + to_decode + 2
    tree.push(split_node(property, splitval, l, r))
    to_decode = to_decode + 2
  }
}

/// Decode a meta-adaptive tree plus its entropy tables (`DecodeTree`).
pub fn decode_tree(reader : @bitio.BitReader) -> Array[TreeNode] raise @error.JxlError {
  let (code, context_map) = @entropy.decode_histograms(reader, K_NUM_TREE_CONTEXTS, false)
  let initial_state = if code.use_prefix_code { 0U } else { reader.read_bits(32) }
  let ans_reader = @entropy.ANSSymbolReader::new(code, initial_state, 0)
  let tree : Array[TreeNode] = []
  decode_tree_body(reader, ans_reader, context_map, tree, K_MAX_TREE_SIZE)
  if !ans_reader.check_ans_final_state() {
    raise @error.JxlError::InvalidValue("ANS decode final state failed")
  }
  tree
}

/// One node of the flattened tree produced by `filter_tree`.
pub struct FlatDecisionNode {
  property0 : Int
  splitval0 : Int
  splitvals0 : Int
  splitvals1 : Int
  properties0 : Int
  properties1 : Int
  childID : Int
}

/// The result of a flattened-tree lookup.
pub struct LookupResult {
  context : Int
  predictor : Int
  offset : Int
  multiplier : Int
}

fn mark_property(
  p : Int,
  has_wp : Bool,
  has_non_wp : Bool,
  gradient_only : Bool
) -> (Bool, Bool, Bool) {
  let mut hw = has_wp
  let mut hnw = has_non_wp
  let mut go = gradient_only
  if p == K_WP_PROP {
    hw = true
  } else if p >= K_NUM_STATIC_PROPERTIES {
    hnw = true
  }
  if p >= K_NUM_STATIC_PROPERTIES && p != K_GRADIENT_PROP {
    go = false
  }
  (hw, hnw, go)
}

/// Remove static-property splits (decidable now) and collapse two levels of the
/// tree into a flattened form (`FilterTree`). Returns the flat tree, the number
/// of properties, and the `use_wp` / `wp_only` / `gradient_only` flags.
pub fn filter_tree(
  global_tree : Array[TreeNode],
  static_props : Array[Int]
) -> (Array[FlatDecisionNode], Int, Bool, Bool, Bool) {
  let mut num_props = 0
  let mut has_wp = false
  let mut has_non_wp = false
  let mut gradient_only = true
  let queue : Array[Int] = []
  queue.push(0)
  let mut qhead = 0
  let output : Array[FlatDecisionNode] = []
  while qhead < queue.length() {
    let mut cur = queue[qhead]
    qhead = qhead + 1
    while global_tree[cur].property < K_NUM_STATIC_PROPERTIES && global_tree[cur].property != -1 {
      if static_props[global_tree[cur].property] > global_tree[cur].splitval {
        cur = global_tree[cur].lchild
      } else {
        cur = global_tree[cur].rchild
      }
    }
    if global_tree[cur].property == -1 {
      let node = global_tree[cur]
      let flat = {
        property0: -1,
        splitval0: node.predictor,
        splitvals0: node.multiplier,
        splitvals1: 0,
        properties0: node.predictor_offset,
        properties1: 0,
        childID: node.lchild,
      }
      gradient_only = gradient_only && node.predictor == PRED_GRADIENT
      has_wp = has_wp || node.predictor == PRED_WEIGHTED
      has_non_wp = has_non_wp || node.predictor != PRED_WEIGHTED
      output.push(flat)
      continue
    }
    let child_id = output.length() + (queue.length() - qhead) + 1
    let property0 = global_tree[cur].property
    if property0 + 1 > num_props {
      num_props = property0 + 1
    }
    let splitval0 = global_tree[cur].splitval
    let mut props0 = 0
    let mut props1 = 0
    let mut splitvals0 = 0
    let mut splitvals1 = 0
    let mut i = 0
    while i < 2 {
      let mut cur_child = if i == 0 { global_tree[cur].lchild } else { global_tree[cur].rchild }
      while global_tree[cur_child].property < K_NUM_STATIC_PROPERTIES &&
        global_tree[cur_child].property != -1 {
        if static_props[global_tree[cur_child].property] > global_tree[cur_child].splitval {
          cur_child = global_tree[cur_child].lchild
        } else {
          cur_child = global_tree[cur_child].rchild
        }
      }
      if global_tree[cur_child].property == -1 {
        if i == 0 {
          props0 = 0
          splitvals0 = 0
        } else {
          props1 = 0
          splitvals1 = 0
        }
        queue.push(cur_child)
        queue.push(cur_child)
      } else {
        let p = global_tree[cur_child].property
        let sv = global_tree[cur_child].splitval
        if i == 0 {
          props0 = p
          splitvals0 = sv
        } else {
          props1 = p
          splitvals1 = sv
        }
        queue.push(global_tree[cur_child].lchild)
        queue.push(global_tree[cur_child].rchild)
        if p + 1 > num_props {
          num_props = p + 1
        }
      }
      i = i + 1
    }
    let (hw, hnw, go) = mark_property(props0, has_wp, has_non_wp, gradient_only)
    has_wp = hw
    has_non_wp = hnw
    gradient_only = go
    let (hw2, hnw2, go2) = mark_property(props1, has_wp, has_non_wp, gradient_only)
    has_wp = hw2
    has_non_wp = hnw2
    gradient_only = go2
    let (hw3, hnw3, go3) = mark_property(property0, has_wp, has_non_wp, gradient_only)
    has_wp = hw3
    has_non_wp = hnw3
    gradient_only = go3
    output.push({
      property0: property0,
      splitval0: splitval0,
      splitvals0: splitvals0,
      splitvals1: splitvals1,
      properties0: props0,
      properties1: props1,
      childID: child_id,
    })
  }
  if num_props > K_NUM_NONREF_PROPERTIES {
    num_props = ((num_props - K_NUM_NONREF_PROPERTIES + K_EXTRA_PROPS_PER_CHANNEL - 1) /
      K_EXTRA_PROPS_PER_CHANNEL) * K_EXTRA_PROPS_PER_CHANNEL + K_NUM_NONREF_PROPERTIES
  } else {
    num_props = K_NUM_NONREF_PROPERTIES
  }
  let use_wp = has_wp
  let wp_only = has_wp && !has_non_wp
  (output, num_props, use_wp, wp_only, gradient_only)
}

/// Traverse the flattened tree for the given properties (`MATreeLookup::Lookup`).
pub fn mat_lookup(nodes : Array[FlatDecisionNode], properties : Array[Int]) -> LookupResult {
  let mut pos = 0
  let mut done = false
  let mut result = { context: 0, predictor: 0, offset: 0, multiplier: 0 }
  while !done {
    let node = nodes[pos]
    if node.property0 < 0 {
      result = {
        context: node.childID,
        predictor: node.splitval0,
        offset: node.properties0,
        multiplier: node.splitvals0,
      }
      done = true
    } else {
      let p0 = properties[node.property0] <= node.splitval0
      let off = if p0 {
        2 + (if properties[node.properties1] <= node.splitvals1 { 0 } else { 1 })
      } else {
        (if properties[node.properties0] <= node.splitvals0 { 0 } else { 1 })
      }
      pos = node.childID + off
    }
  }
  result
}
