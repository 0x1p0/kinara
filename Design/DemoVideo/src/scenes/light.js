// 82.5–87.5 s. Almost no battery (measured idle numbers), then privacy.
import { h, at, tf, words, reveal, fade, glyph } from "../ui.js";
import { prog, ease, lerp, ep, SCENES, LIGHT } from "../timeline.js";

const S = SCENES.find((s) => s.id === "light");

const stat = (label) => {
  const value = h("div", { style: { font: "700 128px/1 var(--font)", letterSpacing: "-0.05em", fontVariantNumeric: "tabular-nums", background: "linear-gradient(180deg,#fff,#b4b8c0)", WebkitBackgroundClip: "text", color: "transparent", padding: "0 10px 12px" } }, "0");
  const el = h("div", { style: { textAlign: "center" } }, value, h("div", { class: "sub", style: { marginTop: "4px" } }, label));
  el.__value = value;
  return el;
};

export default {
  id: "light",
  pre: 0.4,
  post: 0.4,
  mount(root) {
    this.t1 = at(words("Almost no battery.", "h1 grad center"), 960, 330);
    this.cpu = at(stat("CPU when idle"), 680, 640);
    this.mem = at(stat("of memory"), 1240, 640);
    this.t2 = at(words("Private by design.", "h1 grad center"), 960, 330);
    const line = (icon, text) => h("div", { style: { display: "flex", alignItems: "center", gap: "20px", font: "560 38px/1.2 var(--font)", color: "#d9dbe0", letterSpacing: "-0.015em" } }, h("span", { style: { width: "60px", height: "60px", borderRadius: "50%", background: "rgba(255,255,255,0.08)", display: "grid", placeItems: "center", color: "#f5f5f7" } }, glyph(icon, 28)), text);
    this.lines = [line("mute", "Audio is never recorded or saved."), line("clipboard", "Clipboard history stays in memory."), line("shield", "No analytics. No tracking.")].map((l, i) => at(l, 960, 540 + i * 100));
    root.append(this.t1, this.cpu, this.mem, this.t2, ...this.lines);
  },
  update(t, { bg }) {
    const out1 = LIGHT.promise - 0.35;
    reveal(this.t1, t, S.start + 0.05, out1, { rise: 0.3 });
    const count = ease.expoOut(prog(t, LIGHT.count[0], LIGHT.count[1]));
    this.cpu.__value.textContent = `${(0.015 * count).toFixed(3)}%`;
    this.mem.__value.textContent = `${Math.round(12 * count)} MB`;
    fade(this.cpu, t, LIGHT.count[0] - 0.1, out1, { rise: 30 });
    fade(this.mem, t, LIGHT.count[0] + 0.05, out1, { rise: 30 });
    reveal(this.t2, t, LIGHT.promise, S.end - 0.65, { rise: 0.3 });
    this.lines.forEach((l, i) => fade(l, t, LIGHT.promise + 0.35 + i * 0.18, S.end - 0.7 + i * 0.04, { rise: 26 }));
    bg.style.setProperty("--by", "45%");
    bg.style.setProperty("--ba", "0.5");
  },
};
