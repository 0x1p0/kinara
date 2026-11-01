// Small DOM toolkit for the film: element creation, per-frame transforms,
// word-by-word reveals, glyphs, and Sway's own UI pieces (icon, indicator).
import { prog, ease, clamp, lerp } from "./timeline.js";

const SVG = "http://www.w3.org/2000/svg";

export function h(tag, attrs = {}, ...children) {
  const svg = ["svg", "path", "circle", "rect", "g", "defs", "linearGradient", "radialGradient", "stop", "line", "polyline", "filter", "feGaussianBlur", "mask", "clipPath", "ellipse"].includes(tag);
  const el = svg ? document.createElementNS(SVG, tag) : document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue;
    if (k === "style" && typeof v === "object") Object.assign(el.style, v);
    else if (k === "class") el.setAttribute("class", v);
    else if (k === "html") el.innerHTML = v;
    else el.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null) el.append(c.nodeType ? c : document.createTextNode(String(c)));
  return el;
}

/** An absolutely positioned element anchored at its centre on (x, y). */
export function at(el, x, y, extra = {}) {
  Object.assign(el.style, { position: "absolute", left: `${x}px`, top: `${y}px`, transform: "translate(-50%, -50%)", ...extra });
  el.__base = { x, y };
  return el;
}

/** Sets an anchored element's transform, opacity and blur for this frame. */
export function tf(el, { x = 0, y = 0, z = 0, s = 1, sx, sy, r = 0, rx = 0, ry = 0, o = 1, blur = 0, bright } = {}) {
  const scale = sx != null || sy != null ? `scale(${sx ?? s}, ${sy ?? s})` : `scale(${s})`;
  el.style.transform = `translate(-50%, -50%) translate3d(${x}px, ${y}px, ${z}px) rotateX(${rx}deg) rotateY(${ry}deg) rotate(${r}deg) ${scale}`;
  el.style.opacity = String(clamp(o));
  const filters = [];
  if (blur > 0.05) filters.push(`blur(${blur.toFixed(2)}px)`);
  if (bright != null) filters.push(`brightness(${bright})`);
  el.style.filter = filters.join(" ");
  el.style.visibility = o <= 0.001 ? "hidden" : "visible";
}

export const show = (el, visible) => (el.style.display = visible ? "" : "none");

/** Text split into word spans, so each word can arrive on its own. */
export function words(text, cls = "h1", style = {}) {
  const el = h("div", { class: `words ${cls}`, style });
  for (const [i, part] of text.split(/(\s+|\n)/).entries()) {
    if (part === "\n") el.append(h("br"));
    else if (/^\s+$/.test(part)) el.append(document.createTextNode(" "));
    else if (part) el.append(h("span", { class: "w", "data-i": i }, part));
  }
  el.__words = [...el.querySelectorAll(".w")];
  return el;
}

/**
 * Apple-style word reveal: each word rises, sharpens and fades in, staggered;
 * on exit the words lift and soften away.
 */
export function reveal(el, t, tIn, tOut = Infinity, { stagger = 0.05, dur = 0.95, rise = 0.42, blur = 16, outDur = 0.42, outStagger = 0.025, lift = 0.25 } = {}) {
  const ws = el.__words;
  const size = parseFloat(getComputedStyle(el).fontSize) || 100;
  let any = false;
  ws.forEach((w, i) => {
    const pin = ease.settle(prog(t, tIn + i * stagger, tIn + i * stagger + dur));
    const pout = ease.leave(prog(t, tOut + i * outStagger, tOut + i * outStagger + outDur));
    const o = pin * (1 - pout);
    if (o > 0.001) any = true;
    w.style.opacity = o.toFixed(3);
    w.style.transform = `translateY(${((1 - pin) * rise - pout * lift) * size}px) scale(${lerp(0.96, 1, pin)})`;
    const b = (1 - pin) * blur + pout * blur * 0.6;
    w.style.filter = b > 0.05 ? `blur(${b.toFixed(2)}px)` : "";
  });
  el.style.visibility = any ? "visible" : "hidden";
}

/** Fades a whole block with a blur, for secondary text. */
export function fade(el, t, tIn, tOut = Infinity, { dur = 0.7, outDur = 0.4, rise = 18, blur = 10, x = 0, y = 0 } = {}) {
  const pin = ease.settle(prog(t, tIn, tIn + dur));
  const pout = ease.leave(prog(t, tOut, tOut + outDur));
  tf(el, { x, y: y + (1 - pin) * rise - pout * rise * 0.6, o: pin * (1 - pout), blur: (1 - pin) * blur + pout * blur * 0.7 });
  return pin * (1 - pout);
}

