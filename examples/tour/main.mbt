///|
/// One number, written five ways, and read back.
///
///     moon run examples/tour
#coverage.skip
fn main {
  // The fixed widths: the octets go in the order you ask for, and reading a view that
  // is too short answers rather than walking off the end.
  let buf = Buffer()
  @fixed.write_u32(buf, 0x12345678)
  @fixed.write_u32(buf, 0x12345678, order=Little)
  @fixed.write_u24(buf, 0x010203)
  @fixed.write_f64(buf, 1.5)
  let wire = buf.to_bytes()
  println("fixed           \{hex(wire)}")
  println("  u32 at 0      \{opt_u(@fixed.read_u32(wire[:]))}")
  println(
    "  u32 at 4 (le) \{opt_u(@fixed.read_u32(wire[:], at=4, order=Little))}",
  )
  println("  u24 at 8      \{opt_i(@fixed.read_u24(wire[:], at=8))}")
  println("  f64 at 11     \{opt_d(@fixed.read_f64(wire[:], at=11))}")
  // Nineteen octets went in, so a u32 wanting 16 through 19 has nowhere to read
  // the last one from.
  println("  u32 at 16     \{opt_u(@fixed.read_u32(wire[:], at=16))}")

  // The same value in each variable-length encoding, and what each one costs.
  println("")
  for v in [1UL, 150UL, 1337UL, 65536UL] {
    println(
      "\{pad(v.to_string())} quic=\{hex(@quic.encode(v))}  prefix5=\{hex(@prefix.encode(v.to_int(), prefix=5))}  leb128=\{hex(@leb128.encode(v))}  lenenc=\{hex(@lenenc.encode(v))}",
    )
  }

  // Zigzag is why protobuf's signed types stay short.
  println("")
  for v in [0L, -1L, 1L, -64L, 63L] {
    println(
      "\{pad(v.to_string())} raw=\{@leb128.encode(v.reinterpret_as_uint64()).length()} octets  zigzag=\{@leb128.encode(@leb128.zigzag(v)).length()} octets",
    )
  }
}

///|
fn pad(s : String) -> String {
  let sb = StringBuilder()
  for i = s.length(); i < 8; i = i + 1 {
    sb.write_char(' ')
  }
  sb.write_string(s)
  sb.to_string()
}

///|
fn opt_u(o : UInt?) -> String {
  match o {
    Some(v) => "0x" + hex_u32(v)
    None => "(too short)"
  }
}

///|
fn opt_i(o : Int?) -> String {
  match o {
    Some(v) => v.to_string()
    None => "(too short)"
  }
}

///|
fn opt_d(o : Double?) -> String {
  match o {
    Some(v) => v.to_string()
    None => "(too short)"
  }
}

///|
fn hex_u32(v : UInt) -> String {
  let buf = Buffer()
  @fixed.write_u32(buf, v)
  hex(buf.to_bytes())
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
