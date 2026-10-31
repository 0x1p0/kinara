// 22.5–32.5 s. "It feels built in." Four glass cards glide past, each one
// demonstrating a detail of how Sway feels: fine control by sliding inward,
// speed-sensitive levels, notches, and the strongest haptics.
import { h, at, tf, words, reveal, glyph, glass } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, FEEL, feelCard } from "../timeline.js";

const S = SCENES.find((s) => s.id === "feel");
const SPACING = 1010;

function card(icon, title, sub, visual) {
  const el = glass("feel-card", { width: "900px", height: "580px", padding: "54px 60px", display: "flex", flexDirection: "column" },
    h("div", { style: { display: "flex", alignItems: "center", gap: "22px" } },
      h("div", { style: { width: "68px", height: "68px", borderRadius: "50%", background: "#f2f2f4", color: "#16171a", display: "grid", placeItems: "center" } }, glyph(icon, 34)),
      h("div", {},
        h("div", { class: "h3", style: { fontSize: "48px" } }, title),
        h("div", { class: "small", style: { fontSize: "26px", marginTop: "6px" } }, sub))),
    h("div", { style: { flex: 1, position: "relative", marginTop: "34px" } }, visual));
  return el;
}

const svg = (w, hh) => h("svg", { width: w, height: hh, viewBox: `0 0 ${w} ${hh}`, style: { position: "absolute", left: 0, top: 0, overflow: "visible" } });

