// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a value was refused: it continues past the end of what it was given, or past the
/// ten octets sixty-four bits can occupy.
pub(all) suberror Refused {
  Truncated(String)
  Exceeded(limit~ : Int, got~ : Int)
} derive(Eq, Debug)

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
pub let limit : Int = 10

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
pub fn size(v : UInt64) -> Int {
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
pub fn decode(b : BytesView, at? : Int = 0) -> (UInt64, Int) raise Refused {
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
