// Things several scenes share: left-aligned captions, and the finger.
import { h, words, reveal } from "./ui.js";
import { prog, ease, clamp } from "./timeline.js";
import { TEX } from "./world.js";

/** Words anchored by their left edge and vertical middle. */
export function caption(text, cls, x, y, style = {}) {
  const el = words(text, cls, { position: "absolute", left: `${x}px`, top: `${y}px`, transform: "translateY(-50%)", ...style });
  return el;
}
/** Shows captions one after another: each leaves as the next arrives. */
export function sequence(els, t, times, end, options = {}) {
  els.forEach((el, i) => reveal(el, t, times[i], (i + 1 < times.length ? times[i + 1] : end) - 0.28, { rise: 0.3, stagger: 0.04, dur: 0.7, outDur: 0.3, ...options }));
}

// Where a fingertip lands in each corner of the trackpad's surface.
export const CORNER_POINT = { tl: { x: 150, y: 132 }, tr: { x: TEX.w - 150, y: 132 }, bl: { x: 150, y: TEX.h - 132 }, br: { x: TEX.w - 150, y: TEX.h - 132 } };

/** A double-tap in a corner: two brief touches, the corner glowing with each. No rings. */
export function tapCorner(pad, corner, t, pair, hold = 0) {
  const p = CORNER_POINT[corner];
  let o = 0, glow = 0;
  pair.forEach((at, i) => {
    const age = t - at;
    const last = i === pair.length - 1;
    o = Math.max(o, Math.min(ease.out(prog(age, -0.05, 0.02)), 1 - prog(age, last ? 0.12 + hold : 0.07, last ? 0.3 + hold : 0.12)));
    if (age >= 0) glow = Math.max(glow, (last ? 1 : 0.55) * Math.exp(-age * (last ? 3.2 : 9)));
  });
  if (o > 0.002) pad.contacts.push({ x: p.x, y: p.y, o: clamp(o), size: 1.05 });
  pad.corners[corner] = Math.max(pad.corners[corner], glow);
}

/** A small glass chip, for naming things in the frame. */
export function chip(icon, text) {
  const label = h("span", {}, text);
  const el = h("div", { class: "pill dark", style: { fontSize: "34px", padding: "16px 30px 16px 22px", gap: "14px", background: "rgba(28,29,34,0.78)", backdropFilter: "blur(20px)" } }, icon, label);
  el.__label = label;
  return el;
}