// ---------------------------------------------------------------- glyphs

const G = {
  speaker: '<path d="M3.5 9.2h3.3L11 5.3v13.4l-4.2-3.9H3.5z" fill="currentColor" stroke="none"/><path d="M14.6 9.3a3.8 3.8 0 0 1 0 5.4M17.2 6.8a7.4 7.4 0 0 1 0 10.4"/>',
  mute: '<path d="M3.5 9.2h3.3L11 5.3v13.4l-4.2-3.9H3.5z" fill="currentColor" stroke="none"/><path d="M15 9.5l5 5M20 9.5l-5 5"/>',
  sun: '<circle cx="12" cy="12" r="3.8" fill="currentColor" stroke="none"/><path d="M12 2.6v2.2M12 19.2v2.2M2.6 12h2.2M19.2 12h2.2M5.4 5.4l1.5 1.5M17.1 17.1l1.5 1.5M5.4 18.6l1.5-1.5M17.1 6.9l1.5-1.5"/>',
  moon: '<path d="M19.5 14.6A8 8 0 0 1 9.4 4.5a8 8 0 1 0 10.1 10.1z" fill="currentColor" stroke="none"/>',
  clipboard: '<rect x="5" y="4.5" width="14" height="16.5" rx="2.6"/><rect x="8.6" y="2.8" width="6.8" height="3.6" rx="1.4" fill="currentColor" stroke="none"/><path d="M8.5 11h7M8.5 14.5h7M8.5 18h4"/>',
  doc: '<path d="M6.5 3h7.5l4 4v14H6.5z"/><path d="M14 3v4h4"/><path d="M9 12h6M9 15.5h6"/>',
  lock: '<rect x="5" y="10.5" width="14" height="10" rx="2.4" fill="currentColor" stroke="none"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  headphones: '<path d="M4 15v-3a8 8 0 0 1 16 0v3"/><rect x="3.4" y="13.5" width="4.4" height="7" rx="1.8" fill="currentColor" stroke="none"/><rect x="16.2" y="13.5" width="4.4" height="7" rx="1.8" fill="currentColor" stroke="none"/>',
  display: '<rect x="2.8" y="4" width="18.4" height="12.5" rx="2"/><path d="M9 20.5h6M12 16.5v4"/>',
  laptop: '<rect x="4.5" y="5" width="15" height="10.5" rx="1.6"/><path d="M2.5 19h19"/>',
  pointer: '<path d="M6 3.5l12.5 9.2-6 .9 3.4 6.6-2.5 1.3-3.4-6.7L6 19.3z" fill="currentColor" stroke="none"/>',
  wave: '<path d="M3 12h2M7 8v8M11 4v16M15 7v10M19 10v4M21 12h0"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6"/>',
  sparkle: '<path d="M12 2.8l1.9 5.9 5.9 1.9-5.9 1.9L12 18.4l-1.9-5.9L4.2 10.6l5.9-1.9z" fill="currentColor" stroke="none"/>',
  note: '<path d="M9 18V6l10-2.2v12" /><circle cx="6.8" cy="18" r="2.6" fill="currentColor" stroke="none"/><circle cx="16.8" cy="15.8" r="2.6" fill="currentColor" stroke="none"/>',
  window: '<rect x="3" y="4.5" width="18" height="15" rx="2.4"/><path d="M3 8.5h18"/>',
  tile: '<rect x="3" y="4.5" width="18" height="15" rx="2.4"/><rect x="5" y="6.5" width="6.5" height="11" rx="1.2" fill="currentColor" stroke="none"/>',
  map: '<path d="M3.5 6.5l5.5-2.2 6 2.2 5.5-2.2v13.2l-5.5 2.2-6-2.2-5.5 2.2z"/><path d="M9 4.3v13.2M15 6.5v13.2"/>',
  bolt: '<path d="M13.5 2.5L5.5 13.5h6l-1 8 8-11h-6z" fill="currentColor" stroke="none"/>',
  palm: '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V11M11 11V4a1.5 1.5 0 0 1 3 0v7M14 11V5.5a1.5 1.5 0 0 1 3 0V13M17 11.5V9a1.5 1.5 0 0 1 3 0v5.5a7 7 0 0 1-7 7h-1a6.5 6.5 0 0 1-5.6-3.2L4 14.2a1.5 1.5 0 0 1 2.5-1.6L8 15"/>',
  shield: '<path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
  link: '<path d="M10 14a4 4 0 0 0 5.7 0l3.3-3.3a4 4 0 0 0-5.7-5.7L12 6.3"/><path d="M14 10a4 4 0 0 0-5.7 0L5 13.3A4 4 0 0 0 10.7 19L12 17.7"/>',
  mission: '<rect x="3" y="4" width="8" height="6.5" rx="1.4"/><rect x="13" y="4" width="8" height="6.5" rx="1.4"/><rect x="3" y="13.5" width="8" height="6.5" rx="1.4"/><rect x="13" y="13.5" width="8" height="6.5" rx="1.4"/>',
  shortcut: '<rect x="4" y="4" width="16" height="16" rx="4.5"/><path d="M9.5 8.5l5 3.5-5 3.5" fill="currentColor"/>',
  keyboard: '<rect x="2.5" y="6" width="19" height="12" rx="2.2"/><path d="M6 10h.01M9 10h.01M12 10h.01M15 10h.01M18 10h.01M7.5 14h9"/>',
  hifi: '<rect x="6" y="3" width="12" height="18" rx="2.5"/><circle cx="12" cy="14.5" r="3.2"/><circle cx="12" cy="7.5" r="1.2" fill="currentColor" stroke="none"/>',
  airpods: '<path d="M8.2 4A3.2 3.2 0 0 0 5 7.2v1.3a3.2 3.2 0 0 0 3.2 3.2h.3v8.3a1.6 1.6 0 0 0 3.2 0V7.4A3.4 3.4 0 0 0 8.2 4zM15.8 4A3.2 3.2 0 0 1 19 7.2v1.3a3.2 3.2 0 0 1-3.2 3.2h-.3v8.3a1.6 1.6 0 0 1-3.2 0V7.4A3.4 3.4 0 0 1 15.8 4z" fill="currentColor" stroke="none"/>',
  bubble: '<path d="M4 11.5c0-4 3.6-7 8-7s8 3 8 7-3.6 7-8 7c-1 0-2-.1-2.9-.4L5 19.5l1.2-3.4C4.8 14.9 4 13.3 4 11.5z" fill="currentColor" stroke="none"/>',
  phone: '<path d="M6.6 3.6l3 .6 1.4 3.9-2 1.6a12 12 0 0 0 5.4 5.4l1.6-2 3.9 1.4.6 3c0 1.1-1 2-2.1 2C10 19.5 4.5 14 4.5 5.7c0-1.1.9-2.1 2.1-2.1z" fill="currentColor" stroke="none"/>',
  battery: '<rect x="2.5" y="7.5" width="16.5" height="9" rx="2.2"/><path d="M21.5 10.5v3"/><rect x="4.6" y="9.6" width="3.2" height="4.8" rx="0.8" fill="currentColor" stroke="none"/>',
};
export function glyph(name, size = 24, style = {}) {
  return h("span", { class: "glyph", style: { width: `${size}px`, height: `${size}px`, ...style }, html: `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${G[name] || ""}</svg>` });
}

