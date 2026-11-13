#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
"""Write the vector tables the conformance tests replay, from implementations that are not
this one.

Every table lands in `src/<package>/<package>_vectors_wbtest.mbt` and is regenerated, never
edited: `python3 scripts/gen_vectors.py` rewrites them, `python3 scripts/gen_vectors.py
check` recomputes them and fails when the tree holds something else. CI runs the second.

Two families of references answer the same cases, and a case is written out only when both
agree with each other and with the MoonBit encoder:

  Python
    hpack           RFC 7541 §5.1 integers, the encoder behind hyper and httpx
    leb128          ULEB128 and SLEB128, the reader and writer pyelftools and llvm tools use
    pyelftools      a second SLEB128 reader, from the ELF/DWARF toolchain
    aioquic         RFC 9000 §16 integers
    PyMySQL         MySQL's length-encoded integers, as its packet reader sees them
    struct          the fixed widths, through CPython's own packer

  Go (scripts/vectors)
    encoding/binary                   fixed widths, and protobuf's varints both ways
    quic-go/quicvarint                RFC 9000 §16, both ways
    go-mysql/mysql                    MySQL's length-encoded integers, both ways
    x/net/http2/hpack                 reads a whole header block, so the 7-bit-prefix
                                      integers in it are read by a second implementation

`scripts/vectors-requirements.txt` pins the Python side; the Go module pins its own.
"""

import io
import json
import pathlib
import struct
import subprocess
import sys

import hpack.hpack
import leb128
from aioquic.buffer import Buffer as QuicBuffer
from elftools.common.construct_utils import SLEB128
from pymysql.protocol import MysqlPacket

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
GO_DIR = ROOT / "scripts" / "vectors"

MASK64 = (1 << 64) - 1

# Name lengths whose 7-bit-prefix integers a header block puts in front of a name. The
# last three need continuation octets, which is the part worth asking a second
# implementation about.
HEADER_NAMES = [1, 100, 300, 1337]


# ---------------------------------------------------------------- cases

def lcg(seed, count, modulus):
    """Deterministic pseudo-random values, so a regeneration changes nothing."""
    out, x = [], seed
    for _ in range(count):
        x = (x * 6364136223846793005 + 1442695040888963407) & MASK64
        out.append(x % modulus)
    return out


