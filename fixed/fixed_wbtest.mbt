// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn hexb(h : String) -> Bytes {
  let buf = Buffer()
  for i = 0; i < h.length(); i = i + 2 {
    buf.write_byte(
      ((nib(h[i].to_int()) << 4) | nib(h[i + 1].to_int())).to_byte(),
    )
  }
  buf.to_bytes()
}

///|
fn nib(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else {
    0
  }
}

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
fn bytes(f : (Buffer) -> Unit) -> Bytes {
  let buf = Buffer()
  f(buf)
  buf.to_bytes()
}

///|
test "each width writes the octets its order puts them in" {
  assert_eq(hex(bytes(b => write_u8(b, 0x12))), "12")
  assert_eq(hex(bytes(b => write_u16(b, 0x1234))), "1234")
  assert_eq(hex(bytes(b => write_u16(b, 0x1234, order=Little))), "3412")
  assert_eq(hex(bytes(b => write_u24(b, 0x123456))), "123456")
  assert_eq(hex(bytes(b => write_u24(b, 0x123456, order=Little))), "563412")
  assert_eq(hex(bytes(b => write_u32(b, 0x12345678))), "12345678")
  assert_eq(hex(bytes(b => write_u32(b, 0x12345678, order=Little))), "78563412")
  assert_eq(
    hex(bytes(b => write_u64(b, 0x123456789abcdef0UL))),
    "123456789abcdef0",
  )
  assert_eq(
    hex(bytes(b => write_u64(b, 0x123456789abcdef0UL, order=Little))),
    "f0debc9a78563412",
  )
}

///|
test "each width reads back what it wrote, either way round" {
  assert_eq(read_u8(hexb("12")[:]), Some(0x12))
  assert_eq(read_u16(hexb("1234")[:]), Some(0x1234))
  assert_eq(read_u16(hexb("1234")[:], order=Little), Some(0x3412))
  assert_eq(read_u24(hexb("123456")[:]), Some(0x123456))
  assert_eq(read_u24(hexb("123456")[:], order=Little), Some(0x563412))
  assert_eq(read_u32(hexb("12345678")[:]), Some(0x12345678U))
  assert_eq(read_u32(hexb("12345678")[:], order=Little), Some(0x78563412U))
  assert_eq(read_u64(hexb("123456789abcdef0")[:]), Some(0x123456789abcdef0UL))
  assert_eq(
    read_u64(hexb("123456789abcdef0")[:], order=Little),
    Some(0xf0debc9a78563412UL),
  )
}

///|
test "the offset is where reading starts, and the default is the front" {
  let b = hexb("00112233445566778899aabbccddeeff")
  assert_eq(read_u8(b[:], at=0), Some(0x00))
  assert_eq(read_u8(b[:], at=15), Some(0xff))
  assert_eq(read_u16(b[:], at=2), Some(0x2233))
  assert_eq(read_u32(b[:], at=4), Some(0x44556677U))
  assert_eq(read_u64(b[:], at=8), Some(0x8899aabbccddeeffUL))
  // Reading with no offset is reading at the front.
  assert_eq(read_u16(b[:]), read_u16(b[:], at=0))
}

///|
test "a view too short answers None rather than reading past the end" {
  let b = hexb("0011223344556677")
  // One octet short of each width.
  assert_eq(read_u16(b[0:1]), None)
  assert_eq(read_u24(b[0:2]), None)
  assert_eq(read_u32(b[0:3]), None)
  assert_eq(read_u64(b[0:7]), None)
  // An offset that leaves too little behind it.
  assert_eq(read_u32(b[:], at=5), None)
  assert_eq(read_u64(b[:], at=1), None)
  // An offset off either end.
  assert_eq(read_u8(b[:], at=8), None)
  assert_eq(read_u8(b[:], at=-1), None)
  assert_eq(read_u8(b""[:]), None)
  // And the exact fit still reads.
  assert_eq(read_u64(b[:], at=0) is Some(_), true)
}

///|
test "the signed widths are two's complement, both directions" {
  assert_eq(read_i8(hexb("ff")[:]), Some(-1))
  assert_eq(read_i8(hexb("80")[:]), Some(-128))
  assert_eq(read_i8(hexb("7f")[:]), Some(127))
  assert_eq(read_i16(hexb("ffff")[:]), Some(-1))
  assert_eq(read_i16(hexb("8000")[:]), Some(-32768))
  assert_eq(read_i32(hexb("ffffffff")[:]), Some(-1))
  assert_eq(read_i32(hexb("80000000")[:]), Some(-2147483648))
  assert_eq(read_i64(hexb("ffffffffffffffff")[:]), Some(-1L))
  // And what they write reads back.
  for v in [0, 1, -1, 127, -128] {
    assert_eq(read_i8(bytes(b => write_i8(b, v))[:]), Some(v))
  }
  for v in [0, 1, -1, 32767, -32768] {
    assert_eq(read_i16(bytes(b => write_i16(b, v))[:]), Some(v))
  }
  for v in [0, 1, -1, 2147483647, -2147483648] {
    assert_eq(read_i32(bytes(b => write_i32(b, v))[:]), Some(v))
  }
  for v in [0L, 1L, -1L, 9223372036854775807L, -9223372036854775808L] {
    assert_eq(read_i64(bytes(b => write_i64(b, v))[:]), Some(v))
  }
}

