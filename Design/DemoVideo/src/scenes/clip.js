// Clipboard history, the thing only Kinara does. Double-tap a corner and the
// glass picker opens; keep the finger down and slide to choose; lift to paste.
// On the screen, the edge light rides beside the finger, so you see where it is.
import { h, at, words, reveal, glyph } from "../ui.js";
import { notesPage, quietWindow } from "../windows.js";
import { sequence, tapCorner, CORNER_POINT } from "../kit.js";
import { prog, ease, lerp, spring, clamp, CLIP, scene } from "../timeline.js";
import { edgePoint } from "../world.js";

const S = scene("clip");
const ITEMS = [
  { text: "Meet at 7:30 by the north entrance.", app: "Messages", age: "Just now", icon: "bubble" },
  { image: true, app: "Screenshot", age: "2 min ago", detail: "2880 × 1800", size: "1.2 MB" },
  { text: "Flight 1024 · Seat 14C · Boarding 6:05", app: "Mail", age: "4 min ago", icon: "mail" },
  { text: "The edges of your trackpad, as controls.", app: "Notes", age: "6 min ago", icon: "notes" },
  { text: "Thanks again, see you Friday!", app: "Mail", age: "1 hr ago", icon: "mail" },
];
const PICK = 3, ROW = 54, PICKER = { x: 764, y: 150, w: 480 };
const tile = (icon) => h("div", { style: { width: "44px", display: "grid", placeItems: "center", flex: "none" } }, h("div", { style: { width: "30px", height: "30px", borderRadius: "8px", background: "linear-gradient(180deg,#4a4b51,#2c2d32)", color: "#f1f2f5", display: "grid", placeItems: "center", boxShadow: "inset 0 1px 0 rgba(255,255,255,0.14)" } }, glyph(icon, 18)));
// A copied screenshot, shown as the picker shows pictures: a small thumbnail.
const thumbnail = () => h("div", { style: { width: "44px", height: "34px", flex: "none", borderRadius: "7px", overflow: "hidden", position: "relative", boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.16)", background: "radial-gradient(ellipse at 70% 15%, rgba(170,196,255,0.8), transparent 55%), linear-gradient(160deg,#4a5a86,#1d2333)" } },
  h("div", { class: "abs", style: { left: "6px", top: "7px", width: "24px", height: "18px", borderRadius: "3px", background: "rgba(245,246,250,0.88)" } }),
  h("div", { class: "abs", style: { left: "22px", top: "13px", width: "17px", height: "14px", borderRadius: "3px", background: "rgba(40,44,58,0.92)" } }));
const rowTitle = (item) => (item.image ? "Image" : item.text);
const rowDetail = (item) => (item.image ? [item.detail, item.app, item.age, item.size].join(" · ") : `${item.app} · ${item.age} · ${item.text.length} characters`);

export default {
  id: "clip",
  mount(root, ctx, screen) {
    this.page = notesPage({ x: 196, y: 170, w: 548, ht: 380 });
    // The picker, laid out like Kinara's own: search first (just type), then
    // Cancel, then the history, with ⌘1 to ⌘9 on the first nine.
    this.highlight = h("div", { class: "abs", style: { left: "0", right: "0", height: `${ROW - 4}px`, borderRadius: "13px", background: "rgba(255,255,255,0.13)" } });
    this.counter = h("span", { style: { font: "600 12.5px var(--font)", color: "#9a9ca3", fontVariantNumeric: "tabular-nums" } }, "1 of 5");
    this.searchCaret = h("span", { style: { width: "2px", height: "18px", borderRadius: "1px", background: "#3b8bff", flex: "none" } });
    const search = h("div", { style: { display: "flex", alignItems: "center", gap: "9px", height: "40px", padding: "0 14px", borderRadius: "12px", background: "rgba(255,255,255,0.07)", color: "#9a9ca3" } },
      glyph("search", 16), this.searchCaret, h("span", { style: { font: "500 15px var(--font)", color: "#74767d", flex: 1 } }, "Search clipboard"), this.counter);
    const cancel = h("div", { style: { position: "relative", height: `${ROW}px`, display: "flex", alignItems: "center", gap: "10px", padding: "0 12px", color: "#a9abb2" } },
      h("div", { style: { width: "44px", display: "grid", placeItems: "center" } }, glyph("xmark", 20)),
      h("span", { style: { font: "600 15px var(--font)", flex: 1 } }, "Cancel"), h("span", { style: { font: "500 12px var(--font)", color: "#8d8f96" } }, "Paste nothing"));
    this.rows = ITEMS.map((item, i) => h("div", { style: { position: "relative", height: `${ROW}px`, display: "flex", alignItems: "center", gap: "10px", padding: "0 12px" } },
      item.image ? thumbnail() : tile(item.icon),
      h("div", { style: { flex: 1, minWidth: 0 } },
        h("div", { class: "rowtext", style: { font: "500 15px/1.25 var(--font)", color: "#f2f3f6", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, rowTitle(item)),
        h("div", { style: { font: "500 11px/1.5 var(--font)", color: "#8d8f96", whiteSpace: "nowrap" } }, rowDetail(item))),
      h("div", { style: { padding: "0 7px", height: "22px", borderRadius: "6px", background: "rgba(255,255,255,0.08)", display: "grid", placeItems: "center", font: "650 11.5px var(--rounded)", color: "#9a9ca3" } }, `⌘${i + 1}`)));
    this.picker = h("div", { class: "abs glass", style: { left: `${PICKER.x}px`, top: `${PICKER.y}px`, width: `${PICKER.w}px`, borderRadius: "24px", padding: "16px 16px 13px", background: "linear-gradient(180deg, rgba(54,55,62,0.84), rgba(30,31,36,0.9))", transformOrigin: "92% 4%" } },
      search, h("div", { style: { position: "relative", margin: "9px 0 4px" } }, this.highlight, cancel, ...this.rows),
      h("div", { style: { padding: "5px 6px 0", font: "500 11.5px var(--font)", color: "#8d8f96" } }, "Slide to choose  ·  lift to paste  ·  type to search  ·  esc to cancel"));
    this.page.__body.firstChild.style.fontSize = "18px";
    screen.append(quietWindow({ x: 420, y: 470, w: 380, ht: 290, title: "Mail" }), this.page, this.picker);

    this.title = at(words("Clipboard history.", "h0 grad center shadowed"), 760, 560);
    this.caps = [at(words("Slide to choose.", "h2 grad center shadowed"), 560, 930), at(words("Lift to paste.", "h2 grad center shadowed"), 560, 930)];
    root.append(this.title, ...this.caps);
  },
  update(t, { pad, d }) {
    d.app = "Notes";
    pad.gloss = 0.14;
    pad.env = 1.5;
    pad.labels.o = 0;
    // The finger: a tap, then a tap that stays down and slides along the right edge.
    tapCorner(pad, "tr", t, [CLIP.taps[0]]);
    let steps = 0;
    for (const s of CLIP.steps) steps += ease.inOut(prog(t, s - 0.2, s + 0.06));
    const down = Math.min(ease.out(prog(t, CLIP.taps[1] - 0.04, CLIP.taps[1] + 0.03)), 1 - ease.smooth(prog(t, CLIP.lift, CLIP.lift + 0.25)));
    const level = 0.84 - steps * 0.17;
    if (down > 0.002) {
      const from = CORNER_POINT.tr, edge = edgePoint("right", level);
      const along = ease.out(prog(steps, 0, 0.6));
      pad.contacts.push({ x: lerp(from.x, edge.x, along), y: lerp(from.y, edge.y, along), from: steps > 0.05 ? from : null, o: down, size: 1.05 });
    }
    if (t >= CLIP.taps[1]) pad.corners.tr = Math.max(pad.corners.tr, Math.exp(-(t - CLIP.taps[1]) * 3));
    // The screen's edge lights beside the finger while it is down.
    if (down > 0.002) d.edge = { side: "right", level: level * 100, o: down * ease.out(prog(t, CLIP.bloom, CLIP.bloom + 0.3)), palette: "accent" };

    // The picker blooms (Kinara's spring: response 0.34, damping 0.8)…
    const bloom = spring(t - CLIP.bloom, 0.34, 0.8);
    const gone = ease.leave(prog(t, CLIP.lift, CLIP.lift + 0.24));
    this.picker.style.opacity = String((t >= CLIP.bloom ? clamp(ease.out(prog(t, CLIP.bloom, CLIP.bloom + 0.16))) : 0) * (1 - gone));
    this.picker.style.transform = `translateY(${(1 - clamp(bloom)) * -10}px) scale(${lerp(0.86, 1, bloom) * lerp(1, 0.96, gone)})`;
    this.picker.style.visibility = t >= CLIP.bloom && gone < 1 ? "visible" : "hidden";
    // …and the highlight springs from row to row (response 0.3, damping 0.86).
    let sel = 0;
    for (const s of CLIP.steps) sel += spring(t - s, 0.3, 0.86);
    // Row 0 is Cancel; the history starts below it.
    this.highlight.style.top = `${2 + (sel + 1) * ROW}px`;
    const index = Math.round(clamp(sel, 0, ITEMS.length - 1));
    this.counter.textContent = `${index + 1} of ${ITEMS.length}`;
    this.rows.forEach((r, i) => (r.querySelector(".rowtext").style.fontWeight = i === index ? "640" : "500"));
    this.searchCaret.style.opacity = Math.floor((t - CLIP.bloom) * 2) % 2 === 0 ? "1" : "0";

    // The paste: text appears at the caret with a soft glow.
    const pasted = t >= CLIP.lift + 0.05;
    this.page.__pasted.textContent = pasted ? ITEMS[PICK].text : "";
    const glow = pasted ? 1 - ease.smooth(prog(t, CLIP.lift + 0.3, CLIP.lift + 2.2)) : 0;
    this.page.__pasted.style.background = `rgba(120,170,255,${0.3 * glow})`;
    this.page.__pasted.style.boxShadow = `0 0 ${26 * glow}px rgba(120,170,255,${0.45 * glow})`;
    this.page.__pasted.style.color = pasted ? "#f5f5f7" : "";
    this.page.__caret.style.opacity = Math.floor((t - S.start) * 1.8) % 2 === 0 || (t > CLIP.taps[0] && t < CLIP.lift + 0.7) ? "1" : "0";

    reveal(this.title, t, CLIP.title, CLIP.taps[0] - 0.3, { rise: 0.25, dur: 0.8, outDur: 0.25 });
    sequence(this.caps, t, [CLIP.bloom + 0.6, CLIP.lift - 0.1], S.end - 0.1);
  },
};
