// The score: every scene boundary, gesture and sound cue in the film lives
// here, so the picture (src/main.js) and the soundtrack (soundtrack.mjs) are
// driven by the same numbers and can never drift apart. Times are seconds.

export const FILM = { fps: 60, width: 1920, height: 1080, bpm: 100, duration: 86.4 };
export const BEAT = 60 / FILM.bpm; // 0.6 s, 36 frames
export const BAR = BEAT * 4; // 2.4 s
const bar = (n) => n * BAR;

// One studio, one trackpad, one screen. It opens without a word: a finger on
// the edge, and the film's own sound and light follow it. Then the name, then
// what only Kinara does, each scene cut on a downbeat.
export const SCENES = [
  { id: "open", start: 0, end: bar(4) },
  { id: "title", start: bar(4), end: bar(6) },
  { id: "corners", start: bar(6), end: bar(9) },
  { id: "clip", start: bar(9), end: bar(13) },
  { id: "light", start: bar(13), end: bar(17) },
  { id: "mixer", start: bar(17), end: bar(21) },
  { id: "apps", start: bar(21), end: bar(24) },
  { id: "feel", start: bar(24), end: bar(28) },
  { id: "more", start: bar(28), end: bar(32) },
  { id: "end", start: bar(32), end: FILM.duration },
];

// ---------------------------------------------------------------- easing

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, p) => a + (b - a) * p;
/** 0 before a, 1 after b, linear between. Safe when a or b is infinite ("never"). */
export const prog = (t, a, b) => (t <= a ? 0 : t >= b ? 1 : (t - a) / (b - a));

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
  settle: bezier(0.16, 1, 0.3, 1), // Kinara's HUD entrance: fast out, gentle settle
  leave: bezier(0.4, 0, 1, 1), // Kinara's HUD exit
  inOut: bezier(0.65, 0, 0.35, 1),
  smooth: bezier(0.45, 0, 0.2, 1),
  out: bezier(0.22, 1, 0.36, 1),
  in: bezier(0.55, 0, 0.9, 0.4),
  glide: bezier(0.76, 0, 0.24, 1), // camera moves: slow out, slow in
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
/** How present a swipe's finger is: in on touch, out after the lift. */
export const touchAt = (g, t, inD = 0.14, outD = 0.3) => Math.min(ease.out(prog(t, g.down - 0.02, g.down + inD)), 1 - ease.smooth(prog(t, g.lift, g.lift + outD)));
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
/** A level that follows keys [[t, value], …], easing between them. */
export function path(keys, t, curve = ease.inOut) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    if (t <= keys[i][0]) return lerp(keys[i - 1][1], keys[i][1], curve(prog(t, keys[i - 1][0], keys[i][0])));
  }
  return keys[keys.length - 1][1];
}

const S = Object.fromEntries(SCENES.map((s) => [s.id, s]));
export const scene = (id) => S[id];

// ---------------------------------------------------------------- choreography

// The open: the right edge is volume, and the film's own score rises with it;
// the left edge is brightness, and the studio lights up with the screen.
export const OPEN = {
  volume: swipe(0.9, 1.15, 3.7, 4.0, 10, 72),
  brightness: swipe(4.8, 5.05, 7.4, 7.75, 14, 100),
  dim: 0.14, // the screen's backlight before the brightness slide
};

const ti = S.title.start;
export const TITLE = { draw: [ti + 0.05, ti + 1.1], word: ti + 0.55, line: ti + 1.25, out: S.title.end - 0.5 };

// A double-tap pauses the music (the score really does stop), and the same
// tap again undoes it. The film watches the finger tap, then cuts to the
// screen and lets it answer there: `fire` is when the screen does.
const cr = S.corners.start;
export const CORNERS = {
  title: cr + 0.1,
  // The second tap of each pair lands on the beat.
  taps: [cr + 2.22, cr + 2.4],
  cut: cr + 2.74,
  fire: cr + 2.82,
  // Inside the two seconds Kinara allows for an undo.
  undo: [cr + 4.62, cr + 4.8],
  fold: cr + 6.45,
};
/** The score stops while the film's music is paused. */
export const PAUSE = { from: CORNERS.fire, to: CORNERS.undo[1] + 0.02, level: 0.05 };