// ---------------------------------------------------------------- Sway icon

/** Apple-style continuous-corner tile (a superellipse) inside a 1024 canvas. */
function squirclePath(cx = 512, cy = 512, half = 412, n = 5) {
  const points = [];
  for (let i = 0; i < 240; i++) {
    const a = (i / 240) * Math.PI * 2;
    const c = Math.cos(a), s = Math.sin(a);
    points.push(`${(cx + half * Math.sign(c) * Math.pow(Math.abs(c), 2 / n)).toFixed(2)},${(cy + half * Math.sign(s) * Math.pow(Math.abs(s), 2 / n)).toFixed(2)}`);
  }
  return `M${points.join("L")}Z`;
}

let iconCount = 0;
/** Sway's app icon, drawn as vectors so it stays crisp at any size. The
 * fingertip can travel: set icon.__finger(p) with p = 0 (bottom) … 1 (top). */
export function swayIcon(size = 300) {
  const id = `icon${iconCount++}`;
  const el = h("div", { class: "sway-icon", style: { width: `${size}px`, height: `${size}px` } });
  el.innerHTML = `
  <svg viewBox="0 0 1024 1024" width="${size}" height="${size}" style="overflow:visible">
    <defs>
      <linearGradient id="${id}body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3a3a3e"/><stop offset="0.55" stop-color="#1e1e21"/><stop offset="1" stop-color="#121214"/></linearGradient>
      <linearGradient id="${id}sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.10"/><stop offset="0.45" stop-color="#fff" stop-opacity="0"/></linearGradient>
      <linearGradient id="${id}streak" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#eef3ff" stop-opacity="0.96"/><stop offset="1" stop-color="#9fb0d6" stop-opacity="0.22"/></linearGradient>
      <radialGradient id="${id}glow"><stop offset="0" stop-color="#e6edff" stop-opacity="0.55"/><stop offset="0.35" stop-color="#c9d6ff" stop-opacity="0.18"/><stop offset="1" stop-color="#c9d6ff" stop-opacity="0"/></radialGradient>
      <clipPath id="${id}clip"><path d="${squirclePath()}"/></clipPath>
    </defs>
    <path d="${squirclePath(512, 540, 400)}" fill="#000" opacity="0.55" style="filter:blur(28px)"/>
    <path d="${squirclePath()}" fill="url(#${id}body)"/>
    <g clip-path="url(#${id}clip)">
      <rect x="0" y="0" width="1024" height="1024" fill="url(#${id}sheen)"/>
      <rect x="226" y="226" width="58" height="572" rx="29" fill="#fff" opacity="0.055"/>
      <rect x="740" y="226" width="58" height="572" rx="29" fill="#fff" opacity="0.055"/>
      <rect class="streak" x="740" y="400" width="58" height="398" rx="29" fill="url(#${id}streak)"/>
      <circle class="glow" cx="769" cy="420" r="230" fill="url(#${id}glow)"/>
      <circle class="tip" cx="769" cy="420" r="37" fill="#fff"/>
    </g>
    <path d="${squirclePath()}" fill="none" stroke="#fff" stroke-opacity="0.14" stroke-width="3"/>
  </svg>`;
  const streak = el.querySelector(".streak"), glow = el.querySelector(".glow"), tip = el.querySelector(".tip");
  el.__finger = (p, intensity = 1) => {
    const y = lerp(770, 420, p);
    streak.setAttribute("y", String(y - 29));
    streak.setAttribute("height", String(Math.max(58, 798 - (y - 29))));
    glow.setAttribute("cy", String(y));
    tip.setAttribute("cy", String(y));
    glow.setAttribute("opacity", String(intensity));
    tip.setAttribute("opacity", String(clamp(intensity * 1.2)));
    streak.setAttribute("opacity", String(clamp(intensity * 1.1)));
  };
  el.__finger(1);
  return el;
}

