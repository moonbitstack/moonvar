// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The largest value the encoding can carry: sixty-two bits (RFC 9000 §16).
pub let max : UInt64 = 0x3fffffffffffffffUL

///|
/// Encode `v` as a QUIC variable-length integer (RFC 9000 §16) in the shortest
/// form that holds it: the two most-significant bits of the first byte select the
/// length (00 → 1 byte / 6-bit value, 01 → 2 / 14-bit, 10 → 4 / 30-bit, 11 → 8 /
/// 62-bit) and the remaining bits carry the value big-endian.
///
/// A value above `max` has no encoding here, and the first two bits of it would silently
/// become the width the reader believed: the call aborts rather than write a number that
/// reads back as a different one.
pub fn encode(v : UInt64) -> Bytes {
  let buf = Buffer()
  write(buf, v)
  buf.to_bytes()
}

///|
/// The same, appended to a buffer rather than allocated.
pub fn write(buf : Buffer, v : UInt64) -> Unit {
  if v <= 0x3fUL {
    buf.write_byte(v.to_byte())
  } else if v <= 0x3fffUL {
    buf.write_byte((0x40UL | (v >> 8)).to_byte())
    buf.write_byte(v.to_byte())
  } else if v <= 0x3fffffffUL {
    buf.write_byte((0x80UL | (v >> 24)).to_byte())
    buf.write_byte((v >> 16).to_byte())
    buf.write_byte((v >> 8).to_byte())
    buf.write_byte(v.to_byte())
  } else if v <= max {
    buf.write_byte((0xc0UL | (v >> 56)).to_byte())
    buf.write_byte((v >> 48).to_byte())
    buf.write_byte((v >> 40).to_byte())
    buf.write_byte((v >> 32).to_byte())
    buf.write_byte((v >> 24).to_byte())
    buf.write_byte((v >> 16).to_byte())
    buf.write_byte((v >> 8).to_byte())
    buf.write_byte(v.to_byte())
  } else {
    abort("a QUIC varint carries sixty-two bits at most")
  }
}

///|
/// Decode a QUIC variable-length integer at `at`, returning its value and the number
/// of bytes it occupied, or `None` when the bytes from `at` are fewer than the length
/// its first byte's prefix declares.
pub fn decode(b : BytesView, at~ : Int32 = 0) -> (UInt64, Int32)? {
  if at < 0 || at >= b.length() {
    return None
  }
  let first = b[at].to_int()
  let length = 1 << (first >> 6)
  if b.length() - at < length {
    return None
  }
  let mut v = (first & 0x3f).to_uint64()
  for i = 1; i < length; i = i + 1 {
    v = (v << 8) | b[at + i].to_int().to_uint64()
  }
  Some((v, length))
}

///|
/// How many octets `v` takes, without writing it.
///
/// A writer that has to put a length before a payload needs this: the length field's own
/// size is part of what it describes, and measuring twice is cheaper than writing twice.
pub fn size(v : UInt64) -> Int32 {
  if v <= 0x3fUL {
    1
  } else if v <= 0x3fffUL {
    2
  } else if v <= 0x3fffffffUL {
    4
  } else {
    8
  }
}
