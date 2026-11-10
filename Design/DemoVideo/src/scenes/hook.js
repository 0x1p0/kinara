// The hook. The open has just shown volume and brightness, and a groove lands
// on the downbeat: "Volume and brightness? Every app does that." Then the tape
// stops, and the studio's lights drain with it: the brightness indicator runs
// down to nothing and the screen goes out. In the dark and the silence, a
// question, and a double-tap in the trackpad's corner, the one thing the
// trackpad was never asked to do, brings everything back on the next downbeat.
import { at, words, reveal, fade, h } from "../ui.js";
import { musicPlayer, quietWindow } from "../windows.js";
import { tapCorner } from "../kit.js";
import { prog, ease, lerp, env, HOOK, SILENCE, scene } from "../timeline.js";

const S = scene("hook");

export default {
  id: "hook",
  mount(root, ctx, screen) {
    // The screen as the open left it.
    this.player = musicPlayer({ x: 170, y: 210 });
    screen.append(quietWindow({ x: 700, y: 110, w: 440, ht: 330, title: "Notes" }), this.player);
    this.ask = at(h("div", { class: "sub center shadowed", style: { fontSize: "46px", color: "#c4c6cc" } }, "Volume and brightness?"), 960, 404);
    this.claim = at(words("Every app does that.", "h0 grad center shadowed"), 960, 530);
    // Low in the frame: the tapped corner glows in its upper half.
    this.question = at(words("So what’s different?", "h1 grad center shadowed"), 960, 770);
    root.append(this.ask, this.claim, this.question);
  },
  update(t, { pad, d }) {
    // The lights go out with the tape: 0 while the groove plays, 1 in the dark.
    const drain = ease.in(prog(t, HOOK.stop, SILENCE.from));
    const dark = t >= HOOK.cut;

    d.app = "Music";
    this.player.__set({ seconds: 72 + Math.min(t, HOOK.stop) + 0.4 * Math.max(0, Math.min(t, SILENCE.from) - HOOK.stop) });
    // The screen steps back behind the words: softened and quieted, as a keynote slide would.
    // It comes back into focus as they leave, so the brightness is seen draining.
    const back = ease.smooth(prog(t, S.start, S.start + 0.5)) * (1 - ease.smooth(prog(t, HOOK.out, HOOK.stop + 0.1)));
    d.mood = back;
    d.blur = 16 * back;
    d.brightness = (1 - drain) * (1 - 0.35 * back);
    d.o = dark ? 0 : 1 - ease.inOut(prog(t, SILENCE.from - 0.3, HOOK.cut));
    // The brightness indicator falls to nothing as the power goes.
    const sun = env(t, HOOK.stop - 0.05, SILENCE.from + 0.2, 0.12, 0.2);
    if (sun > 0 && !dark) d.hud = { kind: "sun", level: 100 * (1 - drain), o: sun, scale: 1.7 };

    // The studio: lit as the open left it, then dark, then each tap a flash.
    const flash = HOOK.taps.reduce((a, at, i) => a + (t >= at ? (i ? 0.9 : 0.45) * Math.exp(-(t - at) * (i ? 4.5 : 9)) : 0), 0);
    pad.env = dark ? 0.05 + flash : lerp(1, 0.05, drain);
    pad.exposure = dark ? 0.78 + 0.2 * Math.min(1, flash) : lerp(1, 0.78, drain);
    pad.rim = dark ? 0.35 + flash : lerp(1, 0.35, drain);
    pad.bloom = dark ? 0.85 + 0.6 * flash : 0.85;
    pad.labels.o = 1 - ease.out(prog(t, HOOK.stop, HOOK.stop + 0.4));
    pad.zones.left = pad.zones.right = lerp(0.25, 0, drain);
    if (dark) tapCorner(pad, "tl", t, HOOK.taps, 0.08);

    // The words.
    fade(this.ask, t, HOOK.ask, HOOK.out, { rise: 14, dur: 0.6, outDur: 0.3 });
    reveal(this.claim, t, HOOK.claim, HOOK.out + 0.05, { stagger: 0.07, rise: 0.25, dur: 0.8, outDur: 0.3 });
    reveal(this.question, t, HOOK.question, S.end - 0.18, { stagger: 0.09, rise: 0.2, dur: 0.9, outDur: 0.18, blur: 20 });
  },
};