// Clipboard history: double-tap a corner, slide to choose, lift to paste.
const cl = S.clip.start;
export const CLIP = {
  title: cl + 0.1,
  taps: [cl + 1.62, cl + 1.8],
  cut: cl + 2.1,
  bloom: cl + 2.18,
  // One row every two beats: slow enough to read each one.
  steps: [cl + 3.6, cl + 4.8, cl + 6.0],
  lift: cl + 7.2,
  toDoc: [cl + 7.1, cl + 8.4],
};

// The screen answers in light: the edge beside the finger, in any colour, and
// a light that laps the screen when you want it to.
const lg = S.light.start;
export const LIGHT = {
  title: lg + 0.1,
  down: lg + 0.6,
  // The finger wanders the right edge while the colours change on the beat.
  level: [[lg + 0.8, 22], [lg + 1.9, 78], [lg + 3.0, 38], [lg + 4.0, 86], [lg + 4.75, 58]],
  lift: lg + 4.8,
  palettes: [[lg + 0.6, "accent"], [lg + 2.4, "aurora"], [lg + 3.0, "sunset"], [lg + 3.6, "ember"], [lg + 4.2, "mint"]],
  ambientTap: [lg + 5.22, lg + 5.4],
  ambient: lg + 5.4,
  lap: 4.2, // seconds per lap of the screen
  out: S.light.end - 0.35,
};

// The mixer: one fader per app. Drag one down, mute one, solo one, send one
// to AirPods, then a call lowers everything else (the score ducks too).
const mx = S.mixer.start;
export const MIXER = {
  open: mx + 0.15,
  drag: [mx + 1.2, mx + 2.1],
  mute: mx + 3.0,
  solo: mx + 4.2,
  stop: mx + 5.4,
  menu: mx + 6.0,
  pick: mx + 6.6,
  call: mx + 7.2,
  captions: [mx + 0.1, mx + 2.75, mx + 3.95, mx + 5.75, mx + 7.0],
};
/** Music layers duck to this level while the film's call is on. */
export const DUCK = { from: MIXER.call + 0.05, to: S.mixer.end - 0.15, level: 0.42 };

// Every app gets its own edges: the right edge is volume, then tabs in the
// browser, then seek in Music.
const ap = S.apps.start;
export const APPS = {
  title: ap + 0.1,
  switches: [ap + 2.4, ap + 4.8],
  swipes: [
    swipe(ap + 0.7, ap + 0.85, ap + 1.8, ap + 1.95, 40, 64),
    swipe(ap + 3.0, ap + 3.15, ap + 4.2, ap + 4.35, 0, 3),
    swipe(ap + 5.4, ap + 5.55, ap + 6.6, ap + 6.75, 0.28, 0.7),
  ],
};

// It feels built in: a tick for every 1%, a notch that holds, finer steps as
// the finger moves inward, and haptics up to Strongest.
const fe = S.feel.start;
export const FEEL = {
  title: fe + 0.1,
  slide: swipe(fe + 1.5, fe + 1.7, fe + 4.2, fe + 8, 38, 50, ease.linear),
  notch: fe + 4.2,
  inward: [fe + 5.0, fe + 5.6],
  fine: [fe + 5.6, fe + 7.2, 50, 53],
  lift: fe + 7.35,
  pulses: [fe + 7.8, fe + 8.2, fe + 8.6, fe + 9.0],
  captions: [fe + 1.8, fe + 4.3, fe + 5.2, fe + 7.5],
};
/** The level in the feel scene, whole percents as the app shows them. */
export const feelLevel = (t) => (t < FEEL.fine[0] ? levelAt(FEEL.slide, t) : lerp(FEEL.fine[2], FEEL.fine[3], ease.linear(prog(t, FEEL.fine[0], FEEL.fine[1]))));

const mo = S.more.start;
export const MORE = {
  count: [mo + 0.05, mo + 1.0],
  wall: mo + 1.2,
  scatter: mo + 4.0,
  // Two beats each: Night Shift, extra dim, tiling, palms.
  cuts: [mo + 4.8, mo + 6.0, mo + 7.2, mo + 8.4],
};

const en = S.end.start;
export const END = {
  battery: [en + 0.1, en + 2.15],
  private: [en + 2.5, en + 4.5],
  card: en + 4.8,
  word: en + 5.4,
  line: en + 6.0,
  fade: FILM.duration - 1.5,
};

// ---------------------------------------------------------------- the film hears itself

