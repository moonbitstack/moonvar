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

///|
test "signed LEB128 keeps the sign in the last octet's bit six" {
  // DWARF §7.6 and WebAssembly: seven bits a group, and the last group is extended with
  // its own top bit, so 7f is -1 rather than 127.
  assert_eq(hex(encode_signed(0L)), "00")
  assert_eq(hex(encode_signed(1L)), "01")
  assert_eq(hex(encode_signed(-1L)), "7f")
  // 63 is the last positive that fits in six bits of one octet; 64 needs a second, and
  // in the second all seven bits are zero.
  assert_eq(hex(encode_signed(63L)), "3f")
  assert_eq(hex(encode_signed(64L)), "c000")
  // -64 is the last negative that does, because its bit six is the sign.
  assert_eq(hex(encode_signed(-64L)), "40")
  assert_eq(hex(encode_signed(-65L)), "bf7f")
  assert_eq(hex(encode_signed(127L)), "ff00")
  assert_eq(hex(encode_signed(-128L)), "807f")
  assert_eq(hex(encode_signed(-129L)), "ff7e")
  assert_eq(hex(encode_signed(8191L)), "ff3f")
  assert_eq(hex(encode_signed(-8192L)), "8040")
  // Both ends of the sixty-four-bit range, ten octets each.
  assert_eq(hex(encode_signed(9223372036854775807L)), "ffffffffffffffffff00")
  assert_eq(hex(encode_signed(-9223372036854775808L)), "8080808080808080807f")
}

///|
test "a signed value reads back as it was written, at every magnitude" {
  for
    v in [
      0L, 1L, -1L, 2L, -2L, 63L, 64L, -64L, -65L, 127L, 128L, -128L, -129L, 8191L,
      -8192L, 8388607L, -8388608L, 2147483647L, -2147483648L, 2147483648L, -2147483649L,
      9223372036854775807L, -9223372036854775808L, -9223372036854775807L,
    ] {
    let encoded = encode_signed(v)
    assert_eq(
      decode_signed(encoded[:]),
      (v, encoded.length()),
      msg="signed \{v}",
    )
    assert_eq(size_signed(v), encoded.length(), msg="signed size of \{v}")
  }
}

///|
test "signed and unsigned LEB128 differ only where the sign bit lands" {
  // A non-negative value the unsigned form writes without a sign bit is the same run of
  // octets in both, which is why a reader has to be told which one it is holding.
  for v in [0L, 1L, 5L, 63L, 8191L] {
    assert_eq(
      hex(encode_signed(v)),
      hex(encode(v.reinterpret_as_uint64())),
      msg="value \{v}",
    )
  }
  // Above 63 the signed form pays an octet for the sign: 64 is c0 00, not 40.
  assert_eq(hex(encode(64UL)), "40")
  assert_eq(hex(encode_signed(64L)), "c000")
}

///|
test "a signed value that runs off the end, or past ten octets, is refused" {
  for b in [b"", b"\x80", b"\x96", b"\x80\x80\x80"] {
    assert_eq(signed_refused(b) is Truncated(_), true, msg=hex(b))
  }
  assert_eq(
    signed_refused(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01")
    is Exceeded(_),
    true,
  )
}

///|
fn signed_refused(b : Bytes) -> Refused {
  let mut out : Refused? = None
  try {
    let _ = decode_signed(b[:])
  } catch {
    e => out = Some(e)
  }
  match out {
    Some(e) => e
    None => abort("these octets should have been refused")
  }
}

///|
test "a signed value appended to a buffer reads back from its offset" {
  let buf = Buffer()
  write_signed(buf, -1L)
  write_signed(buf, 64L)
  write(buf, 150UL)
  let b = buf.to_bytes()
  assert_eq(hex(b), "7fc0009601")
  assert_eq(decode_signed(b[:]), (-1L, 1))
  assert_eq(decode_signed(b[:], at=1), (64L, 2))
  assert_eq(decode(b[:], at=3), (150UL, 2))
}