// ---------------------------------------------------------------- indicator

/** Sway's vertical level indicator (the native HUD pill). */
export function indicator(kind = "speaker", scale = 1.55) {
  const fill = h("div", { class: "ind-fill" });
  const number = h("div", { class: "ind-num" }, "0");
  const el = h("div", { class: "indicator", style: { transform: `scale(${scale})` } },
    glyph(kind, 26), h("div", { class: "ind-track" }, fill), number);
  const wrap = h("div", { class: "ind-wrap" }, el);
  wrap.__set = (v) => {
    fill.style.height = `${clamp(v / 100) * 100}%`;
    number.textContent = String(Math.round(v));
  };
  return wrap;
}

/** A frosted glass panel. */
export const glass = (cls = "", style = {}, ...children) => h("div", { class: `glass ${cls}`, style }, ...children);

/** Animated ripple rings for taps and haptic ticks, drawn into an SVG group. */
export function ripples(svg, events, t, { max = 70, life = 0.75, stroke = 2.4, color = "#eef3ff" } = {}) {
  svg.innerHTML = "";
  for (const e of events) {
    const age = t - e.t;
    if (age < 0 || age > life) continue;
    const p = ease.out(age / life);
    const r = (e.r0 ?? 8) + p * (e.max ?? max);
    svg.append(h("circle", { cx: e.x, cy: e.y, r, fill: "none", stroke: color, "stroke-width": stroke * (1 - p * 0.6), opacity: (1 - p) * (e.o ?? 0.9) }));
  }
}
