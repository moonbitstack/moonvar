// A length-prefixed frame, which is the shape most protocols send: a varint
// holding the payload's length, then the payload. The length's own width is not
// known until the payload is, which is what `quic.size` is for.
//
//     moon run src/examples/frame

///|
#coverage.skip
fn main {
  let payload = b"\x01\x02\x03\x04\x05"[:]
  let framed = frame(payload)
  println("framed      \{hex(framed[:])}")
  println("length      \{@quic.decode(framed[:]).unwrap().0}")
  println("payload     \{hex(unframe(framed[:]).unwrap()[:])}")
  // A payload long enough that its length no longer fits in one octet: the
  // same two lines, with a wider number in front.
  let big = Bytes::make(300, b'\x2a')
  let wide = frame(big[:])
  println("300 octets  \{hex(wide[:3])} ... (\{wide.length()} octets in all)")
  println("round trip  \{unframe(wide[:]).unwrap().length() == 300}")
  // A frame that claims more than it carries is refused, not half-read.
  println("refused     \{unframe(b"\x05\x01\x02"[:]) is None}")
}

///|
/// `payload` with its length in front, as QUIC writes a length.
fn frame(payload : BytesView) -> Bytes {
  let buf = Buffer()
  // The length is itself a QUIC varint, so a short payload costs one octet.
  buf.write_bytes(@quic.encode(payload.length().to_uint64()))
  buf.write_bytes(payload.to_owned())
  buf.to_bytes()
}

///|
/// The payload of `b`, or `None` when the frame claims more than it carries.
fn unframe(b : BytesView) -> Bytes? {
  match @quic.decode(b) {
    Some((len, taken)) =>
      if b.length() - taken >= len.to_int() {
        Some(b[taken:taken + len.to_int()].to_owned())
      } else {
        None
      }
    None => None
  }
}

///|
/// Octets as hex, two digits each.
fn hex(b : BytesView) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    let octet = b[i].to_int()
    out.write_char(digits[octet >> 4].unsafe_to_char())
    out.write_char(digits[octet & 0xf].unsafe_to_char())
  }
  out.to_string()
}