///|
test "a float is its bits, not its value" {
  // IEEE-754 binary32 and binary64 for one, which every reference prints.
  assert_eq(hex(bytes(b => write_f32(b, 1.0))), "3f800000")
  assert_eq(hex(bytes(b => write_f64(b, 1.0))), "3ff0000000000000")
  assert_eq(read_f32(hexb("3f800000")[:]), Some((1.0 : Float)))
  assert_eq(read_f64(hexb("3ff0000000000000")[:]), Some(1.0))
  // A negative zero keeps its sign bit through the round trip, which a conversion
  // through a value rather than through the bits would lose.
  assert_eq(hex(bytes(b => write_f64(b, -0.0))), "8000000000000000")
  guard read_f64(hexb("8000000000000000")[:]) is Some(back) else {
    fail("a negative zero should read back")
  }
  assert_eq(back == 0.0, true)
  assert_eq(hex(bytes(b => write_f64(b, back))), "8000000000000000")
  // And the order applies to a float as to anything else.
  assert_eq(hex(bytes(b => write_f32(b, 1.0, order=Little))), "0000803f")
}

///|
test "the preset order is the big end, which is what the network writes" {
  assert_eq(order, Big)
  assert_eq(
    hex(bytes(b => write_u32(b, 1))),
    hex(bytes(b => write_u32(b, 1, order=Big))),
  )
  assert_eq(read_u32(hexb("00000001")[:]), Some(1U))
}

///|
test "the widths round-trip across their whole range" {
  for v in [0, 1, 0x7f, 0x80, 0xff, 0x1234, 0xffff] {
    assert_eq(read_u16(bytes(b => write_u16(b, v))[:]), Some(v))
    assert_eq(
      read_u16(bytes(b => write_u16(b, v, order=Little))[:], order=Little),
      Some(v),
    )
  }
  for v in [0, 1, 0xffff, 0x10000, 0xffffff] {
    assert_eq(read_u24(bytes(b => write_u24(b, v))[:]), Some(v))
  }
  for v in [0U, 1U, 0xffffU, 0xffffffffU] {
    assert_eq(read_u32(bytes(b => write_u32(b, v))[:]), Some(v))
  }
  for v in [0UL, 1UL, 0xffffffffUL, 0xffffffffffffffffUL] {
    assert_eq(read_u64(bytes(b => write_u64(b, v))[:]), Some(v))
  }
}

///|
test "a width carried in a variable is the same arithmetic as a named one" {
  // What the named widths do, `size` does, either way round.
  assert_eq(
    read_uint(hexb("1234")[:], size=2),
    read_u16(hexb("1234")[:]).map(v => v.to_uint64()),
  )
  assert_eq(
    read_uint(hexb("123456")[:], size=3, order=Little),
    read_u24(hexb("123456")[:], order=Little).map(v => v.to_uint64()),
  )
  assert_eq(read_uint(hexb("12345678")[:], size=4), Some(0x12345678UL))
  assert_eq(
    read_uint(hexb("123456789abcdef0")[:], size=8, order=Little),
    Some(0xf0debc9a78563412UL),
  )
  // And the widths no named function has, which is why this exists.
  assert_eq(read_uint(hexb("010203040506")[:], size=6), Some(0x010203040506UL))
  assert_eq(
    hex(bytes(b => write_uint(b, 0x010203040506UL, size=6))),
    "010203040506",
  )
  assert_eq(
    hex(bytes(b => write_uint(b, 0x010203040506UL, size=6, order=Little))),
    "060504030201",
  )
  // Octets above the width are dropped, which is what `int<n>` means by it.
  assert_eq(hex(bytes(b => write_uint(b, 0x1234UL, size=1))), "34")
  // A width outside one to eight octets is not a width.
  assert_eq(read_uint(hexb("12")[:], size=0), None)
  assert_eq(read_uint(hexb("123456789abcdef012")[:], size=9), None)
  // And a view too short still answers rather than reading past the end.
  assert_eq(read_uint(hexb("1234")[:], size=3), None)
  assert_eq(read_uint(hexb("1234")[:], at=1, size=2), None)
}

///|
test "the width a value needs is one octet per eight bits it occupies" {
  assert_eq(size(0UL), 1)
  assert_eq(size(255UL), 1)
  assert_eq(size(256UL), 2)
  assert_eq(size(0xffffffUL), 3)
  assert_eq(size(0xffffffffffffffffUL), 8)
  // Which is the width that round-trips it.
  for v in [0UL, 1UL, 255UL, 256UL, 0x010203040506UL, 0xffffffffffffffffUL] {
    let n = size(v)
    assert_eq(
      read_uint(bytes(b => write_uint(b, v, size=n))[:], size=n),
      Some(v),
    )
  }
}
