///|
/// Runnable demo for the JPEG XL decoder: decode several embedded streams and
/// print their parsed image info, then reconstruct the pixels of a real
/// lossless Modular stream.
///
/// Run with: `moon run demo`

// Minimal 32x32 raw codestream (all-default metadata, 8-bit RGB).
let minimal : Bytes = b"\xFF\x0A\x47\x02"

// A 512x256 image selected via the 2:1 fixed aspect ratio.
let widescreen : Bytes = b"\xFF\x0A\xFF\x03"

// The same minimal codestream wrapped in an ISO-BMFF container.
let boxed : Bytes =
  b"\x00\x00\x00\x0C\x4A\x58\x4C\x20\x0D\x0A\x87\x0A" +
  b"\x00\x00\x00\x0C\x6A\x78\x6C\x63\xFF\x0A\x47\x02"

// A 64x64, 16-bit image with one alpha channel and orientation 2.
let rich : Bytes = b"\xFF\x0A\x4F\x0C\xFC\x0C\x00\x06"

// A real 8x8 lossless Modular codestream: a solid (200, 30, 40) RGB image.
let solid_8x8 : Bytes =
  b"\xff\x0a\x41\x40\x40\x71\x21\x08\x02\x01\x00\xa8\x02\x4b\x18\x9b\x9c\x71\x84\x03\x38\x80\x03\x38\x20\x4a\xc0\x39\x05\x01\x00\x20\x44\x80\x08\x10\x01\x22\x40\xe4\xff\x91\x7b\xfa\x1e\x5a\x67\x57\x55\x55\x55\x25\x49\x92\x10\x50\x77\x77\x77\x77\x77\xff\xff\xff\xbf\x55\x6f\x66\x66\x66\x86\xe7\xbf\xbf\xe7\xff\x0b\x1a\x6b\xae\xb5\xf6\x3e\xf7\x46\x44\x44\x44\x10\x50\x66\x66\x66\x66\x66\x56\x55\xd5\x7d\xef\x77\x77\x77\x77\xc3\xff\xfb\xf7\xfc\xf7\xd0\x98\x73\xce\xb5\xf6\xb9\x37\x49\x92\x84\x80\xaa\xaa\xaa\xaa\xaa\xea\xff\xff\xff\xb9\xf7\x75\x77\x77\x77\xc3\xff\xfb\xf7\xfc\xf7\xd0\x98\x73\xce\xb5\xf6\xb9\x37\x49\x92\x84\x80\xaa\xaa\xaa\xaa\xaa\xea\xff\xff\xff\xb9\xf7\x75\x77\x77\x77\x5f\x20\x04\x00\x0f\x48\x8f\x29\x17\x0a\x80\x2f\x08"

// Garbage input exercises the error path.
let garbage : Bytes = b"\x00\x01\x02\x03"

fn main {
  show("minimal 32x32", minimal)
  show("512x256 (2:1)", widescreen)
  show("boxed container", boxed)
  show("64x64 16-bit + alpha", rich)
  show_decode("8x8 solid (200,30,40)", solid_8x8)
  show("garbage", garbage)
}

fn show_decode(label : String, data : Bytes) -> Unit {
  println("== \{label} ==")
  let _ = try {
    let img = @jxl.decode(data)
    let mut sum = 0
    let mut i = 0
    while i < img.rgba.length() {
      sum = (sum + img.rgba[i]) % 1000003
      i = i + 1
    }
    println("  decoded       : \{img.width}x\{img.height} rgba checksum \{sum}")
    println("  first pixel   : rgba(\{img.rgba[0]}, \{img.rgba[1]}, \{img.rgba[2]}, \{img.rgba[3]})")
  } catch {
    e => println("  error: \{e.message()}")
  }
  println("")
}

fn show(label : String, data : Bytes) -> Unit {
  println("== \{label} ==")
  let _ = try {
    let i = @jxl.info(data)
    println("  \{@jxl.summary(data)}")
    println("  orientation  : \{i.orientation}")
    println("  floating     : \{i.floating_point}")
    println("  xyb encoded  : \{i.xyb_encoded}")
  } catch {
    e => println("  error: \{e.message()}")
  }
  println("")
}
