// 87.5–96 s. The end card: the icon lands once more, the swipe rises, and
// the name settles in before everything fades to black.
import { h, at, tf, words, reveal, fade, swayIcon } from "../ui.js";
import { prog, ease, lerp, spring, ep, SCENES, END, FILM } from "../timeline.js";

const S = SCENES.find((s) => s.id === "end");
const ICON = 300 * (1024 / 824);

export default {
  id: "end",
  pre: 0.4,
  post: 0,
  mount(root) {
    this.halo = at(h("div", { style: { width: "1500px", height: "1500px", borderRadius: "50%", background: "radial-gradient(circle, rgba(214,226,255,0.2) 0%, rgba(160,180,230,0.06) 28%, transparent 62%)" } }), 960, 400);
    this.icon = at(swayIcon(ICON), 960, 400);
    this.word = at(words("Sway", "h1 grad center", { fontSize: "150px", fontWeight: 700, letterSpacing: "-0.045em" }), 960, 668);
    this.tag = at(words("The edges of your trackpad, as controls.", "sub center", { fontSize: "38px" }), 960, 772);
    this.foot = at(h("div", { class: "eyebrow center" }, "For Mac  ·  macOS 13 or later"), 960, 900);
    root.append(this.halo, this.icon, this.word, this.tag, this.foot);
  },
  update(t, { bg }) {
    const local = t - S.start;
    const out = ease.inOut(prog(t, END.fade, FILM.duration - 0.6));
    const drift = lerp(1, 1.035, ease.smooth(prog(t, S.start, FILM.duration)));
    const land = spring(local + 0.05, 0.6, 0.62);
    tf(this.icon, { s: lerp(0.86, 1, land) * drift, o: ep(t, S.start - 0.12, S.start + 0.2) * (1 - out), blur: (1 - ep(t, S.start - 0.12, S.start + 0.35)) * 18 });
    this.icon.__finger(lerp(0, 1, spring(local - 0.25, 0.9, 0.78)), ep(t, S.start + 0.1, S.start + 0.5));
    const flash = local >= 0 ? Math.exp(-local * 2.2) : 0;
    tf(this.halo, { s: lerp(0.6, 1.05, ep(t, S.start, S.start + 1.6)) * drift, o: (0.5 + flash) * ep(t, S.start - 0.2, S.start + 0.2) * (1 - out) });
    reveal(this.word, t, END.word, END.fade, { stagger: 0, dur: 1.1, rise: 0.22, blur: 22, outDur: 1.2 });
    this.word.style.letterSpacing = `${lerp(0.02, -0.045, ease.settle(prog(t, END.word, END.word + 1.8)))}em`;
    reveal(this.tag, t, END.word + 0.45, END.fade, { stagger: 0.04, outDur: 1.0 });
    fade(this.foot, t, END.line, END.fade, { outDur: 1.0 });
    bg.style.setProperty("--by", "40%");
    bg.style.setProperty("--ba", String(0.55 * (1 - out)));
  },
};
