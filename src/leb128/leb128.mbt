// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a value was refused: it continues past the end of what it was given, or past the
/// ten octets sixty-four bits can occupy.
#derive(Eq, Debug)
pub(all) suberror Refused {
  Truncated(String)
  Exceeded(limit~ : Int32, got~ : Int32)
}

///|
/// A refusal prints as the fault it is.
pub impl Show for Refused with fn output(self, logger) {
  match self {
    Truncated(m) => logger.write_string("Truncated(" + m + ")")
    Exceeded(limit~, got~) =>
      logger.write_string("Exceeded(limit=\{limit}, got=\{got})")
  }
}

///|
pub extend Refused with Debug::{to_repr}

///|
pub extend Refused with Show::{to_string, output}

///|
pub extend Refused with Eq::{not_equal, equal}

///|
/// How many octets sixty-four bits can occupy: nine of seven bits and one of the last.
///
/// A reader that did not stop here would follow continuation bits for as long as a peer
/// cared to send them.
pub let limit : Int32 = 10

///|
/// `v` as base-128 octets: seven bits each, least significant group first, the high bit
/// set on every octet but the last.
///
/// This is protobuf's "Base 128 Varints" and DWARF's unsigned LEB128, which are the same
/// encoding under two names.
pub fn encode(v : UInt64) -> Bytes {
  let buf = Buffer()
  write(buf, v)
  buf.to_bytes()
}

///|
/// The same, appended to a buffer rather than allocated.
pub fn write(buf : Buffer, v : UInt64) -> Unit {
  let mut rest = v
  while rest >= 0x80 {
    buf.write_byte(((rest & 0x7f) | 0x80).to_byte())
    rest = rest >> 7
  }
  buf.write_byte(rest.to_byte())
}

///|
/// How many octets `v` takes, without writing it.
pub fn size(v : UInt64) -> Int32 {
  let mut n = 1
  let mut rest = v >> 7
  while rest > 0 {
    n = n + 1
    rest = rest >> 7
  }
  n
}

///|
/// The value at `at` and how many octets it took.
pub fn decode(b : BytesView, at~ : Int32 = 0) -> (UInt64, Int32) raise Refused {
  let mut out = 0UL
  let mut shift = 0
  let mut used = 0
  for ;; {
    if used >= limit {
      raise Exceeded(limit~, got=used + 1)
    }
    if at + used >= b.length() || at < 0 {
      raise Truncated("the value continues past the end")
    }
    let octet = b[at + used].to_int()
    used = used + 1
    out = out | ((octet & 0x7f).to_uint64() << shift)
    if (octet & 0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  (out, used)
}

///|
/// `v` as signed LEB128: seven bits an octet, least significant group first, with the
/// high bit of the last octet doubling as the value's sign bit.
///
/// This is the form DWARF writes a signed attribute in (§7.6) and WebAssembly writes an
/// `i32.const` in. It is not protobuf's signed varint: that one folds the sign onto an
/// unsigned value and encodes that, which is what `zigzag` and `encode` do together. The
/// difference shows at -64, one octet here (`40`) and two the other way (`7f`).
pub fn encode_signed(v : Int64) -> Bytes {
  let buf = Buffer()
  write_signed(buf, v)
  buf.to_bytes()
}

///|
/// The same, appended to a buffer rather than allocated.
pub fn write_signed(buf : Buffer, v : Int64) -> Unit {
  let mut rest = v
  let mut more = true
  while more {
    let octet = (rest & 0x7fL).to_int()
    // An arithmetic shift, so a negative value fills the gap with ones and reaches
    // -1 rather than growing a tail of zero groups.
    rest = rest >> 7
    let sign = (octet & 0x40) != 0
    more = !((rest == 0L && !sign) || (rest == -1L && sign))
    buf.write_byte((if more { octet | 0x80 } else { octet }).to_byte())
  }
}

///|
/// How many octets a signed value takes, without writing it.
pub fn size_signed(v : Int64) -> Int32 {
  let mut n = 1
  let mut rest = v
  for ;; {
    let sign = (rest & 0x40L) != 0L
    rest = rest >> 7
    if (rest == 0L && !sign) || (rest == -1L && sign) {
      break
    }
    n = n + 1
  }
  n
}

///|
/// The signed value at `at` and how many octets it took.
///
/// The last group's bit six is the sign, and the value is extended with it: `7f` is -1
/// rather than 127, and `40` is -64.
pub fn decode_signed(
  b : BytesView,
  at~ : Int32 = 0,
) -> (Int64, Int32) raise Refused {
  let mut out = 0L
  let mut shift = 0
  let mut used = 0
  for ;; {
    if used >= limit {
      raise Exceeded(limit~, got=used + 1)
    }
    if at < 0 || at + used >= b.length() {
      raise Truncated("the value continues past the end")
    }
    let octet = b[at + used].to_int()
    used = used + 1
    if shift < 64 {
      out = out | ((octet & 0x7f).to_int64() << shift)
    }
    if (octet & 0x80) == 0 {
      if (octet & 0x40) != 0 && shift + 7 < 64 {
        out = out | (-1L << (shift + 7))
      }
      break
    }
    shift = shift + 7
  }
  (out, used)
}

///|
/// A signed value folded onto an unsigned one so that small magnitudes stay short:
/// `-1` becomes 1, `1` becomes 2, `-2` becomes 3 (protobuf's `sint32` and `sint64`).
///
/// Without it a negative value would sign-extend to sixty-four bits and take all ten
/// octets, whatever its magnitude.
pub fn zigzag(v : Int64) -> UInt64 {
  ((v << 1) ^ (v >> 63)).reinterpret_as_uint64()
}

///|
/// The inverse: an unsigned value unfolded back onto a signed one.
pub fn unzigzag(v : UInt64) -> Int64 {
  // The shift has to be logical, not arithmetic: done on the signed value, the top
  // half of the range would come back with its sign smeared and `Int64::MAX` would
  // read as `-1`.
  (v >> 1).reinterpret_as_int64() ^ -(v & 1UL).reinterpret_as_int64()
}
