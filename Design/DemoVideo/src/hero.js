// The website hero: 12 seconds of the film's graphite trackpad, rendered as an
// image sequence that the page scrubs with scroll. Same scene, studio,
// lighting and bloom as the film (src/gl.js); only the choreography is new.
//
// window.__seek(t) poses the pad as a pure function of t (seconds) and
// renders, so any frame can be drawn on demand and in any order.
//
//   0.0–1.6   the camera dives from straight down to a calm 3/4 view while a
//             band of light runs once around the rim; the edges power on
//   2.2–4.6   clipboard: double-tap the bottom-right corner, slide down the
//             right edge, lift
//   5.0–7.4   per-app volume: lean right, slide the right edge down
//   7.8–10.0  brightness: lean left, slide the left edge down, the scene dims
//   10.0–12.0 corner taps (top right, top left), then pull back and settle
import * as THREE from "three";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { createGL, edgePoint, PAD, ZONES } from "./gl.js";
import { ease, bezier, lerp, prog, ep, clamp, spring, seeded, swipe, levelAt, crossings } from "./timeline.js";

export const HERO = { fps: 24, duration: 12, width: 1920, height: 1080 };

// ------------------------------------------------------------------ look

const LOOK = {
  // Between the film's 0.81 (before its brightness swipe) and 1.2 (after),
  // so the graphite reads with the sheen of the film's best shots.
  exposure: 0.92,
  bloom: 0.85, // as in the film's slide scene
  tracks: 0.7,
  zone: 0.45, // resting edge-zone glow once the pad is on
  off: -0.35, // …and before it powers on
  offTracks: 0.3,
  edgeLight: 0.11, // soft light around each edge track, scaled by its zone glow
  // The wider lens shows the pad at ~0.73× the film's size; scale the finger
  // back up so it reads as clearly as in the film.
  finger: 1.3,
  // The film's bloom switches on over a 0.01 luminance step, so anything that
  // brightens or moves across the threshold pops from one frame to the next.
  // A soft knee centred on the same point keeps full-white elements blooming
  // exactly as in the film while partial ones fade in smoothly.
  knee: { threshold: 0.66, width: 0.3 },
};

// Camera poses. The camera travels the film's own path (straight down at
// 17.5, then a 3/4 view at 25.5), so the pad's perspective and every studio
// reflection on the graphite are the film's. The lens is wider than the
// film's 28° so the pad fills ~58% of the frame, centred, with the top ~30%
// free for the page's text. A calm azimuth of −4.5° puts the studio's strip
// light across the graphite and a glint on the far corner.
const OPEN = { elevation: 88, azimuth: 0, distance: 17.5, target: [0, 0, 0], fov: 38 };
const CALM = { elevation: 31, azimuth: -4.5, distance: 25.5, target: [0, -0.4, 0.9], fov: 38 };
const WIDE = { elevation: 1.5, distance: 2.2, target: [0, 0, 0] }; // added by the final pull-back
const LEAN = { right: 1.6, left: 4.5, x: 1.3, distance: 0.8 }; // right is gentler: the far-corner glint grows fast below −7°
const DRIFT = { azimuth: 0.6, elevation: 0.22 };

// ------------------------------------------------------------------ score

/** A one-finger edge slide. Levels are 0 (bottom of the edge) … 100 (top). */
const slideGesture = (side, appear, start, end, lift, liftEnd, from, to, ticks) => ({
  side, appear, liftEnd, ticks, ...swipe(appear, start, end, lift, from, to, ease.inOut),
});

const GESTURES = [
  // Clipboard: choose by sliding down the right edge, lift to paste.
  slideGesture("right", 2.9, 3.0, 4.2, 4.3, 4.5, 88, 22, { step: 15, notch: -1 }),
  // Per-app volume, with the film's tick every 1/16 and a firmer notch at 50%.
  slideGesture("right", 5.05, 5.2, 6.8, 6.9, 7.2, 80, 30, { step: 100 / 16, notch: 50 }),
  // Brightness.
  slideGesture("left", 7.86, 8.0, 9.5, 9.5, 9.8, 80, 45, { step: 100 / 16, notch: 50 }),
];
const [CLIPBOARD, VOLUME, BRIGHTNESS] = GESTURES;

