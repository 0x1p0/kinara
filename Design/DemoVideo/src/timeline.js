// The score: every scene boundary, gesture and sound cue in the film lives
// here, so the picture (src/main.js) and the soundtrack (soundtrack.mjs) are
// driven by the same numbers and can never drift apart. Times are seconds.

export const FILM = { fps: 60, width: 1920, height: 1080, bpm: 96, duration: 96 };
export const BEAT = 60 / FILM.bpm; // 0.625 s
export const BAR = BEAT * 4; // 2.5 s
const bar = (n) => n * BAR;

export const SCENES = [
  { id: "intro", start: 0, end: bar(3) },
  { id: "logo", start: bar(3), end: bar(5) },
  { id: "slide", start: bar(5), end: bar(9) },
  { id: "feel", start: bar(9), end: bar(13) },
  { id: "actions", start: bar(13), end: bar(16) },
  { id: "taps", start: bar(16), end: bar(19) },
  { id: "clipboard", start: bar(19), end: bar(24) },
  { id: "aware", start: bar(24), end: bar(27) },
  { id: "sound", start: bar(27), end: bar(30) },
  { id: "details", start: bar(30), end: bar(33) },
  { id: "light", start: bar(33), end: bar(35) },
  { id: "end", start: bar(35), end: FILM.duration },
];

// ---------------------------------------------------------------- easing

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, p) => a + (b - a) * p;
/** 0 before a, 1 after b, linear between. */
export const prog = (t, a, b) => clamp((t - a) / (b - a));

/** CSS-style cubic-bezier easing, solved with Newton steps and bisection. */
export function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = (t) => ((ax * t + bx) * t + cx) * t;
  const sy = (t) => ((ay * t + by) * t + cy) * t;
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 6; i++) {
      const e = sx(t) - x;
      const d = dx(t);
      if (Math.abs(e) < 1e-6) return sy(t);
      if (Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    let lo = 0, hi = 1;
    t = x;
    for (let i = 0; i < 30; i++) {
      const v = sx(t);
      if (Math.abs(v - x) < 1e-6) break;
      if (x > v) lo = t; else hi = t;
      t = (lo + hi) / 2;
    }
    return sy(t);
  };
}

export const ease = {
  settle: bezier(0.16, 1, 0.3, 1), // Sway's HUD entrance: fast out, gentle settle
  leave: bezier(0.4, 0, 1, 1), // Sway's HUD exit
  inOut: bezier(0.65, 0, 0.35, 1),
  smooth: bezier(0.45, 0, 0.2, 1),
  out: bezier(0.22, 1, 0.36, 1),
  in: bezier(0.55, 0, 0.9, 0.4),
  expoOut: (p) => (p >= 1 ? 1 : 1 - Math.pow(2, -10 * p)),
  linear: (p) => p,
};

/** SwiftUI-style spring(response, dampingFraction), evaluated at seconds since start. */
export function spring(seconds, response = 0.4, damping = 0.8) {
  if (seconds <= 0) return 0;
  const w0 = (2 * Math.PI) / response;
  if (damping >= 1) return 1 - (1 + w0 * seconds) * Math.exp(-w0 * seconds);
  const wd = w0 * Math.sqrt(1 - damping * damping);
  const decay = Math.exp(-damping * w0 * seconds);
  return 1 - decay * (Math.cos(wd * seconds) + ((damping * w0) / wd) * Math.sin(wd * seconds));
}

/** Eased progress between a and b. */
export const ep = (t, a, b, curve = ease.settle) => curve(prog(t, a, b));
/** In-hold-out envelope: rises over [a, a+inD], holds, falls over [b-outD, b]. */
export function env(t, a, b, inD = 0.5, outD = 0.4, inCurve = ease.settle, outCurve = ease.leave) {
  if (t < a || t > b) return 0;
  return Math.min(inCurve(prog(t, a, a + inD)), 1 - outCurve(prog(t, b - outD, b)));
}

/** Deterministic pseudo-random numbers. */
export function seeded(seed = 1) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let r = Math.imul(s ^ (s >>> 15), 1 | s);
    r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------- gestures

/** A one-finger swipe: touch down, slide a level from → to, lift. */
export const swipe = (down, start, end, lift, from, to, curve = ease.inOut) => ({ down, start, end, lift, from, to, curve });
export const levelAt = (g, t) => lerp(g.from, g.to, g.curve(prog(t, g.start, g.end)));
/** Times at which a swipe's level crosses each multiple of step (for haptic ticks). */
export function crossings(g, step, notch = 50) {
  const out = [];
  let previous = Math.floor(g.from / step);
  for (let i = 1; i <= 400; i++) {
    const t = lerp(g.start, g.end, i / 400);
    const v = levelAt(g, t);
    const index = Math.floor(v / step);
    if (index !== previous) {
      const value = Math.max(index, previous) * step;
      out.push({ t, value, notch: Math.abs(value - notch) < 0.01 });
      previous = index;
    }
  }
  return out;
}

