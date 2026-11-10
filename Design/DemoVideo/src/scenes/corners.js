// Corners. A double-tap in the trackpad's corner, and the screen answers in
// that corner: a glass bead that stretches into a pill naming what happened.
// It pauses the music, and the film's own score stops with it. The same tap
// again undoes it, and the score comes back.
import { at, words, reveal } from "../ui.js";
import { musicPlayer, quietWindow } from "../windows.js";
import { sequence, tapCorner } from "../kit.js";
import { CORNERS, scene } from "../timeline.js";

const S = scene("corners");
const C = CORNERS;

export default {
  id: "corners",
  mount(root, { desk }, screen) {
    this.player = musicPlayer({ x: 330, y: 104, w: 560, ht: 290 });
    screen.append(quietWindow({ x: 860, y: 480, w: 380, ht: 280, title: "Notes" }), this.player);
    this.island = desk.island("tr", {
      play: { title: "Play / pause", detail: "Double-tap again to undo", icon: "playpause" },
      undone: { title: "Undone", detail: null, icon: "uturn" },
    });
    this.title = at(words("Tap a corner.", "h0 grad center shadowed"), 760, 560);
    this.caps = [at(words("It answers, right there.", "h2 grad center shadowed"), 1380, 910), at(words("Again to undo.", "h2 grad center shadowed"), 1380, 910)];
    root.append(this.title, ...this.caps);
  },
  update(t, { pad, d, desk }) {
    d.app = "Music";
    pad.gloss = 0.14;
    pad.env = 1.5;
    pad.labels.o = 0;
    const paused = t >= C.fire + 0.08 && t < C.undo[1] + 0.08;
    const played = (Math.min(t, C.fire) - S.start) + Math.max(0, t - C.undo[1]);
    this.player.__set({ paused, seconds: 96 + played });

    // The trackpad: two taps in the top-right corner.
    tapCorner(pad, "tr", t, C.taps, 0.1);

    // The screen: its corner lights as the taps land, and the glass blooms.
    d.corners.tr = [desk.flash(t, C.fire, 1, 1), desk.flash(t, C.undo[0], 0.5, 0.4), desk.flash(t, C.undo[1], 1, 1)].reduce((a, b) => (b.i > a.i ? b : a));
    desk.drawIsland(this.island, t, [
      { t: C.cut - 0.2, kind: "arm" },
      { t: C.fire, kind: "bloom", id: "play" },
      { t: C.undo[1], kind: "swap", id: "undone" },
      { t: C.fold, kind: "fold" },
    ]);

    reveal(this.title, t, C.title, C.taps[0] - 0.3, { rise: 0.25, dur: 0.8, outDur: 0.25 });
    sequence(this.caps, t, [C.fire + 0.7, C.undo[1] + 0.2], S.end - 0.05);
  },
};
