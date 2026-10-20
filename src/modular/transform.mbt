///|
/// Global modular transform headers: RCT, palette, and squeeze. This ports the
/// `Transform::VisitFields` and `SqueezeParams::VisitFields` read orders from
/// libjxl's `modular/transform/transform.cc` and `squeeze_params.cc`, restricted
/// to the lossless decoding path (no near-lossless / delta-palette encoding).

pub const TRANSFORM_RCT : UInt = 0U
pub const TRANSFORM_PALETTE : UInt = 1U
pub const TRANSFORM_SQUEEZE : UInt = 2U
pub const TRANSFORM_INVALID : UInt = 3U

/// A single squeeze step (Haar-style sub-sampling in one direction).
pub struct SqueezeParams {
  horizontal : Bool
  in_place : Bool
  begin_c : Int
  num_c : Int
}

/// One global modular transform (RCT, palette, or squeeze).
pub struct Transform {
  id : UInt
  begin_c : Int
  rct_type : Int
  num_c : Int
  nb_colors : Int
  nb_deltas : Int
  predictor : Int
  squeezes : Array[SqueezeParams]
}

/// The unsigned-32 field for `begin_c` shared by RCT/palette and squeeze.
fn begin_c_u32(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  @field.read_u32(
    reader,
    @field.bits(3U),
    @field.bits_offset(6U, 8U),
    @field.bits_offset(10U, 72U),
    @field.bits_offset(13U, 1096U)
  )
}

/// Read one `SqueezeParams` bundle (`SqueezeParams::VisitFields`).
pub fn read_squeeze_params(reader : @bitio.BitReader) -> SqueezeParams raise @error.JxlError {
  let horizontal = @field.read_bool(reader)
  let in_place = @field.read_bool(reader)
  let begin_c = begin_c_u32(reader).reinterpret_as_int()
  let num_c = @field.read_u32(
    reader,
    @field.val(1U),
    @field.val(2U),
    @field.val(3U),
    @field.bits_offset(4U, 4U)
  ).reinterpret_as_int()
  {
    horizontal: horizontal,
    in_place: in_place,
    begin_c: begin_c,
    num_c: num_c,
  }
}

/// Read one `Transform` bundle (`Transform::VisitFields`).
pub fn read_transform(reader : @bitio.BitReader) -> Transform raise @error.JxlError {
  let id = @field.read_u32(
    reader,
    @field.val(TRANSFORM_RCT),
    @field.val(TRANSFORM_PALETTE),
    @field.val(TRANSFORM_SQUEEZE),
    @field.val(TRANSFORM_INVALID)
  )
  if id == TRANSFORM_INVALID {
    raise @error.JxlError::InvalidValue("invalid transform id")
  }
  let mut begin_c = 0
  if id == TRANSFORM_RCT || id == TRANSFORM_PALETTE {
    begin_c = begin_c_u32(reader).reinterpret_as_int()
  }
  let mut rct_type = 6
  if id == TRANSFORM_RCT {
    rct_type = @field.read_u32(
      reader,
      @field.val(6U),
      @field.bits(2U),
      @field.bits_offset(4U, 2U),
      @field.bits_offset(6U, 10U)
    ).reinterpret_as_int()
    if rct_type >= 42 {
      raise @error.JxlError::InvalidValue("invalid transform RCT type")
    }
  }
  let mut num_c = 3
  let mut nb_colors = 0
  let mut nb_deltas = 0
  let mut predictor = 0
  if id == TRANSFORM_PALETTE {
    num_c = @field.read_u32(
      reader,
      @field.val(1U),
      @field.val(3U),
      @field.val(4U),
      @field.bits_offset(13U, 1U)
    ).reinterpret_as_int()
    nb_colors = @field.read_u32(
      reader,
      @field.bits_offset(8U, 0U),
      @field.bits_offset(10U, 256U),
      @field.bits_offset(12U, 1280U),
      @field.bits_offset(16U, 5376U)
    ).reinterpret_as_int()
    nb_deltas = @field.read_u32(
      reader,
      @field.val(0U),
      @field.bits_offset(8U, 1U),
      @field.bits_offset(10U, 257U),
      @field.bits_offset(16U, 1281U)
    ).reinterpret_as_int()
    predictor = reader.read_bits(4).reinterpret_as_int()
    if predictor >= 14 {
      raise @error.JxlError::InvalidValue("invalid predictor")
    }
  }
  let squeezes : Array[SqueezeParams] = []
  if id == TRANSFORM_SQUEEZE {
    let num_squeezes = @field.read_u32(
      reader,
      @field.val(0U),
      @field.bits_offset(4U, 1U),
      @field.bits_offset(6U, 9U),
      @field.bits_offset(8U, 41U)
    ).reinterpret_as_int()
    let mut i = 0
    while i < num_squeezes {
      squeezes.push(read_squeeze_params(reader))
      i = i + 1
    }
  }
  {
    id: id,
    begin_c: begin_c,
    rct_type: rct_type,
    num_c: num_c,
    nb_colors: nb_colors,
    nb_deltas: nb_deltas,
    predictor: predictor,
    squeezes: squeezes,
  }
}
