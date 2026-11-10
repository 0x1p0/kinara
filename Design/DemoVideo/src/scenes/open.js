// The open, without a word. In the dark, a finger lands on the trackpad's
// right edge and slides: the screen's edge lights beside it, the level
// climbs, and the film's own score rises with it. Then the left edge: the
// screen brightens and the whole studio with it.
import { musicPlayer, quietWindow } from "../windows.js";
import { prog, ease, lerp, clamp, levelAt, touchAt, env, OPEN, scene } from "../timeline.js";
import { edgePoint } from "../world.js";

const S = scene("open");

export default {
  id: "open",
  mount(root, ctx, screen) {
    this.player = musicPlayer({ x: 170, y: 210 });
    screen.append(quietWindow({ x: 700, y: 110, w: 440, ht: 330, title: "Notes" }), this.player);
  },
  update(t, { pad, d }) {
    const v = OPEN.volume, b = OPEN.brightness;
    const touchV = touchAt(v, t), touchB = touchAt(b, t);
    const volume = levelAt(v, t), brightness = t < b.start ? b.from : levelAt(b, t);
    const lit = clamp((brightness - b.from) / (b.to - b.from));

    // The studio wakes with the screen.
    d.app = "Music";
    d.brightness = brightness / 100;
    pad.env = lerp(0.14, 1, ease.smooth(lit));
    pad.exposure = lerp(0.8, 1, ease.smooth(lit));
    this.player.__set({ seconds: 72 + t });

    // The finger, and the edge it is on.
    const contact = (g, side, level, o) => {
      const from = edgePoint(side, g.from / 100), at = edgePoint(side, level / 100);
      // A tap of brightness as it lands.
      const land = 1 + 0.5 * Math.exp(-Math.max(0, t - g.down) * 9);
      pad.contacts.push({ x: at.x, y: at.y, from, o, size: land });
    };
    if (touchV > 0) contact(v, "right", volume, touchV);
    if (touchB > 0) contact(b, "left", brightness, touchB);
    pad.zones.right = 0.25 + 0.75 * touchV;
    pad.zones.left = 0.25 + 0.75 * touchB;
    pad.labels.o = ease.out(prog(t, v.down + 0.1, v.down + 0.8));
    // The far edge's label waits until the camera can read it.
    pad.labels.left = [["BRIGHTNESS", ease.out(prog(t, v.end - 0.6, v.end + 0.2))]];

    // The screen answers: its edge, and the level.
    if (touchV > 0) d.edge = { side: "right", level: volume, o: touchV, palette: "accent" };
    if (touchB > 0) d.edge = { side: "left", level: brightness, o: touchB, palette: "accent" };
    const hudV = env(t, v.down, v.lift + 0.75, 0.3, 0.3), hudB = env(t, b.down, b.lift + 0.9, 0.3, 0.35);
    if (hudB > 0) d.hud = { kind: "sun", level: brightness, o: hudB, scale: 1.7 };
    else if (hudV > 0) d.hud = { kind: "speaker", level: volume, o: hudV, scale: 1.7 };
  },
};
