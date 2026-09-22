// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The widths and their markers are the MySQL protocol's documentation:
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html

///|
fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    let x = b[i].to_int()
    sb.write_char(digits[x >> 4].unsafe_to_char())
    sb.write_char(digits[x & 0xf].unsafe_to_char())
  }
  sb.to_string()
}

///|
test "each width takes the marker the protocol gives it" {
  // Under 251 is the value itself, one octet.
  assert_eq(hex(encode(0UL)), "00")
  assert_eq(hex(encode(250UL)), "fa")
  // 251 is where the two-octet form starts, marked 0xfc and little-endian.
  assert_eq(hex(encode(251UL)), "fcfb00")
  assert_eq(hex(encode(65535UL)), "fcffff")
  // Three octets, marked 0xfd.
  assert_eq(hex(encode(65536UL)), "fd000001")
  assert_eq(hex(encode(16777215UL)), "fdffffff")
  // Eight octets, marked 0xfe.
  assert_eq(hex(encode(16777216UL)), "fe0000000100000000")
  assert_eq(hex(encode(0xffffffffffffffffUL)), "feffffffffffffffff")
}

///|
test "each width reads back, and the width is answered without writing" {
  for
    v in [
      0UL, 1UL, 250UL, 251UL, 65535UL, 65536UL, 16777215UL, 16777216UL, 0xffffffffUL,
      0xffffffffffffffffUL,
    ] {
    let b = encode(v)
    assert_eq(size(v), b.length())
    assert_eq(decode(b[:]), (v, b.length()))
  }
}

///|
test "the markers the protocol keeps for itself are not lengths" {
  // 0xfb is NULL in a row and 0xff begins an error packet; neither is a number.
  assert_eq(refused(b"\xfb"), Reserved(got=0xfb))
  assert_eq(refused(b"\xff"), Reserved(got=0xff))
  // Which is exactly why the one-octet form stops at 250.
  assert_eq(hex(encode(250UL)), "fa")
  assert_eq(encode(251UL)[0].to_int(), 0xfc)
}

///|
test "a value that runs off the end is refused" {
  assert_eq(refused(b"") is Truncated(_), true)
  assert_eq(refused(b"\xfc") is Truncated(_), true)
  assert_eq(refused(b"\xfc\x00") is Truncated(_), true)
  assert_eq(refused(b"\xfd\x00\x00") is Truncated(_), true)
  assert_eq(refused(b"\xfe\x00\x00\x00\x00\x00\x00\x00") is Truncated(_), true)
}

///|
fn refused(b : Bytes) -> Refused {
  let mut out : Refused? = None
  try {
    let _ = decode(b[:])
  } catch {
    e => out = Some(e)
  }
  match out {
    Some(e) => e
    None => abort("these octets should have been refused")
  }
}

///|
test "the offset is where reading starts, and writing appends" {
  assert_eq(decode(b"\xff\xfc\xfb\x00"[:], at=1), (251UL, 3))
  let buf = Buffer()
  write(buf, 5UL)
  write(buf, 300UL)
  assert_eq(hex(buf.to_bytes()), "05fc2c01")
  let b = buf.to_bytes()
  let (a, n) = decode(b[:])
  assert_eq((a, n), (5UL, 1))
  assert_eq(decode(b[:], at=n), (300UL, 3))
}
