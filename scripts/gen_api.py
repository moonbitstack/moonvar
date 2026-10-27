"""Write docs/api.html from each package's interface file and the `///` comments
in its sources, so the reference follows the code. Run from the repository root:

    python scripts/gen_api.py

The output is committed; the docs workflow regenerates it and fails when the
result differs from what is in the tree.
"""

import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent

# (package, folder, one line about it, groups in the order a reader wants them)
PACKAGES = [
    (
        "fixed",
        "fixed",
        "Byte order for the widths a machine has: u8 to u64, the 24-bit length TLS and HTTP/2 "
        "use, floats, and a width carried in a variable.",
    ),
    (
        "quic",
        "quic",
        "RFC 9000 §16. Two bits name the width, sixty-two carry the value.",
    ),
    (
        "prefix",
        "prefix",
        "RFC 7541 §5.1. A value in the low N bits of the first octet, continuing when it does "
        "not fit — HPACK, and QPACK unchanged.",
    ),
    (
        "leb128",
        "leb128",
        "Base-128 varints: seven bits an octet, least significant first, plus the zigzag that "
        "keeps signed values short.",
    ),
    (
        "lenenc",
        "lenenc",
        "MySQL's length-encoded integer: one octet below 251, otherwise a marker and "
        "little-endian octets.",
    ),
]

DECL = re.compile(
    r"^pub(?:\((?:all|open)\))?\s+(fn|let|struct|enum|suberror|trait|type)\s+"
    r"([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)"
)
TRAIT_METHODS = re.compile(
    r"::(equal|not_equal|output|to_string|to_repr|hash|hash_combine|compare)\("
)

GROUP_ORDER = [
    "Types",
    "Values",
    "Encoding",
    "Decoding",
    "Readers",
    "Writers",
    "Measuring",
    "Signed",
    "Errors",
]


def group_of(item):
    if item["kind"] in ("enum", "struct", "suberror"):
        return "Types" if item["kind"] != "suberror" else "Errors"
    if item["kind"] == "let":
        return "Values"
    name = item["name"]
    if name.startswith("read"):
        return "Readers"
    if name.startswith("write") or name == "encode":
        return "Encoding" if name == "encode" else "Writers"
    if name.startswith("decode") or name == "flagged":
        return "Decoding"
    if name == "size":
        return "Measuring"
    if name in ("zigzag", "unzigzag"):
        return "Signed"
    return "Values"


def sources(folder):
    for path in sorted((ROOT / folder).glob("*.mbt")):
        if path.name.endswith("_test.mbt"):
            continue
        yield path.read_text(encoding="utf-8").splitlines()


def docs_of(folder):
    """Doc comments by declared name, and inline `//` notes by `Enum.Variant`."""
    out = {}
    for lines in sources(folder):
        pending, owner = [], None
        for line in lines:
            stripped = line.strip()
            if stripped == "///|":
                pending = []
                continue
            if stripped.startswith("///"):
                pending.append(stripped[3:].strip())
                continue
            m = DECL.match(line)
            if m:
                if pending:
                    out[m.group(2)] = " ".join(p for p in pending if p)
                owner = (
                    m.group(2)
                    if m.group(1) == "enum" and line.rstrip().endswith("{")
                    else None
                )
                pending = []
                continue
            if owner:
                if line.startswith("}"):
                    owner = None
                else:
                    v = re.match(r"\s+([A-Z]\w*)\s*(?://\s*(.*))?$", line)
                    if v and v.group(2):
                        out[owner + "." + v.group(1)] = v.group(2)
            pending = []
    return out