/** The score's level: it rises with the first volume slide, stops for the pause, ducks for the call. */
export function musicLevel(t) {
  const open = t < OPEN.volume.lift + 0.4 ? lerp(0.16, 1, clamp((levelAt(OPEN.volume, t) - OPEN.volume.from) / (OPEN.volume.to - OPEN.volume.from))) : 1;
  const pause = 1 - (1 - PAUSE.level) * Math.min(clamp((t - PAUSE.from) / 0.22), clamp((PAUSE.to + 0.12 - t) / 0.12));
  const call = 1 - (1 - DUCK.level) * Math.min(clamp((t - DUCK.from) / 0.3), clamp((DUCK.to - t) / 0.35));
  return open * pause * call;
}
/** How open the score's filter is: it brightens with the first brightness slide, and closes for the pause. */
export function musicTone(t) {
  const open = t < OPEN.brightness.lift ? lerp(0.25, 1, clamp((levelAt(OPEN.brightness, t) - OPEN.brightness.from) / (OPEN.brightness.to - OPEN.brightness.from))) : 1;
  const pause = 1 - 0.85 * Math.min(clamp((t - PAUSE.from) / 0.22), clamp((PAUSE.to + 0.12 - t) / 0.12));
  return open * pause;
}

// ---------------------------------------------------------------- cues

/** Every sound event, derived from the same choreography the picture uses. */
export function cues() {
  const list = [];
  const add = (t, kind, gain = 1, extra = {}) => list.push({ t, kind, gain, ...extra });
  const slide = (g, step, gain = 0.7) => { add(g.down, "touch", 0.6); for (const c of crossings(g, step)) add(c.t, c.notch ? "notch" : "tick", gain); };

  // Open: a touch in the dark, a tick for every step.
  slide(OPEN.volume, 100 / 16, 0.75);
  slide(OPEN.brightness, 100 / 16, 0.75);
  add(OPEN.brightness.end - 0.05, "glint", 0.4);
  add(S.title.start - 1.9, "riser", 0.8, { length: 1.9 });

  // Title.
  add(S.title.start, "impact", 1);
  add(S.title.start, "bloom", 0.55);
  add(TITLE.word, "motif", 0.85);
  add(S.corners.start - 0.7, "whoosh", 0.6, { length: 0.7 });

  // Corners: the app's haptic grammar, a double tick when a tap fires.
  add(S.corners.start, "thud", 0.5);
  for (const t of CORNERS.taps) add(t, "tap", 0.9);
  add(CORNERS.taps[1] + 0.01, "haptic", 0.6);
  add(CORNERS.taps[1] + 0.1, "haptic", 0.6);
  add(CORNERS.fire, "pop", 0.7);
  for (const t of CORNERS.undo) add(t, "tap", 0.9);
  add(CORNERS.undo[1] + 0.01, "haptic", 0.6);
  add(CORNERS.undo[1] + 0.1, "haptic", 0.6);
  add(CORNERS.undo[1] + 0.06, "pop", 0.65);
  add(CORNERS.undo[1] + 0.02, "bloom", 0.4);
  add(S.clip.start - 0.5, "whoosh", 0.55, { length: 0.6 });

  // Clipboard.
  add(S.clip.start, "thud", 0.5);
  for (const t of CLIP.taps) add(t, "tap", 0.9);
  add(CLIP.bloom, "bloom", 0.7);
  for (const t of CLIP.steps) add(t, "tick", 0.95);
  add(CLIP.lift, "paste", 1);
  add(S.light.start - 0.9, "riser", 0.55, { length: 0.9 });

  // Light: a glint for every colour, and a swell when the light starts its lap.
  add(S.light.start, "impact", 0.7);
  add(LIGHT.down, "touch", 0.55);
  for (const [t] of LIGHT.palettes.slice(1)) add(t, "glint", 0.5);
  for (const t of LIGHT.ambientTap) add(t, "tap", 0.8);
  add(LIGHT.ambient, "bloom", 0.8);
  add(LIGHT.ambient + 0.1, "whoosh", 0.4, { length: 2.2 });
  add(S.mixer.start - 0.6, "whoosh", 0.6, { length: 0.6 });

  // Mixer: clicks, the banner and menu popping in, and the call arriving.
  add(S.mixer.start, "thud", 0.5);
  add(MIXER.open, "pop", 0.5);
  add(MIXER.drag[0], "touch", 0.4);
  for (const t of [MIXER.mute, MIXER.solo, MIXER.stop, MIXER.menu, MIXER.pick]) add(t, "tap", 0.65);
  add(MIXER.solo + 0.12, "pop", 0.5);
  add(MIXER.menu + 0.1, "pop", 0.45);
  add(MIXER.call, "thud", 0.6);
  add(MIXER.call + 0.1, "pop", 0.5);
  add(S.apps.start - 0.5, "whoosh", 0.55, { length: 0.6 });

  // Apps: a swish for every app, ticks for each slide.
  add(S.apps.start, "thud", 0.45);
  for (const t of APPS.switches) add(t, "swish", 0.55);
  add(APPS.swipes[0].down, "touch", 0.5);
  for (const c of crossings(APPS.swipes[0], 100 / 16)) add(c.t, "tick", 0.6);
  add(APPS.swipes[1].down, "touch", 0.5);
  for (const c of crossings(APPS.swipes[1], 1)) add(c.t, "notch", 0.7);
  add(APPS.swipes[2].down, "touch", 0.5);
  add(S.feel.start - 0.5, "whoosh", 0.5, { length: 0.6 });

  // Feel: the film's quietest scene, so every tick is heard.
  add(S.feel.start, "thud", 0.5);
  add(FEEL.slide.down, "touch", 0.6);
  for (const c of crossings(FEEL.slide, 1, 999)) if (c.value < 50) add(c.t, "tick", 0.8);
  add(FEEL.notch, "notch", 1.15);
  for (const c of crossings({ start: FEEL.fine[0], end: FEEL.fine[1], from: FEEL.fine[2], to: FEEL.fine[3], curve: ease.linear }, 1, 999)) add(c.t, "tick", 0.8);
  FEEL.pulses.forEach((t, i) => add(t, "haptic", 0.45 + i * 0.22));
  add(S.more.start - 1.5, "riser", 0.75, { length: 1.5 });

  // More: the count, the wall arriving, a whip on every cut.
  add(S.more.start, "impact", 0.95);
  for (let i = 0; i < 14; i++) add(MORE.count[0] + ease.expoOut(i / 14) * (MORE.count[1] - MORE.count[0]), "tick", 0.35);
  add(MORE.wall, "bloom", 0.6);
  add(MORE.scatter, "whoosh", 0.7, { length: 0.5 });
  for (const t of MORE.cuts) add(t - 0.1, "whip", 0.6);
  for (const t of MORE.cuts.slice(0, 3)) add(t + 0.05, "pop", 0.45);
  add(MORE.cuts[3] + 0.12, "thud", 0.7);
  add(S.end.start - 0.5, "whoosh", 0.5, { length: 0.6 });

  // End.
  add(S.end.start, "impact", 0.55);
  add(END.private[0], "glint", 0.4);
  add(END.card - 1.7, "riser", 0.7, { length: 1.7 });
  add(END.card, "impact", 1);
  add(END.card, "bloom", 0.6);
  add(END.card + 0.3, "motif", 1);
  return list.sort((a, b) => a.t - b.t);
}

