// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which end of a number goes first (RFC 1700 calls the big end "network byte order").
pub(all) enum Order {
  Big
  Little
} derive(Eq, Debug)

///|
/// Big-endian, because every protocol in reach of this package writes that way: IP and
/// everything over it, TLS, QUIC, HTTP/2 and HTTP/3. The exceptions are local formats —
/// MySQL's wire protocol, most file headers — and they say so.
pub let order : Order = Big

///|
/// How many bytes a reader needs past `at` to hold `size` of them.
///
/// Every reader here checks this before it indexes, so a short buffer answers `None`
/// rather than reading past the end or wrapping an offset.
fn fits(b : BytesView, at : Int, size : Int) -> Bool {
  at >= 0 && size >= 0 && at <= b.length() - size
}

///|
/// The octet at `at`, or `None` when the view is shorter than that.
pub fn read_u8(b : BytesView, at? : Int = 0) -> Int? {
  if fits(b, at, 1) {
    Some(b[at].to_int())
  } else {
    None
  }
}

///|
/// The sixteen-bit value at `at`.
pub fn read_u16(b : BytesView, at? : Int = 0, order? : Order = order) -> Int? {
  if !fits(b, at, 2) {
    return None
  }
  let (a, c) = match order {
    Big => (b[at].to_int(), b[at + 1].to_int())
    Little => (b[at + 1].to_int(), b[at].to_int())
  }
  Some((a << 8) | c)
}

///|
/// The twenty-four-bit value at `at`.
///
/// Three-octet lengths are how TLS writes a handshake message (RFC 8446 §4) and how
/// HTTP/2 writes a frame (RFC 9113 §4.1), which is why a width no language has is here.
pub fn read_u24(b : BytesView, at? : Int = 0, order? : Order = order) -> Int? {
  if !fits(b, at, 3) {
    return None
  }
  let (a, c, d) = match order {
    Big => (b[at].to_int(), b[at + 1].to_int(), b[at + 2].to_int())
    Little => (b[at + 2].to_int(), b[at + 1].to_int(), b[at].to_int())
  }
  Some((a << 16) | (c << 8) | d)
}

///|
/// The thirty-two-bit value at `at`.
pub fn read_u32(b : BytesView, at? : Int = 0, order? : Order = order) -> UInt? {
  if !fits(b, at, 4) {
    return None
  }
  let mut out = 0U
  for i = 0; i < 4; i = i + 1 {
    let byte = match order {
      Big => b[at + i].to_int()
      Little => b[at + 3 - i].to_int()
    }
    out = (out << 8) | byte.reinterpret_as_uint()
  }
  Some(out)
}

///|
/// The sixty-four-bit value at `at`.
pub fn read_u64(
  b : BytesView,
  at? : Int = 0,
  order? : Order = order,
) -> UInt64? {
  if !fits(b, at, 8) {
    return None
  }
  let mut out = 0UL
  for i = 0; i < 8; i = i + 1 {
    let byte = match order {
      Big => b[at + i].to_int()
      Little => b[at + 7 - i].to_int()
    }
    out = (out << 8) | byte.to_int64().reinterpret_as_uint64()
  }
  Some(out)
}

///|
/// The signed octet at `at`, two's complement.
pub fn read_i8(b : BytesView, at? : Int = 0) -> Int? {
  match read_u8(b, at~) {
    Some(v) => Some(if v >= 0x80 { v - 0x100 } else { v })
    None => None
  }
}

///|
/// The signed sixteen-bit value at `at`, two's complement.
pub fn read_i16(b : BytesView, at? : Int = 0, order? : Order = order) -> Int? {
  match read_u16(b, at~, order~) {
    Some(v) => Some(if v >= 0x8000 { v - 0x10000 } else { v })
    None => None
  }
}

///|
/// The signed thirty-two-bit value at `at`, two's complement.
pub fn read_i32(b : BytesView, at? : Int = 0, order? : Order = order) -> Int? {
  match read_u32(b, at~, order~) {
    Some(v) => Some(v.reinterpret_as_int())
    None => None
  }
}

///|
/// The signed sixty-four-bit value at `at`, two's complement.
pub fn read_i64(b : BytesView, at? : Int = 0, order? : Order = order) -> Int64? {
  match read_u64(b, at~, order~) {
    Some(v) => Some(v.reinterpret_as_int64())
    None => None
  }
}

///|
/// The IEEE-754 binary32 at `at`.
///
/// The bits are reinterpreted, not converted: a signalling NaN or a negative zero comes
/// back as it was written, which is what a wire format means by a float.
pub fn read_f32(b : BytesView, at? : Int = 0, order? : Order = order) -> Float? {
  match read_u32(b, at~, order~) {
    Some(v) => Some(Float::reinterpret_from_int(v.reinterpret_as_int()))
    None => None
  }
}

///|
/// The IEEE-754 binary64 at `at`.
pub fn read_f64(
  b : BytesView,
  at? : Int = 0,
  order? : Order = order,
) -> Double? {
  match read_u64(b, at~, order~) {
    Some(v) => Some(v.reinterpret_as_double())
    None => None
  }
}

