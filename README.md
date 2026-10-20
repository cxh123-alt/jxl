# cxh123-alt/jxl

A pure-MoonBit, zero-dependency JPEG XL (ISO/IEC 18181) decoder.

`jxl` parses JPEG XL bitstreams — both raw codestreams and ISO-BMFF-style
containers — using only the MoonBit core library. It compiles to native code,
JavaScript, and WebAssembly.

## Features

- **Container handling** — detects a raw codestream (leading `FF 0A`) or a
  `JXL ` container, and extracts the codestream payload from a `jxlc` box or a
  sequence of `jxlp` chunks.
- **LSB-first bit reader** — a forward-only bit reader matching JPEG XL's
  least-significant-bit-first field order.
- **Field codecs** — the bundle wire-format primitives: fixed-width bits,
  booleans, the 4-distribution `U32` coder, the variable-length `U64` coder,
  enumerations, and IEEE 754 binary16 (`F16`).
- **Header decoding** — the size header (including the 1:1 … 2:1 fixed aspect
  ratios and non-divisible-by-8 dimensions), image metadata (bit depth,
  orientation, intrinsic/preview sizes, animation), color encoding (color
  space, white point, primaries, transfer function, custom CIE xy
  chromaticities), extra channels (alpha, depth, spot color, CFA), and tone
  mapping.
- **Entropy decoding** — the full JPEG XL entropy layer: rANS symbol decoding
  (alias tables, 32-bit state machine, LZ77 copy support, final-state check)
  and canonical prefix (Huffman) decoding, plus the histogram reader (simple,
  flat, and log-count representations), the hybrid-uint config reader, and the
  per-context entropy-code table reader (`DecodeANSCodes`).

Lossless Modular sample reconstruction (single-group, single-pass frames) is
implemented: `decode` turns a lossless Modular `.jxl` into flat 8-bit RGBA.
VarDCT (lossy) reconstruction is not yet supported; see [Roadmap](#roadmap).

## Install

```
moon add cxh123-alt/jxl
```

## Usage

```moonbit
let info = @jxl.info(bytes)
println(info.width)   // image width in pixels
println(info.height)  // image height in pixels
println(info.bits)    // bits per sample
println(info.color_space_name)

let line = @jxl.summary(bytes)
println(line)  // e.g. "JPEG XL 512x256, 8-bit RGB, 0 extra channel(s), container"
```

`info` and `summary` accept either a raw codestream or a boxed container.

To reconstruct pixels from a lossless Modular file:

```moonbit
let image = @jxl.decode(bytes)
println(image.width)   // image width in pixels
println(image.height)  // image height in pixels
// image.rgba is a flat, row-major `Array[Int]` of `width * height * 4`
// 8-bit RGBA samples.
```

`decode` supports single-group, single-pass, direct-RGB/grayscale lossless
Modular frames; anything else raises `InvalidValue`.

A runnable demo that decodes several embedded streams is included:

```
moon run demo
```

## Module layout

| Package | Purpose |
| --- | --- |
| `cxh123-alt/jxl` | Public entry points (`info`, `summary`, `decode`) |
| `cxh123-alt/jxl/src/error` | Error type |
| `cxh123-alt/jxl/src/bitio` | LSB-first bit reader |
| `cxh123-alt/jxl/src/field` | Bundle field codecs |
| `cxh123-alt/jxl/src/codestream` | Container, size, color, metadata, parse |
| `cxh123-alt/jxl/src/entropy` | rANS/Huffman tables, histogram, hybrid uint |
| `cxh123-alt/jxl/src/frame` | Frame header, dimensions, TOC |
| `cxh123-alt/jxl/src/modular` | MA tree, channel decode, inverse transforms, RGBA |

## Roadmap

- VarDCT (lossy) transform decoding.
- Multi-group and multi-pass Modular frames.

## License

Apache-2.0.
