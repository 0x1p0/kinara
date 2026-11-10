// The film's score, synthesised from scratch so it is original, royalty-free
// and locked to the picture: every UI sound comes from the same cue list the
// visuals use (src/timeline.js). 48 kHz stereo, written as 16-bit WAV.
//
// Music: a warm pad over D major (Dmaj9 · Bm9 · Gmaj9 · A add9) at 100 BPM,
// a plucked arpeggio, sub bass, soft kick, hats and claps, with sidechain
// pumping. Sound design: haptic ticks, taps, pops, whooshes, risers, impacts.
//
// The score follows the film's own gestures (musicLevel and musicTone in the
// timeline): it rises with the first volume slide, brightens with the first
// brightness slide, stops when the film's music is paused, and ducks for its call.
import { FILM, BEAT, SCENES, MIX, HOOK, SILENCE, musicLevel, musicTone, musicGate, cues, seeded, clamp } from "./src/timeline.js";

const SR = 48000;
const TAU = Math.PI * 2;
const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);

// Chords: [bass, pad notes]
const CHORDS = {
  Dmaj9: [38, [50, 57, 61, 64, 66]],
  Bm9: [35, [47, 54, 57, 61, 62]],
  Gmaj9: [31, [55, 59, 62, 66, 69]],
  Aadd9: [33, [57, 61, 64, 71, 69]],
  Asus: [33, [57, 62, 64, 71, 69]],
};
// Tension under the open, resolving to Dmaj9 as the title lands; then a
// two-bar cycle, and Dmaj9 again for the end.
function chordTimeline() {
  const logo = SCENES.find((s) => s.id === "title").start, last = SCENES.find((s) => s.id === "end").start;
  const list = [[0, "Bm9"], [logo / 2, "Asus"]];
  const cycle = ["Dmaj9", "Bm9", "Gmaj9", "Aadd9"];
  for (let t = logo, i = 0; t < last; t += BEAT * 8, i++) list.push([t, cycle[i % 4]]);
  list.push([last, "Dmaj9"]);
  return list.map(([t, name], i, all) => ({ start: t, end: i + 1 < all.length ? all[i + 1][0] : FILM.duration, name }));
}

function layerGain(name, t) {
  const index = SCENES.findIndex((s) => t >= s.start && t < s.end);
  const i = index < 0 ? SCENES.length - 1 : index;
  const scene = SCENES[i];
  let value = MIX[scene.id][name] ?? 0;
  const next = SCENES[i + 1];
  if (next && t > scene.end - 0.35) value = value + ((MIX[next.id][name] ?? 0) - value) * clamp((t - (scene.end - 0.35)) / 0.35);
  return value;
}

// ---------------------------------------------------------------- DSP bits

function polyblep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
}

class Freeverb {
  constructor(room = 0.88, damp = 0.25, spread = 23) {
    const scale = SR / 44100;
    const combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
    const allpasses = [556, 441, 341, 225];
    this.feedback = room;
    this.damp = damp;
    this.ch = [0, spread].map((s) => ({
      combs: combs.map((n) => ({ buf: new Float32Array(Math.round((n + s) * scale)), i: 0, store: 0 })),
      aps: allpasses.map((n) => ({ buf: new Float32Array(Math.round((n + s) * scale)), i: 0 })),
    }));
  }
  process(input, c) {
    const ch = this.ch[c];
    let out = 0;
    for (const comb of ch.combs) {
      const y = comb.buf[comb.i];
      comb.store = y * (1 - this.damp) + comb.store * this.damp;
      comb.buf[comb.i] = input + comb.store * this.feedback;
      if (++comb.i >= comb.buf.length) comb.i = 0;
      out += y;
    }
    for (const ap of ch.aps) {
      const b = ap.buf[ap.i];
      ap.buf[ap.i] = out + b * 0.5;
      out = b - out;
      if (++ap.i >= ap.buf.length) ap.i = 0;
    }
    return out;
  }
}

/** Chamberlin state-variable filter; returns band and low outputs. */
function svf() {
  let low = 0, band = 0;
  return (x, fc, q = 0.7) => {
    const f = 2 * Math.sin(Math.PI * Math.min(fc, SR / 6) / SR);
    low += f * band;
    const high = x - low - q * band;
    band += f * high;
    return { low, band, high };
  };
}

