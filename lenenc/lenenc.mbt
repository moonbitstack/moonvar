// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a length-encoded integer was refused: it continues past the end of what it was
/// given, or its first octet is one the protocol reserves for something else.
///
/// `0xfb` is NULL in a row and `0xff` begins an error packet; neither is a number, and a
/// reader that took one for a length would be off by however much followed.
pub(all) suberror Refused {
  Truncated(String)
  Reserved(got~ : Int)
} derive(Eq, Debug)

///|
/// A refusal prints as the fault it is.
pub impl Show for Refused with fn output(self, logger) {
  match self {
    Truncated(m) => logger.write_string("Truncated(" + m + ")")
    Reserved(got~) => logger.write_string("Reserved(got=\{got})")
  }
}

///|
pub extend Refused with Debug::{to_repr}

///|
pub extend Refused with Show::{to_string, output}

///|
pub extend Refused with Eq::{not_equal, equal}

///|
/// `v` as a length-encoded integer: one octet under 251, otherwise a marker saying how
/// many little-endian octets follow.
///
/// The markers are `0xfc` for two, `0xfd` for three and `0xfe` for eight; 251 through 255
/// are never written as a bare first octet, which is what leaves `0xfb` free for NULL and
/// `0xff` for an error packet.
pub fn encode(v : UInt64) -> Bytes {
  let buf = Buffer()
  write(buf, v)
  buf.to_bytes()
}

///|
/// The same, appended to a buffer rather than allocated.
pub fn write(buf : Buffer, v : UInt64) -> Unit {
  if v < 0xfbUL {
    buf.write_byte(v.to_byte())
  } else if v < 0x10000UL {
    buf.write_byte(b'\xfc')
    little(buf, v, 2)
  } else if v < 0x1000000UL {
    buf.write_byte(b'\xfd')
    little(buf, v, 3)
  } else {
    buf.write_byte(b'\xfe')
    little(buf, v, 8)
  }
}

///|
/// How many octets `v` takes, without writing it.
pub fn size(v : UInt64) -> Int {
  if v < 0xfbUL {
    1
  } else if v < 0x10000UL {
    3
  } else if v < 0x1000000UL {
    4
  } else {
    9
  }
}

///|
/// The value at `at` and how many octets it took.
pub fn decode(b : BytesView, at? : Int = 0) -> (UInt64, Int) raise Refused {
  if at < 0 || at >= b.length() {
    raise Truncated("no first octet")
  }
  let first = b[at].to_int()
  if first < 0xfb {
    return (first.to_uint64(), 1)
  }
  let width = match first {
    0xfc => 2
    0xfd => 3
    0xfe => 8
    _ => raise Reserved(got=first)
  }
  if at + 1 + width > b.length() {
    raise Truncated("the value continues past the end")
  }
  let mut out = 0UL
  for i = width - 1; i >= 0; i = i - 1 {
    out = (out << 8) | b[at + 1 + i].to_int().to_uint64()
  }
  (out, 1 + width)
}

///|
/// Append `n` little-endian octets of `v`.
fn little(buf : Buffer, v : UInt64, n : Int) -> Unit {
  for i = 0; i < n; i = i + 1 {
    buf.write_byte((v >> (i * 8)).to_byte())
  }
}
