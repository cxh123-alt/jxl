///|
/// Field codecs for the JPEG XL "bundle" wire format.
///
/// A bundle is a forward/backward-compatible collection of fields. Individual
/// fields use a small set of codecs: raw bits, booleans, a 4-distribution
/// unsigned-32 coder, a variable-length unsigned-64 coder, enumerations, and
/// IEEE 754 half-precision floats. See ISO/IEC 18181-2 and libjxl's
/// `fields.cc` for the reference implementation.

/// Build a direct U32 distribution: the value itself, signalled in 2 bits.
pub fn val(v : UInt) -> UInt {
  v | 0x8000_0000U
}

/// Build an offset U32 distribution: `n` extra bits with an implicit 0 offset.
pub fn bits(n : UInt) -> UInt {
  (n - 1U) & 0x1FU
}

/// Build an offset U32 distribution: `n` extra bits added to `offset`.
pub fn bits_offset(n : UInt, offset : UInt) -> UInt {
  ((n - 1U) & 0x1FU) | ((offset & 0x03FF_FFFFU) << 5)
}

/// Read a fixed-width unsigned field.
pub fn read_bits(reader : @bitio.BitReader, n : Int) -> UInt raise @error.JxlError {
  reader.read_bits(n)
}

/// Read a single-bit boolean field.
pub fn read_bool(reader : @bitio.BitReader) -> Bool raise @error.JxlError {
  reader.read_bit() != 0
}

/// Read a U32 field governed by four distributions chosen via a 2-bit selector.
pub fn read_u32(
  reader : @bitio.BitReader,
  d0 : UInt,
  d1 : UInt,
  d2 : UInt,
  d3 : UInt
) -> UInt raise @error.JxlError {
  let selector = reader.read_bits(2)
  let d = if selector == 0U {
    d0
  } else if selector == 1U {
    d1
  } else if selector == 2U {
    d2
  } else {
    d3
  }
  if (d & 0x8000_0000U) != 0U {
    d & 0x7FFF_FFFFU
  } else {
    let extra = (d & 0x1FU).reinterpret_as_int() + 1
    let offset = (d >> 5) & 0x03FF_FFFFU
    reader.read_bits(extra) + offset
  }
}

/// Read a U64 field (variable-length unsigned 64-bit integer).
pub fn read_u64(reader : @bitio.BitReader) -> UInt64 raise @error.JxlError {
  let selector = reader.read_bits(2)
  if selector == 0U {
    return 0UL
  }
  if selector == 1U {
    return reader.read_bits(4).to_uint64() + 1UL
  }
  if selector == 2U {
    return reader.read_bits(8).to_uint64() + 17UL
  }
  // Selector 3: varint, groups of first 12 bits, then 8 bits each, with the
  // final group holding the top 4 bits.
  let mut result : UInt64 = reader.read_bits(12).to_uint64()
  let mut shift : Int = 12
  while true {
    let cont = reader.read_bits(1)
    if cont == 0U {
      break
    }
    if shift == 60 {
      result = result | (reader.read_bits(4).to_uint64() << shift)
      break
    }
    result = result | (reader.read_bits(8).to_uint64() << shift)
    shift = shift + 8
  }
  result
}

/// Read an enum field using the standard enum distribution.
pub fn read_enum(reader : @bitio.BitReader) -> UInt raise @error.JxlError {
  read_u32(reader, val(0U), val(1U), bits_offset(4U, 2U), bits_offset(6U, 18U))
}

/// Read an IEEE 754 half-precision float (binary16), widened to `Float`.
pub fn read_f16(reader : @bitio.BitReader) -> Float raise @error.JxlError {
  let bits16 = reader.read_bits(16)
  let sign = bits16 >> 15
  let biased_exp = (bits16 >> 10) & 0x1FU
  let mantissa = bits16 & 0x03FFU
  if biased_exp == 31U {
    raise @error.JxlError::InvalidValue("F16 infinity or NaN are not supported")
  }
  if biased_exp == 0U {
    // Subnormal or zero: value = mantissa * 2^-24.
    let v : Double = (1.0 / 16384.0) * (mantissa.to_double() * (1.0 / 1024.0))
    let signed : Double = if sign == 1U { -v } else { v }
    return Float::from_double(signed)
  }
  // Normalized: widen to binary32 by adjusting the exponent bias.
  let biased_exp32 = biased_exp + (127U - 15U)
  let mantissa32 = mantissa << 13
  let bits32 = (sign << 31) | (biased_exp32 << 23) | mantissa32
  Float::reinterpret_from_uint(bits32)
}
