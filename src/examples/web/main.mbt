// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The documentation site's engine. The pages in `docs/` carry no encoding rules of
// their own: every octet they print came back from the functions the packages ship,
// compiled to JavaScript and run in the reader's tab.

///|
/// One decimal number in, every encoding out, as JSON.
///
/// `bits` is the prefix width handed to `prefix`.
pub fn probe(text : String, bits : Int32) -> String {
  let value = match parse_u64(text) {
    Some(v) => v
    None => return "{\"ok\":false,\"error\":\"not a decimal below 2^64\"}"
  }
  let rows = Rows::new()
  // QUIC: two bits say the width, so the ceiling is 2^62 - 1.
  if value > @quic.max {
    rows.add(row_json("quic", "", 0, "above 2^62-1", ""))
  } else {
    let b = @quic.encode(value)
    let read = match @quic.decode(b[:]) {
      Some((v, n)) =>
        if v == value && n == b.length() {
          v.to_string()
        } else {
          "mismatch"
        }
      None => "mismatch"
    }
    rows.add(row_json("quic", hex(b), b.length(), "", read))
  }
  // HPACK's N-bit prefix, whose reader here holds a signed 31-bit value.
  if value > 0x7fffffffUL {
    rows.add(row_json("prefix", "", 0, "above 2^31-1", ""))
  } else if bits < 1 || bits > 8 {
    rows.add(row_json("prefix", "", 0, "prefix must be 1..8", ""))
  } else {
    let b = @prefix.encode(value.to_int(), prefix=bits)
    let read = match try_decode_prefix(b, bits) {
      Some((v, n)) =>
        if v.to_uint64() == value && n == b.length() {
          v.to_string()
        } else {
          "mismatch"
        }
      None => "mismatch"
    }
    rows.add(row_json("prefix", hex(b), b.length(), "", read))
  }
  // LEB128: seven bits an octet, least significant group first.
  let leb = @leb128.encode(value)
  let leb_read = match try_decode_leb(leb) {
    Some((v, n)) =>
      if v == value && n == leb.length() {
        v.to_string()
      } else {
        "mismatch"
      }
    None => "mismatch"
  }
  rows.add(row_json("leb128", hex(leb), leb.length(), "", leb_read))
  // MySQL's length-encoded integer: one octet, or a marker and little-endian octets.
  let len = @lenenc.encode(value)
  let len_read = match try_decode_lenenc(len) {
    Some((v, n)) =>
      if v == value && n == len.length() {
        v.to_string()
      } else {
        "mismatch"
      }
    None => "mismatch"
  }
  rows.add(row_json("lenenc", hex(len), len.length(), "", len_read))
  // The fixed width, at the narrowest of the five widths the package names.
  let width = fixed_width(value)
  let be = Buffer()
  @fixed.write_uint(be, value, size=width)
  let le = Buffer()
  @fixed.write_uint(le, value, size=width, order=Little)
  let be_read = match @fixed.read_uint(be.to_bytes()[:], size=width) {
    Some(v) => v.to_string()
    None => "mismatch"
  }
  let le_read = match
    @fixed.read_uint(le.to_bytes()[:], size=width, order=Little) {
    Some(v) => v.to_string()
    None => "mismatch"
  }
  rows.add(row_json("fixedbe", hex(be.to_bytes()), width, "", be_read))
  rows.add(row_json("fixedle", hex(le.to_bytes()), width, "", le_read))
  "{\"ok\":true,\"value\":\"" +
  value.to_string() +
  "\",\"bits\":" +
  bits.to_string() +
  ",\"rows\":" +
  rows.finish() +
  "}"
}

///|
/// Hex octets in, what each decoder makes of them out, as JSON.
///
/// Each reader is given the whole run, so a refusal is the reader's own answer and not
/// an artefact of the page trimming its input.
pub fn scan(text : String, bits : Int32) -> String {
  let bytes = match parse_hex(text) {
    Some(b) => b
    None => return "{\"ok\":false,\"error\":\"expected pairs of hex digits\"}"
  }
  let view = bytes[:]
  let rows = Rows::new()
  match try_decode_leb(bytes) {
    Some((v, n)) => rows.add(scan_json("leb128", v.to_string(), n, ""))
    None => rows.add(scan_json("leb128", "", 0, leb_why(bytes)))
  }
  match try_decode_lenenc(bytes) {
    Some((v, n)) => rows.add(scan_json("lenenc", v.to_string(), n, ""))
    None => rows.add(scan_json("lenenc", "", 0, lenenc_why(bytes)))
  }
  match @quic.decode(view) {
    Some((v, n)) => rows.add(scan_json("quic", v.to_string(), n, ""))
    None =>
      rows.add(scan_json("quic", "", 0, "shorter than its width prefix says"))
  }
  if bits < 1 || bits > 8 {
    rows.add(scan_json("prefix", "", 0, "prefix must be 1..8"))
  } else {
    match try_decode_prefix(bytes, bits) {
      Some((v, n)) => rows.add(scan_json("prefix", v.to_string(), n, ""))
      None => rows.add(scan_json("prefix", "", 0, prefix_why(bytes, bits)))
    }
  }
  for w in [1, 2, 3, 4, 8] {
    let id = "fixed" + w.to_string()
    if bytes.length() < w {
      rows.add(scan_json(id, "", 0, "needs \{w} octets, got \{bytes.length()}"))
    } else {
      let be = match @fixed.read_uint(view, size=w) {
        Some(v) => v
        None => 0UL
      }
      let le = match @fixed.read_uint(view, size=w, order=Little) {
        Some(v) => v
        None => 0UL
      }
      rows.add(scan_json(id, be.to_string() + " · " + le.to_string(), w, ""))
    }
  }
  "{\"ok\":true,\"bytes\":\"" +
  hex(bytes) +
  "\",\"rows\":" +
  rows.finish() +
  "}"
}

