// 75–82.5 s. A montage on the beat, joined by whip pans: the edge map,
// Night Shift warmth, extra dim, window tiling, and a ticker of the rest.
import { h, at, tf, words, reveal, glyph } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, DETAILS } from "../timeline.js";

const S = SCENES.find((s) => s.id === "details");
const CUT = Object.fromEntries(DETAILS.cuts.map((c) => [c.id, c]));

function desktop() {
  return h("div", { style: { width: "1240px", height: "720px", borderRadius: "26px", overflow: "hidden", position: "relative", boxShadow: "0 50px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)", background: "radial-gradient(ellipse at 72% 20%, rgba(170,196,255,0.55), transparent 45%), radial-gradient(ellipse at 15% 85%, rgba(120,150,230,0.35), transparent 50%), linear-gradient(160deg, #3d4a6a, #1c2130 55%, #0f1117)" } },
    h("div", { style: { position: "absolute", left: 0, right: 0, top: 0, height: "30px", background: "rgba(10,12,18,0.4)", backdropFilter: "blur(20px)" } }));
}
const hud = (icon, label) => {
  const fill = h("div", { style: { position: "absolute", left: 0, top: 0, bottom: 0, width: "0%", borderRadius: "4px", background: "#fff" } });
  const el = h("div", { class: "pill dark", style: { fontSize: "24px", gap: "16px", padding: "16px 24px" } }, glyph(icon, 28), label, h("div", { style: { width: "200px", height: "8px", borderRadius: "4px", background: "rgba(255,255,255,0.15)", position: "relative", overflow: "hidden" } }, fill));
  el.__fill = fill;
  return el;
};

