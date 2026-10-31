// 0–10 s. The cold open, and the thing only Sway does: clipboard history you
// play with the trackpad. Three copies stack on the beat; then double-tap a
// corner, the glass picker blooms, one finger glides, and lifting pastes.
// The little trackpad then hands off to the intro, which turns it into the icon.
import { h, at, tf, words, reveal, fade, glyph } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, CLIP, BEAT } from "../timeline.js";

const S = SCENES.find((s) => s.id === "hook");
const ITEMS = [
  { text: "Meet at 7:30 by the north entrance.", app: "Messages", age: "Just now", icon: "bubble" },
  { text: "Flight 1024 · Seat 14C · Boarding 6:05", app: "Mail", age: "2 min ago", icon: "mail" },
  { text: "#1F2023", app: "Design", age: "4 min ago", icon: "swatch" },
  { text: "The edges of your trackpad, as controls.", app: "Notes", age: "6 min ago", icon: "notes" },
  { text: "Thanks again, see you Friday!", app: "Mail", age: "1 hr ago", icon: "mail" },
];
const PICK = 3;
const PASTED = ITEMS[PICK].text;
const ROW = 90;
const APP_ICONS = {
  bubble: '<path d="M4 11.5c0-4 3.6-7 8-7s8 3 8 7-3.6 7-8 7c-1 0-2-.1-2.9-.4L5 19.5l1.2-3.4C4.8 14.9 4 13.3 4 11.5z" fill="currentColor"/>',
  mail: '<rect x="3.5" y="6" width="17" height="12.5" rx="2.4" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M4.5 7.5l7.5 6 7.5-6" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/>',
  swatch: '<circle cx="9" cy="10" r="5.2" fill="currentColor" opacity="0.55"/><circle cx="15" cy="10" r="5.2" fill="currentColor" opacity="0.8"/><circle cx="12" cy="15" r="5.2" fill="currentColor"/>',
  notes: '<rect x="5" y="4" width="14" height="16.5" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4.5" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/>',
};
const appIcon = (name) => h("div", { style: { width: "48px", height: "48px", borderRadius: "12px", flex: "none", background: "linear-gradient(180deg,#45464b,#2a2b2f)", color: "#f1f2f5", display: "grid", placeItems: "center", boxShadow: "inset 0 1px 0 rgba(255,255,255,0.12)" } }, h("span", { html: `<svg viewBox="0 0 24 24" width="28" height="28">${APP_ICONS[name]}</svg>` }));

