// And the rest. "53" counts up, every action Kinara can put on an edge or a
// tap sweeps past as a curved wall of chips, and then four quick cuts on the
// beat: Night Shift, extra dim, window tiling, and a palm that does nothing.
import { h, at, tf, words, reveal } from "../ui.js";
import { quietWindow, musicPlayer } from "../windows.js";
import { caption } from "../kit.js";
import { prog, ease, lerp, spring, ep, clamp, seeded, MORE, BEAT, scene } from "../timeline.js";
import { TEX } from "../world.js";

const S = scene("more");
const GROUPS = [
  ["Display", ["Display brightness", "Keyboard backlight", "Night Shift warmth", "True Tone", "Extra dim", "Ambient light"]],
  ["Audio", ["Output volume", "App volume", "Mute app", "Solo app", "Audio apps", "Audio output", "Input gain", "Speaker mute", "Microphone mute"]],
  ["Media", ["Previous / next track", "Play / pause", "Seek in track", "Now playing"]],
  ["Editing", ["Copy", "Cut", "Paste", "Paste as plain text", "Paste previous", "Clipboard history", "Undo / redo", "Select all", "Find"]],
  ["Navigation", ["Tabs", "Back / forward", "App zoom", "Page up / down", "Start / end", "New / close tab", "Reopen closed tab"]],
  ["Windows", ["Switch desktops", "Mission Control", "App Exposé", "Show desktop", "Switch apps", "Cycle windows", "Full screen", "Minimize", "Hide app", "Tile window"]],
  ["Tools", ["Spotlight", "Screenshot", "Emoji & Symbols", "Run a Shortcut", "Edge map", "Lock screen", "Sleep displays", "Custom shortcut"]],
];
const ALL = GROUPS.flatMap(([, items]) => items);
// The camera sits on the cylinder's axis, so the wall curves around it.
const ROWS = [7, 8, 8, 8, 8, 7, 7], RADIUS = 1760, COL_DEG = 14, ROW_H = 104, EYE = 1500;
const TOTAL = ROWS.reduce((a, b) => a + b, 0);
const place = (i) => {
  let row = 0, index = i;
  while (index >= ROWS[row]) index -= ROWS[row++];
  return { row, col: index - (ROWS[row] - 1) / 2 };
};
const CUTS = ["Night Shift.", "Extra dim.", "Tile windows.", "Palms, ignored."];

