// 40–47.5 s. A top-down trackpad map, styled like Sway's Overview. Double-tap
// a corner to paste, tap and hold an edge to mute, and a resting palm is
// ignored. Ends by diving into the corner that pastes.
import { h, at, tf, words, reveal, fade, glyph } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, TAPS } from "../timeline.js";

const S = SCENES.find((s) => s.id === "taps");
const W = 1040, H = 640, R = 46;
const CORNER = { w: 180, h: 118 };
const PAD = { x: 960, y: 610 };
// Points in pad-local coordinates (origin top-left).
const TR = { x: W - CORNER.w / 2 - 14, y: CORNER.h / 2 + 14 };
const BL = { x: CORNER.w / 2 + 14, y: H - CORNER.h / 2 - 14 };
const LEFT = { x: 70, y: H / 2 };

function popPill(icon, label) {
  return h("div", { class: "pill light", style: { fontSize: "30px" } }, glyph(icon, 30), label);
}

export default {
  id: "taps",
  pre: 0.5,
  post: 0.5,
  mount(root) {
    this.pad = at(h("div", { style: { width: `${W}px`, height: `${H}px`, borderRadius: `${R}px`, background: "linear-gradient(180deg,#18191c,#111214)", border: "1px solid rgba(255,255,255,0.1)", boxShadow: "0 50px 120px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.06)", overflow: "hidden" } }), PAD.x, PAD.y);
    const dash = (x, y, w, hh, corner) => h("div", { class: "zone", style: { position: "absolute", left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${hh}px`, border: "2px dashed rgba(255,255,255,0.16)", borderRadius: corner, background: "rgba(255,255,255,0)" } });
    this.zones = {
      tl: dash(14, 14, CORNER.w, CORNER.h, `${R - 14}px 14px 14px 14px`),
      tr: dash(W - CORNER.w - 14, 14, CORNER.w, CORNER.h, `14px ${R - 14}px 14px 14px`),
      bl: dash(14, H - CORNER.h - 14, CORNER.w, CORNER.h, `14px 14px 14px ${R - 14}px`),
      br: dash(W - CORNER.w - 14, H - CORNER.h - 14, CORNER.w, CORNER.h, `14px 14px ${R - 14}px 14px`),
    };
    const strip = (left, icon) => h("div", { style: { position: "absolute", top: `${CORNER.h + 30}px`, bottom: `${CORNER.h + 30}px`, [left ? "left" : "right"]: "14px", width: "112px", borderRadius: "22px", background: "rgba(255,255,255,0.035)", display: "grid", placeItems: "center", color: "#9a9ca3" } }, glyph(icon, 34));
    this.leftStrip = strip(true, "sun");
    this.rightStrip = strip(false, "speaker");
    this.center = h("div", { style: { position: "absolute", inset: "0", display: "grid", placeItems: "center", color: "#5d5f66", font: "600 24px/1.4 var(--font)", textAlign: "center" } }, h("div", {}, glyph("pointer", 34), h("div", {}, "Free space")));
    this.fx = h("svg", { width: W, height: H, style: { position: "absolute", left: 0, top: 0, overflow: "visible" } });
    this.palm = h("div", { style: { position: "absolute", left: `${W / 2 - 250}px`, top: `${H - 225}px`, width: "500px", height: "290px", borderRadius: "50%", background: "radial-gradient(closest-side, rgba(230,236,255,0.22), rgba(230,236,255,0.08) 60%, transparent)", filter: "blur(6px)" } });
    this.shield = h("div", { class: "pill dark", style: { position: "absolute", left: `${W / 2}px`, top: `${H - 92}px`, transform: "translate(-50%,-50%)", fontSize: "26px" } }, glyph("shield", 28), "Palm ignored");
    this.pad.append(this.leftStrip, this.rightStrip, this.center, ...Object.values(this.zones), this.palm, this.fx, this.shield);
    this.paste = at(popPill("doc", "Paste"), PAD.x - W / 2 + TR.x - 40, PAD.y - H / 2 + TR.y + 120);
    this.mission = at(popPill("mission", "Mission Control"), PAD.x - W / 2 + BL.x + 120, PAD.y - H / 2 + BL.y - 120);
    this.mute = at(popPill("mute", "Mute"), PAD.x - W / 2 + LEFT.x + 200, PAD.y - H / 2 + LEFT.y);
    this.title = at(words("Tap the corners.", "h2 grad center"), 960, 132);
    this.sub1 = at(h("div", { class: "sub center" }, "Double-tap a corner. One finger is enough."), 960, 212);
    this.sub2 = at(h("div", { class: "sub center" }, "Or tap and hold any edge."), 960, 212);
    this.title2 = at(words("Your palm never triggers a thing.", "h2 grad center"), 960, 132);
    this.sub3 = at(h("div", { class: "sub center" }, "Every touch is checked for intent."), 960, 212);
    root.append(this.pad, this.paste, this.mission, this.mute, this.title, this.sub1, this.sub2, this.title2, this.sub3);
  },
  update(t, { bg }) {
    const enter = ease.settle(prog(t, S.start - 0.35, S.start + 0.7));
    // Exit: dive into the top-right corner (where Paste lives).
    const dive = ease.in(prog(t, S.end - 0.75, S.end + 0.3));
    this.pad.style.transformOrigin = `${TR.x}px ${TR.y}px`;
    tf(this.pad, { y: (1 - enter) * 40, s: lerp(0.94, 1, enter) * lerp(1, 6, dive * dive), rx: (1 - enter) * 18, o: enter * (1 - ease.smooth(prog(t, S.end - 0.25, S.end + 0.25))), blur: (1 - enter) * 10 + dive * 8 });

    // Taps: ripples, corner zone fills, and the pills they trigger.
    const events = [];
    const tap = (p, times, big = false) => times.forEach((tt) => events.push({ x: p.x, y: p.y, t: tt, big }));
    tap(TR, TAPS.corner);
    tap(BL, TAPS.corner2);
    let svg = "";
    for (const e of events) {
      const age = t - e.t;
      if (age < -0.04 || age > 0.7) continue;
      const press = age < 0.09 ? ease.out(clamp(age / 0.09 + 0.4)) : 1 - ease.smooth(clamp((age - 0.09) / 0.25));
      const p = ease.out(clamp(age / 0.7));
      svg += `<circle cx="${e.x}" cy="${e.y}" r="${18 + p * 90}" fill="none" stroke="#eef3ff" stroke-width="${3.5 * (1 - p) + 0.5}" opacity="${(1 - p) * 0.9}"/>`;
      svg += `<circle cx="${e.x}" cy="${e.y}" r="${26}" fill="#fff" opacity="${Math.max(0, press) * 0.95}"/>`;
    }
    // Tap and hold: a ring fills around the finger.
    const [h0, h1] = TAPS.hold;
    const holdO = Math.min(ep(t, h0 - 0.05, h0 + 0.1, ease.out), 1 - ease.smooth(prog(t, h1 + 0.1, h1 + 0.45)));
    if (holdO > 0) {
      const fill = ease.inOut(prog(t, h0, h1));
      const c = 2 * Math.PI * 46;
      svg += `<circle cx="${LEFT.x}" cy="${LEFT.y}" r="46" fill="none" stroke="#fff" stroke-opacity="0.15" stroke-width="5" opacity="${holdO}"/>`;
      svg += `<circle cx="${LEFT.x}" cy="${LEFT.y}" r="46" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-dasharray="${c * fill} ${c}" transform="rotate(-90 ${LEFT.x} ${LEFT.y})" opacity="${holdO}"/>`;
      svg += `<circle cx="${LEFT.x}" cy="${LEFT.y}" r="${26 * (1 + 0.15 * Math.sin(prog(t, h0, h1) * Math.PI))}" fill="#fff" opacity="${holdO * 0.95}"/>`;
      const done = t - h1;
      if (done > 0 && done < 0.7) { const p = ease.out(done / 0.7); svg += `<circle cx="${LEFT.x}" cy="${LEFT.y}" r="${50 + p * 80}" fill="none" stroke="#eef3ff" stroke-width="3" opacity="${1 - p}"/>`; }
    }
    this.fx.innerHTML = svg;
    const lit = (zone, a, b) => { const o = env(t, a, b); zone.style.background = `rgba(255,255,255,${0.12 * o})`; zone.style.borderColor = `rgba(255,255,255,${0.16 + 0.5 * o})`; };
    lit(this.zones.tr, TAPS.corner[0] - 0.05, TAPS.corner[1] + 1.1);
    lit(this.zones.bl, TAPS.corner2[0] - 0.05, TAPS.corner2[1] + 1.1);
    this.leftStrip.style.background = `rgba(255,255,255,${0.035 + 0.08 * env(t, h0 - 0.05, h1 + 0.9)})`;

    const pill = (el, t0, t1, dx, dy) => {
      const pin = spring(t - t0, 0.42, 0.68);
      const pout = ease.leave(prog(t, t1, t1 + 0.25));
      tf(el, { x: (1 - pin) * dx, y: (1 - pin) * dy, s: lerp(0.6, 1, Math.min(1.2, pin)), o: clamp(pin * 3) * (1 - pout) * (t >= t0 ? 1 : 0), blur: (1 - clamp(pin)) * 6 });
    };
    pill(this.paste, TAPS.corner[1] + 0.1, TAPS.corner[1] + 1.15, 40, -110);
    pill(this.mission, TAPS.corner2[1] + 0.1, TAPS.corner2[1] + 0.95, -110, 110);
    pill(this.mute, h1 + 0.02, h1 + 0.95, -160, 0);

    // The palm: rests on the bottom, shimmers, and is ignored.
    const palmIn = ease.settle(prog(t, TAPS.palm - 0.3, TAPS.palm + 0.5));
    const palmOut = ease.leave(prog(t, S.end - 1.0, S.end - 0.6));
    this.palm.style.transform = `translateY(${(1 - palmIn) * 160}px) scale(${lerp(0.9, 1, palmIn)})`;
    this.palm.style.opacity = String(palmIn * (1 - palmOut));
    tf(this.shield, { y: (1 - ep(t, TAPS.palm + 0.4, TAPS.palm + 0.9)) * 16, o: ep(t, TAPS.palm + 0.4, TAPS.palm + 0.8) * (1 - palmOut) });

    reveal(this.title, t, S.start + 0.05, TAPS.palm - 0.25, { rise: 0.3 });
    fade(this.sub1, t, S.start + 0.35, TAPS.hold[0] - 0.45);
    fade(this.sub2, t, TAPS.hold[0] - 0.25, TAPS.palm - 0.3);
    reveal(this.title2, t, TAPS.palm + 0.05, S.end - 0.5, { rise: 0.3 });
    fade(this.sub3, t, TAPS.palm + 0.35, S.end - 0.55);
    bg.style.setProperty("--by", "55%");
    bg.style.setProperty("--ba", "0.5");
  },
};

function env(t, a, b) {
  if (t < a || t > b) return 0;
  return Math.min(ease.out(prog(t, a, a + 0.12)), 1 - ease.smooth(prog(t, b - 0.45, b)));
}
