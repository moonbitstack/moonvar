// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The three worked integers are RFC 7541 Appendix C.1's.
// https://www.rfc-editor.org/rfc/rfc7541#appendix-C.1

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
test "the three integers RFC 7541 C.1 works out" {
  // C.1.1: ten fits a five-bit prefix.
  assert_eq(hex(encode(10, prefix=5)), "0a")
  // C.1.2: 1337 does not, so the prefix is all ones and the rest continues.
  assert_eq(hex(encode(1337, prefix=5)), "1f9a0a")
  // C.1.3: forty-two at an octet boundary, which is an eight-bit prefix.
  assert_eq(hex(encode(42, prefix=8)), "2a")
  // And each reads back with whatever flag bits sit above the prefix ignored.
  assert_eq(decode(b"\xea"[:], prefix=5), (10, 1))
  assert_eq(decode(b"\xff\x9a\x0a"[:], prefix=5), (1337, 3))
  assert_eq(decode(b"\x2a"[:], prefix=8), (42, 1))
}

///|
test "the flag bits are the caller's and survive the prefix" {
  // HPACK's six representations each set a pattern above the prefix (§6).
  assert_eq(hex(encode(2, prefix=7, flags=0x80)), "82")
  assert_eq(hex(encode(1, prefix=6, flags=0x40)), "41")
  assert_eq(hex(encode(256, prefix=5, flags=0x20)), "3fe101")
  // Decoding masks them off, so the same octets read as the value alone.
  assert_eq(decode(encode(2, prefix=7, flags=0x80)[:], prefix=7), (2, 1))
  assert_eq(decode(encode(256, prefix=5, flags=0x20)[:], prefix=5), (256, 3))
}

///|
test "the width is answered without writing the value" {
  for one in [(10, 5), (1337, 5), (42, 8), (0, 1), (1, 1), (127, 7), (128, 7)] {
    let (v, p) = one
    assert_eq(size(v, prefix=p), encode(v, prefix=p).length())
  }
}

///|
test "every prefix width round-trips across magnitudes" {
  for p = 1; p <= 8; p = p + 1 {
    for v in [0, 1, 2, 126, 127, 128, 255, 256, 16383, 16384, 1000000] {
      let b = encode(v, prefix=p)
      assert_eq(decode(b[:], prefix=p), (v, b.length()))
    }
  }
}

///|
test "a value that runs off the end, or past what an Int holds, is refused" {
  // The prefix says it continues but nothing follows.
  assert_eq(refused(b"\x1f", 5) is Truncated(_), true)
  assert_eq(refused(b"\x1f\x80", 5) is Truncated(_), true)
  assert_eq(refused(b"", 5) is Truncated(_), true)
  // Ten continuation octets is more than a thirty-one bit value can need.
  assert_eq(
    refused(b"\x1f\xff\xff\xff\xff\xff\xff\xff\xff\x7f", 5) is Exceeded(_),
    true,
  )
}

///|
/// What decoding these octets refuses with.
fn refused(b : Bytes, p : Int) -> Refused {
  let mut out : Refused? = None
  try {
    let _ = decode(b[:], prefix=p)
  } catch {
    e => out = Some(e)
  }
  match out {
    Some(e) => e
    None => abort("these octets should have been refused")
  }
}

///|
test "the offset is where reading starts" {
  let b = b"\xff\xff\x9a\x0a"
  assert_eq(decode(b[:], at=1, prefix=5), (1337, 3))
  assert_eq(refused(b"\xff", 5) is Truncated(_), true)
}

///|
test "the high bit of an octet is the Huffman flag both compressions use" {
  assert_eq(flagged(b"\x8c"[:]), true)
  assert_eq(flagged(b"\x0c"[:]), false)
  assert_eq(flagged(b"\x00\x8c"[:], at=1), true)
  // The bit is a knob, because QPACK puts its H at a different place (§4.1.2).
  assert_eq(flagged(b"\x20"[:], bit=5), true)
  assert_eq(flagged(b"\x20"[:], bit=7), false)
  assert_eq(flagged(b""[:]), false)
}
