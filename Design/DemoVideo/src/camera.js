// The film's camera: named shots, and the track that says when it moves to
// each. Within a scene it travels; between scenes it cuts on the downbeat. It
// never stands quite still: every shot drifts a little.
//
// A shot is where the camera looks (q), from how far (d), how high (el, in
// degrees above the floor) and from which side (az), through what lens (fov),
// and what it holds in focus.
import { ease, prog, lerp, scene, OPEN, HOOK, CORNERS, CLIP, LIGHT, MORE, END } from "./timeline.js";
import { padPoint, screenPoint, edgePoint, SCREEN, DISPLAY, TEX } from "./world.js";

const right = (p) => { const e = edgePoint("right", p); return padPoint(e.x, e.y); };
const pad = (x, y) => padPoint(x * TEX.w, y * TEX.h);
const scr = (x, y) => screenPoint(x * SCREEN.w, y * SCREEN.h);
const mid = (a, b, p = 0.5) => [lerp(a[0], b[0], p), lerp(a[1], b[1], p), lerp(a[2], b[2], p)];
const centre = scr(0.5, 0.5);

export const SHOTS = {
  // The desk: the screen above, the trackpad below, as you'd sit at it.
  desk: { q: [0, 7.1, -7.5], d: 52, el: 10, az: 0, fov: 31, focus: centre, dof: 0 },
  deskIn: { q: [0, 7.3, -7.5], d: 47, el: 9.5, az: 0, fov: 31, focus: centre, dof: 0 },
  // Low and wide, for the floor's reflections.
  wide: { q: [0, 7.2, -9], d: 52, el: 5.5, az: -10, fov: 30, focus: centre, dof: 0 },
  wideR: { q: [0.5, 7.4, -9], d: 50, el: 5.5, az: 14, fov: 30, focus: centre, dof: 0 },
  // The trackpad, close.
  edgeR: { q: right(0.42), d: 15.5, el: 15, az: 32, fov: 30, focus: right(0.4), dof: 1, range: 0.3 },
  edgeRup: { q: mid(right(0.6), [3, 3, -6], 0.35), d: 24, el: 14, az: 22, fov: 30, focus: right(0.5), dof: 0.7, range: 0.34 },
  top: { q: [0, 0.4, 3.9], d: 62, el: 89.9, az: 0, fov: 28, focus: [0, 0.4, 0], dof: 0 },
  cornerTR: { q: pad(0.7, 0.36), d: 18, el: 36, az: -26, fov: 30, focus: pad(0.9, 0.14), dof: 0.22, range: 0.55 },
  // The top-left corner in the dark, for the hook's double-tap.
  cornerTL: { q: pad(0.3, 0.4), d: 19, el: 30, az: 28, fov: 30, focus: pad(0.1, 0.14), dof: 0.24, range: 0.55 },
  cornerTRb: { q: pad(0.74, 0.34), d: 17, el: 30, az: 20, fov: 30, focus: pad(0.9, 0.14), dof: 0.22, range: 0.55 },
  apps: { q: [-2.4, 6.2, -6.5], d: 42, el: 13, az: 0, fov: 31, focus: centre, dof: 0 },
  padHero: { q: [0, 2.6, -2.5], d: 30, el: 26, az: 0, fov: 30, focus: [0, 0.4, 0], dof: 0.55, range: 0.5 },
  ruler: { q: [3.3, 0.4, 0.3], d: 14, el: 52, az: 0, fov: 30, focus: right(0.5), dof: 0.3, range: 0.5 },
  // The screen, close.
  screen: { q: centre, d: 36, el: 4, az: 0, fov: 30, focus: centre, dof: 0 },
  screenTR: { q: scr(0.72, 0.24), d: 22, el: 4, az: 6, fov: 30, focus: centre, dof: 0 },
  // Screen and trackpad's right side together: the finger below, the picker above.
  picker: { q: scr(0.56, 0.44), d: 35, el: 4, az: 2.5, fov: 30, focus: centre, dof: 0 },
  doc: { q: scr(0.37, 0.4), d: 24, el: 4, az: -3, fov: 30, focus: centre, dof: 0 },
  mixer: { q: scr(0.655, 0.255), d: 25, el: 4, az: 3, fov: 30, focus: centre, dof: 0 },
  neon: { q: scr(0.95, 0.62), d: 12.5, el: 7, az: 46, fov: 30, focus: centre, dof: 0 },
  lightR: { q: mid(scr(0.84, 0.62), right(0.5), 0.42), d: 31, el: 10, az: 36, fov: 30, focus: centre, dof: 0 },
};