def items_of(folder):
    """Declarations from the interface file, in the order it lists them."""
    lines = (ROOT / folder / "pkg.generated.mbti").read_text(encoding="utf-8").splitlines()
    items, block = [], None
    for line in lines:
        if block is not None:
            if line.startswith("}"):
                items.append(block)
                block = None
            else:
                block["variants"].append(line.strip())
            continue
        m = re.match(r"pub(?:\((?:all|open)\))?\s+(enum|struct|suberror)\s+(\w+)", line)
        if m:
            block = {
                "kind": m.group(1),
                "name": m.group(2),
                "sig": line.rstrip(" {"),
                "variants": [],
            }
            if not line.rstrip().endswith("{"):
                items.append(block)
                block = None
            continue
        m = re.match(r"pub fn (\w+)::(\w+)", line)
        if m:
            items.append(
                {
                    "kind": "method",
                    "name": m.group(1) + "::" + m.group(2),
                    "sig": line,
                    "owner": m.group(1),
                }
            )
            continue
        m = re.match(r"pub fn (\w+)", line)
        if m:
            items.append({"kind": "fn", "name": m.group(1), "sig": line})
            continue
        m = re.match(r"pub let (\w+)", line)
        if m:
            items.append({"kind": "let", "name": m.group(1), "sig": line})
            continue
        m = re.match(r"pub impl (\w+) for (\w+)", line)
        if m:
            items.append(
                {"kind": "impl", "name": m.group(1), "sig": line, "owner": m.group(2)}
            )
    return items


def prose(text):
    if not text:
        return ""
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text, quote=False))
    return f"<p>{text}</p>"


def sig(text):
    return f'<pre class="sig">{html.escape(text.strip(), quote=False)}</pre>'


def anchor(pkg, name):
    return f"{pkg}-{name}".replace("::", "-")


def render():
    nav, body, total = [], [], 0
    for pkg, folder, intro in PACKAGES:
        docs, items = docs_of(folder), items_of(folder)
        route = f"moonbitstack/moonvar/{pkg}"
        entries = [i for i in items if i["kind"] != "impl" and not TRAIT_METHODS.search(i["sig"])]
        total += len(entries)

        grouped = {}
        for item in entries:
            grouped.setdefault(group_of(item), []).append(item)
        groups = [g for g in GROUP_ORDER if g in grouped]

        nav.append(f'<ol><li><a href="#{anchor(pkg, "top")}">{pkg}</a><ol class="sub">')
        for g in groups:
            for i in sorted(grouped[g], key=lambda x: x["name"]):
                nav.append(
                    f'<li><a href="#{anchor(pkg, i["name"])}">{i["name"]}</a></li>'
                )
        nav.append("</ol></li></ol>")

        body.append(f'<section class="band" id="{anchor(pkg, "top")}">')
        body.append(
            f'<div class="band-head"><h2>{pkg}</h2>'
            f'<span class="route">{route}</span></div>'
        )
        body.append(prose(intro))
        for g in groups:
            body.append(f'<h4 class="group">{g}</h4>')
            for item in sorted(grouped[g], key=lambda x: x["name"]):
                body.append(f'<div class="entry" id="{anchor(pkg, item["name"])}">')
                kind = item["kind"]
                badge = {"fn": "fn", "let": "let", "enum": "enum",
                         "suberror": "error", "struct": "struct"}.get(kind, kind)
                badge_cls = "kind" + (" ty" if kind in ("enum", "struct") else "") + (
                    " er" if kind == "suberror" else ""
                )
                body.append(
                    f'<h3><span class="{badge_cls}">{badge}</span>{item["name"]}</h3>'
                )
                body.append(prose(docs.get(item["name"], "")))
                if item.get("variants"):
                    body.append(sig(item["sig"] + " {"))
                    chips = []
                    for v in item["variants"]:
                        note = docs.get(f'{item["name"]}.{v}', "")
                        chips.append(
                            "<li>"
                            + html.escape(v)
                            + (f"<small>{html.escape(note)}</small>" if note else "")
                            + "</li>"
                        )
                    body.append(f'<ul class="variants">{"".join(chips)}</ul>')
                else:
                    body.append(sig(item["sig"]))
                impls = sorted(
                    {
                        i["name"]
                        for i in items
                        if i["kind"] == "impl" and i["owner"] == item["name"]
                    }
                )
                if impls:
                    body.append(
                        prose("Implements " + ", ".join(f"`{n}`" for n in impls) + ".")
                    )
                body.append("</div>")
        body.append("</section>")

    page = (ROOT / "docs" / "api.template.html").read_text(encoding="utf-8")
    count = f"{len(PACKAGES)} packages · {total} public items"
    page = (
        page.replace("<!-- nav -->", "\n".join(nav))
        .replace("<!-- body -->", "\n".join(body))
        .replace("<!-- count -->", count)
    )
    (ROOT / "docs" / "api.html").write_text(page, encoding="utf-8", newline="\n")
    print(f"docs/api.html: {len(PACKAGES)} packages, {total} public items")


render()
