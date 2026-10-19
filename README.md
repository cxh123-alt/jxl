# jxl-moonbit/jxl

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

Sample reconstruction (Modular lossless and VarDCT) is in progress; see
[Roadmap](#roadmap).

## Install

```
moon add jxl-moonbit/jxl
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

A runnable demo that decodes several embedded streams is included:

```
moon run demo
```

## Module layout

| Package | Purpose |
| --- | --- |
| `jxl-moonbit/jxl` | Public entry points (`info`, `summary`) |
| `jxl-moonbit/jxl/src/error` | Error type |
| `jxl-moonbit/jxl/src/bitio` | LSB-first bit reader |
| `jxl-moonbit/jxl/src/field` | Bundle field codecs |
| `jxl-moonbit/jxl/src/codestream` | Container, size, color, metadata, parse |
| `jxl-moonbit/jxl/src/entropy` | rANS/Huffman tables, histogram, hybrid uint |

## Roadmap

- Modular (lossless) channel decoding.
- VarDCT (lossy) transform decoding.
- Sample reconstruction to RGBA.

## License

Apache-2.0.
