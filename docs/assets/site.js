/* Shared behaviour: theme, water, copy buttons, revealed sections, and the
   display-width fix for any glyph that is not one character cell wide. */

(function () {
  const root = document.documentElement;

  /* ---- theme --------------------------------------------------------- */

  const saved = localStorage.getItem("moonvar-theme");
  if (saved === "light" || saved === "dark") root.dataset.theme = saved;

  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)");
  const isDark = () => {
    const t = root.dataset.theme;
    return t === "dark" || (!t && prefersDark.matches);
  };

  function paintThemeButton() {
    const b = document.querySelector(".themebtn");
    if (!b) return;
    const dark = isDark();
    b.textContent = dark ? "☾" : "☀";
    b.setAttribute("aria-label", dark ? "Switch to the light pool" : "Switch to the dark pool");
    b.title = b.getAttribute("aria-label");
  }

  document.addEventListener("click", (e) => {
    const b = e.target.closest(".themebtn");
    if (!b) return;
    root.dataset.theme = isDark() ? "light" : "dark";
    localStorage.setItem("moonvar-theme", root.dataset.theme);
    paintThemeButton();
    document.dispatchEvent(new CustomEvent("moonvar:theme"));
  });

  /* ---- droplets ------------------------------------------------------ */

  let lastDrop = 0;
  document.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    if (e.target.closest(".surface, .lab, input, select, button, a, pre")) return;
    const now = Date.now();
    if (now - lastDrop < 90) return;
    lastDrop = now;
    for (let i = 0; i < 2; i++) {
      const r = document.createElement("span");
      r.className = "ripple";
      r.style.left = e.clientX + "px";
      r.style.top = e.clientY + "px";
      r.style.animationDelay = i * 140 + "ms";
      document.body.appendChild(r);
      setTimeout(() => r.remove(), 2100 + i * 140);
    }
  });

  /* ---- copy ---------------------------------------------------------- */

  document.addEventListener("click", async (e) => {
    const b = e.target.closest(".copy, [data-copy]");
    if (!b) return;
    const box = b.closest(".code");
    const text = b.dataset.copy || (box ? box.querySelector("pre").innerText : "");
    const was = b.textContent;
    try {
      await navigator.clipboard.writeText(text);
      b.classList.add("done");
      b.textContent = "copied";
      setTimeout(() => {
        b.classList.remove("done");
        b.textContent = was;
      }, 1400);
    } catch (_) {
      b.textContent = "ctrl+c";
    }
  });

  /* ---- reveal -------------------------------------------------------- */

  let observers = [];

  function watchReveals() {
    const items = document.querySelectorAll(".reveal:not(.in)");
    if (!("IntersectionObserver" in window)) {
      items.forEach((el) => el.classList.add("in"));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.05 }
    );
    items.forEach((el) => io.observe(el));
    observers.push(io);
  }

  /* ---- display width ------------------------------------------------ */

  // A monospaced grid counts cells, not characters: an East Asian glyph is two
  // cells wide and an emoji is often two, while the fallback face that draws it
  // measures neither. Wrapping each non-ASCII cluster in a box of its cell width
  // keeps the columns of a terminal transcript straight.
  const WIDE =
    /[\u1100-\u115F\u2E80-\u303E\u3041-\u33FF\u3400-\u4DBF\u4E00-\u9FFF\uA000-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFF60\uFFE0-\uFFE6\u{1F300}-\u{1FAFF}\u{20000}-\u{3FFFD}]/u;

  function alignGlyphs(scope) {
    scope.querySelectorAll(".term").forEach((block) => {
      if (block.dataset.aligned) return;
      block.dataset.aligned = "1";
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      nodes.forEach((node) => {
        const text = node.nodeValue;
        if (!/[^\x00-\x7F]/.test(text)) return;
        const frag = document.createDocumentFragment();
        for (const ch of text) {
          if (ch === "\n") {
            frag.appendChild(document.createTextNode(ch));
            continue;
          }
          if (!/^[\x00-\x7F]$/.test(ch)) {
            const span = document.createElement("span");
            span.className = "glyph" + (WIDE.test(ch) ? " w2" : "");
            span.textContent = ch;
            frag.appendChild(span);
          } else {
            frag.appendChild(document.createTextNode(ch));
          }
        }
        node.parentNode.replaceChild(frag, node);
      });
    });
  }

  /* ---- table of contents -------------------------------------------- */

  function watchHeadings() {
    const links = [...document.querySelectorAll(".toc a[href^='#'], .api-nav a[href^='#']")];
    if (!links.length || !("IntersectionObserver" in window)) return;
    const map = new Map();
    links.forEach((a) => {
      const id = a.getAttribute("href").slice(1);
      const el = document.getElementById(id);
      if (el) map.set(el, a);
    });
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          links.forEach((a) => a.classList.remove("active"));
          const a = map.get(entry.target);
          if (a) a.classList.add("active");
        });
      },
      { rootMargin: "-15% 0px -70% 0px" }
    );
    map.forEach((_, el) => io.observe(el));
    observers.push(io);
  }

  /* ---- API filter ---------------------------------------------------- */

  function wireFilter() {
    const input = document.getElementById("api-filter");
    if (!input || input.dataset.wired) return;
    input.dataset.wired = "1";
    const entries = [...document.querySelectorAll(".entry")];
    const bands = [...document.querySelectorAll(".band")];
    const count = document.getElementById("api-count");
    const total = entries.length;

    const apply = () => {
      const q = input.value.trim().toLowerCase();
      let shown = 0;
      entries.forEach((e) => {
        const hit = !q || e.textContent.toLowerCase().includes(q);
        e.hidden = !hit;
        if (hit) shown++;
      });
      bands.forEach((band) => {
        let group = null;
        let anyInGroup = false;
        const flush = () => {
          if (group) group.hidden = !anyInGroup;
        };
        [...band.children].forEach((child) => {
          if (child.classList.contains("group")) {
            flush();
            group = child;
            anyInGroup = false;
          } else if (child.classList.contains("entry") && !child.hidden) {
            anyInGroup = true;
          }
        });
        flush();
        band.hidden = ![...band.querySelectorAll(".entry")].some((e) => !e.hidden);
      });
      if (count) count.textContent = q ? `${shown} of ${total} entries` : `${total} entries`;
    };

    input.addEventListener("input", apply);
    apply();
  }

  function markNav() {
    const here = (location.pathname.split("/").pop() || "index.html").toLowerCase();
    document.querySelectorAll(".nav a[href]").forEach((a) => {
      const href = a.getAttribute("href").replace(/^\.\//, "").toLowerCase();
      if (href === here) a.setAttribute("aria-current", "page");
      else a.removeAttribute("aria-current");
    });
  }

  document.addEventListener("htmx:afterRequest", (e) => {
    const xhr = e.detail && e.detail.xhr;
    if (!xhr || !xhr.responseText) return;
    const m = /<title>([^<]*)<\/title>/i.exec(xhr.responseText);
    if (m) document.title = m[1];
  });

  document.addEventListener("htmx:afterSettle", () => {
    markNav();
    if (typeof window.moonvarBoot === "function") window.moonvarBoot();
  });

  function boot() {
    paintThemeButton();
    markNav();
    wireFilter();
    watchReveals();
    alignGlyphs(document);
    watchHeadings();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  document.addEventListener("htmx:afterSettle", () => {
    observers.forEach((o) => o.disconnect());
    observers = [];
    paintThemeButton();
    wireFilter();
    watchReveals();
    alignGlyphs(document);
    watchHeadings();
  });

  prefersDark.addEventListener("change", paintThemeButton);
})();