export default {
  id: "more",
  mount(root, ctx, screen) {
    this.count = at(h("div", { style: { font: "720 420px/1 var(--font)", letterSpacing: "-0.06em", fontVariantNumeric: "tabular-nums", background: "linear-gradient(180deg,#fff 10%,#b9bcc4 100%)", WebkitBackgroundClip: "text", color: "transparent", padding: "0 30px 30px" } }, "0"), 960, 460);
    this.label = at(words("actions.", "h1 center", { color: "#8d8f96" }), 960, 760);
    this.space = at(h("div", { style: { width: "1920px", height: "1080px", perspective: "1500px", perspectiveOrigin: "50% 50%" } }), 960, 560);
    this.cylinder = h("div", { style: { position: "absolute", left: "960px", top: "540px", transformStyle: "preserve-3d" } });
    this.space.append(this.cylinder);
    const random = seeded(7);
    // Shuffled, so neighbours come from different categories, like a real library.
    const order = ALL.map((label, i) => ({ label, k: random() + (i % 7) * 0.01 })).sort((x, y) => x.k - y.k).map((x) => x.label);
    this.chips = order.map((label, i) => {
      const { col, row } = place(i);
      const el = h("div", { class: "pill dark", style: { position: "absolute", left: "0", top: "0", fontSize: "29px", padding: "18px 30px", backfaceVisibility: "hidden" } },
        h("span", { style: { width: "10px", height: "10px", borderRadius: "50%", background: "#eef3ff", opacity: "0.5" } }), label);
      el.__pos = { col, row, delay: (Math.abs(col) + Math.abs(row - 3)) * 0.045 + random() * 0.1, twinkle: random() };
      this.cylinder.append(el);
      return el;
    });
    this.line = at(words("Any edge. Any corner. Any action.", "h2 grad center shadowed"), 960, 978);
    this.cuts = CUTS.map((text, i) => (i < 3 ? at(words(text, "h2 grad center shadowed"), 960, 800) : at(words(text, "h1 grad center shadowed"), 960, 470)));
    // On the screen, for the cuts.
    this.window = quietWindow({ x: 350, y: 150, w: 580, ht: 420, title: "Notes" });
    this.player = musicPlayer({ x: 560, y: 330, w: 540, ht: 280 });
    this.tile = h("div", { class: "abs", style: { left: "8px", top: "36px", width: "628px", height: "756px", borderRadius: "14px", border: "2px solid rgba(120,170,255,0.85)", background: "rgba(90,140,255,0.14)" } });
    screen.append(this.player, this.tile, this.window);
    root.append(this.space, this.count, this.label, this.line, ...this.cuts);
  },
  update(t, ctx) {
    const { pad, d } = ctx;
    const cutsOn = t >= MORE.cuts[0];
    ctx.gl = cutsOn;
    for (const el of [this.space, this.count, this.label, this.line]) el.style.display = cutsOn ? "none" : "";
    this.cuts.forEach((el, i) => (el.style.display = cutsOn ? "" : "none"));

    if (!cutsOn) {
      const p = prog(t, MORE.count[0], MORE.count[1]);
      this.count.textContent = String(p >= 1 ? TOTAL : Math.floor(TOTAL * ease.expoOut(p) + 0.0001));
      // The number punches in, then rises and recedes behind the wall.
      const punch = lerp(0.8, 1, spring(t - S.start, 0.5, 0.62));
      const up = ease.inOut(prog(t, MORE.wall - 0.1, MORE.wall + 0.8));
      const gone = ease.leave(prog(t, MORE.scatter - 0.1, MORE.scatter + 0.3));
      tf(this.count, { y: lerp(0, -340, up), s: punch * lerp(1, 0.36, up), o: ep(t, S.start, S.start + 0.25) * (1 - gone), blur: (1 - ep(t, S.start, S.start + 0.35)) * 20 + gone * 10 });
      reveal(this.label, t, S.start + 0.3, MORE.wall - 0.2, { rise: 0.3, outDur: 0.25 });

      // The wall: sweep across it, pushing in.
      const drift = ease.smooth(prog(t, MORE.wall - 0.3, MORE.scatter + 0.4));
      this.cylinder.style.transform = `translateZ(${EYE + lerp(-560, 200, drift)}px) rotateX(${lerp(5, -3, drift)}deg) rotateY(${lerp(26, -18, drift)}deg)`;
      const scatter = ease.in(prog(t, MORE.scatter, MORE.cuts[0] - 0.02));
      for (const el of this.chips) {
        const { col, row, delay, twinkle } = el.__pos;
        const arrive = ease.settle(prog(t, MORE.wall + delay, MORE.wall + delay + 0.75));
        const z = -RADIUS + lerp(-900, 0, arrive) + scatter * (900 + twinkle * 900);
        el.style.transform = `rotateY(${col * COL_DEG}deg) translateZ(${z}px) translateY(${(row - 3) * ROW_H * (1 + scatter * 0.6)}px) translate(-50%, -50%)`;
        const wave = Math.max(0, Math.sin((t - MORE.wall) * 2.6 - (col + 4) * 0.55 - row * 0.3 - twinkle * 2));
        const lit = Math.pow(wave, 6) * 0.8;
        el.style.opacity = String(arrive * (1 - scatter));
        el.style.background = `rgba(${lerp(30, 242, lit)}, ${lerp(31, 242, lit)}, ${lerp(35, 244, lit)}, 0.94)`;
        el.style.color = lit > 0.5 ? "#141518" : "#f5f5f7";
        el.style.filter = arrive < 1 || scatter > 0 ? `blur(${((1 - arrive) * 10 + scatter * 8).toFixed(1)}px)` : "";
      }
      reveal(this.line, t, MORE.wall + 0.4, MORE.scatter - 0.1, { stagger: 0.04, dur: 0.6, outDur: 0.25 });
      return;
    }

    // The cuts: one idea per beat.
    let k = 0;
    while (k + 1 < MORE.cuts.length && MORE.cuts[k + 1] <= t) k++;
    const age = t - MORE.cuts[k], p = ease.out(prog(age, 0.05, 0.6));
    d.app = "Notes";
    pad.labels.o = 0;
    this.tile.style.opacity = "0";
    this.window.style.transform = "";
    Object.assign(this.window.style, { left: "350px", top: "150px", width: "580px", height: "420px" });
    if (k === 0) d.warm = p;
    if (k === 1) d.extraDim = p;
    if (k === 2) {
      // The window springs into the left half, behind its outline.
      const snap = spring(age - 0.3, 0.38, 0.8);
      this.tile.style.opacity = String(Math.min(ease.out(prog(age, 0.02, 0.2)), 1 - prog(age, 0.6, 0.8)) * 0.9);
      Object.assign(this.window.style, { left: `${lerp(350, 8, snap)}px`, top: `${lerp(150, 36, snap)}px`, width: `${lerp(580, 628, snap)}px`, height: `${lerp(420, 756, snap)}px` });
    }
    if (k === 3) {
      // A whole palm on the trackpad: nothing lights, nothing fires.
      const land = ease.out(prog(age, 0.1, 0.5));
      pad.palm = { x: TEX.w * 0.52, y: TEX.h * 0.74, rx: 560, ry: 330, o: land };
      pad.gloss = 0.14;
    }
    this.cuts.forEach((el, i) => reveal(el, t, i === k ? MORE.cuts[k] + 0.02 : Infinity, Infinity, { stagger: 0.03, dur: 0.5, rise: 0.2, blur: 10 }));
  },
};
