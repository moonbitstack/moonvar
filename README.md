# moonvar

How a number becomes bytes and back. The fixed widths with their byte order, and the
variable-length integers four protocol families each define differently.

```moonbit
// The fixed widths, either way round, reading nothing it was not given.
let buf = Buffer()
@fixed.write_u32(buf, 0x12345678)          // big end first, as the network writes
@fixed.write_u16(buf, 513, order=Little)   // unless it does not
@fixed.read_u32(bytes[:], at=4)            // None when the view is too short

// And the variable-length ones, each under the name of the protocol that defines it.
@quic.encode(1337UL)                       // RFC 9000 §16, two-bit width prefix
@prefix.encode(1337, prefix=5)             // RFC 7541 §5.1, HPACK and QPACK
@leb128.encode(150UL)                      // protobuf, DWARF
@lenenc.encode(65536UL)                    // MySQL and MariaDB
```

Run `moon run examples/tour` for the whole surface in one go.

## Packages

|  | Encoding | Who writes it |
|:--:|:--|:--|
| `fixed` | Byte order for `u8`…`u64`, `i8`…`i64`, `f32`, `f64`, and the 24-bit width protocols use for lengths | Everything |
| `quic` | Two bits say the width, sixty-two carry the value ([RFC 9000 §16](https://www.rfc-editor.org/rfc/rfc9000#section-16)) | QUIC, HTTP/3, the datagram extension |
| `prefix` | A value in the low N bits, continuing when it does not fit ([RFC 7541 §5.1](https://www.rfc-editor.org/rfc/rfc7541#section-5.1)) | HPACK, and QPACK unchanged ([RFC 9204 §4.1.1](https://www.rfc-editor.org/rfc/rfc9204#section-4.1.1)) |
| `leb128` | Seven bits an octet, least significant first, plus zigzag | protobuf, DWARF |
| `lenenc` | One octet under 251, else a marker and little-endian octets | MySQL, MariaDB |

Each package is separate and carries no dependency, so wanting protobuf's varint does not
mean linking QUIC's.

## Why this is a library

Four of these encodings are written in more than one place across a protocol stack, and
the fixed widths are written everywhere: a hand-rolled `(b[0] << 24) | (b[1] << 16) | …`
appears in every parser that has ever read a length. They are one thing — a number,
becoming bytes — they are frozen by the specifications that define them, and none of them
knows or cares who is calling.

## What is not here

Text. A number written as digits is `moonjson`'s question, not this one, and a number
written in base 32 or 64 is `moonbase`'s.

Variable-*width* floats. CBOR and MessagePack pick the narrowest of binary16, binary32
and binary64 that round-trips exactly; that is a real encoding and will live here as
`ieee` when something in reach needs it. Nothing does yet, and a package written before
its first caller is a guess.

ASN.1's length octets stay in `mooncrypt/asn1`. They are an integer encoding, but they are
so bound to DER's tag-length-value that pulling them out would be a split for its own
sake.

## What is checked

`quic` is measured against the four widths RFC 9000 §16 defines at the value that first
needs each. `prefix` is measured against the three integers RFC 7541 Appendix C.1 works
out. `leb128` is measured against the values protobuf's encoding guide prints, and its
zigzag against protobuf's own table — including both ends of the signed range, which is
where an arithmetic shift in place of a logical one shows up. `lenenc` is measured against
each of the four widths and against the two first octets the MySQL protocol reserves for
things that are not lengths.

Every reader is given a truncated input at each width and must answer rather than read
past the end.

The gate is `moon clean` → `moon fmt` → `moon check --target all --deny-warn` →
`moon build --target all` → `moon test --target all`, across `wasm`, `wasm-gc`, `js` and
`native`.

## Install

```bash
moon add moonbitstack/moonvar
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