// Double taps just inside a corner (surface-canvas pixels).
const TAPS = [
  { x: 1876, y: 1108, at: [2.4, 2.55] }, // bottom right: clipboard
  { x: 1876, y: 174, at: [10.3, 10.45] }, // top right
  { x: 172, y: 174, at: [10.9, 11.05] }, // top left
];

const RIM_RUN = { from: 0, to: 1.5, tail: 0.2, startTail: 0.05, overshoot: 0.12 };
const POWER = [1.36, 1.66];

// ------------------------------------------------------------------ setup

// Soft knee for the bloom threshold (see LOOK.knee). Patched on the prototype
// for this page only; the film keeps its own bloom.
const bloomRender = UnrealBloomPass.prototype.render;
UnrealBloomPass.prototype.render = function (...args) {
  this.threshold = LOOK.knee.threshold;
  this.highPassUniforms.smoothWidth.value = LOOK.knee.width;
  return bloomRender.apply(this, args);
};

// gl.js keeps its surface canvas private. Catch its 2D context as it is
// created so the hero can paint its edge glow and rim light onto the same
// surface. drawSurface() starts every frame with clearRect, so they are
// painted right after that clear, underneath the film's own surface graphics.
let surface = null;
const getContext = HTMLCanvasElement.prototype.getContext;
HTMLCanvasElement.prototype.getContext = function (type, ...rest) {
  const context = getContext.call(this, type, ...rest);
  if (type === "2d" && !surface && this.width === 2048 && this.height === 1280) surface = context;
  return context;
};
const gl = await createGL(document.getElementById("gl"));
HTMLCanvasElement.prototype.getContext = getContext;
const pad = gl.pad;

let rimState = null; // what the rim band should look like this frame
if (surface) {
  const clear = surface.clearRect;
  surface.clearRect = function (...args) {
    clear.apply(this, args);
    drawEdgeLight(this);
    if (rimState) drawRim(this, rimState);
  };
}

// ------------------------------------------------------------------ edge light

// A soft light around each edge track, so a lit zone reads as glowing rather
// than as a flat bar. Drawn additively under the film's own zone graphics,
// with its strength following that zone's glow. The glow is so faint that
// 8-bit steps would show as rings, so each frame it is written with a fixed
// dither pattern (static on the surface, so it never shimmers) that the
// texture's mipmaps then average into a smooth falloff.
const EDGE_GLOW = (() => {
  const margin = 150, w = 70, h = ZONES.bottom - ZONES.top;
  const width = w + margin * 2, height = h + margin * 2;
  const c = document.createElement("canvas");
  c.width = width;
  c.height = height;
  const g = c.getContext("2d", { willReadFrequently: true });
  g.filter = "blur(44px)";
  g.fillStyle = "#fff";
  g.beginPath();
  g.roundRect(margin, margin, w, h, w / 2);
  g.fill();
  const alpha = g.getImageData(0, 0, width, height).data;
  const profile = new Float32Array(width * height);
  for (let i = 0; i < profile.length; i++) profile[i] = alpha[i * 4 + 3] / 255;
  const random = seeded(7);
  const noise = new Float32Array(width * height);
  for (let i = 0; i < noise.length; i++) noise[i] = random() - random(); // triangular, ±1 level
  const out = document.createElement("canvas");
  out.width = width;
  out.height = height;
  const og = out.getContext("2d");
  return { profile, noise, out, og, image: og.createImageData(width, height), ox: margin + w / 2, oy: margin };
})();
const EDGE_TINT = [255, 255, 255]; // white: a tint would not survive premultiplied 8-bit at these alphas

function drawEdgeLight(g) {
  const { profile, noise, out, og, image, ox, oy } = EDGE_GLOW;
  g.save();
  g.globalCompositeOperation = "lighter";
  for (const side of ["left", "right"]) {
    const k = 255 * LOOK.edgeLight * clamp(pad.zones[side], 0, 1.5);
    if (k <= 0.01) continue;
    const d = image.data;
    // Light is carried in alpha (the surface is added to the scene as
    // colour × alpha, in linear light), so the dither goes on alpha.
    for (let i = 0, j = 0; i < profile.length; i++, j += 4) {
      d[j] = EDGE_TINT[0];
      d[j + 1] = EDGE_TINT[1];
      d[j + 2] = EDGE_TINT[2];
      const v = profile[i] * k;
      d[j + 3] = v + noise[i] * Math.min(1, v); // no dither where the glow fades to nothing
    }
    og.putImageData(image, 0, 0);
    g.drawImage(out, ZONES[side] - ox, ZONES.top - oy);
  }
  g.restore();
}

