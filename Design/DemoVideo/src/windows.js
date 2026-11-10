// The windows on the film's screen: a music player, a page of notes, a
// browser. Plain, quiet stand-ins, so Kinara's own feedback is what you watch.
import { h, glyph } from "./ui.js";

const lights = (dim) => ["#ff5f57", "#febc2e", "#28c840"].map((c) => h("span", { style: { width: "12px", height: "12px", borderRadius: "50%", background: dim ? "rgba(255,255,255,0.18)" : c, opacity: dim ? 1 : 0.9, flex: "none" } }));
const line = (w, o = 0.12, ht = 11) => h("div", { style: { width: w, height: `${ht}px`, borderRadius: `${ht / 2}px`, background: `rgba(255,255,255,${o})` } });

/** A window: glass, a title bar, and whatever goes inside. */
export function frame({ x, y, w, ht, title = "", solid = false, dim = false }, ...children) {
  const body = h("div", { style: { position: "absolute", left: "0", right: "0", top: "40px", bottom: "0" } }, ...children);
  const el = h("div", { class: "abs", style: { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${ht}px`, borderRadius: "14px", background: solid ? "linear-gradient(180deg,#26272c,#1b1c20)" : "rgba(26,27,36,0.62)", border: "1px solid rgba(255,255,255,0.11)", backdropFilter: solid ? "" : "blur(34px) saturate(1.4)", boxShadow: "0 30px 70px rgba(0,0,0,0.42), inset 0 1px 0 rgba(255,255,255,0.08)", overflow: "hidden" } },
    h("div", { style: { position: "absolute", left: "0", right: "0", top: "0", height: "40px", display: "flex", alignItems: "center", gap: "8px", padding: "0 14px", borderBottom: "1px solid rgba(255,255,255,0.06)" } }, ...lights(dim),
      h("span", { style: { flex: 1, textAlign: "center", marginRight: "52px", font: "600 13.5px var(--font)", color: "rgba(235,235,245,0.6)" } }, title)),
    body);
  el.__body = body;
  return el;
}

/** The music player: the play/pause target, and what a seek moves. */
export function musicPlayer({ x = 150, y = 190, w = 600, ht = 300 } = {}) {
  const playIcon = h("span", { style: { display: "grid", placeItems: "center" } });
  const progress = h("div", { class: "abs", style: { left: "0", top: "0", bottom: "0", borderRadius: "3px", background: "rgba(255,255,255,0.88)" } });
  const knob = h("div", { class: "abs", style: { top: "50%", width: "13px", height: "13px", margin: "-6.5px 0 0 -6.5px", borderRadius: "50%", background: "#fff", boxShadow: "0 2px 6px rgba(0,0,0,0.4)", opacity: "0" } });
  const elapsed = h("span", {}, "1:12");
  const remaining = h("span", {}, "3:48");
  const art = h("div", { style: { width: "180px", height: "180px", borderRadius: "14px", flex: "none", background: "radial-gradient(120% 90% at 20% 15%, #ffb36b, transparent 55%), radial-gradient(90% 80% at 85% 85%, #6b4dff, transparent 60%), linear-gradient(140deg, #ff5f7e, #7a2cff)", boxShadow: "0 16px 36px rgba(0,0,0,0.35), inset 0 1px 0 rgba(255,255,255,0.25)", position: "relative", overflow: "hidden" } },
    h("div", { class: "abs", style: { left: "24px", bottom: "20px", width: "124px", height: "124px", borderRadius: "50%", border: "2px solid rgba(255,255,255,0.35)" } }));
  const el = frame({ x, y, w, ht, title: "Music" },
    h("div", { style: { display: "flex", gap: "30px", padding: "34px 36px", height: "100%", alignItems: "center" } }, art,
      h("div", { style: { flex: 1, display: "flex", flexDirection: "column", gap: "8px", color: "#fff" } },
        h("div", { style: { font: "700 30px/1.1 var(--font)", letterSpacing: "-0.02em" } }, "Night Drive"),
        h("div", { style: { font: "500 17px/1.3 var(--font)", color: "rgba(235,235,245,0.6)" } }, "Kinara Radio"),
        h("div", { style: { position: "relative", height: "6px", borderRadius: "3px", background: "rgba(255,255,255,0.16)", marginTop: "22px" } }, progress, knob),
        h("div", { style: { display: "flex", justifyContent: "space-between", font: "500 13px var(--font)", color: "rgba(235,235,245,0.5)", fontVariantNumeric: "tabular-nums" } }, elapsed, remaining),
        h("div", { style: { display: "flex", alignItems: "center", justifyContent: "center", gap: "40px", marginTop: "6px", color: "rgba(255,255,255,0.88)" } }, glyph("back", 24), playIcon, glyph("forward", 24)))));
  let wasPaused = null;
  const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
  el.__set = ({ paused = false, seconds = 72, total = 228, seeking = 0 }) => {
    if (paused !== wasPaused) { playIcon.innerHTML = ""; playIcon.append(glyph(paused ? "play" : "pause", 30)); wasPaused = paused; }
    progress.style.width = `${(seconds / total) * 100}%`;
    knob.style.left = `${(seconds / total) * 100}%`;
    knob.style.opacity = String(seeking);
    elapsed.textContent = clock(seconds);
    remaining.textContent = `-${clock(total - seconds)}`;
  };
  el.__set({});
  return el;
}

/** A window of nothing in particular, for depth. */
export function quietWindow({ x, y, w, ht, title = "" }) {
  return frame({ x, y, w, ht, title },
    h("div", { style: { padding: "22px 24px", display: "grid", gap: "14px" } },
      h("div", { style: { height: "110px", borderRadius: "10px", background: "linear-gradient(135deg, rgba(255,255,255,0.13), rgba(255,255,255,0.03))" } }), line("84%"), line("66%", 0.08), line("74%", 0.08), line("52%", 0.08)));
}

/** A page of notes to paste into. */
export function notesPage({ x, y, w, ht }) {
  const caret = h("span", { style: { display: "inline-block", width: "2.5px", height: "25px", background: "#4c9bff", verticalAlign: "-5px", marginLeft: "1px", borderRadius: "2px" } });
  const pasted = h("span", { style: { borderRadius: "6px", padding: "1px 0" } }, "");
  const el = frame({ x, y, w, ht, title: "Launch notes", solid: true },
    h("div", { style: { padding: "34px 44px", font: "500 21px/1.8 var(--font)", color: "#d9dbe0" } },
      h("div", { style: { font: "700 34px/1.2 var(--font)", color: "#f5f5f7", letterSpacing: "-0.02em", marginBottom: "18px" } }, "Launch notes"),
      h("div", { style: { whiteSpace: "nowrap" } }, h("span", { style: { color: "#8d8f96" } }, "Tagline: "), pasted, caret),
      h("div", { style: { color: "#6f7178" } }, "Ship Friday. Keep it simple."),
      h("div", { style: { color: "#6f7178" } }, "Demo: corners, edges, clipboard.")));
  Object.assign(el, { __caret: caret, __pasted: pasted });
  return el;
}

/** A browser: tabs along the top, a page below. */
export function browser({ x, y, w, ht, tabs = ["Kinara", "Inbox", "Calendar", "Docs"] }) {
  const tabEls = tabs.map((name) => h("div", { style: { flex: 1, height: "30px", borderRadius: "8px", display: "flex", alignItems: "center", justifyContent: "center", font: "550 13px var(--font)", color: "rgba(235,235,245,0.7)" } }, name));
  const pill = h("div", { class: "abs", style: { top: "6px", height: "30px", borderRadius: "8px", background: "rgba(255,255,255,0.14)", boxShadow: "inset 0 0.5px 0 rgba(255,255,255,0.2)" } });
  const pages = tabs.map((_, i) => h("div", { class: "abs", style: { inset: "0", padding: "26px 30px", display: "grid", gap: "14px", alignContent: "start" } },
    h("div", { style: { height: "150px", borderRadius: "12px", background: `linear-gradient(${120 + i * 40}deg, ${["rgba(90,120,255,0.5)", "rgba(255,120,150,0.42)", "rgba(80,210,200,0.42)", "rgba(255,180,90,0.42)"][i % 4]}, rgba(255,255,255,0.04))` } }),
    line(`${78 - i * 6}%`, 0.16, 14), line("92%", 0.08), line("86%", 0.08), line(`${60 + i * 7}%`, 0.08)));
  const strip = h("div", { class: "abs", style: { left: "0", right: "0", top: "0", height: "42px", display: "flex", gap: "6px", padding: "6px 12px", background: "rgba(255,255,255,0.03)", borderBottom: "1px solid rgba(255,255,255,0.06)" } }, pill, ...tabEls);
  const el = frame({ x, y, w, ht, title: "Browser", solid: true }, strip, h("div", { class: "abs", style: { left: "0", right: "0", top: "42px", bottom: "0" } }, ...pages));
  const inner = w - 24, tabW = (inner - 6 * (tabs.length - 1)) / tabs.length;
  /** `at` may be fractional: the pill slides between tabs. */
  el.__set = (at) => {
    pill.style.left = `${12 + at * (tabW + 6)}px`;
    pill.style.width = `${tabW}px`;
    const active = Math.round(at);
    tabEls.forEach((tab, i) => (tab.style.color = i === active ? "#fff" : "rgba(235,235,245,0.6)"));
    pages.forEach((page, i) => (page.style.opacity = String(Math.max(0, 1 - Math.abs(at - i) * 1.6))));
  };
  el.__set(0);
  return el;
}