def fixed_cases():
    """(value, width) for the widths a machine has, which are the ones formats name."""
    cases = []
    for width in (1, 2, 4, 8):
        top = (1 << (8 * width)) - 1
        values = [0, 1, top, top // 2, top // 3, 0x12, 0x1234] + lcg(width * 7919, 4, top + 1)
        for v in values:
            if 0 <= v <= top and (v, width) not in cases:
                cases.append((v, width))
    return cases


def fixed_minimal_cases():
    """Values whose own length is the width, which is what `fixed.encode` writes."""
    values = [0, 1, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x10000, 0xFFFFFF, 0x1000000,
              0xFFFFFFFF, 0x100000000, 1 << 40, (1 << 63) - 1, 1 << 63, MASK64]
    return sorted(set(values + lcg(104729, 6, 1 << 64)))


def leb128_unsigned_cases():
    values = [0, 1, 2, 63, 64, 127, 128, 129, 150, 255, 256, 300, 16383, 16384,
              2097151, 2097152, 0xFFFFFFFF, 0x100000000, (1 << 63) - 1, 1 << 63, MASK64]
    return sorted(set(values + lcg(15485863, 6, 1 << 64)))


def leb128_signed_cases():
    values = [0, 1, -1, 2, -2, 63, 64, -64, -65, 127, 128, -128, -129, 8191, 8192,
              -8192, -8193, (1 << 31) - 1, -(1 << 31), (1 << 63) - 1, -(1 << 63)]
    values += [v - (1 << 63) for v in lcg(32452843, 4, 1 << 64)]
    return sorted(set(values))


def quic_cases():
    values = [0, 1, 37, 63, 64, 1337, 15293, 16383, 16384, 494878333,
              (1 << 30) - 1, 1 << 30, (1 << 62) - 1]
    return sorted(set(values + lcg(49979687, 5, 1 << 62)))


def prefix_cases():
    """(value, prefix bits) for every width an HPACK or QPACK field uses."""
    cases = []
    for bits in range(1, 9):
        ceiling = (1 << bits) - 1
        values = [0, 1, 10, 42, ceiling - 1, ceiling, ceiling + 1, 127, 128, 255, 256,
                  1337, 65535, 65536, (1 << 31) - 1]
        for v in values:
            if v >= 0 and (v, bits) not in cases:
                cases.append((v, bits))
    return cases


def lenenc_cases():
    values = [0, 1, 250, 251, 65535, 65536, 0xFFFFFF, 0x1000000, 0xFFFFFFFF, 1 << 32,
              (1 << 63), MASK64]
    return sorted(set(values + lcg(67867967, 5, 1 << 64)))


def quic_padded_cases():
    """Octets that carry a value in a wider form than it needs; RFC 9000 §16 allows them."""
    return [
        (37, "4025"),
        (37, "80000025"),
        (37, "c000000000000025"),
        (15293, "7bbd"),
        (494878333, "9d7f3e7d"),
        (0, "4000"),
        (63, "403f"),
        (16383, "7fff"),
    ]


def leb128_overlong_cases():
    """Values whose last group is zero, which readers accept and writers do not produce."""
    return [(1, "8100"), (0, "8000"), (150, "9601"), (127, "ff00"), (128, "808100")]


# ---------------------------------------------------------------- Python references

def py_fixed(value, width, big):
    """CPython's packer: the fixed widths, either way round."""
    code = {1: "B", 2: "H", 4: "I", 8: "Q"}[width]
    return struct.pack((">" if big else "<") + code, value)


def py_quic(value):
    buf = QuicBuffer(capacity=8)
    buf.push_uint_var(value)
    return buf.data


def py_quic_read(data):
    buf = QuicBuffer(data=data)
    return buf.pull_uint_var()


def py_prefix(value, bits):
    return hpack.hpack.encode_integer(value, bits)


def py_prefix_read(data, bits):
    return hpack.hpack.decode_integer(data, bits)


def py_lenenc_read(data):
    return MysqlPacket(data, "utf-8").read_length_encoded_integer()


def elf_sleb128(data):
    """pyelftools' SLEB128 reader, the one its DWARF parser uses."""
    return SLEB128("value").parse_stream(io.BytesIO(data))


# ---------------------------------------------------------------- the Go references

def go_answer(request):
    proc = subprocess.run(
        ["go", "run", "."],
        cwd=GO_DIR,
        input=json.dumps(request).encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        sys.exit("go run failed:\n" + proc.stderr.decode(errors="replace"))
    return json.loads(proc.stdout)


# ---------------------------------------------------------------- rendering

HEADER = """\
// Generated by scripts/gen_vectors.py. Do not edit: run the script instead.
//
// {provenance}
"""

BYTES_HELPERS = '''
///|
/// Octets from hex, for the tables below.
fn vec_bytes(hex : String) -> Bytes {
  let buf = Buffer()
  for i = 0; i < hex.length(); i = i + 2 {
    buf.write_byte(
      ((vec_nibble(hex[i].to_int()) << 4) | vec_nibble(hex[i + 1].to_int())).to_byte(),
    )
  }
  buf.to_bytes()
}

///|
fn vec_nibble(c : Int32) -> Int32 {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else {
    0
  }
}
'''

HEX_HELPER = '''
///|
/// Octets as hex, for the messages of a failed case.
fn vec_hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    let x = b[i].to_int()
    sb.write_char(digits[x >> 4].unsafe_to_char())
    sb.write_char(digits[x & 0xf].unsafe_to_char())
  }
  sb.to_string()
}
'''

EMIT_HELPER = '''
///|
/// A buffer the closure appends to, as octets.
fn vec_emit(f : (Buffer) -> Unit) -> Bytes {
  let buf = Buffer()
  f(buf)
  buf.to_bytes()
}
'''


def preamble(hex_message=True, emit=True):
    """Only the helpers a file uses: a package is checked with warnings as errors."""
    return BYTES_HELPERS + (HEX_HELPER if hex_message else "") + (EMIT_HELPER if emit else "")


def u64(v):
    return f"{v}UL"


def i64(v):
    if v == -(1 << 63):
        return "-9223372036854775807L - 1L"
    return f"{v}L"


def table(name, rows, row_type):
    body = "".join(f"  {r},\n" for r in rows)
    return f"\n///|\nlet {name} : Array[{row_type}] = [\n{body}]\n"


TEST_FIXED = '''
///|
test "the fixed widths, as the reference packers write them" {
  for case in fixed_widths {
    let (value, width, big, little) = case
    let be = vec_bytes(big)
    let le = vec_bytes(little)
    assert_eq(
      vec_hex(vec_emit(b => write_uint(b, value, size=width))),
      big,
      msg="big-endian \\{value} in \\{width}",
    )
    assert_eq(
      vec_hex(vec_emit(b => write_uint(b, value, size=width, order=Little))),
      little,
      msg="little-endian \\{value} in \\{width}",
    )
    assert_eq(
      read_uint(be[:], size=width),
      Some(value),
      msg="read big-endian \\{big}",
    )
    assert_eq(
      read_uint(le[:], size=width, order=Little),
      Some(value),
      msg="read little-endian \\{little}",
    )
  }
}

///|
test "the narrowest width, as the reference packers write it" {
  for case in fixed_minimal {
    let (value, big, little) = case
    assert_eq(vec_hex(encode(value)), big, msg="encode \\{value}")
    assert_eq(
      vec_hex(encode(value, order=Little)),
      little,
      msg="encode \\{value} little-endian",
    )
    assert_eq(encode(value).length(), size(value), msg="size of \\{value}")
    assert_eq(decode(vec_bytes(big)[:]), Some(value), msg="decode \\{big}")
    assert_eq(
      decode(vec_bytes(little)[:], order=Little),
      Some(value),
      msg="decode \\{little}",
    )
  }
}
'''

TEST_LEB128 = '''
///|
test "unsigned LEB128, as the reference implementations write it" {
  for case in leb128_unsigned {
    let (value, octets) = case
    let wire = vec_bytes(octets)
    assert_eq(vec_hex(encode(value)), octets, msg="encode \\{value}")
    assert_eq(decode(wire[:]), (value, wire.length()), msg="decode \\{octets}")
    assert_eq(size(value), wire.length(), msg="size of \\{value}")
  }
}

///|
test "signed LEB128, as the reference implementations write it" {
  for case in leb128_signed {
    let (value, octets) = case
    let wire = vec_bytes(octets)
    assert_eq(vec_hex(encode_signed(value)), octets, msg="encode \\{value}")
    assert_eq(
      decode_signed(wire[:]),
      (value, wire.length()),
      msg="decode \\{octets}",
    )
    assert_eq(size_signed(value), wire.length(), msg="size of \\{value}")
  }
}
'''

TEST_QUIC = '''
///|
test "QUIC varints, as the reference implementations write them" {
  for case in quic_varints {
    let (value, octets) = case
    let wire = vec_bytes(octets)
    assert_eq(vec_hex(encode(value)), octets, msg="encode \\{value}")
    assert_eq(
      vec_hex(vec_emit(b => write(b, value))),
      octets,
      msg="write \\{value}",
    )
    assert_eq(
      decode(wire[:]),
      Some((value, wire.length())),
      msg="decode \\{octets}",
    )
    assert_eq(size(value), wire.length(), msg="size of \\{value}")
  }
}

///|
test "a value a sender padded to a wider form still reads" {
  // RFC 9000 §16 lets a sender use more octets than the value needs, so the reader
  // cannot insist on the shortest form; the A.1 vectors include one.
  for case in quic_padded {
    let (value, octets) = case
    let wire = vec_bytes(octets)
    assert_eq(
      decode(wire[:]),
      Some((value, wire.length())),
      msg="decode \\{octets}",
    )
  }
}
'''

TEST_PREFIX = '''
///|
test "prefix integers, as the reference implementation writes them" {
  for case in prefix_integers {
    let (value, bits, octets) = case
    let wire = vec_bytes(octets)
    assert_eq(
      vec_hex(encode(value, prefix=bits)),
      octets,
      msg="encode \\{value} in \\{bits}",
    )
    assert_eq(
      decode(wire[:], prefix=bits),
      (value, wire.length()),
      msg="decode \\{octets}",
    )
    assert_eq(size(value, prefix=bits), wire.length(), msg="size of \\{value}")
  }
}
'''

TEST_LENENC = '''
///|
test "length-encoded integers, as the reference implementations write them" {
  for case in lenenc_integers {
    let (value, octets) = case
    let wire = vec_bytes(octets)
    assert_eq(vec_hex(encode(value)), octets, msg="encode \\{value}")
    assert_eq(
      vec_hex(vec_emit(b => write(b, value))),
      octets,
      msg="write \\{value}",
    )
    assert_eq(decode(wire[:]), (value, wire.length()), msg="decode \\{octets}")
    assert_eq(size(value), wire.length(), msg="size of \\{value}")
  }
}
'''


def render_fixed(cases, minimal):
    width_rows = [f'({u64(v)}, {w}, "{be}", "{le}")' for v, w, be, le in cases]
    min_rows = [f'({u64(v)}, "{be}", "{le}")' for v, be, le in minimal]
    out = [HEADER.format(provenance=(
        "The fixed widths come from CPython's `struct` and Go's `encoding/binary`; the\n"
        "// narrowest-width table from `int.to_bytes` and the same `binary` functions."))]
    out.append(preamble())
    out.append(table("fixed_widths", width_rows, "(UInt64, Int32, String, String)"))
    out.append(table("fixed_minimal", min_rows, "(UInt64, String, String)"))
    out.append(TEST_FIXED)
    return "".join(out)


def render_leb128(unsigned, signed):
    u_rows = [f'({u64(v)}, "{h}")' for v, h in unsigned]
    s_rows = [f'({i64(v)}, "{h}")' for v, h in signed]
    out = [HEADER.format(provenance=(
        "The unsigned table comes from the `leb128` package and Go's\n"
        "// `binary.PutUvarint`; the signed one (SLEB128, as DWARF and WebAssembly write\n"
        "// a signed value) from the same package, whose reader and pyelftools' agree."))]
    out.append(preamble(emit=False))
    out.append(table("leb128_unsigned", u_rows, "(UInt64, String)"))
    out.append(table("leb128_signed", s_rows, "(Int64, String)"))
    out.append(TEST_LEB128)
    return "".join(out)


def render_quic(cases, padded):
    rows = [f'({u64(v)}, "{h}")' for v, h in cases]
    pad_rows = [f'({u64(v)}, "{h}")' for v, h in padded]
    out = [HEADER.format(provenance=(
        "The table comes from aioquic's `push_uint_var` and quic-go's `quicvarint`,\n"
        "// RFC 9000 §16's own A.1 vectors included."))]
    out.append(preamble())
    out.append(table("quic_varints", rows, "(UInt64, String)"))
    out.append(table("quic_padded", pad_rows, "(UInt64, String)"))
    out.append(TEST_QUIC)
    return "".join(out)


def render_prefix(cases):
    rows = [f'({v}, {bits}, "{h}")' for v, bits, h in cases]
    out = [HEADER.format(provenance=(
        "The table comes from hpack's `encode_integer`, which is RFC 7541 §5.1's own\n"
        "// worked examples and the encoder hyper sends with. Go's `x/net/http2/hpack`\n"
        "// reads the 7-bit-prefix form back out of a whole header block."))]
    out.append(preamble(emit=False))
    out.append(table("prefix_integers", rows, "(Int32, Int32, String)"))
    out.append(TEST_PREFIX)
    return "".join(out)


def render_lenenc(cases):
    rows = [f'({u64(v)}, "{h}")' for v, h in cases]
    out = [HEADER.format(provenance=(
        "The table comes from go-mysql's `PutLengthEncodedInt` and PyMySQL's packet\n"
        "// reader, which is MySQL's own wire documentation worked out twice."))]
    out.append(preamble())
    out.append(table("lenenc_integers", rows, "(UInt64, String)"))
    out.append(TEST_LENENC)
    return "".join(out)


# ---------------------------------------------------------------- generation

def generate():
    """Every table, with the references cross-checked against each other first."""
    fixed = fixed_cases()
    minimal_values = fixed_minimal_cases()
    leb_u = leb128_unsigned_cases()
    leb_s = leb128_signed_cases()
    quic = quic_cases()
    quic_pad = quic_padded_cases()
    leb_over = leb128_overlong_cases()
    prefix = prefix_cases()
    lenenc = lenenc_cases()

    written = go_answer({
        "fixed": [{"value": v, "width": w} for v, w in fixed],
        "leb128_unsigned": leb_u,
        "quic": quic,
        "lenenc": lenenc,
        "header_blocks": [hpack.Encoder().encode({("z" * n): "v"}).hex()
                          for n in HEADER_NAMES],
    })
    if written["header_blocks"] != HEADER_NAMES:
        sys.exit(f"header blocks: go read {written['header_blocks']} where hpack wrote "
                 f"{HEADER_NAMES}")

    # Fixed widths: CPython's packer and Go's binary both write them, both orders.
    fixed_rows = []
    for (value, width), answer in zip(fixed, written["fixed"]):
        py_be = py_fixed(value, width, True).hex()
        py_le = py_fixed(value, width, False).hex()
        if (py_be, py_le) != (answer["big"], answer["little"]):
            sys.exit(f"fixed {value}/{width}: python {py_be}/{py_le} != go "
                     f"{answer['big']}/{answer['little']}")
        fixed_rows.append((value, width, py_be, py_le))

    # The narrowest width: CPython's `int.to_bytes`, which the Go side reads back below.
    minimal_rows = []
    for value in minimal_values:
        width = max(1, (value.bit_length() + 7) // 8)
        minimal_rows.append((value,
                             value.to_bytes(width, "big").hex(),
                             value.to_bytes(width, "little").hex()))

    # LEB128 unsigned: the `leb128` package and Go's PutUvarint.
    leb_u_rows = []
    for value, answer in zip(leb_u, written["leb128_unsigned"]):
        mine = leb128.u.encode(value).hex()
        if mine != answer:
            sys.exit(f"uleb128 {value}: python {mine} != go {answer}")
        if leb128.u.decode(bytes.fromhex(mine)) != value:
            sys.exit(f"uleb128 {value}: leb128 did not read its own octets back")
        leb_u_rows.append((value, mine))

    # LEB128 signed: `leb128` writes it, `leb128` and pyelftools read it.
    leb_s_rows = []
    for value in leb_s:
        octets = leb128.i.encode(value).hex()
        if leb128.i.decode(bytes.fromhex(octets)) != value:
            sys.exit(f"sleb128 {value}: leb128 did not read its own octets back")
        if elf_sleb128(bytes.fromhex(octets)) != value:
            sys.exit(f"sleb128 {value}: pyelftools read "
                     f"{elf_sleb128(bytes.fromhex(octets))}")
        leb_s_rows.append((value, octets))

    # QUIC: aioquic and quic-go.
    quic_rows = []
    for value, answer in zip(quic, written["quic"]):
        mine = py_quic(value).hex()
        if mine != answer:
            sys.exit(f"quic {value}: aioquic {mine} != quic-go {answer}")
        if py_quic_read(bytes.fromhex(mine)) != value:
            sys.exit(f"quic {value}: aioquic did not read its own octets back")
        quic_rows.append((value, mine))

    # HPACK integers: hpack writes and reads; Go's hpack read the whole blocks above.
    prefix_rows = []
    for value, bits in prefix:
        octets = py_prefix(value, bits).hex()
        if py_prefix_read(bytes.fromhex(octets), bits) != (value, len(bytes.fromhex(octets))):
            sys.exit(f"prefix {value}/{bits}: hpack did not read its own octets back")
        prefix_rows.append((value, bits, octets))

    # MySQL: go-mysql writes; PyMySQL reads what it wrote.
    lenenc_rows = []
    for value, answer in zip(lenenc, written["lenenc"]):
        if py_lenenc_read(bytes.fromhex(answer)) != value:
            sys.exit(f"lenenc {value}: PyMySQL read "
                     f"{py_lenenc_read(bytes.fromhex(answer))}")
        lenenc_rows.append((value, answer))

    # The other direction: the Go decoders read the octets back, including the forms no
    # writer here produces (a padded varint, a value whose last group is zero).
    read = go_answer({
        "fixed_read": [{"hex": be, "width": w, "big": True} for _, w, be, _ in fixed_rows],
        "leb128_read": [h for _, h in leb_over],
        "quic_read": [h for _, h in quic_pad],
        "lenenc_read": [h for _, h in lenenc_rows],
    })
    for (value, _, be, _), answer in zip(fixed_rows, read["fixed_read"]):
        if answer != value or int(be, 16) != value:
            sys.exit(f"fixed read {be}: go answered {answer}, expected {value}")
    for (value, octets), answer in zip(leb_over, read["leb128_read"]):
        if answer != value or leb128.u.decode(bytes.fromhex(octets)) != value:
            sys.exit(f"uleb128 padded {octets}: references disagree")
    for (value, octets), answer in zip(quic_pad, read["quic_read"]):
        if answer != value or py_quic_read(bytes.fromhex(octets)) != value:
            sys.exit(f"quic padded {octets}: references disagree")
    for (value, octets), answer in zip(lenenc_rows, read["lenenc_read"]):
        if answer != value:
            sys.exit(f"lenenc {value}: go-mysql read {answer}")

    return {
        SRC / "fixed" / "fixed_vectors_wbtest.mbt": render_fixed(fixed_rows, minimal_rows),
        SRC / "leb128" / "leb128_vectors_wbtest.mbt": render_leb128(leb_u_rows, leb_s_rows),
        SRC / "quic" / "quic_vectors_wbtest.mbt": render_quic(quic_rows, quic_pad),
        SRC / "prefix" / "prefix_vectors_wbtest.mbt": render_prefix(prefix_rows),
        SRC / "lenenc" / "lenenc_vectors_wbtest.mbt": render_lenenc(lenenc_rows),
    }


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "write"
    files = generate()
    stale = []
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old != text:
            stale.append(path)
            if mode == "write":
                path.write_text(text, encoding="utf-8", newline="\n")
    if mode == "check":
        for path in stale:
            print(f"{path.relative_to(ROOT).as_posix()}: the vectors are out of date")
        if stale:
            print("run python3 scripts/gen_vectors.py")
            return 1
    cases = sum(text.count("\n  (") for text in files.values())
    print(f"{len(files)} vector tables, {cases} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