/** Musical sections: how much of each layer plays (0..1) per scene. */
export const MIX = {
  open: { pad: 0.85, arp: 0.25, kick: 0, hats: 0, bass: 0.55, clap: 0 },
  title: { pad: 0.95, arp: 0.6, kick: 0.5, hats: 0.2, bass: 0.8, clap: 0 },
  corners: { pad: 0.85, arp: 0.8, kick: 0.75, hats: 0.55, bass: 0.9, clap: 0.35 },
  clip: { pad: 0.9, arp: 0.9, kick: 0.85, hats: 0.7, bass: 0.95, clap: 0.45 },
  light: { pad: 1, arp: 0.7, kick: 0.45, hats: 0.35, bass: 0.9, clap: 0.2 },
  mixer: { pad: 0.9, arp: 0.9, kick: 0.95, hats: 0.8, bass: 1, clap: 0.55 },
  apps: { pad: 0.9, arp: 0.95, kick: 1, hats: 0.85, bass: 1, clap: 0.6 },
  feel: { pad: 0.8, arp: 0.5, kick: 0.5, hats: 0.15, bass: 0.8, clap: 0 },
  more: { pad: 0.95, arp: 1, kick: 1, hats: 1, bass: 1, clap: 0.7 },
  end: { pad: 1, arp: 0.35, kick: 0, hats: 0, bass: 0.65, clap: 0 },
};
export const sceneAt = (t) => SCENES.find((s) => t >= s.start && t < s.end) || SCENES[SCENES.length - 1];