const S = scene;
const STILL = { d: 0, az: 0, el: 0 };
// Each entry: at `t`, start moving to `shot` over `dur` seconds (0 cuts).
// `drift` is how the shot keeps moving while it holds: d is the push in
// (fraction of the distance per second), az and el are degrees per second.
export const TRACK = [
  // Open: on the edge in the dark, then up and back as the screen answers.
  { t: 0, shot: "edgeR", drift: { d: -0.012, az: -0.5, el: 0.2 } },
  { t: OPEN.volume.start + 0.35, shot: "desk", dur: 2.7, drift: { d: -0.006, az: 0, el: 0 } },
  // Hook: in a little as the groove lands, then the dark corner.
  { t: S("hook").start, shot: "deskIn", dur: 2.2, drift: { d: -0.006, az: 0, el: 0 } },
  { t: HOOK.cut, shot: "cornerTL", drift: { d: -0.016, az: 0.6, el: 0 } },
  // Title: straight down on the trackpad, which is the logo.
  { t: S("title").start, shot: "top", drift: { d: -0.008, az: 0, el: 0 } },
  // Corners: the tap, then the screen's corner; the rest, then its corner.
  { t: S("corners").start, shot: "cornerTR", drift: { d: -0.01, az: -0.5, el: 0 } },
  { t: CORNERS.cut, shot: "screenTR", drift: { d: -0.008, az: -0.12, el: 0 } },
  // Clipboard: finger and picker in one frame, then across to the page.
  { t: S("clip").start, shot: "cornerTRb", drift: { d: -0.01, az: 0.5, el: 0 } },
  { t: CLIP.cut, shot: "picker", drift: { d: -0.006, az: -0.1, el: 0 } },
  { t: CLIP.toDoc[0], shot: "doc", dur: CLIP.toDoc[1] - CLIP.toDoc[0], drift: { d: -0.006, az: 0.1, el: 0 } },
  // Light: beside the lit edge, then back for the lap.
  { t: S("light").start, shot: "neon", drift: { d: -0.01, az: -0.8, el: 0 } },
  { t: S("light").start + 1.2, shot: "lightR", drift: { d: -0.008, az: -0.45, el: 0 } },
  { t: LIGHT.ambient - 0.3, shot: "wide", dur: 2.8, drift: { d: -0.004, az: 0.5, el: 0 } },
  // Mixer.
  { t: S("mixer").start, shot: "mixer", drift: { d: -0.005, az: -0.1, el: 0 } },
  // Apps.
  { t: S("apps").start, shot: "apps", drift: { d: -0.008, az: 0.35, el: 0 } },
  // Feel.
  { t: S("feel").start, shot: "ruler", drift: { d: -0.006, az: -0.25, el: 0 } },
  // More: the quick cuts.
  { t: S("more").start, shot: "desk", drift: STILL },
  { t: MORE.cuts[0], shot: "deskIn", drift: { d: -0.008, az: 0, el: 0 } },
  { t: MORE.cuts[3], shot: "padHero", drift: { d: -0.012, az: 0, el: 0 } },
  // End.
  { t: S("end").start, shot: "wideR", drift: { d: -0.004, az: -0.6, el: 0 } },
  { t: END.card, shot: "top", drift: { d: -0.006, az: 0, el: 0 } },
];

const NUMBERS = ["d", "el", "az", "fov", "dof", "range", "roll"];
function pose(entry, t) {
  const base = typeof entry.shot === "string" ? SHOTS[entry.shot] : entry.shot;
  const drift = entry.drift || { d: -0.006, az: 0.2, el: 0 };
  const dt = Math.max(0, t - entry.t);
  return { ...base, range: base.range ?? 0.42, roll: base.roll ?? 0, d: base.d * Math.exp(drift.d * dt), az: base.az + drift.az * dt, el: base.el + (drift.el || 0) * dt };
}
function blend(a, b, p) {
  const out = { q: mid(a.q, b.q, p), focus: mid(a.focus, b.focus, p) };
  for (const k of NUMBERS) out[k] = lerp(a[k], b[k], p);
  // Distance blends in log space, so pushing in and pulling out feel even.
  out.d = Math.exp(lerp(Math.log(a.d), Math.log(b.d), p));
  return out;
}

/** The camera at time t. */
export function shotAt(t) {
  let k = 0;
  while (k + 1 < TRACK.length && TRACK[k + 1].t <= t) k++;
  const entry = TRACK[k];
  const now = pose(entry, t);
  if (k === 0 || !entry.dur || t >= entry.t + entry.dur) return now;
  return blend(pose(TRACK[k - 1], t), now, (entry.curve || ease.glide)(prog(t, entry.t, entry.t + entry.dur)));
}
export const DISPLAY_CENTRE = [DISPLAY.x, DISPLAY.y, DISPLAY.z];
