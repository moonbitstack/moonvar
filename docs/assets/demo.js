/* The live half of the site: every octet on this page comes back from
   assets/moonvar.js, which is this repository compiled to JavaScript. */

const state = { value: "1337", bits: 5, enc: "quic", hex: "4539" };

let engine = null;
let engineError = null;

async function load() {
  if (engine || engineError) return engine;
  try {
    engine = await import("./moonvar.js");
  } catch (err) {
    engineError = err;
    console.warn("moonvar.js is not built; the panels stay empty.", err);
  }
  return engine;
}

const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* ---- the five rows of the surface ------------------------------------ */

const NAMES = {
  quic: ["quic", "RFC 9000 §16"],
  prefix: ["prefix", "RFC 7541 §5.1"],
  leb128: ["leb128", "protobuf · DWARF"],
  lenenc: ["lenenc", "MySQL · MariaDB"],
  fixedbe: ["fixed", "big-endian"],
  fixedle: ["fixed", "little-endian"],
};

function octets(hex) {
  const out = [];
  for (let i = 0; i < hex.length; i += 2) out.push(hex.slice(i, i + 2));
  return out;
}

function rowHTML(row) {
  const [name, note] = NAMES[row.id] || [row.id, ""];
  const cells = octets(row.hex)
    .map((o) => `<span class="octet">${o}</span>`)
    .join("");
  const meta = row.err
    ? `<span class="bad">${row.err}</span>`
    : `<span>${row.size} ${row.size === 1 ? "octet" : "octets"}</span>` +
      `<span class="tick" aria-hidden="true">✓</span>` +
      `<span>reads ${row.read}</span>`;
  return `<div class="row" data-id="${row.id}">
      <div class="row-name"><b>${name}</b><span>${note}</span></div>
      <div class="octets">${cells || `<span class="octet sep">—</span>`}</div>
      <div class="row-meta">${meta}</div>
    </div>`;
}

function paintSurface(payload) {
  const box = document.getElementById("rows");
  if (!box) return;
  if (!payload.ok) {
    box.innerHTML = `<div class="row"><div class="row-name"><b>—</b></div>
      <div class="octets"><span class="octet sep">${payload.error}</span></div>
      <div class="row-meta"></div></div>`;
    return;
  }
  box.innerHTML = payload.rows.map(rowHTML).join("");
  const total = payload.rows.length;
  const good = payload.rows.filter((r) => !r.err).length;
  const status = document.getElementById("status");
  if (status) {
    status.textContent = `${good} of ${total} encodings carry this value`;
  }
}

async function refreshSurface() {
  const api = await load();
  if (!api) return;
  paintSurface(JSON.parse(api.probe(state.value, state.bits)));
}

/* ---- bit anatomy ------------------------------------------------------ */

/* Each octet as eight cells, with the class of every bit in the encoding the
   tab names. The rules are the specifications, written out once. */
function classify(enc, bytes, bits) {
  const cells = [];
  const push = (byte, cls) => {
    const row = [];
    for (let b = 7; b >= 0; b--) row.push({ bit: (byte >> b) & 1, cls: cls(b) });
    return row;
  };
  if (enc === "quic") {
    const width = 1 << (bytes[0] >> 6);
    bytes.forEach((byte, i) => {
      if (i === 0) cells.push(push(byte, (b) => (b >= 6 ? "prefix" : "value")));
      else cells.push(push(byte, () => "value"));
    });
    return { cells, width, note: `The top two bits read ${bytes[0] >> 6}, so the integer is ${width} ${width === 1 ? "octet" : "octets"} wide.` };
  }
  if (enc === "prefix") {
    let flags = 8 - bits;
    bytes.forEach((byte, i) => {
      if (i === 0) cells.push(push(byte, (b) => (b >= bits ? "flag" : "prefix")));
      else cells.push(push(byte, (b) => (b === 7 ? "cont" : "value")));
    });
    return { cells, width: bytes.length, note: `The low ${bits} bits of the first octet carry the value; the ${flags} above them belong to the field's flags. Every later octet spends its top bit on "one more follows".` };
  }
  if (enc === "leb128") {
    bytes.forEach((byte, i) => {
      cells.push(push(byte, (b) => (b === 7 ? "cont" : "value")));
    });
    return { cells, width: bytes.length, note: "Every octet gives seven bits to the value, least significant group first. The eighth bit says whether another octet follows." };
  }
  if (enc === "lenenc") {
    const first = bytes[0];
    const marker = first >= 0xfb;
    bytes.forEach((byte, i) => {
      if (i === 0) cells.push(push(byte, () => (marker ? "marker" : "value")));
      else cells.push(push(byte, () => "value"));
    });
    return {
      cells,
      width: bytes.length,
      note: marker
        ? `The first octet is the marker 0x${first.toString(16)}, and the ${bytes.length - 1} after it are the value, little-endian.`
        : "Under 251 there is no marker: the first octet is the value.",
    };
  }
  bytes.forEach((byte) => cells.push(push(byte, () => "value")));
  return { cells, width: bytes.length, note: "A fixed width is all value bits. Byte order is the only decision the caller makes." };
}