///|
/// The narrowest of the widths `fixed` names that holds `v`.
fn fixed_width(v : UInt64) -> Int32 {
  let n = @fixed.size(v)
  if n <= 1 {
    1
  } else if n <= 2 {
    2
  } else if n <= 3 {
    3
  } else if n <= 4 {
    4
  } else {
    8
  }
}

///|
/// Rows of a JSON array, with the commas kept in one place.
priv struct Rows {
  buf : StringBuilder
  mut n : Int32
}

///|
fn Rows::new() -> Rows {
  { buf: StringBuilder(), n: 0, }
}

///|
fn Rows::add(self : Rows, json : String) -> Unit {
  if self.n > 0 {
    self.buf.write_char(',')
  }
  self.n = self.n + 1
  self.buf.write_string(json)
}

///|
fn Rows::finish(self : Rows) -> String {
  "[" + self.buf.to_string() + "]"
}

///|
/// One row of `probe`.
fn row_json(
  id : String,
  hex : String,
  size : Int32,
  err : String,
  read : String,
) -> String {
  "{\"id\":\"" +
  id +
  "\",\"hex\":\"" +
  hex +
  "\",\"size\":" +
  size.to_string() +
  ",\"err\":\"" +
  err +
  "\",\"read\":\"" +
  read +
  "\"}"
}

///|
/// One row of `scan`.
fn scan_json(id : String, value : String, used : Int32, err : String) -> String {
  "{\"id\":\"" +
  id +
  "\",\"value\":\"" +
  value +
  "\",\"used\":" +
  used.to_string() +
  ",\"err\":\"" +
  err +
  "\"}"
}

///|
/// LEB128 read back, or `None` where the reader refuses.
fn try_decode_leb(b : Bytes) -> (UInt64, Int32)? {
  Some(@leb128.decode(b[:])) catch {
    _ => None
  }
}

///|
/// The refusal a LEB128 reader gave, in words.
fn leb_why(b : Bytes) -> String {
  try {
    let _ = @leb128.decode(b[:])
    ""
  } catch {
    Truncated(m) => "truncated: " + m
    Exceeded(limit~, got~) => "exceeded: limit \{limit}, got \{got}"
  }
}

///|
/// A length-encoded integer read back, or `None` where the reader refuses.
fn try_decode_lenenc(b : Bytes) -> (UInt64, Int32)? {
  Some(@lenenc.decode(b[:])) catch {
    _ => None
  }
}

///|
/// The refusal a length-encoded reader gave, in words.
fn lenenc_why(b : Bytes) -> String {
  try {
    let _ = @lenenc.decode(b[:])
    ""
  } catch {
    Truncated(m) => "truncated: " + m
    Reserved(got~) => "reserved first octet 0x\{hex_byte(got)}"
  }
}

///|
/// A prefix integer read back, or `None` where the reader refuses.
fn try_decode_prefix(b : Bytes, bits : Int32) -> (Int32, Int32)? {
  Some(@prefix.decode(b[:], prefix=bits)) catch {
    _ => None
  }
}

///|
/// The refusal a prefix reader gave, in words.
fn prefix_why(b : Bytes, bits : Int32) -> String {
  try {
    let _ = @prefix.decode(b[:], prefix=bits)
    ""
  } catch {
    Truncated(m) => "truncated: " + m
    Exceeded(limit~, got~) => "exceeded: limit \{limit}, got \{got}"
  }
}

///|
/// Decimal digits to a value below 2^64, nothing else.
fn parse_u64(s : String) -> UInt64? {
  if s.length() == 0 || s.length() > 20 {
    return None
  }
  let zero = '0'.to_int()
  let mut out = 0UL
  for i = 0; i < s.length(); i = i + 1 {
    let d = s[i].to_int() - zero
    if d < 0 || d > 9 {
      return None
    }
    let digit = d.to_uint64()
    if out > (0xffffffffffffffffUL - digit) / 10UL {
      return None
    }
    out = out * 10UL + digit
  }
  Some(out)
}

///|
/// Pairs of hex digits to octets, ignoring spaces, colons and underscores.
fn parse_hex(s : String) -> Bytes? {
  let buf = Buffer()
  let mut high = -1
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == ' ' || c == ':' || c == '_' || c == '\n' || c == '\t' {
      continue
    }
    let code = c.to_int()
    let d = if code >= 48 && code <= 57 {
      code - 48
    } else if code >= 97 && code <= 102 {
      code - 87
    } else if code >= 65 && code <= 70 {
      code - 55
    } else {
      -1
    }
    if d < 0 {
      return None
    }
    if high < 0 {
      high = d
    } else {
      buf.write_byte((high * 16 + d).to_byte())
      high = -1
    }
  }
  if high >= 0 {
    return None
  }
  Some(buf.to_bytes())
}

///|
/// Octets as lowercase hex, no separators.
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
/// One octet as two hex digits.
fn hex_byte(x : Int32) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  sb.write_char(digits[(x >> 4) & 0xf].unsafe_to_char())
  sb.write_char(digits[x & 0xf].unsafe_to_char())
  sb.to_string()
}
