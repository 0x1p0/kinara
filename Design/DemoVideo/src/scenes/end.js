// The promises, the name, and where to get it. The studio goes quiet, the
// ambient light laps the screen, and three lines say what Kinara costs you:
// almost no battery, nothing of your privacy, and no money. Then the trackpad
// as the logo, the word, and the two addresses, held long enough to read.
import { h, at, words, reveal, fade, glyph } from "../ui.js";
import { musicPlayer, quietWindow } from "../windows.js";
import { chip } from "../kit.js";
import { logoPad } from "./title.js";
import { prog, ease, lerp, END, FILM, scene } from "../timeline.js";

const S = scene("end");

export default {
  id: "end",
  mount(root, ctx, screen) {
    screen.append(quietWindow({ x: 640, y: 150, w: 420, ht: 320, title: "Notes" }), musicPlayer({ x: 190, y: 250, w: 540, ht: 280 }));
    const promise = (title, sub) => [at(words(title, "h0 grad center shadowed"), 960, 470), at(h("div", { class: "sub center shadowed", style: { fontSize: "40px", color: "#b4b6be" } }, sub), 960, 600)];
    [this.battery, this.batterySub] = promise("Almost no battery.", "0.014% CPU at rest.");
    [this.private, this.privateSub] = promise("Private by design.", "No analytics. No tracking. Nothing leaves your Mac.");
    [this.open, this.openSub] = promise("Free and open source.", "MIT License. Read every line of it.");
    this.word = at(words("Kinara", "mega grad center"), 960, 742);
    this.line = at(h("div", { class: "sub center", style: { fontSize: "38px", color: "#a0a2aa" } }, "The edges of your trackpad, as controls."), 960, 905);
    const link = (icon, text) => chip(glyph(icon, 32, { color: "#9fc4ff" }), text);
    this.links = at(h("div", { style: { display: "flex", gap: "26px", alignItems: "center" } }, link("code", "github.com/0x1p0/kinara"), link("globe", "kinara-app.pages.dev")), 960, 1000);
    root.append(this.battery, this.batterySub, this.private, this.privateSub, this.open, this.openSub, this.word, this.line, this.links);
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
      reveal(this.open, t, END.open[0], END.open[1], { rise: 0.25, dur: 0.9, outDur: 0.25 });
      fade(this.openSub, t, END.open[0] + 0.45, END.open[1], { rise: 14, outDur: 0.25 });
      reveal(this.word, t, Infinity);
      fade(this.line, t, Infinity);
      fade(this.links, t, Infinity);
      return;
    }
    // The card: the trackpad is the logo, as in the title.
    logoPad(pad, d, ease.out(prog(t, END.card, END.card + 1.1)), ease.out(prog(t, END.card, END.card + 0.15)));
    pad.bloom = lerp(1.5, 0.9, ease.out(prog(t, END.card, END.card + 0.9)));
    for (const el of [this.battery, this.private, this.open]) reveal(el, t, Infinity);
    for (const el of [this.batterySub, this.privateSub, this.openSub]) fade(el, t, Infinity);
    reveal(this.word, t, END.word, FILM.duration + 1, { stagger: 0, dur: 1.1, rise: 0.22, blur: 22 });
    fade(this.line, t, END.line, FILM.duration + 1, { rise: 16 });
    fade(this.links, t, END.links, FILM.duration + 1, { rise: 20, dur: 0.8 });
  },
};
