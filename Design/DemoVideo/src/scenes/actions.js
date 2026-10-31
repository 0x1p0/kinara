// 32.5–40 s. "49" counts up, then every action Sway can put on an edge or a
// tap arrives as a curved wall of chips the camera drifts across.
import { h, at, tf, words, reveal } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, seeded, SCENES, ACTIONS } from "../timeline.js";

const S = SCENES.find((s) => s.id === "actions");
const GROUPS = [
  ["Display", ["Display brightness", "Keyboard backlight", "Night Shift warmth", "True Tone", "Extra dim"]],
  ["Audio", ["Output volume", "App volume", "Audio output", "Input gain", "Speaker mute", "Microphone mute"]],
  ["Media", ["Previous / next track", "Play / pause", "Seek in track", "Now playing"]],
  ["Editing", ["Copy", "Cut", "Paste", "Paste as plain text", "Paste previous", "Clipboard history", "Undo / redo", "Select all", "Find"]],
  ["Navigation", ["Tabs", "Back / forward", "App zoom", "Page up / down", "Start / end", "New / close tab", "Reopen closed tab"]],
  ["Windows", ["Switch desktops", "Mission Control", "App Exposé", "Show desktop", "Switch apps", "Cycle windows", "Full screen", "Minimize", "Hide app", "Tile window"]],
  ["Tools", ["Spotlight", "Screenshot", "Emoji & Symbols", "Run a Shortcut", "Edge map", "Lock screen", "Sleep displays", "Custom shortcut"]],
];
const ALL = GROUPS.flatMap(([group, items]) => items.map((label) => ({ label, group })));
// The camera sits on the cylinder's axis, so the wall curves around it.
const COLS = 7, ROWS = 7, RADIUS = 1760, COL_DEG = 14, ROW_H = 100, EYE = 1500;

export default {
  id: "actions",
  pre: 0.5,
  post: 0.5,
  mount(root) {
    this.count = at(h("div", { class: "grad-num", style: { font: "720 360px/1 var(--font)", letterSpacing: "-0.06em", fontVariantNumeric: "tabular-nums", background: "linear-gradient(180deg,#fff 10%,#b9bcc4 100%)", WebkitBackgroundClip: "text", color: "transparent", padding: "0 30px 30px" } }, "0"), 960, 470);
    this.label = at(words("actions.", "h2 center", { color: "#8d8f96" }), 960, 720);
    this.world = at(h("div", { style: { width: "1920px", height: "1080px", perspective: "1500px", perspectiveOrigin: "50% 50%" } }), 960, 575);
    this.cylinder = h("div", { style: { position: "absolute", left: "960px", top: "540px", transformStyle: "preserve-3d" } });
    this.world.append(this.cylinder);
    const random = seeded(7);
    // Shuffle so neighbours come from different categories, like a real library.
    const order = ALL.map((a, i) => ({ a, k: random() + (i % 7) * 0.01 })).sort((x, y) => x.k - y.k).map((x) => x.a);
    this.chips = order.map((a, i) => {
      const col = i % COLS, row = Math.floor(i / COLS);
      const el = h("div", { class: "pill dark chip", style: { position: "absolute", left: "0", top: "0", fontSize: "29px", padding: "18px 30px", backfaceVisibility: "hidden", transformOrigin: "50% 50%" } },
        h("span", { style: { width: "10px", height: "10px", borderRadius: "50%", background: "#eef3ff", opacity: "0.5" } }), a.label);
      el.__pos = { col, row, delay: (Math.abs(col - 3) + Math.abs(row - 3)) * 0.06 + random() * 0.12, twinkle: random() };
      this.cylinder.append(el);
      return el;
    });
    this.caption = at(words("Any edge. Any tap. Any action.", "h2 grad center"), 960, 960);
    root.append(this.world, this.count, this.label, this.caption);
  },
  update(t, { bg }) {
    const p = prog(t, ACTIONS.countStart, ACTIONS.countEnd);
    const n = Math.floor(49 * ease.expoOut(p) + 0.0001);
    this.count.textContent = String(p >= 1 ? 49 : n);
    // The number punches in, then rises and recedes behind the wall.
    const punch = lerp(0.82, 1, spring(t - S.start, 0.5, 0.65));
    const up = ease.inOut(prog(t, ACTIONS.wallStart - 0.1, ACTIONS.wallStart + 0.9));
    const gone = ease.leave(prog(t, S.end - 1.2, S.end - 0.7));
    tf(this.count, { y: lerp(0, -392, up), s: punch * lerp(1, 0.34, up), o: ep(t, S.start + 0.0, S.start + 0.3) * (1 - gone), blur: (1 - ep(t, S.start, S.start + 0.4)) * 20 + gone * 10 });
    reveal(this.label, t, S.start + 0.35, ACTIONS.wallStart - 0.2, { rise: 0.3 });

    // The wall: drift across it, slowly pushing in.
    const drift = ease.smooth(prog(t, ACTIONS.wallStart - 0.3, S.end));
    const yaw = lerp(22, -14, drift);
    const push = lerp(-520, 160, drift);
    this.cylinder.style.transform = `translateZ(${EYE + push}px) rotateX(${lerp(5, -3, drift)}deg) rotateY(${yaw}deg)`;
    const scatter = ease.in(prog(t, ACTIONS.scatter, S.end - 0.15));
    for (const el of this.chips) {
      const { col, row, delay, twinkle } = el.__pos;
      const angle = (col - 3) * COL_DEG;
      const arrive = ease.settle(prog(t, ACTIONS.wallStart + delay, ACTIONS.wallStart + delay + 0.9));
      const z = -RADIUS + lerp(-900, 0, arrive) + scatter * (900 + twinkle * 900);
      const y = (row - 3) * ROW_H * (1 + scatter * 0.6);
      el.style.transform = `rotateY(${angle}deg) translateZ(${z}px) translateY(${y}px) translate(-50%, -50%)`;
      const wave = Math.max(0, Math.sin((t - ACTIONS.wallStart) * 2.2 - col * 0.55 - row * 0.3 - twinkle * 2));
      const lit = Math.pow(wave, 12);
      el.style.opacity = String(arrive * (1 - scatter));
      el.style.background = `rgba(${lerp(30, 242, lit)}, ${lerp(31, 242, lit)}, ${lerp(35, 244, lit)}, 0.94)`;
      el.style.color = lit > 0.5 ? "#141518" : "#f5f5f7";
      el.style.filter = arrive < 1 || scatter > 0 ? `blur(${((1 - arrive) * 10 + scatter * 8).toFixed(1)}px)` : "";
    }
    reveal(this.caption, t, S.end - 3.1, S.end - 0.8);
    bg.style.setProperty("--by", "50%");
    bg.style.setProperty("--ba", String(0.45 + 0.25 * ep(t, ACTIONS.wallStart, ACTIONS.wallStart + 1)));
  },
};
