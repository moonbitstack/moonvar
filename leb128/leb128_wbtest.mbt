// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The worked values are protobuf's own documentation:
// https://protobuf.dev/programming-guides/encoding/#varints

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
test "the values protobuf's encoding guide works out" {
  // One is one octet; 150 is two, groups least significant first.
  assert_eq(hex(encode(1UL)), "01")
  assert_eq(hex(encode(150UL)), "9601")
  // 127 is the last that fits an octet, 128 the first that does not.
  assert_eq(hex(encode(127UL)), "7f")
  assert_eq(hex(encode(128UL)), "8001")
  assert_eq(hex(encode(0UL)), "00")
  // And each reads back.
  assert_eq(decode(b"\x01"[:]), (1UL, 1))
  assert_eq(decode(b"\x96\x01"[:]), (150UL, 2))
  assert_eq(decode(b"\x7f"[:]), (127UL, 1))
  assert_eq(decode(b"\x80\x01"[:]), (128UL, 2))
}

///|
test "sixty-four bits takes ten octets and no more" {
  let all = 0xffffffffffffffffUL
  assert_eq(encode(all).length(), 10)
  assert_eq(size(all), 10)
  assert_eq(decode(encode(all)[:]), (all, 10))
  assert_eq(limit, 10)
}

///|
test "the width is answered without writing the value" {
  for
    v in [
      0UL, 1UL, 127UL, 128UL, 16383UL, 16384UL, 0xffffffffUL, 0xffffffffffffffffUL,
    ] {
    assert_eq(size(v), encode(v).length())
    assert_eq(decode(encode(v)[:]), (v, size(v)))
  }
}

///|
test "zigzag keeps a small magnitude short, either sign" {
  // protobuf's own table.
  assert_eq(zigzag(0L), 0UL)
  assert_eq(zigzag(-1L), 1UL)
  assert_eq(zigzag(1L), 2UL)
  assert_eq(zigzag(-2L), 3UL)
  assert_eq(zigzag(2L), 4UL)
  assert_eq(zigzag(2147483647L), 4294967294UL)
  assert_eq(zigzag(-2147483648L), 4294967295UL)
  // And back.
  for
    v in [
      0L, 1L, -1L, 2L, -2L, 2147483647L, -2147483648L, 9223372036854775807L, -9223372036854775808L,
    ] {
    assert_eq(unzigzag(zigzag(v)), v)
  }
  // Without it, -1 sign-extends and takes every octet; with it, one.
  assert_eq(encode(zigzag(-1L)).length(), 1)
  assert_eq(encode((-1L).reinterpret_as_uint64()).length(), 10)
}

///|
test "a value that runs off the end, or past ten octets, is refused" {
  assert_eq(refused(b"\x80") is Truncated(_), true)
  assert_eq(refused(b"") is Truncated(_), true)
  assert_eq(refused(b"\x96") is Truncated(_), true)
  // Eleven continuation octets is one past what sixty-four bits can occupy.
  assert_eq(
    refused(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01") is Exceeded(_),
    true,
  )
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
  assert_eq(decode(b"\xff\x96\x01"[:], at=1), (150UL, 2))
  let buf = Buffer()
  write(buf, 1UL)
  write(buf, 150UL)
  write(buf, 0UL)
  assert_eq(hex(buf.to_bytes()), "01960100")
  // Reading them back in order walks the offsets.
  let b = buf.to_bytes()
  let (a, n) = decode(b[:])
  assert_eq((a, n), (1UL, 1))
  let (c, m) = decode(b[:], at=n)
  assert_eq((c, m), (150UL, 2))
  assert_eq(decode(b[:], at=n + m), (0UL, 1))
}