// ------------------------------------------------------------------ rim light

const TEX = gl.TEX;
const RIM = (() => {
  const inset = 24;
  const x0 = inset, y0 = inset, x1 = TEX.w - inset, y1 = TEX.h - inset;
  const r = (PAD.r * TEX.w) / PAD.w - inset;
  const cx = TEX.w / 2;
  const q = (Math.PI * r) / 2;
  // Clockwise on the surface (as seen from above), starting at the middle of
  // the near edge: left along the near edge, up the left edge, across the far
  // edge, down the right edge, and home.
  const parts = [
    { len: cx - (x0 + r), at: (u) => [cx - u, y1] },
    { len: q, at: (u) => arc(x0 + r, y1 - r, Math.PI / 2 + u / r) },
    { len: y1 - y0 - 2 * r, at: (u) => [x0, y1 - r - u] },
    { len: q, at: (u) => arc(x0 + r, y0 + r, Math.PI + u / r) },
    { len: x1 - x0 - 2 * r, at: (u) => [x0 + r + u, y0] },
    { len: q, at: (u) => arc(x1 - r, y0 + r, Math.PI * 1.5 + u / r) },
    { len: y1 - y0 - 2 * r, at: (u) => [x1, y0 + r + u] },
    { len: q, at: (u) => arc(x1 - r, y1 - r, u / r) },
    { len: x1 - r - cx, at: (u) => [x1 - r - u, y1] },
  ];
  function arc(x, y, angle) {
    return [x + r * Math.cos(angle), y + r * Math.sin(angle)];
  }
  const length = parts.reduce((sum, p) => sum + p.len, 0);
  function point(s) {
    s = ((s % length) + length) % length;
    for (const p of parts) {
      if (s <= p.len) return p.at(s);
      s -= p.len;
    }
    return parts[0].at(0);
  }
  return { length, point };
})();

function sprite(size, stops) {
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const g = c.getContext("2d");
  const gradient = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [o, color] of stops) gradient.addColorStop(o, color);
  g.fillStyle = gradient;
  g.fillRect(0, 0, size, size);
  return c;
}
const CORE = sprite(64, [[0, "rgba(255,255,255,1)"], [0.35, "rgba(246,249,255,0.85)"], [0.7, "rgba(230,238,255,0.25)"], [1, "rgba(230,238,255,0)"]]);
const HALO = sprite(128, [[0, "rgba(220,230,255,1)"], [0.4, "rgba(205,218,255,0.35)"], [1, "rgba(200,214,255,0)"]]);

/** The rim band: a bright head with a tail that fades behind it, painted by
 * stamping soft sprites along the rim with additive compositing, so it reads
 * as one continuous line of light with no beads or seams. */
function drawRim(g, { head, tail, o }) {
  if (o <= 0.002) return;
  g.save();
  g.globalCompositeOperation = "lighter";
  const step = 3;
  const n = Math.ceil(tail / step);
  for (let k = n; k >= 0; k--) {
    const d = k * step; // distance behind the head
    const u = d / tail;
    if (u >= 1) continue;
    const fall = Math.pow(1 - u, 2.4);
    if (fall <= 0.001) continue;
    const [x, y] = RIM.point(head - d);
    g.globalAlpha = clamp(0.05 * fall * o);
    g.drawImage(HALO, x - 46, y - 46, 92, 92);
    g.globalAlpha = clamp(0.16 * fall * o);
    g.drawImage(CORE, x - 13, y - 13, 26, 26);
  }
  // The head itself: a hot point with a wide soft glow.
  const [hx, hy] = RIM.point(head);
  g.globalAlpha = clamp(0.4 * o);
  g.drawImage(HALO, hx - 75, hy - 75, 150, 150);
  g.globalAlpha = clamp(0.9 * o);
  g.drawImage(CORE, hx - 24, hy - 24, 48, 48);
  g.restore();
}

// A gentle in-out, so the head never jumps far between frames (peak speed is
// about 1.7× the average, against ~3× for the film's ease.inOut).
const RIM_EASE = bezier(0.4, 0, 0.6, 1);

