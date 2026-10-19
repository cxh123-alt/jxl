///|
/// Runnable demo for the JPEG XL header decoder: decode several embedded
/// JPEG XL streams — a raw codestream, a boxed container, a 2:1 image, and a
/// 16-bit image with an alpha channel — and print the parsed image info.
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

// Garbage input exercises the error path.
let garbage : Bytes = b"\x00\x01\x02\x03"

fn main {
  show("minimal 32x32", minimal)
  show("512x256 (2:1)", widescreen)
  show("boxed container", boxed)
  show("64x64 16-bit + alpha", rich)
  show("garbage", garbage)
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