function bitsHTML(bytes, cells) {
  return bytes
    .map((byte, i) => {
      const row = cells[i] || [];
      const bits = row
        .map(
          (c, b) =>
            `<span class="bit ${c.cls}" title="bit ${7 - b} of octet ${i} · ${c.cls}">${c.bit}</span>`
        )
        .join("");
      return `<div class="bite">
          <div class="bite-head"><b>${String(i + 1).padStart(2, "0")}</b>
            <span>0x${byte.toString(16).padStart(2, "0")}</span></div>
          <div class="bits">${bits}</div>
        </div>`;
    })
    .join("");
}

function stepsHTML(enc, row, bytes, bits) {
  const out = [];
  const step = (label, text) =>
    out.push(`<div class="step"><b>${label}</b><div>${text}</div></div>`);
  const hx = (b) => "0x" + b.toString(16).padStart(2, "0");
  const num = (n) => n.toLocaleString("en-US").replace(/,/g, "\u2009");

  if (enc === "quic") {
    const w = 1 << (bytes[0] >> 6);
    step("01", `${hx(bytes[0])} · top two bits <code>${(bytes[0] >> 6).toString(2).padStart(2, "0")}</code> name ${w} ${w === 1 ? "octet" : "octets"}; the six below them start the value.`);
    for (let i = 1; i < bytes.length; i++)
      step(String(i + 1).padStart(2, "0"), `${hx(bytes[i])} · eight more bits, big-end first.`);
  } else if (enc === "prefix") {
    const ceiling = (1 << bits) - 1;
    const first = bytes[0] & ceiling;
    step("01", first < ceiling
      ? `${hx(bytes[0])} · the low ${bits} bits carry ${first}, and that is the whole value.`
      : `${hx(bytes[0])} · the low ${bits} bits are all ones (${ceiling}), the ceiling for this width, so the rest is a base-128 remainder.`);
    let scale = 1;
    for (let i = 1; i < bytes.length; i++) {
      const body = bytes[i] & 0x7f;
      const more = (bytes[i] & 0x80) !== 0;
      step(String(i + 1).padStart(2, "0"), `${hx(bytes[i])} · seven bits ${num(body)}${i > 1 ? " × " + num(scale) : ""}; bit 7 is ${more ? "set, another octet follows" : "clear, this is the last one"}.`);
      scale *= 128;
    }
    step("=", `the library reads <code>${row.read}</code>.`);
  } else if (enc === "leb128") {
    let scale = 1;
    bytes.forEach((b, i) => {
      const body = b & 0x7f;
      const more = (b & 0x80) !== 0;
      step(String(i + 1).padStart(2, "0"), `${hx(b)} · low seven bits ${body}${i ? " × " + num(scale) : ""}; bit 7 is ${more ? "set, so another octet follows" : "clear, so the value ends here"}.`);
      scale *= 128;
    });
    step("=", `the library reads <code>${row.read}</code>.`);
  } else if (enc === "lenenc") {
    const first = bytes[0];
    if (first < 0xfb) {
      step("01", `${hx(first)} is below 0xfb, so it is the value itself.`);
    } else {
      step("01", `${hx(first)} is a marker: ${bytes.length - 1} octet${bytes.length > 2 ? "s" : ""} of value follow, little-endian.`);
      for (let i = 1; i < bytes.length; i++)
        step(String(i + 1).padStart(2, "0"), `${hx(bytes[i])} · octet ${i} of ${bytes.length - 1}, least significant first.`);
    }
    step("=", `the library reads <code>${row.read}</code>.`);
  } else {
    bytes.forEach((b, i) =>
      step(String(i + 1).padStart(2, "0"), `${hx(b)} · octet ${i + 1} of ${bytes.length}, big-end first.`)
    );
    step("=", `the library reads <code>${row.read}</code>.`);
  }
  return out.join("");
}

async function paintLab() {
  const api = await load();
  const bites = document.getElementById("bites");
  if (!api || !bites) return;
  const payload = JSON.parse(api.probe(state.value, state.bits));
  if (!payload.ok) {
    bites.innerHTML = `<p class="dim small">${payload.error}</p>`;
    return;
  }
  const row = payload.rows.find((r) => r.id === state.enc);
  const note = document.getElementById("lab-note");
  if (!row || row.err) {
    bites.innerHTML = `<p class="bad">${row ? row.err : "no such encoding"}</p>`;
    if (note) note.textContent = "This value does not fit the encoding, so there are no octets to show.";
    document.getElementById("steps").innerHTML = "";
    return;
  }
  const bytes = octets(row.hex).map((h) => parseInt(h, 16));
  const { cells, note: text } = classify(state.enc, bytes, state.bits);
  bites.innerHTML = bitsHTML(bytes, cells);
  const sum = document.getElementById("lab-sum");
  if (sum) sum.innerHTML = `<b>${row.read}</b> → ${octets(row.hex).join(" ")}`;
  if (note) note.textContent = text;
  document.getElementById("steps").innerHTML = stepsHTML(state.enc, row, bytes, state.bits);
}