///|
/// Append an octet.
pub fn write_u8(buf : Buffer, v : Int) -> Unit {
  buf.write_byte(v.to_byte())
}

///|
/// Append a sixteen-bit value.
pub fn write_u16(buf : Buffer, v : Int, order? : Order = order) -> Unit {
  match order {
    Big => {
      buf.write_byte((v >> 8).to_byte())
      buf.write_byte(v.to_byte())
    }
    Little => {
      buf.write_byte(v.to_byte())
      buf.write_byte((v >> 8).to_byte())
    }
  }
}

///|
/// Append a twenty-four-bit value.
pub fn write_u24(buf : Buffer, v : Int, order? : Order = order) -> Unit {
  match order {
    Big =>
      for i = 2; i >= 0; i = i - 1 {
        buf.write_byte((v >> (i * 8)).to_byte())
      }
    Little =>
      for i = 0; i < 3; i = i + 1 {
        buf.write_byte((v >> (i * 8)).to_byte())
      }
  }
}

///|
/// Append a thirty-two-bit value.
pub fn write_u32(buf : Buffer, v : UInt, order? : Order = order) -> Unit {
  match order {
    Big =>
      for i = 3; i >= 0; i = i - 1 {
        buf.write_byte((v >> (i * 8)).to_byte())
      }
    Little =>
      for i = 0; i < 4; i = i + 1 {
        buf.write_byte((v >> (i * 8)).to_byte())
      }
  }
}

///|
/// Append a sixty-four-bit value.
pub fn write_u64(buf : Buffer, v : UInt64, order? : Order = order) -> Unit {
  match order {
    Big =>
      for i = 7; i >= 0; i = i - 1 {
        buf.write_byte((v >> (i * 8)).to_byte())
      }
    Little =>
      for i = 0; i < 8; i = i + 1 {
        buf.write_byte((v >> (i * 8)).to_byte())
      }
  }
}

///|
/// Append a signed octet, two's complement.
pub fn write_i8(buf : Buffer, v : Int) -> Unit {
  write_u8(buf, v & 0xff)
}

///|
/// Append a signed sixteen-bit value, two's complement.
pub fn write_i16(buf : Buffer, v : Int, order? : Order = order) -> Unit {
  write_u16(buf, v & 0xffff, order~)
}

///|
/// Append a signed thirty-two-bit value, two's complement.
pub fn write_i32(buf : Buffer, v : Int, order? : Order = order) -> Unit {
  write_u32(buf, v.reinterpret_as_uint(), order~)
}

///|
/// Append a signed sixty-four-bit value, two's complement.
pub fn write_i64(buf : Buffer, v : Int64, order? : Order = order) -> Unit {
  write_u64(buf, v.reinterpret_as_uint64(), order~)
}

///|
/// Append an IEEE-754 binary32, bits as they are.
pub fn write_f32(buf : Buffer, v : Float, order? : Order = order) -> Unit {
  write_u32(buf, v.reinterpret_as_int().reinterpret_as_uint(), order~)
}

///|
/// Append an IEEE-754 binary64, bits as they are.
pub fn write_f64(buf : Buffer, v : Double, order? : Order = order) -> Unit {
  write_u64(buf, v.reinterpret_as_uint64(), order~)
}

///|
/// The value in `size` octets at `at`, for a width the caller only knows at run time.
///
/// The named widths above are what most callers want and read better where they apply.
/// This is for a protocol that spells its own: MySQL's `int<n>` and the three-octet
/// lengths of a Kafka or DNS field are the same arithmetic with `size` carried in a
/// variable, and writing the loop out again per protocol is how the widths drift.
///
/// `None` when `size` is outside one to eight octets, or when the view is shorter than
/// `at` plus `size`.
pub fn read_uint(
  b : BytesView,
  at? : Int = 0,
  size~ : Int,
  order? : Order = order,
) -> UInt64? {
  if size < 1 || size > 8 || !fits(b, at, size) {
    return None
  }
  let mut out = 0UL
  for i = 0; i < size; i = i + 1 {
    let octet = match order {
      Big => b[at + i].to_int()
      Little => b[at + size - 1 - i].to_int()
    }
    out = (out << 8) | octet.to_uint64()
  }
  Some(out)
}

///|
/// Append the low `size` octets of `v`, for a width the caller only knows at run time.
///
/// Octets above `size` are dropped, which is what a protocol that says `int<3>` means by
/// it; a caller that needs to know a value did not fit asks `size` first.
pub fn write_uint(
  buf : Buffer,
  v : UInt64,
  size~ : Int,
  order? : Order = order,
) -> Unit {
  for i = 0; i < size; i = i + 1 {
    let shift = match order {
      Big => (size - 1 - i) * 8
      Little => i * 8
    }
    buf.write_byte((v >> shift).to_byte())
  }
}

///|
/// How many octets `v` needs, which is one for zero and otherwise as many as its highest
/// set bit occupies.
pub fn size(v : UInt64) -> Int {
  let mut n = 1
  let mut rest = v >> 8
  while rest > 0 {
    n = n + 1
    rest = rest >> 8
  }
  n
}

///|
pub extend Order with Debug::{to_repr}

///|
pub extend Order with Eq::{not_equal, equal}
