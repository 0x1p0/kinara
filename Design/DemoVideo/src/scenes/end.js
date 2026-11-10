// The promises, and the name. The studio goes quiet, the ambient light laps
// the screen, and two lines say what Kinara costs you: almost no battery, and
// nothing of your privacy. Then the trackpad as the logo, and the word.
import { h, at, words, reveal, fade } from "../ui.js";
import { musicPlayer, quietWindow } from "../windows.js";
import { logoPad } from "./title.js";
import { prog, ease, lerp, END, FILM, scene } from "../timeline.js";

const S = scene("end");

export default {
  id: "end",
  mount(root, ctx, screen) {
    screen.append(quietWindow({ x: 640, y: 150, w: 420, ht: 320, title: "Notes" }), musicPlayer({ x: 190, y: 250, w: 540, ht: 280 }));
    this.battery = at(words("Almost no battery.", "h0 grad center shadowed"), 960, 470);
    this.batterySub = at(h("div", { class: "sub center shadowed", style: { fontSize: "40px", color: "#b4b6be" } }, "0.014% CPU at rest."), 960, 600);
    this.private = at(words("Private by design.", "h0 grad center shadowed"), 960, 470);
    this.privateSub = at(h("div", { class: "sub center shadowed", style: { fontSize: "40px", color: "#b4b6be" } }, "No analytics. No tracking. Nothing leaves your Mac."), 960, 600);
    this.word = at(words("Kinara", "mega grad center"), 960, 792);
    this.line = at(h("div", { class: "sub center", style: { fontSize: "38px", color: "#a0a2aa" } }, "The edges of your trackpad, as controls."), 960, 962);
    this.platform = at(h("div", { class: "eyebrow center" }, "For Mac  ·  macOS 13 or later"), 960, 1030);
    root.append(this.battery, this.batterySub, this.private, this.privateSub, this.word, this.line, this.platform);
  },
  update(t, { pad, d }) {
    if (t < END.card) {
      d.app = "Music";
      d.mood = 1;
      d.brightness = 0.42;
      pad.env = 0.3;
      pad.rim = 0.1;
      pad.exposure = 0.85;
      pad.labels.o = 0;
      d.ambient = { o: ease.out(prog(t, S.start, S.start + 0.6)), lap: 0.3 + (t - S.start) / 5.2, palette: "aurora" };
      reveal(this.battery, t, END.battery[0], END.battery[1], { rise: 0.25, dur: 0.9, outDur: 0.3 });
      fade(this.batterySub, t, END.battery[0] + 0.45, END.battery[1] + 0.05, { rise: 14 });
      reveal(this.private, t, END.private[0], END.private[1], { rise: 0.25, dur: 0.9, outDur: 0.25 });
      fade(this.privateSub, t, END.private[0] + 0.45, END.private[1], { rise: 14, outDur: 0.25 });
      reveal(this.word, t, Infinity);
      fade(this.line, t, Infinity);
      fade(this.platform, t, Infinity);
      return;
    }
    // The card: the trackpad is the logo, as in the title.
    logoPad(pad, d, ease.out(prog(t, END.card, END.card + 1.1)), ease.out(prog(t, END.card, END.card + 0.15)));
    pad.bloom = lerp(1.5, 0.9, ease.out(prog(t, END.card, END.card + 0.9)));
    for (const el of [this.battery, this.private]) reveal(el, t, Infinity);
    for (const el of [this.batterySub, this.privateSub]) fade(el, t, Infinity);
    reveal(this.word, t, END.word, FILM.duration + 1, { stagger: 0, dur: 1.1, rise: 0.22, blur: 22 });
    fade(this.line, t, END.line, FILM.duration + 1, { rise: 16 });
    fade(this.platform, t, END.line + 0.5, FILM.duration + 1, { rise: 10 });
  },
};