/** RBJ biquad filters. */
function biquad(type, f0, q = 0.7, gainDb = 0) {
  const A = Math.pow(10, gainDb / 40), w = TAU * f0 / SR, cos = Math.cos(w), alpha = Math.sin(w) / (2 * q);
  let b0, b1, b2, a0, a1, a2;
  if (type === "highpass") { b0 = (1 + cos) / 2; b1 = -(1 + cos); b2 = b0; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; }
  else if (type === "peak") { b0 = 1 + alpha * A; b1 = -2 * cos; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cos; a2 = 1 - alpha / A; }
  else {
    const s = 2 * Math.sqrt(A) * alpha, sign = type === "lowshelf" ? 1 : -1;
    b0 = A * ((A + 1) - sign * (A - 1) * cos + s); b1 = sign * 2 * A * ((A - 1) - sign * (A + 1) * cos); b2 = A * ((A + 1) - sign * (A - 1) * cos - s);
    a0 = (A + 1) + sign * (A - 1) * cos + s; a1 = -sign * 2 * ((A - 1) + sign * (A + 1) * cos); a2 = (A + 1) + sign * (A - 1) * cos - s;
  }
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x) => { const y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0; x2 = x1; x1 = x; y2 = y1; y1 = y; return y; };
}

// ---------------------------------------------------------------- render