function rimAt(t) {
  const { from, to, tail, overshoot } = RIM_RUN;
  if (t < from || t >= to) return null;
  const p = prog(t, from, to);
  const head = RIM_EASE(p) * RIM.length * (1 + overshoot);
  // Already lit on the first frame, with a short tail, so the page opens on
  // light travelling along the rim; the tail stretches as it gathers speed.
  const length = RIM.length * lerp(RIM_RUN.startTail, tail, ease.smooth(prog(p, 0, 0.35)));
  const o = Math.min(0.7 + 0.3 * ease.smooth(prog(p, 0, 0.15)), 1 - ease.smooth(prog(p, 0.7, 1)));
  return { head, tail: length, o };
}

// ------------------------------------------------------------------ gestures

function gesture(g, t) {
  const now = edgePoint(g.side, levelAt(g, t) / 100);
  const down = edgePoint(g.side, g.from / 100);
  const o = Math.min(ep(t, g.appear, g.appear + 0.2, ease.smooth), 1 - ease.smooth(prog(t, g.lift, g.liftEnd)));
  if (o > 0.001) {
    const press = 1 + 0.25 * (1 - spring(t - g.appear, 0.32, 0.55));
    const fromY = lerp(down.y, now.y, ease.smooth(prog(t, g.lift, g.lift + 0.5)));
    pad.contacts.push({ x: now.x, y: now.y, fromY, o, size: press * LOOK.finger });
  }
  // A tick ripple as the level passes each step (the film's haptic ticks).
  for (const c of crossings(g, g.ticks.step, g.ticks.notch)) {
    const age = t - c.t;
    if (age < 0 || age > 0.6) continue;
    const p = ease.out(age / 0.6);
    const at = edgePoint(g.side, c.value / 100);
    const o = (1 - p) * (c.notch ? 0.7 : 0.36) * ease.smooth(clamp(age / 0.07));
    pad.ripples.push({ x: at.x, y: at.y, r: 34 + p * (c.notch ? 150 : 85), o, w: c.notch ? 7 : 4.5 });
  }
}

/** How strongly an edge zone is lit by a gesture on it. */
function zoneLight(g, t) {
  return Math.min(ep(t, g.appear, g.appear + 0.25, ease.smooth), 1 - ease.smooth(prog(t, g.lift, g.liftEnd + 0.35)));
}

function taps(t) {
  for (const corner of TAPS) {
    const [first, last] = corner.at;
    // The finger: one soft glow held across both taps, so the double tap
    // reads through its two rings rather than a blinking dot.
    const press = Math.min(ep(t, first - 0.1, first, ease.smooth), 1 - ease.smooth(prog(t, last + 0.03, last + 0.32)));
    if (press > 0.001) pad.contacts.push({ x: corner.x, y: corner.y, o: press * 0.6, size: 0.72 * LOOK.finger });
    for (const tt of corner.at) {
      const age = t - tt;
      if (age < 0 || age > 0.8) continue;
      const p = ease.out(age / 0.8);
      pad.ripples.push({ x: corner.x, y: corner.y, r: 22 + p * 150, o: (1 - p) * 0.8 * ease.smooth(clamp(age / 0.07)), w: 5 * (1 - p) + 1.5 });
    }
  }
}

// ------------------------------------------------------------------ camera

