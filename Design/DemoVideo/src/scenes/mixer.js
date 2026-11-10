// The mixer, laid out like Kinara's own: one fader per app, hanging from the
// menu bar. Drag one down, mute one before it pings, solo one, send one to
// AirPods, and then a call lowers everything else (the score ducks with it).
import { h, at, tf, words, glyph } from "../ui.js";
import { sequence } from "../kit.js";
import { prog, ease, lerp, spring, ep, env, clamp, MIXER, scene } from "../timeline.js";

const S = scene("mixer");
// The panel is drawn at this size and scaled onto the screen.
const W = 1000, ROW = 112, TOP = 104, BANNER = 64, SCALE = 0.44, PLACE = { right: 1204, top: 38 };
const SLIDER = { x0: 44, x1: 956 };
const BUTTONS = { mute: 808, solo: 870, output: 932 };
const APPS = [
  { name: "Browser", icon: "window", volume: 1 },
  { name: "Chat", icon: "bubble", volume: 0.8 },
  { name: "Music", icon: "note", volume: 0.7 },
  { name: "Video call", icon: "display", volume: 1 },
];

const smoothstep = (t, a, b) => ease.inOut(prog(t, a, b));
const soloOn = (t) => env(t, MIXER.solo, MIXER.stop + 0.05, 0.12, 0.2, ease.out, ease.smooth);
const callOn = (t) => ep(t, MIXER.call, MIXER.call + 0.35, ease.settle);
const bannerShift = (t) => Math.max(spring(t - MIXER.solo, 0.4, 0.85) * (t < MIXER.stop ? 1 : 1 - spring(t - MIXER.stop, 0.4, 0.9)), spring(t - MIXER.call, 0.4, 0.85));
const rowTop = (i, t) => TOP + i * ROW + bannerShift(t) * BANNER;
const knobX = (v) => SLIDER.x0 + (SLIDER.x1 - SLIDER.x0) * v;

function button(symbol) {
  const el = h("div", { style: { position: "absolute", top: "12px", width: "48px", height: "48px", marginLeft: "-24px", borderRadius: "50%", display: "grid", placeItems: "center" } }, glyph(symbol, 24));
  el.__set = (on, icon) => {
    el.style.background = on ? "#f2f2f4" : "rgba(255,255,255,0.08)";
    el.style.color = on ? "#16171a" : "#f2f3f6";
    if (icon !== el.__icon) { el.innerHTML = ""; el.append(glyph(icon, 24)); el.__icon = icon; }
  };
  return el;
}

function row(app) {
  const tile = h("div", { style: { position: "absolute", left: "44px", top: "8px", width: "60px", height: "60px", borderRadius: "15px", background: "linear-gradient(180deg,#46474c,#2a2b2f)", display: "grid", placeItems: "center", color: "#f1f2f5", boxShadow: "inset 0 1px 0 rgba(255,255,255,0.12)" } }, glyph(app.icon, 32));
  const name = h("div", { style: { position: "absolute", left: "124px", top: "8px", font: "640 30px/1.2 var(--font)", letterSpacing: "-0.015em" } }, app.name);
  const status = h("div", { style: { position: "absolute", left: "124px", top: "46px", font: "500 21px/1.2 var(--font)", color: "#8d8f96" } }, "Playing");
  const percent = h("div", { style: { position: "absolute", right: `${W - 772}px`, top: "20px", font: "650 26px/1 var(--rounded)", color: "#a7a9b0", fontVariantNumeric: "tabular-nums" } }, "100%");
  const mute = button("speaker"), solo = button("headphones"), output = button("hifi");
  mute.style.left = `${BUTTONS.mute}px`;
  solo.style.left = `${BUTTONS.solo}px`;
  output.style.left = `${BUTTONS.output}px`;
  const fill = h("div", { style: { position: "absolute", left: 0, top: 0, bottom: 0, borderRadius: "4px", background: "#fff" } });
  const knob = h("div", { style: { position: "absolute", top: "50%", width: "30px", height: "30px", marginTop: "-15px", marginLeft: "-15px", borderRadius: "50%", background: "#fff", boxShadow: "0 3px 10px rgba(0,0,0,0.5)" } });
  const slider = h("div", { style: { position: "absolute", left: `${SLIDER.x0}px`, width: `${SLIDER.x1 - SLIDER.x0}px`, top: "88px", height: "8px", borderRadius: "4px", background: "rgba(255,255,255,0.14)" } }, fill, knob);
  const el = h("div", { style: { position: "absolute", left: 0, width: `${W}px`, height: `${ROW}px` } }, tile, name, status, percent, mute, solo, output, slider);
  Object.assign(el, { __tile: tile, __status: status, __percent: percent, __mute: mute, __solo: solo, __output: output, __fill: fill, __knob: knob, __slider: slider });
  return el;
}

