///|
/// Modular image model: a set of `Channel`s (each a flat array of `pixel_type`
/// samples with its own dimensions and subsampling shifts) plus the ordered
/// list of transforms that must be undone. Ports `modular_image.h`.

/// One modular sample plane, stored row-major as a flat `Array[Int]`.
pub struct Channel {
  plane : Array[Int]
  w : Int
  h : Int
  hshift : Int
  vshift : Int
}

/// Allocate a zeroed `w`-by-`h` channel with subsampling shifts.
pub fn Channel::create(w : Int, h : Int, hshift : Int, vshift : Int) -> Channel {
  let plane : Array[Int] = []
  let mut i = 0
  while i < w * h {
    plane.push(0)
    i = i + 1
  }
  { plane: plane, w: w, h: h, hshift: hshift, vshift: vshift }
}

/// Allocate a zeroed full-resolution `w`-by-`h` channel.
pub fn Channel::new(w : Int, h : Int) -> Channel {
  Channel::create(w, h, 0, 0)
}

/// Replace the sample plane with a zeroed `new_w`-by-`new_h` one, keeping the
/// shifts (`Channel::shrink` in the reference reallocates a fresh zeroed plane).
pub fn Channel::shrink(self : Channel, new_w : Int, new_h : Int) -> Channel {
  Channel::create(new_w, new_h, self.hshift, self.vshift)
}

/// A collection of channels and the transforms that produced their current
/// shape (which must be undone in reverse order to recover the image).
pub struct Image {
  mut channel : Array[Channel]
  mut transform : Array[Transform]
  w : Int
  h : Int
  bitdepth : Int
  mut nb_meta_channels : Int
}

/// Allocate an image with `nb_chans` full-resolution channels.
pub fn Image::new(w : Int, h : Int, bitdepth : Int, nb_chans : Int) -> Image {
  let channels : Array[Channel] = []
  let mut i = 0
  while i < nb_chans {
    channels.push(Channel::new(w, h))
    i = i + 1
  }
  {
    channel: channels,
    transform: [],
    w: w,
    h: h,
    bitdepth: bitdepth,
    nb_meta_channels: 0,
  }
}

/// Number of channels currently present.
pub fn Image::num_channels(self : Image) -> Int {
  self.channel.length()
}

/// Replace the channel list with `new_channels` (used by transform undo).
fn Image::set_channels(self : Image, new_channels : Array[Channel]) -> Unit {
  self.channel = new_channels
}