function camera(t, [jx, jy] = [0, 0]) {
  // The dive: pull back from straight down while tilting to the 3/4 view.
  const back = ease.smooth(prog(t, 0, 1.55));
  const tilt = ease.smooth(prog(t, 0, 1.6));
  // Idle drift, breathing in after the dive and out before the last frames.
  const drift = ease.smooth(prog(t, 1.3, 2.4)) * (1 - ease.smooth(prog(t, 10.9, 11.9)));
  const driftA = Math.sin(((t - 1.3) / 6.4) * Math.PI * 2) * DRIFT.azimuth * drift;
  const driftE = Math.sin(((t - 1.3) / 8.6) * Math.PI * 2) * DRIFT.elevation * drift;
  // Leans toward the edge in use, softer than the film's.
  const right = Math.min(ease.inOut(prog(t, 4.95, 5.95)), 1 - ease.inOut(prog(t, 6.85, 7.4)));
  const left = Math.min(ease.inOut(prog(t, 7.75, 8.75)), 1 - ease.inOut(prog(t, 9.45, 10.0)));
  // The final pull-back, settled by the last frame.
  const wide = ease.smooth(prog(t, 11.0, 11.95));

  pad.fov = lerp(OPEN.fov, CALM.fov, back);
  pad.elevation = lerp(OPEN.elevation, CALM.elevation, tilt) + driftE + wide * WIDE.elevation;
  pad.azimuth = lerp(OPEN.azimuth, CALM.azimuth, tilt) + driftA - right * LEAN.right + left * LEAN.left;
  pad.distance = lerp(OPEN.distance, CALM.distance, back) - (right + left) * LEAN.distance + wide * WIDE.distance;
  pad.target = [
    (right - left) * LEAN.x,
    lerp(OPEN.target[1], CALM.target[1], back) + wide * WIDE.target[1],
    lerp(OPEN.target[2], CALM.target[2], back) + wide * WIDE.target[2],
  ];
  // Sub-pixel jitter for supersampling: slide camera and target together
  // along the image plane by (jx, jy) pixels.
  if (jx || jy) {
    const e = THREE.MathUtils.degToRad(pad.elevation), a = THREE.MathUtils.degToRad(pad.azimuth);
    const px = (2 * pad.distance * Math.tan(THREE.MathUtils.degToRad(pad.fov / 2))) / HERO.height;
    const right = [Math.cos(a), 0, -Math.sin(a)];
    const up = [-Math.sin(e) * Math.sin(a), Math.cos(e), -Math.sin(e) * Math.cos(a)];
    for (let i = 0; i < 3; i++) pad.target[i] += (right[i] * jx + up[i] * jy) * px;
  }
}

// ------------------------------------------------------------------ frame

function pose(t, jitter) {
  t = clamp(t, 0, HERO.duration);
  camera(t, jitter);

  // Power on: the edge zones start dark and glow up as the rim light closes
  // its loop. (gl.js draws a zone at 0.018 + 0.03 × glow alpha, so a glow of
  // LOOK.off dims it below the film's resting level.)
  const on = ease.smooth(prog(t, POWER[0], POWER[1]));
  const rest = lerp(LOOK.off, LOOK.zone, on);
  pad.tracks = lerp(LOOK.offTracks, LOOK.tracks, on);
  pad.labels.o = 0;
  pad.zones.right = rest + (1 - rest) * Math.max(zoneLight(CLIPBOARD, t), zoneLight(VOLUME, t));
  pad.zones.left = rest + (1 - rest) * zoneLight(BRIGHTNESS, t);

  pad.contacts = [];
  pad.ripples = [];
  taps(t);
  for (const g of GESTURES) gesture(g, t);
  rimState = rimAt(t);

  // Brightness dims the whole picture as the left edge slides down, then
  // eases back after the lift.
  const dim = ((BRIGHTNESS.from - levelAt(BRIGHTNESS, t)) / (BRIGHTNESS.from - BRIGHTNESS.to)) * (1 - ease.inOut(prog(t, 9.55, 10.0)));
  pad.exposure = LOOK.exposure * (1 - 0.3 * dim);
  pad.bloom = LOOK.bloom;
}

// Each frame is the average of SAMPLES renders, each with a sub-pixel camera
// jitter (supersampling, so thin bevel highlights and their bloom don't
// twinkle as the camera drifts) spread over a short shutter (a touch of
// motion blur on fast moves, like a film camera). Still a pure function of t.
const params = new URLSearchParams(location.search);
const SAMPLES = Math.max(1, Number(params.get("samples") ?? (params.has("scrub") ? 1 : 8)));
const SHUTTER = 0.4; // fraction of a frame interval
const halton = (i, base) => { let f = 1, r = 0; for (; i > 0; i = Math.floor(i / base)) { f /= base; r += f * (i % base); } return r; };
const JITTER = Array.from({ length: SAMPLES }, (_, k) => (SAMPLES === 1 ? [0, 0] : [halton(k + 1, 2) - 0.5, halton(k + 1, 3) - 0.5]));
const out = document.getElementById("out");
const outContext = out.getContext("2d");
const grab = document.createElement("canvas");
grab.width = HERO.width;
grab.height = HERO.height;
const grabContext = grab.getContext("2d", { willReadFrequently: true });
const sum = new Uint16Array(HERO.width * HERO.height * 4);
const frameImage = outContext.createImageData(HERO.width, HERO.height);

