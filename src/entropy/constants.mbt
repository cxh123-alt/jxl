///|
/// Shared entropy-coding constants (ISO/IEC 18181-2). The rANS coder uses a
/// 12-bit table (`ANS_TAB_SIZE = 4096`); the prefix (Huffman) coder uses up to
/// 15-bit codes and an 8-bit root lookup table.

pub const ANS_LOG_TAB_SIZE : Int = 12
pub const ANS_TAB_SIZE : UInt = 4096U
pub const ANS_TAB_MASK : UInt = 4095U

pub const ANS_MAX_ALPHABET_SIZE : Int = 256
pub const PREFIX_MAX_ALPHABET_SIZE : Int = 4096
pub const PREFIX_MAX_BITS : Int = 15

pub const ANS_SIGNATURE : UInt = 0x13U

pub const HUFFMAN_TABLE_BITS : Int = 8