export default {
  id: "details",
  pre: 0.4,
  post: 0.3,
  mount(root) {
    this.groups = {};
    const group = (id) => (this.groups[id] = at(h("div", { style: { width: "1920px", height: "1080px" } }), 960, 540));

    // 1 · The edge map.
    const map = group("map");
    this.mapTitle = at(words("See every edge, any time.", "h2 grad center"), 960, 130);
    const label = (text, x, y) => at(h("div", { class: "pill dark maplabel", style: { fontSize: "26px", padding: "12px 22px" } }, text), x, y);
    this.mapPad = at(h("div", { class: "glass", style: { width: "820px", height: "500px", borderRadius: "40px" } },
      h("div", { style: { position: "absolute", inset: "70px 120px", borderRadius: "28px", border: "2px solid rgba(255,255,255,0.12)", background: "rgba(0,0,0,0.25)" } })), 960, 590);
    this.labels = [
      label("Brightness", 600, 590), label("Volume", 1320, 590), label("Media", 960, 370), label("Tabs", 960, 810),
      label("Mission Control", 660, 400), label("Paste", 1260, 400), label("Show desktop", 660, 780), label("Clipboard", 1260, 780),
    ];
    map.append(this.mapPad, ...this.labels, this.mapTitle);

    // 2 · Night Shift, 3 · Extra dim, 4 · Tile.
    for (const id of ["night", "dim", "tile"]) {
      const g = group(id);
      const d = at(desktop(), 960, 500);
      g.__desk = d;
      g.append(d);
    }
    this.warm = h("div", { style: { position: "absolute", inset: 0, background: "#ffad5c", mixBlendMode: "multiply", opacity: 0 } });
    this.groups.night.__desk.append(this.warm);
    this.nightHud = at(hud("sun", "Night Shift"), 960, 760);
    this.groups.night.append(this.nightHud, at(words("Night Shift warmth.", "h2 grad center"), 960, 960));
    this.dark = h("div", { style: { position: "absolute", inset: 0, background: "#000", opacity: 0 } });
    this.groups.dim.__desk.append(this.dark);
    this.dimHud = at(hud("moon", "Extra dim"), 960, 760);
    this.groups.dim.append(this.dimHud, at(words("Extra dim, below the lowest backlight.", "h2 grad center"), 960, 960));
    this.win = h("div", { class: "glass", style: { position: "absolute", borderRadius: "16px", overflow: "hidden" } },
      h("div", { style: { height: "36px", borderBottom: "1px solid rgba(255,255,255,0.07)", background: "rgba(255,255,255,0.04)" } }),
      h("div", { style: { padding: "24px", display: "grid", gap: "14px" } }, ...[0.8, 0.6, 0.7, 0.5].map((w) => h("div", { style: { width: `${w * 100}%`, height: "14px", borderRadius: "7px", background: "rgba(255,255,255,0.12)" } }))));
    this.groups.tile.__desk.append(this.win);
    this.groups.tile.append(at(words("Tile windows.", "h2 grad center"), 960, 960));

    // 5 · And more: a ticker of everything else.
    const more = group("more");
    const rows = [
      ["Lock screen", "Sleep displays", "True Tone", "Spotlight", "Emoji & Symbols", "Screenshot"],
      ["Audio output", "Mission Control", "sway:// links", "Menu bar scroll", "Input gain", "App Exposé"],
      ["Export settings", "Keyboard backlight", "Microphone mute", "Full screen", "Reopen tab", "Find"],
    ];
    this.tickers = rows.map((items, r) => {
      const row = h("div", { style: { display: "flex", gap: "22px", whiteSpace: "nowrap" } }, ...[...items, ...items].map((x) => h("div", { class: "pill dark", style: { fontSize: "34px", padding: "18px 32px" } }, x)));
      return at(row, 960, 330 + r * 140);
    });
    this.moreTitle = at(words("And so much more.", "h1 grad center"), 960, 860);
    more.append(...this.tickers, this.moreTitle);
    root.append(...Object.values(this.groups));
  },
  update(t, { bg }) {
    // Whip pans between cuts.
    for (const c of DETAILS.cuts) {
      const g = this.groups[c.id];
      const pin = ease.out(prog(t, c.start - 0.14, c.start + 0.2));
      const last = c === DETAILS.cuts[DETAILS.cuts.length - 1];
      const pout = last ? ease.leave(prog(t, S.end - 0.3, S.end + 0.1)) : ease.in(prog(t, c.end - 0.14, c.end + 0.06));
      const visible = t > c.start - 0.16 && t < c.end + 0.1;
      g.style.display = visible ? "" : "none";
      if (!visible) continue;
      tf(g, { x: last ? 0 : (1 - pin) * 300 - pout * 300, s: last ? lerp(1, 0.96, pout) : 1, o: Math.min(pin * 1.4, 1) * (1 - pout), blur: (1 - pin) * 22 + pout * (last ? 10 : 22) });
    }

    // Edge map: labels pop in one by one.
    const m = CUT.map;
    reveal(this.mapTitle, t, m.start - 0.05, m.end + 0.2, { rise: 0.3 });
    tf(this.mapPad, { s: lerp(0.94, 1, spring(t - m.start, 0.45, 0.75)) });
    this.labels.forEach((l, i) => {
      const at0 = m.start + 0.45 + i * 0.16;
      const p = spring(t - at0, 0.36, 0.66);
      tf(l, { s: lerp(0.5, 1, clamp(p, 0, 1.2)), o: t >= at0 ? clamp(p * 2) : 0, blur: (1 - clamp(p)) * 6 });
    });

    // Night Shift warms; extra dim darkens below the backlight.
    const n = CUT.night;
    const warm = ease.inOut(prog(t, n.start + 0.05, n.end - 0.1));
    this.warm.style.opacity = String(warm * 0.6);
    this.nightHud.__fill.style.width = `${warm * 100}%`;
    const d = CUT.dim;
    const dim = ease.inOut(prog(t, d.start + 0.05, d.end - 0.1));
    this.dark.style.opacity = String(dim * 0.7);
    this.dimHud.__fill.style.width = `${(1 - dim) * 100}%`;

    // A window snaps to the left half.
    const tl = CUT.tile;
    const snap = spring(t - (tl.start + 0.3), 0.38, 0.78);
    const from = { x: 360, y: 170, w: 520, hh: 360 }, to = { x: 14, y: 44, w: 606, hh: 662 };
    const k = clamp(snap, 0, 1.08);
    Object.assign(this.win.style, { left: `${lerp(from.x, to.x, k)}px`, top: `${lerp(from.y, to.y, k)}px`, width: `${lerp(from.w, to.w, k)}px`, height: `${lerp(from.hh, to.hh, k)}px` });

    // And more: three rows drifting in alternate directions.
    const mo = CUT.more;
    this.tickers.forEach((row, r) => {
      const dir = r % 2 === 0 ? -1 : 1;
      tf(row, { x: dir * lerp(-120, 220, prog(t, mo.start - 0.2, mo.end + 0.3)) + (r - 1) * 80, o: 0.55 - Math.abs(r - 1) * 0.12 });
    });
    reveal(this.moreTitle, t, mo.start, S.end, { rise: 0.3, stagger: 0.05, dur: 0.6 });
    bg.style.setProperty("--by", "48%");
    bg.style.setProperty("--ba", "0.55");
  },
};
