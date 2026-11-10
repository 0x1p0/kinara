// The name. Straight down on the trackpad, which is the logo: its right edge
// lights from the bottom, as on the app's icon, and the word arrives under it.
import { at, words, reveal, fade, h } from "../ui.js";
import { prog, ease, lerp, TITLE, scene } from "../timeline.js";
import { edgePoint } from "../world.js";

const S = scene("title");

/** The trackpad as the logo: the swipe drawn up its right edge. Shared with the end card. */
export function logoPad(pad, d, p, glow = 1) {
  d.o = 0;
  pad.gloss = 0;
  pad.face = 1;
  pad.env = 1.4;
  pad.labels.o = 0;
  pad.zones.right = 0.5 + 0.5 * p;
  pad.zones.left = 0.45;
  const from = edgePoint("right", 0.04), to = edgePoint("right", lerp(0.04, 0.74, p));
  pad.contacts.push({ x: to.x, y: to.y, from, o: glow, size: 1.1 });
}

export default {
  id: "title",
  mount(root) {
    this.word = at(words("Kinara", "mega grad center"), 960, 792);
    this.line = at(h("div", { class: "sub center", style: { fontSize: "38px", color: "#a0a2aa" } }, "The edges of your trackpad, as controls."), 960, 962);
    root.append(this.word, this.line);
  },
  update(t, { pad, d }) {
    logoPad(pad, d, ease.out(prog(t, TITLE.draw[0], TITLE.draw[1])), ease.out(prog(t, S.start, S.start + 0.15)));
    pad.bloom = lerp(1.5, 0.9, ease.out(prog(t, S.start, S.start + 0.9)));
    reveal(this.word, t, TITLE.word, TITLE.out, { stagger: 0, dur: 1.1, rise: 0.22, blur: 22 });
    fade(this.line, t, TITLE.line, TITLE.out + 0.05, { rise: 16 });
  },
};
