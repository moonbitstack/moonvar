---
name: moonvar
description: "Write and read numbers as octets in MoonBit with moonbitstack/moonvar: fixed widths in either byte order, the fewest octets a number fits, and the variable-length integers of QUIC (RFC 9000), HPACK and QPACK prefixes (RFC 7541), LEB128 unsigned and signed with zigzag (protobuf, DWARF, WebAssembly) and MySQL's length-encoded integers. Use when code builds or parses a binary wire format, a length prefix or a varint."
---

# moonvar

```bash
moon add moonbitstack/moonvar
```

Each encoding is its own package with no dependency; import the ones your wire speaks:

```moonbit
// moon.pkg
import {
  "moonbitstack/moonvar/fixed",
  "moonbitstack/moonvar/leb128",
}
```

| Package | Encoding | Used by |
|:--|:--|:--|
| `fixed` | `u8` to `u64`, signed, `f32`, `f64`, 24-bit, any byte order, and the narrowest width a value fits | everything |
| `quic` | two bits of width, 62 of value | QUIC, HTTP/3 |
| `prefix` | a value in the low N bits of an octet, then continuation | HPACK, QPACK |
| `leb128` | seven bits an octet; `zigzag` for protobuf's signed values, `encode_signed` for what DWARF and WebAssembly write | protobuf, DWARF, WebAssembly |
| `lenenc` | one octet below 251, else a marker and 2, 3 or 8 octets | MySQL, MariaDB |

## A length-prefixed frame

```moonbit
fn frame(payload : Bytes) -> Bytes {
  let out = Buffer()
  // Appends, rather than allocating the length and copying it in.
  @quic.write(out, payload.length().to_uint64())
  out.write_bytes(payload)
  out.to_bytes()
}

fn unframe(wire : Bytes) -> Bytes raise {
  guard @quic.decode(wire[:]) is Some((length, used)) else {
    fail("the length is cut short")
  }
  let end = used + length.to_int()
  guard end <= wire.length() else { fail("the payload is cut short") }
  wire[used:end].to_bytes()
}
```

A walker reads one field after another by handing `at` the count the previous read returned;
every reader takes `at~` for that.

## Fixed widths

```moonbit
fn header(kind : Int, length : Int) -> Bytes {
  let out = Buffer()
  @fixed.write_u24(out, length) // big-endian unless order=Little
  @fixed.write_u8(out, kind)
  out.to_bytes()
}

fn length_of(wire : Bytes) -> Int? {
  @fixed.read_u24(wire[:]) // None when fewer than three octets are there
}
```

## A number with no width agreed

```moonbit
test "narrowest" {
  let wire = @fixed.encode(0x010203UL) // three octets, which is @fixed.size's answer
  assert_eq(wire, b"\x01\x02\x03")
  assert_eq(@fixed.decode(wire[:]), Some(0x010203UL))
}
```

`fixed.decode` takes the whole run from `at` to the end of the view, and answers `None` when
that run is longer than eight octets: it will not return the low half of a number nobody
wrote.

## Signed values, two spellings

```moonbit
test "signed" {
  // protobuf's sint32/sint64: fold the sign onto an unsigned value, then encode that.
  assert_eq(@leb128.encode(@leb128.zigzag(-2L)), b"\x03")
  // DWARF and WebAssembly: keep the sign in the last group's bit six.
  assert_eq(@leb128.encode_signed(-2L), b"\x7e")
  assert_eq(@leb128.decode_signed(b"\x7e"[:]), (-2L, 1))
}
```

They are not interchangeable: `7e` is 126 to `leb128.decode` and -2 to `decode_signed`, and
nothing in the octets says which one applies.

## Things that catch people out

- The fixed readers answer `None` when the view is short; the variable-length readers raise
  `Refused` (`Truncated`, or a value past what the encoding allows). `quic.decode` answers
  `None` instead of raising, since a QUIC reader often meets a packet that ends early.
- `quic.encode` and `quic.write` abort above 2^62 - 1 (`quic.max`) rather than write a
  number that would read back as a different one. Ask `quic.size` first when the value comes
  from outside.
- Every package has `size(value)`: the octets a value will take, for a length field written
  before its payload.
- `prefix.encode` refuses a negative value: RFC 7541 §5.1 counts from zero, and the sign
  bits would land where the reader takes the field's flags.