export default {
  id: "mixer",
  mount(root, ctx, screen) {
    this.rows = APPS.map(row);
    this.bannerIcon = h("span", {});
    this.bannerText = h("span", { style: { flex: 1 } }, "");
    this.bannerButton = h("span", { style: { padding: "8px 18px", borderRadius: "999px", background: "rgba(255,255,255,0.12)", font: "600 20px var(--font)" } }, "Stop");
    this.banner = h("div", { style: { position: "absolute", left: "44px", right: "44px", top: "92px", height: "52px", borderRadius: "14px", background: "rgba(255,255,255,0.07)", display: "flex", alignItems: "center", gap: "14px", padding: "0 10px 0 18px", font: "560 21px var(--font)", color: "#e9eaee" } }, this.bannerIcon, this.bannerText, this.bannerButton);
    this.panel = h("div", { class: "glass", style: { position: "absolute", left: "0", top: "0", width: `${W}px`, borderRadius: "40px", overflow: "hidden", transformOrigin: "62% 0%", background: "linear-gradient(180deg, rgba(50,51,58,0.84), rgba(28,29,34,0.88))" } },
      h("div", { style: { position: "absolute", left: "44px", top: "34px", display: "flex", alignItems: "baseline", gap: "12px" } },
        h("span", { style: { font: "680 32px var(--font)", letterSpacing: "-0.02em" } }, "Apps"),
        h("span", { style: { font: "650 24px var(--rounded)", color: "#8d8f96" } }, "4")),
      h("div", { class: "eyebrow", style: { position: "absolute", right: "48px", top: "46px", fontSize: "16px" } }, "Mixer"),
      this.banner, ...this.rows);
    // The output menu, opened from Music's speaker button.
    const item = (label, icon, check) => h("div", { class: "item", style: { display: "flex", alignItems: "center", gap: "14px", height: "46px", padding: "0 16px", borderRadius: "10px", font: "520 21px var(--font)", color: "#eceef2" } },
      h("span", { style: { width: "24px", display: "grid", placeItems: "center", color: "#cfd2d8" } }, check ? glyph("check", 20) : glyph(icon, 20)), label);
    this.items = [item("Default output (MacBook Pro Speakers)", "speaker", true), item("MacBook Pro Speakers", "laptop"), item("AirPods Pro", "airpods")];
    this.menu = at(h("div", { class: "glass", style: { width: "470px", padding: "8px", borderRadius: "18px", transformOrigin: "100% 0%", background: "linear-gradient(180deg, rgba(58,59,66,0.95), rgba(36,37,42,0.96))" } },
      this.items[0], h("div", { style: { height: "1px", margin: "6px 10px", background: "rgba(255,255,255,0.1)" } }), this.items[1], this.items[2]), 0, 0);
    this.pointer = at(h("div", { style: { color: "#fff", filter: "drop-shadow(0 4px 10px rgba(0,0,0,0.6))", transformOrigin: "20% 15%" } }, glyph("pointer", 46)), 0, 0);
    this.stage = h("div", { class: "abs", style: { left: `${PLACE.right - W * SCALE}px`, top: `${PLACE.top}px`, width: `${W}px`, height: "10px", transform: `scale(${SCALE})`, transformOrigin: "0 0" } }, this.panel, this.menu, this.pointer);
    screen.append(this.stage);
    this.captions = ["Every app gets\nits own fader.", "Mute one.", "Solo one.", "Send one\nto AirPods.", "Calls lower\nthe rest."]
      .map((text) => at(words(text, "h1 grad center shadowed"), 372, 520));
    root.append(...this.captions);
  },
  update(t, { d }) {
    d.app = "Music";
    const enter = spring(t - MIXER.open, 0.42, 0.78);
    const heightAt = (tt) => TOP + APPS.length * ROW + 24 + bannerShift(tt) * BANNER;
    this.panel.style.transform = `scale(${lerp(0.82, 1, clamp(enter, 0, 1.2))})`;
    this.panel.style.opacity = String(clamp(enter * 2.2));
    this.panel.style.height = `${heightAt(t)}px`;

    // The state of each app at this moment.
    const solo = soloOn(t), call = callOn(t);
    const browserVolume = lerp(1, 0.35, smoothstep(t, MIXER.drag[0], MIXER.drag[1]));
    const chatMuted = t >= MIXER.mute;
    const musicRouted = t >= MIXER.pick;
    const states = [
      { volume: browserVolume, status: solo > 0.5 ? "Silenced by solo" : call > 0.5 ? "Lowered for your call" : "Playing", dim: Math.max(solo, call * 0.45) },
      { volume: 0.8, muted: chatMuted, status: chatMuted ? "Muted" : "Not playing", dim: chatMuted ? 1 : 0 },
      { volume: 0.7, soloed: solo > 0.5, status: solo > 0.5 ? "Solo" : call > 0.5 ? "Lowered for your call" : "Playing", dim: call * 0.45, routed: musicRouted },
      { volume: 1, status: call > 0.5 ? "On a call" : "Not playing", dim: 0 },
    ];
    this.rows.forEach((el, i) => {
      const st = states[i];
      el.style.top = `${rowTop(i, t)}px`;
      el.__status.textContent = st.status;
      el.__percent.textContent = st.muted ? "Muted" : `${Math.round(st.volume * 100)}%`;
      el.__tile.style.opacity = String(lerp(1, 0.45, st.dim));
      el.__fill.style.width = `${st.volume * 100}%`;
      el.__knob.style.left = `${st.volume * 100}%`;
      el.__slider.style.opacity = String(st.muted ? 0.5 : lerp(1, 0.6, st.dim));
      el.__mute.__set(!!st.muted, st.muted ? "mute" : "speaker");
      el.__solo.__set(!!st.soloed, "headphones");
      el.__output.__set(!!st.routed, st.routed ? "airpods" : "hifi");
    });

    // The banner: solo, then the call.
    const bannerO = Math.max(solo, call);
    this.banner.style.opacity = String(bannerO);
    this.banner.style.transform = `translateY(${(1 - bannerO) * -10}px)`;
    const isCall = t >= MIXER.call;
    if (isCall !== this.wasCall) { this.bannerIcon.innerHTML = ""; this.bannerIcon.append(glyph(isCall ? "phone" : "headphones", 22)); this.wasCall = isCall; }
    this.bannerText.textContent = isCall ? "Video call is on a call, so other apps are lower" : "Only Music is playing";
    this.bannerButton.textContent = isCall ? "Don’t lower" : "Stop";

    // The output menu.
    const menuAt = { x: BUTTONS.output - 235 + 24, y: rowTop(2, t) + 36 + 34 + 85 };
    const menuIn = spring(t - MIXER.menu, 0.32, 0.8), menuOut = ease.leave(prog(t, MIXER.pick + 0.05, MIXER.pick + 0.25));
    this.menu.style.left = `${menuAt.x}px`;
    this.menu.style.top = `${menuAt.y}px`;
    tf(this.menu, { s: lerp(0.9, 1, clamp(menuIn)), o: t >= MIXER.menu ? clamp(menuIn * 2) * (1 - menuOut) : 0, y: (1 - clamp(menuIn)) * -8 });
    const airpods = { x: menuAt.x - 60, y: menuAt.y - 85 + 8 + 46 + 13 + 46 + 23 };
    this.items[2].style.background = t > MIXER.pick - 0.3 && t < MIXER.pick + 0.1 ? "rgba(255,255,255,0.14)" : "transparent";

    // The pointer travels between targets, clicking where it stops.
    const stops = [
      [S.start, { x: 560, y: 620 }],
      [MIXER.drag[0] - 0.05, { x: knobX(1), y: rowTop(0, MIXER.drag[0]) + 92 }],
      [MIXER.drag[1], { x: knobX(0.35), y: rowTop(0, MIXER.drag[1]) + 92 }],
      [MIXER.mute - 0.05, { x: BUTTONS.mute, y: rowTop(1, MIXER.mute) + 36 }],
      [MIXER.solo - 0.05, { x: BUTTONS.solo, y: rowTop(2, MIXER.solo) + 36 }],
      [MIXER.stop - 0.05, { x: W - 44 - 70, y: 118 }],
      [MIXER.menu - 0.05, { x: BUTTONS.output, y: rowTop(2, MIXER.menu) + 36 }],
      [MIXER.pick - 0.05, airpods],
      [MIXER.pick + 0.9, { x: 640, y: 700 }],
    ];
    let pos = stops[0][1];
    for (let k = 1; k < stops.length; k++) {
      const [t0, a] = stops[k - 1], [t1, b] = stops[k];
      if (t <= t0) break;
      // Dragging follows the knob exactly; travel eases in and out.
      const travel = k === 2 ? ease.inOut(prog(t, t0, t1)) : smoothstep(t, Math.max(t0 + 0.12, t1 - 0.55), t1);
      pos = { x: lerp(a.x, b.x, travel), y: lerp(a.y, b.y, travel) };
    }
    let press = 0;
    for (const c of [MIXER.mute, MIXER.solo, MIXER.stop, MIXER.menu, MIXER.pick]) {
      const age = t - c;
      if (age > -0.08 && age < 0.18) press = Math.max(press, 1 - Math.abs(age - 0.04) / 0.14);
    }
    this.pointer.style.left = `${pos.x + 14}px`;
    this.pointer.style.top = `${pos.y + 18}px`;
    tf(this.pointer, { s: 1 - press * 0.16, o: ep(t, MIXER.open + 0.2, MIXER.open + 0.6) * (1 - ep(t, MIXER.pick + 0.5, MIXER.pick + 0.9)) });

    sequence(this.captions, t, MIXER.captions, S.end - 0.05, { stagger: 0.05 });
  },
};
