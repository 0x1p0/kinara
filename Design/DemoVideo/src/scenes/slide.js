// The basics, perfected: the 3D trackpad. Every edge app does volume and
// brightness, so this comes after what only Sway does. A swipe up the right
// edge raises the volume with a tick for every step and a notch at 50%; a
// swipe up the left edge brightens the whole picture.
import { h, at, tf, words, reveal, fade, indicator } from "../ui.js";
import { prog, ease, lerp, spring, ep, env, SCENES, SLIDE, levelAt, crossings } from "../timeline.js";
import { edgePoint } from "../gl.js";

const S = SCENES.find((s) => s.id === "slide");

function gesture(g, side, t, out) {
  const span = (g.to - g.from) || 1;
  const pOf = (v) => lerp(0.1, 0.9, (v - g.from) / span);
  const v = levelAt(g, t);
  const down = edgePoint(side, pOf(g.from));
  const now = edgePoint(side, pOf(v));
  const o = Math.min(ep(t, g.down - 0.05, g.down + 0.12, ease.out), 1 - ease.smooth(prog(t, g.lift, g.lift + 0.38)));
  const press = 1 + 0.25 * (1 - spring(t - g.down, 0.32, 0.55));
  if (o > 0) out.contacts.push({ x: now.x, y: now.y, fromY: t < g.lift + 0.6 ? lerp(down.y, now.y, ease.smooth(prog(t, g.lift, g.lift + 0.5))) : now.y, o, size: press });
  for (const c of crossings(g, 100 / 16)) {
    const age = t - c.t;
    if (age < 0 || age > 0.6) continue;
    const p = ease.out(age / 0.6);
    const at = edgePoint(side, pOf(c.value));
    out.ripples.push({ x: at.x, y: at.y, r: 34 + p * (c.notch ? 150 : 85), o: (1 - p) * (c.notch ? 0.75 : 0.4), w: c.notch ? 7 : 4 });
  }
  return v;
}

export default {
  id: "slide",
  pre: 0.55,
  post: 0.6,
  usesGL: (t) => t < S.end + 0.6,
  mount(root) {
    this.vol = at(indicator("speaker"), 1745, 540);
    this.bri = at(indicator("sun"), 175, 540);
    this.volEyebrow = at(h("div", { class: "eyebrow" }, "Right edge"), 520, 452);
    this.volTitle = at(words("Volume.", "h1 grad"), 520, 540);
    this.briEyebrow = at(h("div", { class: "eyebrow" }, "Left edge"), 1400, 452);
    this.briTitle = at(words("Brightness.", "h1 grad"), 1400, 540);
    this.caption = at(words("Slide. It just responds.", "h2 grad center"), 960, 905);
    this.basics = at(words("And the basics? Perfected.", "h2 grad center"), 960, 132);
    root.append(this.basics, this.vol, this.bri, this.volEyebrow, this.volTitle, this.briEyebrow, this.briTitle, this.caption);
  },
  update(t, { gl }) {
    const pad = gl.pad;
    gl.canvas.style.opacity = String(ep(t, S.start - 0.45, S.start + 0.1, ease.smooth) * (1 - ease.smooth(prog(t, S.end - 0.25, S.end + 0.45))));
    gl.canvas.style.filter = `blur(${(1 - ep(t, S.start - 0.45, S.start + 0.3)) * 8 + ease.in(prog(t, S.end - 0.2, S.end + 0.45)) * 14}px)`;

    // Camera: from straight down (matching the icon dive) to a low 3/4 view,
    // leaning toward whichever edge is in use.
    const intro = ease.inOut(prog(t, S.start - 0.2, S.start + 1.9));
    const leanRight = env(t, SLIDE.volume.down - 0.9, SLIDE.volume.lift + 0.6, 1.0, 0.9, ease.inOut, ease.inOut);
    const leanLeft = env(t, SLIDE.brightness.down - 0.9, SLIDE.brightness.lift + 0.6, 1.0, 0.9, ease.inOut, ease.inOut);
    const wide = ease.inOut(prog(t, S.end - 2.6, S.end + 0.5));
    pad.elevation = lerp(90, 33, intro) + wide * 12;
    pad.distance = lerp(17.5, 25.5, intro) + wide * 2;
    pad.azimuth = lerp(0, -3, intro) - leanRight * 7 + leanLeft * 7 + Math.sin(t * 0.35) * 1.2;
    pad.target = [leanRight * 2.6 - leanLeft * 2.6, -0.4 * intro, lerp(0, 0.9, intro)];
    pad.fov = 28;
    pad.tracks = 1;
    pad.labels.o = ep(t, S.start + 1.1, S.start + 2.0);

    pad.contacts = [];
    pad.ripples = [];
    const v = gesture(SLIDE.volume, "right", t, pad);
    const b = gesture(SLIDE.brightness, "left", t, pad);
    pad.zones.right = 0.3 + 0.7 * env(t, SLIDE.volume.down, SLIDE.volume.lift + 0.3, 0.2, 0.5);
    pad.zones.left = 0.3 + 0.7 * env(t, SLIDE.brightness.down, SLIDE.brightness.lift + 0.3, 0.2, 0.5);
    // Brightness changes the picture itself.
    pad.exposure = 0.6 + 0.65 * (b / 100);
    pad.bloom = 0.85;

    // Sway's indicator: rises in with the HUD curve, eases out after the lift.
    const hud = (el, g, value, dx) => {
      const pin = ease.settle(prog(t, g.down, g.down + 0.3));
      const pout = ease.leave(prog(t, g.lift + 0.55, g.lift + 0.77));
      tf(el, { x: (1 - pin) * dx + pout * dx * 0.6, o: pin * (1 - pout) });
      el.__set(value);
    };
    hud(this.vol, SLIDE.volume, v, 46);
    hud(this.bri, SLIDE.brightness, b, -46);

    const vg = SLIDE.volume, bg = SLIDE.brightness;
    fade(this.volEyebrow, t, vg.down + 0.05, vg.lift + 0.75, { x: -0 });
    reveal(this.volTitle, t, vg.down + 0.15, vg.lift + 0.7);
    fade(this.briEyebrow, t, bg.down + 0.05, bg.lift + 0.75);
    reveal(this.briTitle, t, bg.down + 0.15, bg.lift + 0.7);
    reveal(this.basics, t, S.start + 0.05, SLIDE.volume.down - 0.1, { rise: 0.3 });
    reveal(this.caption, t, S.end - 2.35, S.end - 0.35);
  },
};