const S = Object.fromEntries(SCENES.map((s) => [s.id, s]));

export const SLIDE = {
  volume: swipe(14.0, 14.25, 16.0, 16.35, 18, 75),
  brightness: swipe(17.45, 17.7, 19.4, 19.75, 32, 92),
};

export const FEEL = {
  title: [S.feel.start + 0.1, S.feel.start + 1.75],
  cards: 4,
  cardStart: S.feel.start + 1.5,
  cardStep: 2.05,
};
export const feelCard = (k) => FEEL.cardStart + k * FEEL.cardStep;

export const ACTIONS = {
  countStart: S.actions.start + 0.1,
  countEnd: S.actions.start + 1.45,
  wallStart: S.actions.start + 1.3,
  scatter: S.actions.end - 1.05,
};

export const TAPS = {
  enter: S.taps.start,
  corner: [S.taps.start + 1.2, S.taps.start + 1.38],
  corner2: [S.taps.start + 2.45, S.taps.start + 2.63],
  hold: [S.taps.start + 3.5, S.taps.start + 4.15],
  palm: S.taps.start + 5.0,
};

export const CLIP = {
  copies: [S.clipboard.start, S.clipboard.start + BEAT, S.clipboard.start + BEAT * 2],
  title: S.clipboard.start + 1.9,
  desk: S.clipboard.start + 3.1,
  taps: [S.clipboard.start + 3.9, S.clipboard.start + 4.08],
  bloom: S.clipboard.start + 4.22,
  steps: [S.clipboard.start + 5.1, S.clipboard.start + 5.62, S.clipboard.start + 6.14],
  lift: S.clipboard.start + 7.3,
  lines: [S.clipboard.start + 8.1, S.clipboard.start + 10.1],
};

export const AWARE = {
  title: S.aware.start + 0.15,
  apps: [S.aware.start + 1.1, S.aware.start + 2.2, S.aware.start + 3.3],
  dock: S.aware.start + 4.45,
  pointer: S.aware.start + 5.75,
};

export const SOUND = {
  appSwipe: swipe(S.sound.start + 0.75, S.sound.start + 0.9, S.sound.start + 1.9, S.sound.start + 2.1, 80, 22),
  limitSwipe: swipe(S.sound.start + 2.95, S.sound.start + 3.1, S.sound.start + 4.1, S.sound.start + 4.3, 30, 92),
  limit: 60,
  seekSwipe: swipe(S.sound.start + 5.45, S.sound.start + 5.6, S.sound.start + 6.7, S.sound.start + 6.9, 0.3, 0.68),
};

// The edge map gets a longer shot; the rest are quick cuts on the beat.
export const DETAILS = {
  cuts: [
    { id: "map", len: BAR },
    { id: "night", len: BAR / 2 },
    { id: "dim", len: BAR / 2 },
    { id: "tile", len: BAR / 2 },
    { id: "more", len: BAR / 2 },
  ],
};
let cursor = S.details.start;
for (const cut of DETAILS.cuts) { cut.start = cursor; cursor += cut.len; cut.end = cursor; }
export const detailCut = (k) => DETAILS.cuts[k].start;

export const LIGHT = { count: [S.light.start + 0.3, S.light.start + 1.6], promise: S.light.start + 2.55 };
export const END = { icon: S.end.start, word: S.end.start + 0.75, line: S.end.start + 1.5, fade: FILM.duration - 2.2 };

// ---------------------------------------------------------------- cues

