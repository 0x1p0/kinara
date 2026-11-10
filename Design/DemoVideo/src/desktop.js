// The screen's picture: a Mac desktop with Kinara's own feedback on it, at the
// app's real sizes (Sway/CornerBloom.swift, Sway/Overlay.swift) times one
// film scale, so it reads from across the studio. Scenes add their windows to
// `content` and describe the rest (backlight, level, lights) each frame.
import { h, glyph } from "./ui.js";
import { SCREEN, screenPoint } from "./world.js";
import { prog, ease, lerp, clamp, spring } from "./timeline.js";

const W = SCREEN.w, H = SCREEN.h;
/** Kinara's overlays are drawn this much larger than life. */
export const FILM_SCALE = 1.3;

// Kinara's light colours (Sway/Overlay.swift), as the system colours look on a dark screen.
export const PALETTES = {
  accent: [[10, 132, 255]],
  aurora: [[64, 200, 224], [10, 132, 255], [191, 90, 242], [255, 55, 95]],
  sunset: [[255, 159, 10], [255, 55, 95], [191, 90, 242]],
  ember: [[255, 214, 10], [255, 159, 10], [255, 69, 58]],
  mint: [[99, 230, 226], [48, 209, 88], [64, 200, 224]],
  mono: [[255, 255, 255]],
};
export const css = (c, a = 1) => `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${a})`;
const mix = (a, b, p) => [lerp(a[0], b[0], p), lerp(a[1], b[1], p), lerp(a[2], b[2], p)];
/** A palette's colour at a position round its loop (0..1). */
export function paletteAt(colors, p) {
  if (colors.length === 1) return colors[0];
  const f = (((p % 1) + 1) % 1) * colors.length, i = Math.floor(f);
  return mix(colors[i % colors.length], colors[(i + 1) % colors.length], f - i);
}
const middle = (colors) => colors[Math.floor(colors.length / 2)];
function luminance(c) {
  const ch = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
  return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2]);
}
/** The tube's darker rim: the colour darkened until it edges the light on any page. */
function rim(c) {
  let f = 0.5, out = mix(c, [0, 0, 0], f);
  while (luminance(out) > 0.12 && f < 0.85) { f += 0.05; out = mix(c, [0, 0, 0], f); }
  return out;
}

// The light's tube (points): rim to rim, its body, the white core, and its glow.
const TUBE = { rim: 5, body: 3.2, core: 1.6, inset: 1, glow: 9, radius: 12 };
const BEAD = 20, INSET = 14;

/** A value that springs to each key's target from wherever it was, like SwiftUI. */
function track(keys, t, initial) {
  let seg = null;
  for (const k of keys) {
    if (k.t > t) break;
    const now = seg ? seg.from + (seg.to - seg.from) * spring(k.t - seg.t0, seg.r, seg.d) : initial;
    seg = { from: now, to: k.v, t0: k.t, r: k.r, d: k.d };
  }
  return seg ? seg.from + (seg.to - seg.from) * spring(t - seg.t0, seg.r, seg.d) : initial;
}

/** The border the ambient light laps: just inside the screen's edge, round its corners. */
const BORDER = (() => {
  const i = TUBE.inset + TUBE.rim / 2, r = TUBE.radius;
  const top = W - 2 * i - 2 * r, side = H - 2 * i - 2 * r, arc = (Math.PI * r) / 2;
  const d = `M${i + r} ${i} L${W - i - r} ${i} A${r} ${r} 0 0 1 ${W - i} ${i + r} L${W - i} ${H - i - r} A${r} ${r} 0 0 1 ${W - i - r} ${H - i} L${i + r} ${H - i} A${r} ${r} 0 0 1 ${i} ${H - i - r} L${i} ${i + r} A${r} ${r} 0 0 1 ${i + r} ${i} Z`;
  const total = 2 * top + 2 * side + 4 * arc;
  // Clockwise from the top-left, as the path is drawn.
  const at = (s) => {
    s = ((s % total) + total) % total;
    if (s < top) return [i + r + s, i];
    s -= top;
    if (s < arc) { const a = -Math.PI / 2 + (s / arc) * (Math.PI / 2); return [W - i - r + Math.cos(a) * r, i + r + Math.sin(a) * r]; }
    s -= arc;
    if (s < side) return [W - i, i + r + s];
    s -= side;
    if (s < arc) { const a = (s / arc) * (Math.PI / 2); return [W - i - r + Math.cos(a) * r, H - i - r + Math.sin(a) * r]; }
    s -= arc;
    if (s < top) return [W - i - r - s, H - i];
    s -= top;
    if (s < arc) { const a = Math.PI / 2 + (s / arc) * (Math.PI / 2); return [i + r + Math.cos(a) * r, H - i - r + Math.sin(a) * r]; }
    s -= arc;
    if (s < side) return [i, H - i - r - s];
    s -= side;
    const a = Math.PI + (s / arc) * (Math.PI / 2);
    return [i + r + Math.cos(a) * r, i + r + Math.sin(a) * r];
  };
  return { d, total, at };
})();