export default {
  id: "hook",
  pre: 0,
  post: 0.3,
  mount(root) {
    this.copies = [0, 1, 2].map(() => at(words("Copy.", "h1 grad center"), 960, 540));

    // A plain document to paste into.
    this.caret = h("span", { style: { display: "inline-block", width: "3px", height: "40px", background: "#eef3ff", verticalAlign: "-7px", marginLeft: "2px", borderRadius: "2px" } });
    this.pasted = h("span", { style: { borderRadius: "8px", padding: "2px 0" } }, "");
    this.doc = at(h("div", { class: "glass", style: { width: "1080px", height: "600px", borderRadius: "28px", overflow: "hidden" } },
      h("div", { style: { height: "62px", display: "flex", alignItems: "center", gap: "11px", padding: "0 24px", borderBottom: "1px solid rgba(255,255,255,0.07)", background: "rgba(255,255,255,0.03)" } },
        ...[0, 1, 2].map(() => h("span", { style: { width: "15px", height: "15px", borderRadius: "50%", background: "rgba(255,255,255,0.18)" } })),
        h("span", { style: { flex: 1, textAlign: "center", font: "600 22px var(--font)", color: "#8d8f96", marginRight: "70px" } }, "Draft")),
      h("div", { style: { padding: "52px 64px", font: "500 33px/1.75 var(--font)", color: "#d9dbe0" } },
        h("div", { style: { font: "680 50px/1.2 var(--font)", color: "#f5f5f7", letterSpacing: "-0.02em", marginBottom: "26px" } }, "Launch notes"),
        h("div", {}, h("span", { style: { color: "#8d8f96" } }, "Tagline: "), this.pasted, this.caret),
        h("div", { style: { color: "#6f7178" } }, "Ship Friday. Keep it simple."),
        h("div", { style: { color: "#6f7178" } }, "Demo: corners, edges, clipboard."))), 760, 575);

    // A small trackpad showing what the finger does.
    this.inset = at(h("div", { style: { width: "380px", height: "238px", borderRadius: "24px", background: "linear-gradient(180deg,#1a1b1e,#111214)", border: "1px solid rgba(255,255,255,0.11)", boxShadow: "0 30px 70px rgba(0,0,0,0.55)" } },
      h("div", { style: { position: "absolute", right: "10px", top: "10px", width: "84px", height: "56px", border: "2px dashed rgba(255,255,255,0.18)", borderRadius: "8px 16px 8px 8px" } }),
      h("div", { class: "eyebrow", style: { position: "absolute", left: "22px", bottom: "16px", fontSize: "14px" } }, "Trackpad")), 1610, 855);
    this.fx = h("svg", { width: 380, height: 238, style: { position: "absolute", left: 0, top: 0, overflow: "visible" } });
    this.inset.append(this.fx);

    // The picker, laid out like Sway's own.
    this.highlight = h("div", { style: { position: "absolute", left: "14px", right: "14px", height: `${ROW - 6}px`, borderRadius: "18px", background: "rgba(255,255,255,0.11)" } });
    this.counter = h("span", { style: { font: "600 19px var(--font)", color: "#8d8f96", fontVariantNumeric: "tabular-nums" } }, "1 of 5");
    this.rows = ITEMS.map((item, i) => h("div", { class: "row", style: { position: "relative", height: `${ROW}px`, display: "flex", alignItems: "center", gap: "18px", padding: "0 26px" } },
      appIcon(item.icon),
      h("div", { style: { flex: 1, minWidth: 0 } },
        h("div", { class: "rowtext", style: { font: "500 25px/1.25 var(--font)", color: "#f2f3f6", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, item.text),
        h("div", { style: { font: "500 17px/1.5 var(--font)", color: "#8d8f96" } }, `${item.app} · ${item.age} · ${item.text.length} characters`)),
      h("div", { style: { width: "30px", height: "30px", borderRadius: "8px", background: "rgba(255,255,255,0.07)", display: "grid", placeItems: "center", font: "650 17px var(--rounded)", color: "#8d8f96" } }, String(i + 1))));
    const list = h("div", { style: { position: "relative", padding: "0 0 4px" } }, this.highlight, ...this.rows,
      h("div", { style: { height: "70px", display: "flex", alignItems: "center", gap: "18px", padding: "0 26px", color: "#c9cbd1" } },
        h("div", { style: { width: "48px", display: "grid", placeItems: "center", color: "#8d8f96" } }, h("span", { html: '<svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="8.5"/><path d="M9 9l6 6M15 9l-6 6" stroke-linecap="round"/></svg>' })),
        h("span", { style: { font: "600 23px var(--font)" } }, "Cancel"), h("span", { style: { font: "500 18px var(--font)", color: "#8d8f96" } }, "Paste nothing")));
    this.picker = at(h("div", { class: "glass", style: { width: "780px", borderRadius: "34px", padding: "18px 0 14px", background: "linear-gradient(180deg, rgba(52,53,58,0.86), rgba(30,31,35,0.9))" } },
      h("div", { style: { display: "flex", alignItems: "center", gap: "12px", padding: "6px 34px 14px", color: "#f2f3f6" } }, glyph("clipboard", 24), h("span", { style: { font: "650 24px var(--font)", flex: 1 } }, "Clipboard"), this.counter),
      list,
      h("div", { style: { padding: "10px 34px 6px", font: "500 18px var(--font)", color: "#8d8f96", borderTop: "1px solid rgba(255,255,255,0.06)" } }, "Slide to choose  ·  Lift to paste  ·  Slide up to cancel")), 1010, 520);
    this.flash = at(h("div", { style: { width: "1300px", height: "1100px", borderRadius: "50%", background: "radial-gradient(closest-side, rgba(220,230,255,0.16), transparent)" } }), 1010, 520);

    this.toast = at(h("div", { class: "pill dark", style: { fontSize: "25px", padding: "16px 28px 16px 22px" } }, glyph("doc", 26), `Pasted “${PASTED.slice(0, 26)}…”`), 760, 965);
    // One word per move, like a caption on the action itself.
    this.caps = ["Double-tap a corner.", "Slide.", "Lift."].map((text) => at(words(text, "h2 grad center"), 960, 120));
    root.append(...this.copies, this.doc, this.inset, this.flash, this.picker, this.toast, ...this.caps);
  },
  update(t, { bg }) {
    // Three copies, each pushing the last up the history.
    let count = 0;
    for (const c of CLIP.copies) count += spring(t - c, 0.36, 0.78);
    const copiesOut = CLIP.desk - 0.4;
    this.copies.forEach((el, i) => {
      const age = t - CLIP.copies[i];
      const arrive = spring(age, 0.38, 0.62);
      const depth = Math.max(0, count - 1 - i);
      const out = ease.leave(prog(t, copiesOut + (2 - i) * 0.04, copiesOut + 0.35 + (2 - i) * 0.04));
      tf(el, { y: -depth * 128 + 120, s: lerp(1.22, 1, clamp(arrive)) * lerp(1, 0.86, clamp(depth / 2)), o: (age >= 0 ? clamp(arrive * 2) : 0) * (1 - 0.36 * depth) * (1 - out), blur: (1 - clamp(arrive)) * 12 + out * 14 + depth * 1.2 });
      el.__words.forEach((w) => { w.style.opacity = ""; w.style.transform = ""; w.style.filter = ""; });
      el.style.visibility = age >= 0 ? "visible" : "hidden";
    });

    // The desk: document and trackpad.
    const deskIn = ease.settle(prog(t, CLIP.desk, CLIP.desk + 0.8));
    const deskOut = ease.leave(prog(t, CLIP.handoff - 0.15, CLIP.handoff + 0.3));
    tf(this.doc, { y: (1 - deskIn) * 60, s: lerp(0.96, 1, deskIn), o: deskIn * (1 - deskOut), blur: (1 - deskIn) * 12 + deskOut * 10 });
    const insetIn = ease.settle(prog(t, CLIP.desk + 0.2, CLIP.desk + 0.9));
    // The intro takes over this trackpad at the handoff.
    tf(this.inset, { y: (1 - insetIn) * 50, o: insetIn * (1 - prog(t, CLIP.handoff + 0.02, CLIP.handoff + 0.14)), blur: (1 - insetIn) * 10 });

    // Finger on the small trackpad: double-tap the corner, then glide.
    const corner = { x: 328, y: 38 };
    let fx = "";
    for (const tt of CLIP.taps) {
      const age = t - tt;
      if (age < 0 || age > 0.6) continue;
      const p = ease.out(age / 0.6);
      fx += `<circle cx="${corner.x}" cy="${corner.y}" r="${10 + p * 50}" fill="none" stroke="#eef3ff" stroke-width="${2.5 * (1 - p) + 0.4}" opacity="${1 - p}"/>`;
    }
    const tapDot = (tt) => { const a = t - tt; return a > -0.02 && a < 0.12 ? 1 : 0; };
    let steps = 0;
    for (const s of CLIP.steps) steps += ease.inOut(prog(t, s - 0.22, s + 0.05));
    const down = t >= CLIP.taps[1] && t < CLIP.lift + 0.3;
    const dotO = Math.max(tapDot(CLIP.taps[0]), down ? 1 - ease.smooth(prog(t, CLIP.lift, CLIP.lift + 0.25)) : 0);
    if (dotO > 0) {
      const y = corner.y + steps * 44;
      const x = corner.x - steps * 6;
      if (steps > 0.02) fx += `<rect x="${x - 9}" y="${corner.y - 9}" width="18" height="${y - corner.y + 18}" rx="9" fill="url(#trail)" opacity="${dotO}"/>`;
      fx += `<circle cx="${x}" cy="${y}" r="40" fill="url(#tipglow)" opacity="${dotO}"/><circle cx="${x}" cy="${y}" r="13" fill="#fff" opacity="${dotO}"/>`;
    }
    this.fx.innerHTML = `<defs><radialGradient id="tipglow"><stop offset="0" stop-color="#e6edff" stop-opacity="0.5"/><stop offset="1" stop-color="#e6edff" stop-opacity="0"/></radialGradient><linearGradient id="trail" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9fb0d6" stop-opacity="0"/><stop offset="1" stop-color="#eef3ff" stop-opacity="0.75"/></linearGradient></defs>${fx}`;

    // The picker blooms (Sway's spring: response 0.34, damping 0.8)…
    const bloom = spring(t - CLIP.bloom, 0.34, 0.8);
    const gone = ease.leave(prog(t, CLIP.lift, CLIP.lift + 0.24));
    const pickerO = (t >= CLIP.bloom ? clamp(ease.out(prog(t, CLIP.bloom, CLIP.bloom + 0.16))) : 0) * (1 - gone);
    tf(this.picker, { s: lerp(0.9, 1, bloom) * lerp(1, 0.97, gone), y: (1 - clamp(bloom)) * 18, o: pickerO, blur: (1 - clamp(bloom)) * 7 + gone * 6 });
    const flash = t >= CLIP.bloom ? Math.exp(-(t - CLIP.bloom) * 3) : 0;
    tf(this.flash, { s: lerp(0.7, 1.1, clamp(bloom)), o: flash * (1 - gone) });
    // …and the highlight springs from row to row (response 0.3, damping 0.86).
    let sel = 0;
    for (const s of CLIP.steps) sel += spring(t - s, 0.3, 0.86);
    this.highlight.style.top = `${3 + sel * ROW}px`;
    const index = Math.round(clamp(sel, 0, ITEMS.length - 1));
    this.counter.textContent = `${index + 1} of ${ITEMS.length}`;
    this.rows.forEach((r, i) => (r.querySelector(".rowtext").style.fontWeight = i === index ? "620" : "500"));

    // The paste: text appears at the caret with a soft glow.
    const pastedNow = t >= CLIP.lift + 0.05;
    this.pasted.textContent = pastedNow ? PASTED : "";
    const glow = pastedNow ? 1 - ease.smooth(prog(t, CLIP.lift + 0.15, CLIP.lift + 1.4)) : 0;
    this.pasted.style.background = `rgba(225,233,255,${0.22 * glow})`;
    this.pasted.style.boxShadow = `0 0 ${40 * glow}px rgba(225,233,255,${0.35 * glow})`;
    this.pasted.style.color = pastedNow ? "#f5f5f7" : "";
    this.caret.style.opacity = t > CLIP.desk + 0.6 && (Math.floor((t - CLIP.desk) * 1.8) % 2 === 0 || (t > CLIP.taps[0] && t < CLIP.lift + 0.6)) ? "1" : "0";

    const tin = ease.settle(prog(t, CLIP.lift + 0.1, CLIP.lift + 0.4));
    const tout = ease.leave(prog(t, CLIP.handoff - 0.2, CLIP.handoff + 0.05));
    tf(this.toast, { y: (1 - tin) * 30, o: tin * (1 - tout), blur: (1 - tin) * 6 });

    const [c1, c2, c3] = this.caps;
    reveal(c1, t, CLIP.desk + 0.45, CLIP.steps[0] - 0.4, { rise: 0.3, stagger: 0.04, dur: 0.7 });
    reveal(c2, t, CLIP.steps[0] - 0.25, CLIP.lift - 0.35, { rise: 0.3, dur: 0.6 });
    reveal(c3, t, CLIP.lift - 0.2, CLIP.handoff - 0.2, { rise: 0.3, dur: 0.6 });
    bg.style.setProperty("--by", "50%");
    bg.style.setProperty("--ba", String(0.5 + 0.2 * flash));
  },
};