/* ---- what each costs -------------------------------------------------- */

const SAMPLES = [
  ["1", 1],
  ["127", 127],
  ["255", 255],
  ["65 535", 65535],
  ["16 777 215", 16777215],
  ["4 294 967 295", 4294967295],
  ["1 099 511 627 776", 1099511627776],
];

async function paintCost() {
  const api = await load();
  const tbody = document.getElementById("cost-body");
  if (!api || !tbody) return;
  const ids = ["quic", "prefix", "leb128", "lenenc", "fixedbe"];
  const rows = SAMPLES.map(([label, v]) => {
    const payload = JSON.parse(api.probe(String(v), 5));
    const cells = ids.map((id) => {
      const r = payload.rows.find((row) => row.id === id);
      if (!r || r.err) return `<td class="mono dim">—</td>`;
      const px = Math.max(3, Math.round((r.size / 10) * 62));
      return `<td class="mono"><span class="cost"><span class="cost-track"><span class="cost-bar" style="width:${px}px"></span></span><span class="cost-n">${r.size}</span></span></td>`;
    });
    return `<tr><td class="mono">${label}</td>${cells.join("")}</tr>`;
  });
  tbody.innerHTML = rows.join("");
}

/* ---- the other direction ---------------------------------------------- */

async function paintDecode() {
  const api = await load();
  const box = document.getElementById("decode-rows");
  if (!api || !box) return;
  const payload = JSON.parse(api.scan(state.hex, state.bits));
  if (!payload.ok) {
    box.innerHTML = `<p class="bad">${payload.error}</p>`;
    return;
  }
  const LABEL = {
    leb128: "leb128",
    lenenc: "lenenc",
    quic: "quic",
    prefix: `prefix(${state.bits})`,
    fixed1: "fixed 1",
    fixed2: "fixed 2",
    fixed3: "fixed 3",
    fixed4: "fixed 4",
    fixed8: "fixed 8",
  };
  box.innerHTML = payload.rows
    .map((r) => {
      const v = r.err ? `<span class="bad">${r.err}</span>` : `${r.value} <span class="dim">· ${r.used} octets</span>`;
      return `<div class="decode-row"><span class="k">${LABEL[r.id] || r.id}</span><span class="v">${v}</span></div>`;
    })
    .join("");
}

/* ---- wiring ----------------------------------------------------------- */

function wireValue(input, update) {
  if (!input) return;
  let t = 0;
  const run = () => {
    clearTimeout(t);
    t = setTimeout(update, 90);
  };
  input.addEventListener("input", () => {
    const clean = input.value.replace(/[^\d]/g, "").slice(0, 20);
    if (clean !== input.value) input.value = clean;
    state.value = clean || "0";
    run();
  });
  $$(".preset").forEach((b) =>
    b.addEventListener("click", () => {
      input.value = b.dataset.v;
      state.value = b.dataset.v;
      update();
    })
  );
}

function wireBits(select) {
  if (!select) return;
  select.value = String(state.bits);
  select.addEventListener("change", () => {
    state.bits = Number(select.value);
    document.dispatchEvent(new CustomEvent("moonvar:bits"));
  });
}

let bitsWired = false;

function boot() {
  const value = document.getElementById("val");
  const bits = document.getElementById("bits");
  wireBits(bits);

  if (value) {
    wireValue(value, refreshSurface);
    refreshSurface();
  }

  const tabs = $$(".tab");
  tabs.forEach((tab) =>
    tab.addEventListener("click", () => {
      tabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
      state.enc = tab.dataset.enc;
      paintLab();
    })
  );

  if (document.getElementById("bites")) {
    wireValue(document.getElementById("lab-val"), paintLab);
    const labBits = document.getElementById("lab-bits");
    wireBits(labBits);
    if (!bitsWired) {
      bitsWired = true;
      document.addEventListener("moonvar:bits", () => {
        paintLab();
        paintDecode();
        paintCost();
        refreshSurface();
      });
    }
    paintLab();
    paintCost();
  }

  const hexIn = document.getElementById("hex");
  if (hexIn) {
    hexIn.addEventListener("input", () => {
      state.hex = hexIn.value.replace(/[^0-9a-fA-F]/g, "").slice(0, 46);
      if (hexIn.value !== state.hex) hexIn.value = state.hex;
      paintDecode();
    });
    paintDecode();
  }
}

// A boosted navigation replaces #main; site.js calls this again for the new DOM.
window.moonvarBoot = boot;

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