export default {
  id: "feel",
  pre: 0.6,
  post: 0.6,
  mount(root) {
    this.title = at(words("It feels built in.", "h1 grad center"), 960, 540);

    // 1 · Fine control: the ruler zooms as the finger slides inward.
    this.ruler = svg(780, 300);
    this.fineValue = h("div", { style: { position: "absolute", left: "0", top: "176px", width: "780px", textAlign: "center", font: "650 64px/1 var(--font)", fontVariantNumeric: "tabular-nums", letterSpacing: "-0.02em" } }, "42");
    this.fineChip = h("div", { class: "pill dark", style: { position: "absolute", right: "0", top: "190px", fontSize: "22px", padding: "10px 18px" } }, "Fine ×4");
    const fine = card("sparkle", "Fine control", "Slide inward for smaller steps. No keys to hold.", h("div", {}, this.ruler, this.fineValue, this.fineChip));

    // 2 · Speed: the same distance, slow vs. a flick.
    this.speed = svg(780, 300);
    const speed = card("bolt", "Speed-sensitive", "Slow is precise. A quick flick goes far.", this.speed);

    // 3 · Notches: the level rests at 50% with a click.
    this.notch = svg(780, 300);
    this.notchValue = h("div", { style: { position: "absolute", left: "0", top: "30px", font: "650 76px/1 var(--font)", fontVariantNumeric: "tabular-nums", letterSpacing: "-0.03em" } }, "28%");
    const notch = card("wave", "Notches", "Levels rest at 50% and your favorite, with a click you feel.", h("div", {}, this.notchValue, this.notch));

    // 4 · Haptics: strength steps up to Strongest.
    this.levels = ["Off", "Light", "Standard", "Strong", "Strongest"];
    this.segment = h("div", { style: { position: "absolute", left: "0", top: "18px", width: "780px", height: "66px", borderRadius: "18px", background: "rgba(255,255,255,0.06)", border: "1px solid rgba(255,255,255,0.07)" } });
    this.segHighlight = h("div", { style: { position: "absolute", top: "5px", height: "54px", width: "152px", borderRadius: "14px", background: "#f2f2f4", boxShadow: "0 6px 16px rgba(0,0,0,0.35)" } });
    this.segment.append(this.segHighlight, ...this.levels.map((l, i) => h("div", { class: "seg", style: { position: "absolute", top: "0", left: `${5 + i * 154}px`, width: "152px", height: "66px", display: "grid", placeItems: "center", font: "600 23px/1 var(--font)", color: "#9a9ca3" } }, l)));
    this.pulses = svg(780, 200);
    this.pulses.style.top = "110px";
    const haptic = card("wave", "Haptics, up to Strongest", "Drives the trackpad's actuator for its firmest click.", h("div", {}, this.segment, this.pulses));

    this.cards = [fine, speed, notch, haptic].map((c) => at(c, 960, 560));
    this.track = at(h("div", { style: { width: "1920px", height: "1080px", transformStyle: "preserve-3d" } }), 960, 540);
    this.track.append(...this.cards);
    root.append(this.title, this.track);
  },
  update(t, { bg }) {
    reveal(this.title, t, S.start + 0.05, FEEL.title[1] - 0.15, { rise: 0.3 });
    // Carousel focus: -1 (first card waiting at the right) … 3.
    let focus = -1;
    for (let k = 0; k < FEEL.cards; k++) focus += ease.inOut(prog(t, feelCard(k) - 0.6, feelCard(k) + 0.08));
    const leave = ease.in(prog(t, S.end - 0.7, S.end - 0.05));
    this.cards.forEach((c, k) => {
      const d = k - focus;
      const a = Math.min(1, Math.abs(d));
      tf(c, { x: d * SPACING, z: -a * 260 - leave * 400, ry: -clamp(d, -1, 1) * 14, o: lerp(1, 0.32, a) * (1 - leave) * ep(t, feelCard(0) - 0.7, feelCard(0) - 0.2), blur: a * 4 + leave * 12 });
    });

    // 1 · Fine control.
    {
      const c = feelCard(0);
      const inward = ease.inOut(prog(t, c + 0.15, c + 1.25));
      const zoom = lerp(1, 4, inward);
      const value = lerp(41.2, 42.5, ease.inOut(prog(t, c - 0.2, c + 1.6)));
      const step = 9 * zoom;
      let ticks = "";
      for (let v = Math.floor(value - 390 / step) - 1; v <= value + 390 / step + 1; v += zoom > 2.2 ? 0.25 : 1) {
        const x = 390 + (v - value) * step;
        if (x < -10 || x > 790) continue;
        const major = Math.abs(v - Math.round(v / 5) * 5) < 0.01;
        const whole = Math.abs(v - Math.round(v)) < 0.01;
        const len = major ? 64 : whole ? 40 : 22;
        const fadeEdge = Math.min(1, x / 140, (780 - x) / 140);
        ticks += `<line x1="${x}" y1="${110 - len / 2}" x2="${x}" y2="${110 + len / 2}" stroke="#fff" stroke-width="${major ? 3 : 2}" stroke-linecap="round" opacity="${(major ? 0.7 : whole ? 0.4 : 0.22) * fadeEdge}"/>`;
      }
      ticks += `<line x1="390" y1="44" x2="390" y2="176" stroke="#eef3ff" stroke-width="4" stroke-linecap="round"/><circle cx="390" cy="40" r="9" fill="#fff"/>`;
      this.ruler.innerHTML = ticks;
      this.fineValue.textContent = value.toFixed(zoom > 2.2 ? 1 : 0);
      this.fineChip.style.opacity = String(ep(t, c + 0.5, c + 0.9));
    }

    // 2 · Speed: two lanes, same finger distance, different travel.
    {
      const c = feelCard(1);
      const slow = ease.smooth(prog(t, c - 0.2, c + 1.4));
      const flick = ease.expoOut(prog(t, c + 0.35, c + 0.75));
      const lane = (y, label, p, max, color) => {
        const w = 640 * max * p;
        return `<text x="0" y="${y - 24}" fill="#8d8f96" font-weight="600" font-size="24">${label}</text>
          <rect x="0" y="${y}" width="640" height="16" rx="8" fill="#fff" opacity="0.1"/>
          <rect x="0" y="${y}" width="${Math.max(16, w)}" height="16" rx="8" fill="${color}"/>
          <text x="780" y="${y + 15}" text-anchor="end" fill="#f5f5f7" font-weight="650" font-size="30">+${Math.round(max * 60 * p)}</text>`;
      };
      let lines = "";
      for (let i = 0; i < 4; i++) {
        const age = t - (c + 0.35);
        const o = clamp(1 - Math.abs(age - 0.25) * 3) * 0.5;
        lines += `<line x1="${640 * 0.8 * flick - 60 - i * 26}" y1="${196 + (i - 1.5) * 9}" x2="${640 * 0.8 * flick - 20 - i * 26}" y2="${196 + (i - 1.5) * 9}" stroke="#fff" stroke-width="2.5" stroke-linecap="round" opacity="${o}"/>`;
      }
      this.speed.innerHTML = lane(78, "Slow swipe", slow, 0.12, "#c9ccd3") + lane(196, "Quick flick", flick, 0.8, "#ffffff") + lines;
    }

    // 3 · Notches.
    {
      const c = feelCard(2);
      const hit = c + 1.0;
      let v;
      if (t < hit) v = lerp(28, 50, ease.inOut(prog(t, c + 0.05, hit)));
      else if (t < hit + 0.38) v = 50;
      else v = lerp(50, 78, ease.inOut(prog(t, hit + 0.38, hit + 1.05)));
      const x = (p) => 780 * (p / 100);
      const age = t - hit;
      const ring = age > 0 && age < 0.7 ? ease.out(age / 0.7) : null;
      this.notch.innerHTML = `
        <rect x="0" y="170" width="780" height="18" rx="9" fill="#fff" opacity="0.1"/>
        <rect x="0" y="170" width="${Math.max(18, x(v))}" height="18" rx="9" fill="#fff"/>
        <line x1="${x(50)}" y1="148" x2="${x(50)}" y2="210" stroke="#eef3ff" stroke-width="3" stroke-linecap="round" opacity="0.8"/>
        <text x="${x(50)}" y="246" text-anchor="middle" fill="#8d8f96" font-weight="600" font-size="22">50%</text>
        <line x1="${x(75)}" y1="156" x2="${x(75)}" y2="202" stroke="#eef3ff" stroke-width="2" stroke-dasharray="4 5" opacity="0.5"/>
        <text x="${x(75)}" y="246" text-anchor="middle" fill="#5d5f66" font-weight="600" font-size="22">Favorite</text>
        ${ring != null ? `<circle cx="${x(50)}" cy="179" r="${14 + ring * 70}" fill="none" stroke="#eef3ff" stroke-width="${4 * (1 - ring) + 1}" opacity="${1 - ring}"/>` : ""}
        <circle cx="${x(v)}" cy="179" r="${17 * (ring != null ? 1 + 0.25 * (1 - ring) : 1)}" fill="#fff"/>`;
      this.notchValue.textContent = `${Math.round(v)}%`;
    }

    // 4 · Haptics: each step is a stronger click.
    {
      const c = feelCard(3);
      let level = 0;
      for (let i = 0; i < 4; i++) level += spring(t - (c + 0.35 + i * 0.32), 0.28, 0.82);
      this.segHighlight.style.left = `${5 + level * 154}px`;
      [...this.segment.querySelectorAll(".seg")].forEach((s, i) => (s.style.color = Math.abs(level - i) < 0.5 ? "#16171a" : "#9a9ca3"));
      let bars = "";
      for (let i = 0; i < 4; i++) {
        const age = t - (c + 0.35 + i * 0.32);
        const strength = 0.35 + i * 0.22;
        for (let j = 0; j < 14; j++) {
          const x = 30 + i * 190 + j * 10;
          const shape = Math.exp(-j * 0.32) * Math.sin(j * 1.9 + 0.6);
          const hgt = age > 0 ? Math.abs(shape) * 130 * strength * (0.75 + 0.25 * Math.exp(-age * 3)) : 0;
          bars += `<rect x="${x}" y="${100 - hgt / 2}" width="5" height="${Math.max(4, hgt)}" rx="2.5" fill="#fff" opacity="${age > 0 ? 0.35 + strength * 0.5 : 0.12}"/>`;
        }
      }
      this.pulses.innerHTML = bars;
    }
    bg.style.setProperty("--by", "48%");
    bg.style.setProperty("--ba", "0.6");
  },
};