/** Every sound event, derived from the same choreography the picture uses. */
export function cues() {
  const list = [];
  const add = (t, kind, gain = 1, extra = {}) => list.push({ t, kind, gain, ...extra });

  // Intro: the edge lights up, the swipe rises, the logo lands.
  add(0.8, "glint", 0.55);
  add(3.75, "glint", 0.4);
  add(S.logo.start - 2.1, "riser", 0.8, { length: 2.1 });
  add(S.logo.start, "impact", 1);
  add(S.logo.start, "bloom", 0.5);
  add(S.logo.start + 0.05, "motif", 0.85);
  add(S.slide.start - 1.4, "whoosh", 0.7, { length: 1.4 });

  // Slide: a tick for every volume/brightness step, a firmer one at the notch.
  for (const g of [SLIDE.volume, SLIDE.brightness]) {
    add(g.down, "touch", 0.6);
    for (const c of crossings(g, 100 / 16)) add(c.t, c.notch ? "notch" : "tick", 0.8);
  }
  add(S.feel.start - 0.3, "whoosh", 0.6, { length: 0.8 });

  // Feel: one card at a time slides in.
  for (let k = 0; k < FEEL.cards; k++) add(feelCard(k) - 0.15, "swish", 0.45);
  add(feelCard(2) + 1.0, "notch", 1);
  for (let i = 0; i < 4; i++) add(feelCard(3) + 0.35 + i * 0.32, "haptic", 0.5 + i * 0.17);

  // Actions: the count, the wall arriving, the scatter.
  add(S.actions.start - 1.6, "riser", 0.7, { length: 1.6 });
  add(S.actions.start, "impact", 0.9);
  for (let i = 0; i < 14; i++) add(ACTIONS.countStart + ease.expoOut(i / 14) * (ACTIONS.countEnd - ACTIONS.countStart), "tick", 0.35);
  add(ACTIONS.wallStart, "bloom", 0.6);
  add(ACTIONS.scatter, "whoosh", 0.75, { length: 0.9 });

  // Taps.
  for (const t of [...TAPS.corner, ...TAPS.corner2]) add(t, "tap", 0.9);
  add(TAPS.corner[1] + 0.12, "pop", 0.7);
  add(TAPS.corner2[1] + 0.12, "pop", 0.6);
  add(TAPS.hold[0], "touch", 0.7);
  add(TAPS.hold[1], "pop", 0.7);
  add(TAPS.palm, "thud", 0.5);
  add(S.clipboard.start - 0.7, "whoosh", 0.7, { length: 0.7 });

  // Clipboard: three copies on the beat, the bloom, each row, the paste.
  for (const t of CLIP.copies) add(t, "copy", 0.9);
  add(CLIP.title, "impact", 0.55);
  for (const t of CLIP.taps) add(t, "tap", 0.9);
  add(CLIP.bloom, "bloom", 0.9);
  for (const t of CLIP.steps) add(t, "tick", 0.9);
  add(CLIP.lift, "paste", 1);
  add(S.aware.start - 0.5, "whoosh", 0.6, { length: 0.6 });

  // Aware.
  for (const t of AWARE.apps) add(t, "swish", 0.5);
  add(AWARE.dock, "thud", 0.6);
  add(AWARE.dock + 0.55, "pop", 0.5);
  add(AWARE.pointer + 0.7, "glint", 0.4);

  // Sound.
  for (const g of [SOUND.appSwipe, SOUND.limitSwipe]) {
    add(g.down, "touch", 0.5);
    for (const c of crossings(g, 100 / 16)) if (g !== SOUND.limitSwipe || c.value <= SOUND.limit) add(c.t, "tick", 0.7);
  }
  add(SOUND.limitSwipe.start + 0.43, "notch", 1);
  add(SOUND.seekSwipe.down, "touch", 0.5);

  // Details: a whip on every cut.
  for (let k = 0; k < DETAILS.cuts.length; k++) add(detailCut(k) - 0.12, "whip", 0.6);
  for (let i = 0; i < 6; i++) add(detailCut(0) + 0.45 + i * 0.16, "tick", 0.45);

  // Light and end.
  add(S.light.start, "impact", 0.6);
  add(S.end.start - 1.8, "riser", 0.75, { length: 1.8 });
  add(S.end.start, "impact", 1);
  add(S.end.start, "bloom", 0.6);
  add(S.end.start + 0.3, "motif", 1);
  return list.sort((a, b) => a.t - b.t);
}

/** Musical sections: how much of each layer plays (0..1) per scene. */
export const MIX = {
  intro: { pad: 0.55, arp: 0, kick: 0, hats: 0, bass: 0.2, clap: 0 },
  logo: { pad: 0.9, arp: 0.2, kick: 0, hats: 0, bass: 0.6, clap: 0 },
  slide: { pad: 0.85, arp: 0.7, kick: 0, hats: 0.25, bass: 0.7, clap: 0 },
  feel: { pad: 0.85, arp: 0.85, kick: 0.45, hats: 0.5, bass: 0.8, clap: 0 },
  actions: { pad: 0.9, arp: 0.9, kick: 1, hats: 0.8, bass: 1, clap: 0.6 },
  taps: { pad: 0.85, arp: 0.8, kick: 0.8, hats: 0.7, bass: 0.9, clap: 0.5 },
  clipboard: { pad: 0.9, arp: 0.6, kick: 0.6, hats: 0.5, bass: 0.8, clap: 0.3, breakUntil: S.clipboard.start + 3.1 },
  aware: { pad: 0.9, arp: 0.9, kick: 1, hats: 0.8, bass: 1, clap: 0.6 },
  sound: { pad: 0.9, arp: 0.9, kick: 1, hats: 0.85, bass: 1, clap: 0.6 },
  details: { pad: 0.95, arp: 1, kick: 1, hats: 1, bass: 1, clap: 0.7 },
  light: { pad: 0.9, arp: 0.6, kick: 0.4, hats: 0.3, bass: 0.7, clap: 0 },
  end: { pad: 1, arp: 0.3, kick: 0, hats: 0, bass: 0.6, clap: 0 },
};
export const sceneAt = (t) => SCENES.find((s) => t >= s.start && t < s.end) || SCENES[SCENES.length - 1];