export function renderSoundtrack({ from = 0, to = FILM.duration } = {}) {
  const N = Math.ceil(FILM.duration * SR);
  const music = [new Float32Array(N), new Float32Array(N)];
  const fx = [new Float32Array(N), new Float32Array(N)];
  const send = [new Float32Array(N), new Float32Array(N)];
  const random = seeded(2026);
  const noise = () => random() * 2 - 1;
  const add = (bus, i, l, r) => { if (i >= 0 && i < N) { bus[0][i] += l; bus[1][i] += r; } };

  // Pad + bass, chord by chord with overlapping envelopes.
  const chords = chordTimeline();
  for (const c of chords) {
    const [bass, notes] = CHORDS[c.name];
    const attack = c.start === 0 ? 3 : 0.9, release = 1.6;
    const i0 = Math.max(0, Math.floor((c.start - 0.05) * SR)), i1 = Math.min(N, Math.floor((c.end + release) * SR));
    const voices = notes.map((m, k) => ({ f: mtof(m), pan: (k % 2 ? 0.25 : -0.25) * (k / notes.length + 0.4), ph: [random(), random(), random(), random()] }));
    let bassPhase = 0;
    for (let i = i0; i < i1; i++) {
      const t = i / SR;
      const env = clamp((t - c.start + 0.05) / attack) * (t > c.end ? Math.exp(-(t - c.end) / (release / 3)) : 1);
      if (env < 1e-4) continue;
      let l = 0, r = 0;
      for (const v of voices) {
        for (let o = 0; o < 2; o++) {
          const detune = o === 0 ? 1.0035 : 0.9965;
          const dt = (v.f * detune) / SR;
          v.ph[o] += dt; if (v.ph[o] >= 1) v.ph[o] -= 1;
          const saw = 2 * v.ph[o] - 1 - polyblep(v.ph[o], dt);
          if (o === 0) l += saw * (0.6 - v.pan); else r += saw * (0.6 + v.pan);
        }
      }
      // Air: the top notes an octave up, as slow-breathing sines.
      let airL = 0, airR = 0;
      for (let k = 2; k < voices.length; k++) {
        const v = voices[k];
        v.ph[3] += (v.f * 2) / SR; if (v.ph[3] >= 1) v.ph[3] -= 1;
        const a = Math.sin(TAU * v.ph[3]) * (0.6 + 0.4 * Math.sin(t * (0.9 + k * 0.37) + k));
        if (k % 2) airR += a; else airL += a;
      }
      const air = env * 0.012 * (0.4 + layerGain("pad", t)) * musicGate(t);
      send[0][i] += airL * air * 1.4; send[1][i] += airR * air * 1.4;
      fx[0][i] += (airL * 0.8 + airR * 0.2) * air; fx[1][i] += (airR * 0.8 + airL * 0.2) * air;
      const g = env * 0.045;
      music[0][i] += l * g;
      music[1][i] += r * g;
      // Sub bass: sine + a touch of saturation.
      bassPhase += mtof(bass) / SR; if (bassPhase >= 1) bassPhase -= 1;
      const b = Math.tanh(Math.sin(TAU * bassPhase) * 2.2) * env * 0.12 * layerGain("bass", t);
      music[0][i] += b; music[1][i] += b;
    }
  }

  // Pad bus filter: opens with intensity, and breathes slowly.
  {
    const fl = [svf(), svf()];
    for (let i = 0; i < N; i++) {
      const t = i / SR;
      const intensity = layerGain("pad", t) * musicTone(t);
      const cutoff = 650 + 2700 * intensity * intensity + 350 * Math.sin(t * 0.4);
      for (let c = 0; c < 2; c++) {
        // Keep the sub bass (already in the bus) mostly intact by mixing low and band.
        const o = fl[c](music[c][i], cutoff, 0.9);
        music[c][i] = (o.low + o.band * 0.25) * (0.35 + 0.65 * layerGain("pad", t));
      }
    }
  }

  // Drums, arp, sidechain.
  const duck = new Float32Array(N).fill(1);
  const beats = Math.floor(FILM.duration / BEAT);
  for (let k = 0; k < beats; k++) {
    const t0 = k * BEAT;
    const kick = layerGain("kick", t0 + 0.01);
    if (kick > 0.01) {
      let ph = 0;
      const i0 = Math.floor(t0 * SR);
      for (let j = 0; j < 0.45 * SR; j++) {
        const t = j / SR;
        const f = 44 + 100 * Math.exp(-t * 30);
        ph += f / SR;
        const v = (Math.sin(TAU * ph) * Math.exp(-t * 7) + noise() * Math.exp(-t * 900) * 0.4) * 0.5 * kick;
        add(music, i0 + j, v, v);
        if (i0 + j < N) duck[i0 + j] = Math.min(duck[i0 + j], 1 - 0.42 * kick * Math.exp(-t * 7));
      }
    }
    const clap = layerGain("clap", t0 + 0.01);
    if (clap > 0.01 && (k % 4 === 1 || k % 4 === 3)) {
      const i0 = Math.floor(t0 * SR);
      const f = svf();
      for (let j = 0; j < 0.3 * SR; j++) {
        const t = j / SR;
        const burst = Math.exp(-t * 20) * (t < 0.03 ? 0.6 + 0.4 * Math.sin(t * 900) : 1);
        const v = f(noise(), 1700, 1.2).band * burst * 0.32 * clap + Math.sin(TAU * 190 * t) * Math.exp(-t * 40) * 0.08 * clap;
        add(music, i0 + j, v * 0.9, v);
        add(send, i0 + j, v * 0.6, v * 0.6);
      }
    }
    // Hats on the offbeats (and 16ths when it's busiest).
    const hats = layerGain("hats", t0 + 0.01);
    if (hats > 0.01) {
      const hits = hats > 0.9 ? [0.5, 0.75, 0.25] : [0.5];
      for (const off of hits) {
        const i0 = Math.floor((t0 + off * BEAT) * SR);
        let lp = 0;
        const g = (off === 0.5 ? 0.075 : 0.035) * hats;
        for (let j = 0; j < 0.06 * SR; j++) {
          const n = noise();
          lp += 0.5 * (n - lp);
          const v = (n - lp) * Math.exp(-j / SR * 60) * g;
          add(music, i0 + j, v * 0.8, v);
        }
      }
    }
  }
  // Arp: eighth notes through the current chord, an octave up.
  {
    const pattern = [0, 2, 4, 3, 1, 3, 2, 4];
    for (let k = 0; k < beats * 2; k++) {
      const t0 = k * BEAT / 2;
      const arp = layerGain("arp", t0 + 0.01);
      if (arp < 0.01) continue;
      const chord = chords.find((c) => t0 >= c.start && t0 < c.end) || chords[chords.length - 1];
      const notes = CHORDS[chord.name][1];
      const f = mtof(notes[pattern[k % 8]] + 12);
      const pan = k % 2 ? 0.35 : -0.35;
      const accent = k % 4 === 0 ? 1 : 0.72;
      const i0 = Math.floor(t0 * SR);
      for (let j = 0; j < 0.7 * SR; j++) {
        const t = j / SR;
        const e = Math.min(1, t / 0.003) * Math.exp(-t / 0.2);
        const v = (Math.sin(TAU * f * t) + 0.28 * Math.sin(TAU * 2 * f * t) * Math.exp(-t * 8) + 0.1 * Math.sin(TAU * 3 * f * t) * Math.exp(-t * 14)) * e * 0.055 * arp * accent;
        add(music, i0 + j, v * (1 - pan), v * (1 + pan));
        add(send, i0 + j, v * 0.7, v * 0.7);
      }
    }
  }
  // The tape stop: from HOOK.stop the score slows to a halt, as a record does
  // when its power is cut. The playhead's speed falls evenly from 1 to 0, so
  // pitch and tempo sink together; musicLevel keeps the score silent after it.
  {
    const s0 = Math.floor(HOOK.stop * SR), len = Math.floor(HOOK.stopLength * SR);
    for (let c = 0; c < 2; c++) {
      const source = music[c].slice(s0, s0 + len);
      let position = 0;
      for (let j = 0; j < len && s0 + j < N; j++) {
        const left = 1 - j / len;
        const k = Math.floor(position), f = position - k;
        const v = k + 1 < len ? source[k] * (1 - f) + source[k + 1] * f : 0;
        music[c][s0 + j] = v * Math.min(1, left * 8);
        position += left;
      }
    }
  }
  // Sidechain pumping, and the film hearing itself: the music's level and
  // brightness follow what the picture is doing to volume, brightness and playback.
  {
    const low = [0, 0];
    for (let i = 0; i < N; i++) {
      const t = i / SR;
      const gain = duck[i] * musicLevel(t);
      const tone = musicTone(t);
      // Fully open above 0.98; below that, a one-pole lowpass closes over everything.
      const a = tone > 0.98 ? 1 : 1 - Math.exp((-TAU * (180 + 9000 * tone * tone)) / SR);
      for (let c = 0; c < 2; c++) {
        low[c] += a * (music[c][i] * gain - low[c]);
        music[c][i] = low[c];
      }
    }
  }
  // A share of the music goes to the reverb too.
  for (let i = 0; i < N; i++) { send[0][i] += music[0][i] * 0.18; send[1][i] += music[1][i] * 0.18; }

  // ---------------------------------------------------------------- sound design
  const voice = {
    tick(i0, g) { // the haptic tick: a crisp, tiny click
      for (let j = 0; j < 0.03 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * 2600 * t) * Math.exp(-t * 260) * 0.6 + noise() * Math.exp(-t * 1800) * 0.5) * 0.22 * g; add(fx, i0 + j, v, v); }
    },
    notch(i0, g) { // firmer: a click with a little body
      for (let j = 0; j < 0.08 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * 1400 * t) * Math.exp(-t * 120) * 0.5 + Math.sin(TAU * 170 * t) * Math.exp(-t * 45) * 0.7 + noise() * Math.exp(-t * 1500) * 0.4) * 0.32 * g; add(fx, i0 + j, v, v); add(send, i0 + j, v * 0.3, v * 0.3); }
    },
    haptic(i0, g) {
      for (let j = 0; j < 0.1 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * 150 * t) * Math.exp(-t * 40) + Math.sin(TAU * 1900 * t) * Math.exp(-t * 200) * 0.3) * 0.34 * g; add(fx, i0 + j, v, v); }
    },
    touch(i0, g) {
      for (let j = 0; j < 0.12 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * 210 * t) * Math.exp(-t * 35) * 0.6 + noise() * Math.exp(-t * 900) * 0.2) * 0.16 * g; add(fx, i0 + j, v, v); }
    },
    tap(i0, g) {
      for (let j = 0; j < 0.08 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * 950 * t) * Math.exp(-t * 90) * 0.5 + Math.sin(TAU * 240 * t) * Math.exp(-t * 60) * 0.5 + noise() * Math.exp(-t * 1400) * 0.4) * 0.3 * g; add(fx, i0 + j, v, v); add(send, i0 + j, v * 0.25, v * 0.25); }
    },
    pop(i0, g) {
      let ph = 0;
      for (let j = 0; j < 0.2 * SR; j++) { const t = j / SR; ph += (620 + 520 * Math.min(1, t / 0.035)) / SR; const v = Math.sin(TAU * ph) * Math.min(1, t / 0.004) * Math.exp(-t * 22) * 0.2 * g; add(fx, i0 + j, v, v); add(send, i0 + j, v * 0.5, v * 0.5); }
    },
    paste(i0, g) { // two bright bell tones and a soft thump
      for (const [delay, m] of [[0, 86], [0.07, 93]]) {
        const s = i0 + Math.floor(delay * SR), f = mtof(m);
        for (let j = 0; j < 1.4 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * f * t) + 0.3 * Math.sin(TAU * f * 2.01 * t) * Math.exp(-t * 6)) * Math.min(1, t / 0.002) * Math.exp(-t * 3.2) * 0.1 * g; add(fx, s + j, v, v); add(send, s + j, v * 0.9, v * 0.9); }
      }
      for (let j = 0; j < 0.25 * SR; j++) { const t = j / SR; const v = Math.sin(TAU * (90 + 60 * Math.exp(-t * 30)) * t) * Math.exp(-t * 14) * 0.3 * g; add(fx, i0 + j, v, v); }
    },
    copy(i0, g, t0) { // a punchy hit: low thump, click, and a chord stab
      for (let j = 0; j < 0.5 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * (50 + 120 * Math.exp(-t * 35)) * t) * Math.exp(-t * 9) * 0.55 + noise() * Math.exp(-t * 600) * 0.25) * 0.55 * g; add(fx, i0 + j, v, v); }
      const chord = chordTimeline().find((c) => t0 >= c.start && t0 < c.end);
      for (const m of CHORDS[chord.name][1]) {
        const f = mtof(m + 12);
        for (let j = 0; j < 0.8 * SR; j++) { const t = j / SR; const v = (Math.sin(TAU * f * t) + 0.25 * Math.sin(TAU * 2 * f * t)) * Math.min(1, t / 0.003) * Math.exp(-t * 5) * 0.03 * g; add(fx, i0 + j, v, v); add(send, i0 + j, v * 0.8, v * 0.8); }
      }
    },
    thud(i0, g) {
      for (let j = 0; j < 0.4 * SR; j++) { const t = j / SR; const v = Math.sin(TAU * (60 + 40 * Math.exp(-t * 20)) * t) * Math.exp(-t * 9) * 0.35 * g; add(fx, i0 + j, v, v); }
    },
    glint(i0, g) {
      for (const [m, a] of [[98, 1], [105, 0.5], [110, 0.25]]) {
        const f = mtof(m);
        for (let j = 0; j < 2.5 * SR; j++) { const t = j / SR; const v = Math.sin(TAU * f * t + Math.sin(TAU * 5 * t) * 0.3) * Math.min(1, t / 0.01) * Math.exp(-t * 1.6) * 0.035 * a * g; add(fx, i0 + j, v * 0.8, v); add(send, i0 + j, v * 1.6, v * 1.6); }
      }
    },
    bloom(i0, g) { // a shimmering chord swell
      const notes = [74, 78, 81, 85, 88, 90];
      notes.forEach((m, k) => {
        const f = mtof(m), pan = (k / (notes.length - 1)) * 2 - 1;
        for (let j = 0; j < 3 * SR; j++) { const t = j / SR; const v = Math.sin(TAU * f * t + Math.sin(TAU * (4 + k) * t) * 0.15) * Math.min(1, t / 0.06) * Math.exp(-t * 1.3) * 0.022 * g; add(fx, i0 + j, v * (1 - pan * 0.6), v * (1 + pan * 0.6)); add(send, i0 + j, v * 1.4, v * 1.4); }
      });
    },
    impact(i0, g) {
      const f = svf();
      for (let j = 0; j < 2.4 * SR; j++) {
        const t = j / SR;
        const boom = Math.sin(TAU * (38 + 70 * Math.exp(-t * 8)) * t) * Math.exp(-t * 2.2) * 0.7;
        const air = f(noise(), 300 + 2500 * Math.exp(-t * 6), 1).low * Math.exp(-t * 3) * 0.5;
        const v = (boom + air) * 0.5 * g;
        add(fx, i0 + j, v, v);
        add(send, i0 + j, air * 0.6 * g, air * 0.6 * g);
      }
    },
    riser(i0, g, t0, length) {
      const f = [svf(), svf()];
      const n = Math.floor(length * SR);
      for (let j = 0; j < n; j++) {
        const p = j / n;
        const fc = 250 * Math.pow(28, p);
        const a = p * p * 0.22 * g;
        for (let c = 0; c < 2; c++) { const v = f[c](noise(), fc, 0.35).band * a; fx[c][i0 + j] += v; send[c][i0 + j] += v * 0.6; }
        const s = Math.sin(TAU * (180 + 520 * p * p) * (j / SR)) * p * p * 0.02 * g;
        add(fx, i0 + j, s, s);
      }
    },
    whoosh(i0, g, t0, length = 0.8) {
      const f = [svf(), svf()];
      const n = Math.floor(length * SR);
      for (let j = 0; j < n; j++) {
        const p = j / n;
        const bell = Math.sin(Math.PI * Math.pow(p, 0.7));
        const fc = 400 + 2600 * Math.sin(Math.PI * p);
        const pan = p * 2 - 1;
        for (let c = 0; c < 2; c++) { const v = f[c](noise(), fc, 0.5).band * bell * bell * 0.26 * g * (c === 0 ? 1 - pan * 0.6 : 1 + pan * 0.6); fx[c][i0 + j] += v; send[c][i0 + j] += v * 0.4; }
      }
    },
    motif(i0, g) { // Kinara's sonic logo: four rising bell notes, a major-seventh shimmer
      [[86, 0, -0.4], [90, 0.16, 0.2], [93, 0.32, -0.15], [97, 0.5, 0.35]].forEach(([m, delay, pan], k) => {
        const s = i0 + Math.floor(delay * SR), f = mtof(m), len = k === 3 ? 3.4 : 2.2;
        for (let j = 0; j < len * SR; j++) {
          const t = j / SR;
          const v = (Math.sin(TAU * f * t) + 0.22 * Math.sin(TAU * f * 2.76 * t) * Math.exp(-t * 9) + 0.08 * Math.sin(TAU * f * 5.4 * t) * Math.exp(-t * 18)) * Math.min(1, t / 0.002) * Math.exp(-t * (k === 3 ? 1.1 : 2)) * 0.075 * g;
          add(fx, s + j, v * (1 - pan), v * (1 + pan));
          add(send, s + j, v * 1.1, v * 1.1);
        }
      });
    },
    swish(i0, g, t0) { voice.whoosh(i0, g * 0.8, t0, 0.38); },
    whip(i0, g, t0) { voice.whoosh(i0, g * 1.1, t0, 0.26); },
  };
  for (const c of cues()) {
    const fn = voice[c.kind];
    if (!fn) continue;
    fn(Math.floor(c.t * SR), c.gain, c.t, c.length);
  }

  // Reverb, master EQ (clean sub, a little air), limiter.
  const reverb = new Freeverb(0.885, 0.3);
  const eq = [0, 1].map(() => [biquad("highpass", 32, 0.7), biquad("lowshelf", 140, 0.7, -2.5), biquad("peak", 380, 0.9, -2), biquad("highshelf", 6500, 0.7, 3)]);
  const out = [new Float32Array(N), new Float32Array(N)];
  let peak = 0;
  for (let i = 0; i < N; i++) {
    const t = i / SR;
    const wetL = reverb.process(send[0][i] * 0.5, 0), wetR = reverb.process(send[1][i] * 0.5, 1);
    const fade = Math.min(1, t / 0.4) * clamp((FILM.duration - 0.15 - t) / 2.2);
    // In the hook's silence the room goes dead too, so the taps are heard dry and close.
    const room = 1 - Math.min(clamp((t - (SILENCE.from - 0.2)) / 0.3), clamp((SILENCE.to - t) / 0.02));
    for (const [c, wet] of [[0, wetL], [1, wetR]]) {
      let x = (music[c][i] + fx[c][i] + wet * 0.32 * room) * fade;
      for (const f of eq[c]) x = f(x);
      const y = Math.tanh(x * 1.25) / Math.tanh(1.25);
      out[c][i] = y;
      peak = Math.max(peak, Math.abs(y));
    }
  }
  const gain = peak > 0 ? 0.84 / peak : 1;

  // Slice and write a 16-bit stereo WAV.
  const a = Math.floor(from * SR), b = Math.min(N, Math.floor(to * SR));
  const frames = b - a;
  const buffer = Buffer.alloc(44 + frames * 4);
  buffer.write("RIFF", 0); buffer.writeUInt32LE(36 + frames * 4, 4); buffer.write("WAVE", 8);
  buffer.write("fmt ", 12); buffer.writeUInt32LE(16, 16); buffer.writeUInt16LE(1, 20); buffer.writeUInt16LE(2, 22);
  buffer.writeUInt32LE(SR, 24); buffer.writeUInt32LE(SR * 4, 28); buffer.writeUInt16LE(4, 32); buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36); buffer.writeUInt32LE(frames * 4, 40);
  for (let i = 0; i < frames; i++) {
    buffer.writeInt16LE(Math.round(clamp(out[0][a + i] * gain, -1, 1) * 32767), 44 + i * 4);
    buffer.writeInt16LE(Math.round(clamp(out[1][a + i] * gain, -1, 1) * 32767), 46 + i * 4);
  }
  return buffer;
}

// node soundtrack.mjs out.wav — write just the soundtrack.
if (import.meta.url === `file://${process.argv[1]}`) {
  const { writeFile } = await import("node:fs/promises");
  const started = performance.now();
  await writeFile(process.argv[2] || "soundtrack.wav", renderSoundtrack());
  console.log(`soundtrack written in ${((performance.now() - started) / 1000).toFixed(1)} s`);
}
