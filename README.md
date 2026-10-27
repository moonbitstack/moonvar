<h1 align="center">moonvar</h1>

<p align="center"><b>A number, written down as octets.</b></p>

<p align="center">
  Fixed widths, and the variable-length integers that QUIC, HPACK, protobuf and MySQL<br>
  each spell differently — for MoonBit, one package per encoding.
</p>

<p align="center">
  <a href="https://moonbitstack.github.io/moonvar/">Home</a> ·
  <a href="https://moonbitstack.github.io/moonvar/guide.html">Guide</a> ·
  <a href="https://moonbitstack.github.io/moonvar/api.html">API</a> ·
  <a href="https://mooncakes.io/docs/moonbitstack/moonvar">mooncakes</a>
</p>

---

```moonbit
// The fixed widths, either way round, reading nothing it was not given.
let buf = Buffer()
@fixed.write_u32(buf, 0x12345678)               // 12 34 56 78
@fixed.write_u16(buf, 0x1234, order=Little)     // 34 12
let wire = buf.to_bytes()
@fixed.read_u32(wire[:])                        // Some(305419896)
@fixed.read_u32(wire[:], at=10)                 // None, the view is shorter

// One number, in each protocol's own spelling.
@quic.encode(1337UL)                            // 45 39
@prefix.encode(1337, prefix=5)                  // 1f 9a 0a
@leb128.encode(1337UL)                          // b9 0a
@lenenc.encode(1337UL)                          // fc 39 05
```

## Packages

| | Encoding | Written by |
|:--|:--|:--|
| `fixed` | Byte order for `u8`…`u64`, `i8`…`i64`, `f32`, `f64`, the 24-bit length protocols use, and a width carried in a variable | Everything |
| `quic` | Two bits name the width, sixty-two carry the value — [RFC 9000 §16](https://www.rfc-editor.org/rfc/rfc9000#section-16) | QUIC, HTTP/3 |
| `prefix` | A value in the low N bits, continuing when it does not fit — [RFC 7541 §5.1](https://www.rfc-editor.org/rfc/rfc7541#section-5.1) | HPACK, QPACK |
| `leb128` | Seven bits an octet, least significant first, plus zigzag for signed values | protobuf, DWARF |
| `lenenc` | One octet below 251, otherwise a marker and two, three or eight little-endian octets | MySQL, MariaDB |

Each package is separate and carries no dependency, so wanting protobuf's varint does
not mean linking QUIC's.

## The same number, five ways

1337, as each package writes it:

| `fixed` | `quic` | `prefix(5)` | `leb128` | `lenenc` |
|:--|:--|:--|:--|:--|
| `05 39` | `45 39` | `1f 9a 0a` | `b9 0a` | `fc 39 05` |

Two octets, two, three, two, three — and each one is the length some wire already
expects. `quic` spends two bits on the width; `prefix` spends five on being a value that
shares an octet with flags; `leb128` spends one bit per octet on saying "another
follows"; `lenenc` spends a whole octet on a marker; `fixed` spends nothing and pays for
it with width.

## Reading is half of it

- **Nothing read past the end.** Every fixed reader checks the width it needs and answers
  `None` when the view is short. The variable-length readers raise a `Refused` that names
  the fault: `Truncated`, or past the ceiling the encoding allows.
- **A width without writing it.** Every package has `size()`: how many octets a value
  takes, without producing them. A length field has to be measured before the payload it
  describes is written.
- **Signed values stay short.** `leb128.zigzag` folds a negative onto an unsigned value,
  so `-1` costs one octet rather than ten.

## Install

```bash
moon add moonbitstack/moonvar
```

Then import the package whose wire you speak:

```
import {
  "moonbitstack/moonvar/quic",
}
```

## Examples

| | |
|:--|:--|
| [`src/examples/tour`](src/examples/tour/main.mbt) | The whole surface in one run: every encoding, both directions, and the octet count each costs |
| [`src/examples/frame`](src/examples/frame/main.mbt) | A length-prefixed frame — a varint length, then a payload — with the truncated case refused rather than half-read |

```bash
moon run src/examples/tour
moon run src/examples/frame
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
