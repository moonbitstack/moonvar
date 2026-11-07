---
name: moonvar
description: "Write and read numbers as octets in MoonBit with moonbitstack/moonvar: fixed widths in either byte order, and the variable-length integers of QUIC (RFC 9000), HPACK and QPACK prefixes (RFC 7541), LEB128 with zigzag (protobuf, DWARF) and MySQL's length-encoded integers. Use when code builds or parses a binary wire format, a length prefix or a varint."
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
| `fixed` | `u8` to `u64`, signed, `f32`, `f64`, 24-bit, any byte order | everything |
| `quic` | two bits of width, 62 of value | QUIC, HTTP/3 |
| `prefix` | a value in the low N bits of an octet, then continuation | HPACK, QPACK |
| `leb128` | seven bits an octet, plus `zigzag` for signed | protobuf, DWARF |
| `lenenc` | one octet below 251, else a marker and 2, 3 or 8 octets | MySQL, MariaDB |

## A length-prefixed frame

```moonbit
fn frame(payload : Bytes) -> Bytes {
  let out = Buffer()
  @leb128.write(out, payload.length().to_uint64())
  out.write_bytes(payload)
  out.to_bytes()
}

fn unframe(wire : Bytes) -> Bytes raise {
  let (length, used) = @leb128.decode(wire[:]) // raises Truncated on a short view
  let end = used + length.to_int()
  guard end <= wire.length() else { fail("the payload is cut short") }
  wire[used:end].to_bytes()
}
```

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

## Things that catch people out

- The fixed readers answer `None` when the view is short; the variable-length readers raise `Refused` (`Truncated`, or a value past what the encoding allows). `quic.decode` answers `None` instead of raising, since a QUIC reader often meets a packet that ends early.
- Every package has `size(value)`: the octets a value will take, for a length field written before its payload.
- `leb128.encode` takes an unsigned value; a signed one goes through `zigzag` first, so `-1` costs one octet rather than ten. `unzigzag` turns it back.
- `prefix.encode(value, prefix=N, flags=...)` shares its first octet with flag bits above the prefix; `prefix.flagged` reads one of them back.