function seek(t) {
  if (SAMPLES === 1) {
    pose(t);
    gl.render(t);
    outContext.drawImage(gl.canvas, 0, 0);
    return;
  }
  sum.fill(0);
  for (let k = 0; k < SAMPLES; k++) {
    pose(t + (((k + 0.5) / SAMPLES - 0.5) * SHUTTER) / HERO.fps, JITTER[k]);
    gl.render(t);
    grabContext.drawImage(gl.canvas, 0, 0);
    const d = grabContext.getImageData(0, 0, HERO.width, HERO.height).data;
    for (let i = 0; i < d.length; i++) sum[i] += d[i];
  }
  const o = frameImage.data, half = SAMPLES / 2;
  for (let i = 0; i < o.length; i++) o[i] = (sum[i] + half) / SAMPLES;
  outContext.putImageData(frameImage, 0, 0);
  pose(t); // leave the pad describing the frame itself (for bounds())
}

/** Debug: the pad's on-screen bounding box (pixels) for the current pose. */
function bounds() {
  const cam = new THREE.PerspectiveCamera(pad.fov, HERO.width / HERO.height, 0.1, 400);
  const e = THREE.MathUtils.degToRad(pad.elevation), a = THREE.MathUtils.degToRad(pad.azimuth);
  const [tx, ty, tz] = pad.target;
  cam.position.set(tx + pad.distance * Math.cos(e) * Math.sin(a), ty + pad.distance * Math.sin(e), tz + pad.distance * Math.cos(e) * Math.cos(a) + 0.0001);
  cam.lookAt(tx, ty, tz);
  cam.updateMatrixWorld();
  const hw = PAD.w / 2 + PAD.bevel, hd = PAD.d / 2 + PAD.bevel, r = PAD.r + PAD.bevel;
  const box = { left: Infinity, right: -Infinity, top: Infinity, bottom: -Infinity };
  const v = new THREE.Vector3();
  for (const y of [PAD.depth + PAD.bevel, -PAD.bevel]) {
    for (const [cx, cz, a0] of [[hw - r, hd - r, 0], [-(hw - r), hd - r, 90], [-(hw - r), -(hd - r), 180], [hw - r, -(hd - r), 270]]) {
      for (let k = 0; k <= 16; k++) {
        const angle = THREE.MathUtils.degToRad(a0 + (k / 16) * 90);
        v.set(cx + r * Math.cos(angle), y, cz + r * Math.sin(angle)).project(cam);
        const px = ((v.x + 1) / 2) * HERO.width, py = ((1 - v.y) / 2) * HERO.height;
        box.left = Math.min(box.left, px); box.right = Math.max(box.right, px);
        box.top = Math.min(box.top, py); box.bottom = Math.max(box.bottom, py);
      }
    }
  }
  return { ...box, width: box.right - box.left, widthFraction: (box.right - box.left) / HERO.width, topFraction: box.top / HERO.height, bottomFraction: box.bottom / HERO.height, centreX: (box.left + box.right) / 2 / HERO.width };
}

window.__seek = seek;
window.__render = () => gl.render();
window.__hero = { HERO, LOOK, OPEN, CALM, WIDE, LEAN, DRIFT, pose, bounds, pad };
seek(0);
window.__ready = true;

// Scrub preview: /hero.html?scrub
if (location.search.includes("scrub")) {
  document.body.classList.add("scrub");
  const canvas = gl.canvas;
  const fit = () => (canvas.style.transform = `scale(${Math.min(innerWidth / HERO.width, (innerHeight - 60) / HERO.height)})`);
  fit();
  addEventListener("resize", fit);
  const bar = document.createElement("div");
  bar.id = "scrubber";
  bar.innerHTML = `<input type="range" min="0" max="${HERO.duration}" step="${1 / HERO.fps}" value="0"><span id="time">0.00</span>`;
  document.body.append(bar);
  const range = bar.querySelector("input"), label = bar.querySelector("#time");
  range.addEventListener("input", () => { seek(Number(range.value)); label.textContent = Number(range.value).toFixed(2); });
}
