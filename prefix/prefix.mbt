// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Why a prefix integer was refused.
///
/// `Truncated` is a value that continues past the end of what it was given; `Exceeded` is
/// one that needs more than a positive `Int` can hold. RFC 7541 §5.1 makes a value larger
/// than the implementation's limit a decoding error, and an encoding of the same value in
/// more octets than necessary is one too — a receiver that read either would disagree
/// with the sender about what came next.
pub(all) suberror Refused {
  Truncated(String)
  Exceeded(limit~ : Int64, got~ : Int64)
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
/// The largest value this reads, which is what a positive `Int` holds.
///
/// §5.1 leaves the ceiling to the implementation and asks for a decoding error past it,
/// so a peer cannot make a reader loop over continuation octets for as long as it likes.
pub let limit : Int64 = 0x7fffffffL

///|
/// `v` in the low `prefix` bits of the first octet, continuing into further octets when
/// it does not fit (RFC 7541 §5.1).
///
/// `flags` are the bits above the prefix, which every representation using this encoding
/// puts something in: HPACK's six field representations and QPACK's five each begin with
/// a pattern there. They are OR'd into the first octet and are the caller's to get right.
///
/// The three worked examples of Appendix C: ten in a five-bit prefix is one octet,
/// 1337 in five bits is three, and forty-two at an octet boundary is one.
pub fn encode(v : Int, prefix~ : Int, flags? : Int = 0) -> Bytes {
  let buf = Buffer()
  let ceiling = (1 << prefix) - 1
  if v < ceiling {
    buf.write_byte((flags | v).to_byte())
  } else {
    buf.write_byte((flags | ceiling).to_byte())
    let mut rest = v - ceiling
    while rest >= 128 {
      buf.write_byte((rest % 128 + 128).to_byte())
      rest = rest / 128
    }
    buf.write_byte(rest.to_byte())
  }
  buf.to_bytes()
}

///|
/// How many octets `v` takes in a `prefix`-bit prefix, without writing it.
pub fn size(v : Int, prefix~ : Int) -> Int {
  let ceiling = (1 << prefix) - 1
  if v < ceiling {
    return 1
  }
  let mut n = 1
  let mut rest = v - ceiling
  while rest >= 128 {
    n = n + 1
    rest = rest / 128
  }
  n + 1
}

///|
/// The value at `at` and how many octets it took, with the flag bits above the prefix
/// masked off and ignored (RFC 7541 §5.1).
pub fn decode(
  b : BytesView,
  at? : Int = 0,
  prefix~ : Int,
) -> (Int, Int) raise Refused {
  if at < 0 || at >= b.length() {
    raise Truncated("no prefix octet")
  }
  let ceiling = (1 << prefix) - 1
  let first = b[at].to_int() & ceiling
  if first < ceiling {
    return (first, 1)
  }
  // Accumulate in sixty-four bits and refuse anything past a positive `Int`, so a
  // truncated or over-long continuation is an error rather than a read past the end or
  // a wrapped value.
  let mut out = ceiling.to_int64()
  let mut shift = 0
  let mut used = 1
  for ;; {
    if at + used >= b.length() {
      raise Truncated("the value continues past the end")
    }
    if shift >= 35 {
      raise Exceeded(limit~, got=out)
    }
    let octet = b[at + used].to_int()
    used = used + 1
    out = out + (octet & 127).to_int64() * (1L << shift)
    shift = shift + 7
    if out > limit {
      raise Exceeded(limit~, got=out)
    }
    if (octet & 128) == 0 {
      break
    }
  }
  (out.to_int(), used)
}

///|
/// Whether the octet at `at` has its high bit set — the `H` bit of a string literal in
/// both header compressions, which says the octets after the length are Huffman-coded
/// (RFC 7541 §5.2, RFC 9204 §4.1.2).
pub fn flagged(b : BytesView, at? : Int = 0, bit? : Int = 7) -> Bool {
  at >= 0 && at < b.length() && (b[at].to_int() & (1 << bit)) != 0
}
