// It feels built in. The film's quietest scene, so every tick is heard: one
// for every 1% the level moves, a firmer one where a notch holds it, finer
// steps as the finger moves inward, and haptics up to Strongest.
import { h, at, tf, words, reveal } from "../ui.js";
import { caption, sequence } from "../kit.js";
import { prog, ease, lerp, clamp, touchAt, FEEL, feelLevel, scene } from "../timeline.js";
import { ZONES } from "../world.js";

const S = scene("feel");
const F = FEEL;
const PITCH = 34, FINE = 122, START = ZONES.bottom - 70;
const STRENGTHS = ["Light", "Standard", "Strong", "Strongest"];

export default {
  id: "feel",
  mount(root) {
    this.title = at(words("It feels built in.", "h0 grad center shadowed"), 700, 470);
    this.number = h("div", { style: { position: "absolute", left: "150px", top: "290px", font: "700 330px/1 var(--font)", letterSpacing: "-0.06em", fontVariantNumeric: "tabular-nums", background: "linear-gradient(180deg,#fff 10%,#b9bcc4 100%)", WebkitBackgroundClip: "text", color: "transparent", padding: "0 20px 26px 0" } }, "38");
    this.caps = ["A tick for every 1%.", "A notch that holds.", "Slide inward for finer steps.", "Haptics, up to Strongest."].map((text) => caption(text, "h2 grad shadowed", 160, 740));
    this.bars = STRENGTHS.map((name) => h("div", { style: { display: "flex", flexDirection: "column", alignItems: "center", gap: "18px", font: "600 26px var(--font)", color: "#8d8f96", width: "170px" } }, h("div", { style: { width: "20px", borderRadius: "10px", background: "#fff" } }), name));
    this.strength = h("div", { style: { position: "absolute", left: "140px", top: "330px", height: "290px", display: "flex", alignItems: "flex-end", gap: "10px" } }, ...this.bars);
    root.append(this.title, this.number, this.strength, ...this.caps);
  },
  update(t, { pad, d }) {
    d.mood = 1;
    d.brightness = 0.5;
    pad.gloss = 0.12;
    pad.env = 0.75;
    pad.labels.o = 0;
    const level = feelLevel(t);
    const touch = Math.min(touchAt(F.slide, t), 1 - ease.smooth(prog(t, F.lift, F.lift + 0.25)));
    const inward = ease.inOut(prog(t, F.inward[0], F.inward[1]));
    const pitch = lerp(PITCH, FINE, inward);
    const notchY = START - (F.slide.to - F.slide.from) * PITCH;
    // The ruler spreads from the notch as the steps get finer.
    const yOf = (v) => notchY - (v - F.slide.to) * pitch;
    const ruler = Math.min(ease.out(prog(t, S.start + 0.3, S.start + 1.0)), 1 - ease.smooth(prog(t, F.lift + 0.1, F.lift + 0.5)));
    pad.ruler = { side: "right", o: ruler, from: 20, to: 70, level, notch: 50, y: yOf };
    if (touch > 0.002) {
      const x = ZONES.right - inward * 270, y = yOf(level);
      // The tick you feel: a brief brightening each time the number changes.
      const tick = Math.exp(-(level - Math.floor(level)) * 5);
      pad.contacts.push({ x, y, from: { x: ZONES.right, y: START }, o: touch, size: 1 + 0.16 * tick });
    }
    pad.zones.right = 0.4 + 0.6 * touch;
    pad.tracks = 1 - 0.5 * inward;
    // Haptic strengths: four pulses, each firmer than the last.
    let pulse = Math.exp(-Math.max(0, t - F.notch) * 9) * (t >= F.notch ? 0.6 : 0);
    F.pulses.forEach((at, i) => { if (t >= at) pulse = Math.max(pulse, (0.4 + i * 0.3) * Math.exp(-(t - at) * 10)); });
    pad.pulse = pulse;
    this.bars.forEach((bar, i) => {
      const fired = t >= F.pulses[i] ? 1 : 0, hit = fired * Math.exp(-(t - F.pulses[i]) * 7);
      const grow = ease.settle(prog(t, F.pulses[0] - 0.35 + i * 0.05, F.pulses[0] + i * 0.05));
      bar.firstChild.style.height = `${(40 + i * 62) * grow}px`;
      bar.firstChild.style.opacity = String(lerp(0.22, 1, Math.max(fired * 0.75, hit)));
      bar.firstChild.style.boxShadow = `0 0 ${30 * hit}px rgba(238,243,255,${0.8 * hit})`;
      bar.style.color = fired ? "#f5f5f7" : "#8d8f96";
      bar.style.opacity = String(grow);
    });
    const strengthsIn = ease.out(prog(t, F.pulses[0] - 0.4, F.pulses[0] - 0.1));
    this.strength.style.opacity = String(strengthsIn);

    // The number: whole percents, as the app shows them.
    this.number.textContent = String(Math.floor(level + 0.0001));
    const numberO = Math.min(ease.settle(prog(t, F.slide.down - 0.1, F.slide.down + 0.5)), 1 - ease.leave(prog(t, F.pulses[0] - 0.55, F.pulses[0] - 0.3)));
    const snap = t >= F.notch ? Math.exp(-(t - F.notch) * 7) : 0;
    this.number.style.opacity = String(clamp(numberO));
    this.number.style.transform = `translateY(${(1 - ease.settle(prog(t, F.slide.down - 0.1, F.slide.down + 0.5))) * 30}px) scale(${1 + 0.05 * snap})`;
    this.number.style.transformOrigin = "20% 60%";

    reveal(this.title, t, F.title, F.slide.down - 0.15, { rise: 0.25, dur: 0.8, outDur: 0.25 });
    sequence(this.caps, t, F.captions, S.end - 0.1);
  },
};