export function createDesktop(el) {
  const F = FILM_SCALE;
  // Chrome draws a layer under a perspective transform at the page's own pixel
  // density, however large it ends up on screen. So when the camera is close,
  // the whole screen is laid out larger (CSS zoom) and the transform shrinks it
  // back: its text is then drawn at the size it is seen.
  const bezel = h("div", { class: "bezel", style: { width: `${W + SCREEN.bezel * 2}px`, height: `${H + SCREEN.bezel * 2}px` } });
  let zoom = 1;
  const screen = h("div", { class: "screen", style: { left: `${SCREEN.bezel}px`, top: `${SCREEN.bezel}px`, width: `${W}px`, height: `${H}px`, borderRadius: `${SCREEN.radius}px` } });
  const wall = h("div", { class: "abs", style: { inset: "0" } });
  const content = h("div", { class: "abs", style: { inset: "0" } });
  const warm = h("div", { class: "abs", style: { inset: "0", background: "rgb(255,150,40)", mixBlendMode: "multiply", pointerEvents: "none" } });
  const dimmer = h("div", { class: "abs", style: { inset: "0", background: "#000", pointerEvents: "none" } });
  const overlays = h("div", { class: "abs", style: { inset: "0", pointerEvents: "none" } });
  const sheen = h("div", { class: "abs", style: { inset: "0", pointerEvents: "none", background: "linear-gradient(118deg, rgba(255,255,255,0.05) 0%, rgba(255,255,255,0.012) 28%, transparent 46%)" } });

  // Menu bar. No Apple menu: Apple's marketing guidelines don't allow its logo.
  const menuText = (text, bold) => h("span", { style: { font: `${bold ? 700 : 500} 13.5px/1 var(--font)`, color: "rgba(255,255,255,0.92)" } }, text);
  const appName = menuText("Finder", true);
  const mark = h("span", { style: { display: "inline-block", width: "18px", height: "12px", borderRadius: "3px", border: "1.6px solid rgba(255,255,255,0.9)", position: "relative" } }, h("span", { style: { position: "absolute", right: "2px", top: "2px", bottom: "2px", width: "2.2px", borderRadius: "1px", background: "#fff" } }));
  const menubar = h("div", { class: "abs", style: { left: "0", right: "0", top: "0", height: "28px", display: "flex", alignItems: "center", gap: "20px", padding: "0 16px", background: "rgba(8,10,20,0.3)", backdropFilter: "blur(20px)" } },
    appName, ...["File", "Edit", "View", "Window", "Help"].map((m) => menuText(m)),
    h("span", { style: { flex: 1 } }), mark, glyph("wifi", 16, { color: "rgba(255,255,255,0.9)" }), glyph("battery", 18, { color: "rgba(255,255,255,0.9)" }), menuText("Tue 10 Nov  9:41"));

  // Kinara's level pill (the app's is 240 × 48).
  const hudIcon = h("span", { style: { width: "20px", height: "20px", display: "grid", placeItems: "center" } });
  const hudFill = h("div", { class: "abs", style: { left: "0", top: "0", bottom: "0", borderRadius: "3px", background: "#fff" } });
  const hudNum = h("span", { style: { font: "650 16px/1 var(--font)", fontVariantNumeric: "tabular-nums", width: "30px", textAlign: "right" } }, "0");
  const hud = h("div", { class: "abs", style: { left: `${W / 2 - 120}px`, top: `${H * 0.76 - 24}px`, width: "240px", height: "48px", borderRadius: "24px", display: "flex", alignItems: "center", gap: "11px", padding: "0 15px", color: "#fff", background: "rgba(28,28,32,0.62)", border: "0.5px solid rgba(255,255,255,0.2)", backdropFilter: "blur(24px) saturate(1.6)", boxShadow: "0 10px 30px rgba(0,0,0,0.3), inset 0 0.5px 0 rgba(255,255,255,0.3)" } },
    hudIcon, h("div", { style: { position: "relative", flex: 1, height: "6px", borderRadius: "3px", background: "rgba(255,255,255,0.18)" } }, hudFill), hudNum);
  let hudKind = null;

  // ---------------------------------------------------------------- edge light
  // A tube by the edge, beside the finger: glow, darker rim, body, white core.
  const EDGE_LEN = 250, EDGE_DEPTH = 150;
  const tubePart = (width, extra = {}) => h("div", { class: "abs", style: { top: "0", height: "100%", width: `${width * F}px`, borderRadius: `${width * F}px`, backgroundSize: "100% 200%", ...extra } });
  const edge = { wash: h("div", { class: "abs", style: { inset: "0" } }), glow: tubePart(TUBE.body * 2.2, { filter: `blur(${TUBE.glow * F}px)` }), halo: tubePart(TUBE.body * 4, { filter: `blur(${TUBE.glow * 3.2 * F}px)`, opacity: "0.75" }), rim: tubePart(TUBE.rim), body: tubePart(TUBE.body), core: tubePart(TUBE.core, { background: "rgba(255,255,255,0.96)" }) };
  edge.el = h("div", { class: "abs", style: { top: "0", width: `${EDGE_DEPTH}px`, height: `${EDGE_LEN}px`, WebkitMaskImage: "linear-gradient(180deg, transparent 0%, #000 30%, #000 70%, transparent 100%)" } }, edge.wash, edge.halo, edge.glow, edge.rim, edge.body, edge.core);

  // ---------------------------------------------------------------- corner light and ambient light
  const svg = (children, style = {}) => h("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, style: { position: "absolute", left: "0", top: "0", overflow: "visible", ...style } }, ...children);
  // The corner light: along one edge, round the corner, along the other, trimmed outward from the corner.
  const cornerShape = (corner) => {
    const i = TUBE.inset + TUBE.rim / 2, r = TUBE.radius, reach = 190;
    const right = corner.includes("r"), top = corner.includes("t");
    const cx = right ? W - i : i, cy = top ? i : H - i;
    const fx = right ? W - reach : reach, fy = top ? reach : H - reach;
    const sx = right ? -1 : 1, sy = top ? 1 : -1;
    const sweep = (right && top) || (!right && !top) ? 1 : 0;
    return { d: `M${fx} ${cy} L${cx + sx * r} ${cy} A${r} ${r} 0 0 ${sweep} ${cx} ${cy + sy * r} L${cx} ${fy}`, length: (reach - i - r) * 2 + (Math.PI * r) / 2, origin: [right ? W : 0, top ? 0 : H] };
  };
  const cornerDefs = h("defs");
  const cornerLights = {};
  const cornerGroup = h("g");
  for (const corner of ["tl", "tr", "br", "bl"]) {
    const shape = cornerShape(corner);
    // Each stroke fades along its length, away from the corner.
    const fade = (name) => {
      const stops = [h("stop", { offset: "0", "stop-opacity": "1" }), h("stop", { offset: "0.55", "stop-opacity": "0.8" }), h("stop", { offset: "1", "stop-opacity": "0" })];
      cornerDefs.append(h("radialGradient", { id: `corner-${name}-${corner}`, gradientUnits: "userSpaceOnUse", cx: shape.origin[0], cy: shape.origin[1], r: 185 }, ...stops));
      return (color) => stops.forEach((stop) => stop.setAttribute("stop-color", color));
    };
    const line = (width, name) => h("path", { d: shape.d, fill: "none", stroke: `url(#corner-${name}-${corner})`, "stroke-width": width * F, "stroke-linecap": "round", "stroke-linejoin": "round" });
    const paint = { glow: fade("glow"), rim: fade("rim"), body: fade("body"), core: fade("core") };
    const glow = line(TUBE.body * 2.4, "glow"), rimLine = line(TUBE.rim, "rim"), body = line(TUBE.body, "body"), core = line(TUBE.core, "core");
    paint.core("rgb(255,255,255)");
    glow.style.filter = `blur(${TUBE.glow * F}px)`;
    const g = h("g", { opacity: 0 }, glow, rimLine, body, core);
    cornerGroup.append(g);
    cornerLights[corner] = { g, paint, parts: [glow, rimLine, body, core], length: shape.length };
  }
  const cornerSvg = svg([cornerDefs, cornerGroup]);

  // The ambient light: the tube round the whole screen, seen only around a soft
  // spot that laps it. Drawn as short pieces so the colours can run round the centre.
  const PIECES = 56, REACH = 270;
  const piece = (width, cap) => h("path", { d: BORDER.d, fill: "none", "stroke-width": width * F, "stroke-linecap": cap, opacity: 0 });
  const ambient = { glow: [], halo: [], rim: [], body: [], core: [] };
  const ambientGroups = Object.fromEntries(Object.keys(ambient).map((k) => [k, h("g")]));
  for (let k = 0; k < PIECES; k++) {
    ambient.halo.push(piece(TUBE.body * 4, "butt"));
    ambient.glow.push(piece(TUBE.body * 2.2, "butt"));
    ambient.rim.push(piece(TUBE.rim, "butt"));
    ambient.body.push(piece(TUBE.body, "butt"));
    ambient.core.push(piece(TUBE.core, "butt"));
  }
  for (const k of Object.keys(ambient)) ambientGroups[k].append(...ambient[k]);
  ambientGroups.glow.style.filter = `blur(${TUBE.glow * F}px)`;
  ambientGroups.halo.style.filter = `blur(${TUBE.glow * 3.4 * F}px)`;
  const ambientSvg = svg([ambientGroups.halo, ambientGroups.glow, ambientGroups.rim, ambientGroups.body, ambientGroups.core]);

  overlays.append(edge.el, cornerSvg, ambientSvg, hud);
  screen.append(wall, content, menubar, warm, dimmer, overlays, sheen);
  bezel.append(screen);
  el.append(bezel);

  // ---------------------------------------------------------------- islands
  const islands = [];
  // The bloom: one glass shape that stretches from a bead in the corner into a pill.
  function island(corner, pills) {
    const right = corner.includes("r"), top = corner.includes("t");
    const glass = h("div", { class: "abs", style: { borderRadius: "999px", overflow: "hidden", background: "rgba(28,28,34,0.6)", border: "0.5px solid rgba(255,255,255,0.22)", backdropFilter: "blur(22px) saturate(1.8)", boxShadow: "0 4px 10px rgba(0,0,0,0.18), 0 12px 30px rgba(0,0,0,0.25), inset 0 0.5px 0 rgba(255,255,255,0.35)", transformOrigin: `${right ? 100 : 0}% ${top ? 0 : 100}%` } });
    const contents = Object.fromEntries(Object.entries(pills).map(([id, p]) => {
      const row = h("div", { class: "abs", style: { left: "0", top: "0", display: "flex", alignItems: "center", gap: `${10 * F}px`, padding: `0 ${16 * F}px 0 ${8 * F}px`, height: "100%", whiteSpace: "nowrap", color: "#fff" } },
        h("span", { style: { width: `${28 * F}px`, height: `${28 * F}px`, borderRadius: "50%", background: "rgba(255,255,255,0.12)", display: "grid", placeItems: "center", flex: "none" } }, glyph(p.icon, 16 * F)),
        h("span", { style: { display: "flex", flexDirection: "column", gap: "1px" } },
          h("span", { style: { font: `600 ${13 * F}px/1.25 var(--font)` } }, p.title),
          p.detail ? h("span", { style: { font: `500 ${11 * F}px/1.25 var(--font)`, color: "rgba(235,235,245,0.64)" } }, p.detail) : null));
      glass.append(row);
      return [id, row];
    }));
    overlays.append(glass);
    const made = { glass, contents, pills, right, top, drawn: false, widths: null };
    islands.push(made);
    made.widths = Object.fromEntries(Object.entries(contents).map(([id, row]) => [id, Math.ceil(row.offsetWidth)]));
    return made;
  }
  /** One corner's island this frame, from its own sequence of events (arm, bloom, swap, preview, fold, leave). */
  function drawIsland(isl, t, events) {
    isl.drawn = true;
    const bead = BEAD * F, inset = INSET * F;
    const sizeKeys = [], presentKeys = [];
    let shown = null, shownAt = -Infinity, hideAt = Infinity, cap = 1;
    for (const e of events) {
      if (e.kind === "arm") { presentKeys.push({ t: e.t, v: 1, r: 0.24, d: 0.72 }); sizeKeys.push({ t: e.t, v: 0, r: 0.24, d: 0.72 }); }
      if (e.kind === "bloom" || e.kind === "swap" || e.kind === "preview") {
        const r = e.kind === "bloom" ? 0.42 : e.kind === "swap" ? 0.38 : 0.34;
        const d = e.kind === "bloom" ? 0.72 : e.kind === "swap" ? 0.82 : 0.8;
        sizeKeys.push({ t: e.t, v: 1, r, d, id: e.id });
        if (e.kind === "preview") presentKeys.push({ t: e.t, v: 1, r, d });
        if (t >= e.t) { shown = e.id; shownAt = e.t; hideAt = Infinity; cap = e.kind === "preview" ? 0.92 : 1; }
      }
      if (e.kind === "fold") { sizeKeys.push({ t: e.t, v: 0, r: 0.34, d: 0.86 }); presentKeys.push({ t: e.t + 0.32, v: 0, r: 0.3, d: 0.9 }); if (t >= e.t) hideAt = e.t; }
      if (e.kind === "leave") { sizeKeys.push({ t: e.t, v: 0, r: 0.3, d: 0.9 }); presentKeys.push({ t: e.t, v: 0, r: 0.3, d: 0.9 }); if (t >= e.t) hideAt = e.t; }
    }
    const present = track(presentKeys, t, 0);
    // Width and height spring between the bead and whichever pill is showing.
    const w = Math.max(bead * 0.6, track(sizeKeys.map((k) => ({ ...k, v: k.v ? isl.widths[k.id] : bead })), t, bead));
    const ht = Math.max(bead * 0.6, track(sizeKeys.map((k) => ({ ...k, v: k.v ? (isl.pills[k.id].detail ? 50 : 44) * F : bead })), t, bead));
    const { glass } = isl;
    Object.assign(glass.style, { left: `${isl.right ? W - inset - w : inset}px`, top: `${isl.top ? 28 + inset : H - inset - ht}px`, width: `${w}px`, height: `${ht}px` });
    glass.style.transform = `scale(${lerp(0.15, 1, clamp(present, 0, 1.2))})`;
    glass.style.opacity = String(clamp(present * 1.4));
    glass.style.visibility = present > 0.01 ? "visible" : "hidden";
    // The words arrive once the glass has nearly settled, and leave first.
    for (const [id, row] of Object.entries(isl.contents)) {
      let o = 0;
      if (id === shown) {
        o = ease.out(prog(t, shownAt + 0.12, shownAt + 0.36)) * cap;
        if (Number.isFinite(hideAt)) o *= 1 - prog(t, hideAt, hideAt + 0.1);
      } else {
        const swapped = events.find((e) => e.id === id && e.t <= t);
        if (swapped) {
          const next = events.find((e) => e.t > swapped.t && (e.kind === "swap" || e.kind === "fold" || e.kind === "leave" || e.kind === "bloom"));
          if (next && t >= next.t) o = (1 - prog(t, next.t, next.t + 0.12)) * (next.kind === "swap" || next.kind === "bloom" ? 1 : 0);
        }
      }
      row.style.opacity = o.toFixed(3);
      const blur = (1 - clamp(o / cap || 0)) * 5;
      row.style.filter = blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : "";
    }
  }
  /** A corner light flash: runs out from the corner and fades. */
  const flash = (t, at, strength = 1, spread = 1) => {
    if (t < at) return { i: 0, s: 0 };
    const age = t - at;
    return { i: strength * Math.min(ease.out(clamp(age / 0.06)), 1 - ease.smooth(prog(age, 0.18, 0.75))), s: spread * ease.out(clamp(age / 0.32)) };
  };

  const fresh = () => ({
    o: 1, blur: 0, brightness: 1, mood: 0, warm: 0, extraDim: 0, app: "Finder", menu: 1,
    hud: null, // { kind: "speaker" | "sun", level: 0..100, o, scale }
    edge: null, // { side: "left" | "right", level: 0..100, o, palette, drift }
    corners: {}, // corner → { i, s, palette }
    ambient: null, // { o, lap: laps so far, palette }
  });
  let state = fresh();

  /** Draws the frame, and tells the world what light the screen gives off. */
  function apply(t, world) {
    const s = state;
    // Wallpaper: slow blobs of colour, dimmer in the film's night scenes.
    const drift = (k) => Math.sin(t * 0.13 + k * 1.7) * 0.05;
    const quiet = 1 - 0.55 * s.mood;
    const blobs = [
      { x: 0.2 + drift(0), y: 0.3 + drift(1) * 0.6, rx: 0.42, ry: 0.52, color: [76, 108, 255], a: 0.85 * quiet },
      { x: 0.82 + drift(2), y: 0.24 + drift(3) * 0.6, rx: 0.4, ry: 0.46, color: [178, 92, 255], a: 0.72 * quiet },
      { x: 0.6 + drift(4), y: 0.94, rx: 0.52, ry: 0.44, color: [0, 190, 210], a: 0.55 * quiet },
      { x: 0.34 + drift(5), y: 0.82, rx: 0.36, ry: 0.4, color: [255, 120, 160], a: 0.36 * quiet },
    ];
    wall.style.background = [...blobs.map((b) => `radial-gradient(${(b.rx * 100).toFixed(2)}% ${(b.ry * 100).toFixed(2)}% at ${(b.x * 100).toFixed(2)}% ${(b.y * 100).toFixed(2)}%, ${css(b.color, b.a.toFixed(3))}, transparent 70%)`), "linear-gradient(160deg, #0c1230, #120b26 55%, #071a26)"].join(",");
    // The backlight, Night Shift and extra dim.
    const backlight = (0.05 + 0.95 * Math.pow(clamp(s.brightness), 1.35)) * (1 - 0.8 * s.extraDim);
    dimmer.style.opacity = (1 - backlight).toFixed(4);
    warm.style.opacity = (0.72 * s.warm).toFixed(3);
    appName.textContent = s.app;
    menubar.style.opacity = String(s.menu);

    // Level pill.
    if (s.hud && s.hud.o > 0.002) {
      const k = s.hud.kind;
      if (k !== hudKind) { hudIcon.innerHTML = ""; hudIcon.append(glyph(k, 20)); hudKind = k; }
      const sc = (s.hud.scale ?? FILM_SCALE) * lerp(0.94, 1, s.hud.o);
      hud.style.transform = `translateY(${(1 - s.hud.o) * 14}px) scale(${sc})`;
      hud.style.opacity = String(clamp(s.hud.o));
      hud.style.visibility = "visible";
      hudFill.style.width = `${clamp(s.hud.level / 100) * 100}%`;
      hudNum.textContent = String(Math.round(s.hud.level));
    } else hud.style.visibility = "hidden";

    const bars = [], spots = [];
    // Edge light.
    if (s.edge && s.edge.o > 0.002) {
      const e = s.edge, colors = PALETTES[e.palette || "accent"], next = e.to ? PALETTES[e.to] : null;
      const blend = (c, i, n) => (next ? mix(c, paletteAt(next, i / n), e.mix ?? 0) : c);
      const loop = [...colors, colors[0]].map((c, i, all) => blend(c, i, all.length - 1));
      const stops = (f) => (loop.length === 2 ? css(f(loop[0])) : `linear-gradient(180deg, ${[...loop, ...loop.slice(1)].map((c) => css(f(c))).join(",")})`);
      const right = e.side === "right";
      const centre = (TUBE.inset + TUBE.rim / 2) * F;
      const y = H - (e.level / 100) * H;
      edge.el.style.left = right ? `${W - EDGE_DEPTH}px` : "0";
      edge.el.style.top = `${clamp(y - EDGE_LEN / 2, -EDGE_LEN * 0.3, H - EDGE_LEN * 0.7)}px`;
      edge.el.style.opacity = String(clamp(e.o));
      edge.el.style.visibility = "visible";
      const slide = `0 ${(-((t / 4) % 1) * 100).toFixed(2)}%`;
      for (const [part, f] of [[edge.rim, rim], [edge.body, (c) => c], [edge.glow, (c) => c], [edge.halo, (c) => c]]) {
        part.style.background = stops(f);
        part.style.backgroundSize = "100% 200%";
        part.style.backgroundPosition = loop.length === 2 ? "" : slide;
      }
      for (const part of [edge.rim, edge.body, edge.glow, edge.halo, edge.core]) {
        const w = parseFloat(part.style.width);
        part.style.left = right ? `${EDGE_DEPTH - centre - w / 2}px` : `${centre - w / 2}px`;
      }
      const mid = blend(middle(colors), 0.5, 1);
      edge.wash.style.background = `radial-gradient(ellipse 100% 50% at ${right ? 100 : 0}% 50%, ${css(mid, 0.4)}, transparent 70%)`;
      bars.push({ side: e.side, at: clamp(y, 0, H), length: EDGE_LEN, color: mid, o: e.o });
    } else edge.el.style.visibility = "hidden";

    // Corner lights.
    for (const [corner, light] of Object.entries(cornerLights)) {
      const c = s.corners[corner];
      if (!c || c.i <= 0.002) { light.g.setAttribute("opacity", "0"); continue; }
      const color = middle(PALETTES[c.palette || "accent"]);
      const v = Math.max(0.001, c.s * light.length);
      for (const part of light.parts) part.setAttribute("stroke-dasharray", `0 ${((light.length - v) / 2).toFixed(2)} ${v.toFixed(2)} ${light.length}`);
      light.paint.glow(css(color));
      light.paint.body(css(color));
      light.paint.rim(css(rim(color)));
      light.g.setAttribute("opacity", c.i.toFixed(3));
      const at = { tl: [0, 0], tr: [W, 0], br: [W, H], bl: [0, H] }[corner];
      spots.push({ x: at[0], y: at[1], r: 200 * c.s + 60, color, o: c.i * 0.9 });
    }

    // Ambient light.
    if (s.ambient && s.ambient.o > 0.002) {
      const a = s.ambient, colors = PALETTES[a.palette || "aurora"];
      const head = a.lap * BORDER.total;
      const step = (REACH * 2) / PIECES;
      for (let k = 0; k < PIECES; k++) {
        const offset = -REACH + (k + 0.5) * step;
        const at = head + offset;
        const [x, y] = BORDER.at(at);
        // Colours run round the screen's centre, as the app's conic gradient does.
        const angle = Math.atan2(y - H / 2, x - W / 2) / (Math.PI * 2) + 0.25;
        const color = paletteAt(colors, angle);
        const fall = clamp(1 - (Math.abs(offset) / REACH - 0.3) / 0.7);
        const o = a.o * ease.smooth(fall);
        const start = (((at - step / 2 - 0.4) % BORDER.total) + BORDER.total) % BORDER.total;
        const dash = `${(step + 0.8).toFixed(2)} ${(BORDER.total - step - 0.8).toFixed(2)}`;
        for (const [list, stroke, strength] of [[ambient.halo, css(color), 0.7], [ambient.glow, css(color), 1], [ambient.rim, css(rim(color)), 1], [ambient.body, css(color), 1], [ambient.core, "rgba(255,255,255,0.96)", 1]]) {
          const p = list[k];
          p.setAttribute("stroke", stroke);
          p.setAttribute("stroke-dasharray", dash);
          p.setAttribute("stroke-dashoffset", (-start).toFixed(2));
          p.setAttribute("opacity", (o * strength).toFixed(3));
        }
      }
      const [x, y] = BORDER.at(head);
      spots.push({ x, y, r: REACH * 1.5, color: paletteAt(colors, Math.atan2(y - H / 2, x - W / 2) / (Math.PI * 2) + 0.25), o: a.o });
      ambientSvg.style.visibility = "visible";
    } else ambientSvg.style.visibility = "hidden";

    // An island no scene drew this frame is not on screen.
    for (const isl of islands) {
      if (!isl.drawn) isl.glass.style.visibility = "hidden";
      isl.drawn = false;
    }

    // What the world needs to know.
    const w = world.state;
    w.display = s.o;
    w.light = backlight;
    w.wall = blobs;
    w.tint = [255, lerp(255, 190, s.warm), lerp(255, 120, s.warm)];
    w.bars = bars;
    w.spots = spots;
  }

  // Kinara's lights also flare in the lens: a soft glow over the frame where
  // each one is, so it reads as light and not as a drawing of one.
  const flares = Array.from({ length: 6 }, () => {
    const flare = h("div", { style: { position: "absolute", left: "0", top: "0", borderRadius: "50%", mixBlendMode: "screen", pointerEvents: "none", visibility: "hidden" } });
    el.parentNode.append(flare);
    return flare;
  });

  /** Lays the screen onto the slab for this frame's camera. */
  /** Lays the whole screen out this many times larger. Set once, before the first frame. */
  function setZoom(z) {
    zoom = z;
    bezel.style.zoom = String(z);
  }

  function place(world) {
    const s = state;
    el.style.display = s.o > 0.01 ? "" : "none";
    for (const flare of flares) flare.style.visibility = "hidden";
    if (s.o <= 0.01) return;
    const size = world.screenScale(), w = world.state;
    const lights = [
      ...w.bars.map((bar) => ({ x: bar.side === "left" ? 0 : W, y: bar.at, rx: 210, ry: 330, color: bar.color, o: bar.o * 0.6 })),
      ...w.spots.map((spot) => ({ x: spot.x, y: spot.y, rx: spot.r * 1.25, ry: spot.r * 1.25, color: spot.color, o: spot.o * 0.5 })),
    ];
    lights.slice(0, flares.length).forEach((light, i) => {
      const [x, y] = world.project(screenPoint(light.x, light.y));
      const flare = flares[i];
      Object.assign(flare.style, {
        width: `${light.rx * 2 * size}px`, height: `${light.ry * 2 * size}px`, transform: `translate(${x - light.rx * size}px, ${y - light.ry * size}px)`,
        background: `radial-gradient(closest-side, ${css(light.color, 0.55)}, ${css(light.color, 0.16)} 45%, transparent)`, opacity: String(clamp(light.o * s.o)), visibility: "visible",
      });
    });
    // Frame pixels per screen point.
    const scale = world.screenScale(), z = zoom;
    el.style.transform = world.screenTransform(z);
    el.style.opacity = String(clamp(s.o));
    // Blur is asked for in frame pixels; the element is blurred before it is scaled.
    const blur = (s.blur * z) / scale;
    el.style.filter = s.blur > 0.1 ? `blur(${blur.toFixed(2)}px)` : "";
  }

  return {
    el, screen, content, overlays, island, drawIsland, flash, apply, place, setZoom,
    get state() { return state; },
    reset() { state = fresh(); return state; },
  };
}
