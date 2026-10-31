// 7.5–12.5 s. The icon lands with a bloom, the fingertip rises, the name
// arrives. Then the camera dives into the icon's surface, which becomes the
// 3D trackpad of the next scene.
import { h, at, tf, words, reveal, swayIcon } from "../ui.js";
import { prog, ease, lerp, spring, ep, SCENES } from "../timeline.js";

const S = SCENES.find((s) => s.id === "logo");
const ICON = 300 * (1024 / 824); // the tile is 824 of the icon's 1024 units

export default {
  id: "logo",
  pre: 0.35,
  post: 0.2,
  mount(root) {
    this.halo = at(h("div", { style: { width: "1500px", height: "1500px", borderRadius: "50%", background: "radial-gradient(circle, rgba(214,226,255,0.22) 0%, rgba(160,180,230,0.07) 28%, transparent 62%)" } }), 960, 455);
    this.icon = at(swayIcon(ICON), 960, 455);
    this.sheen = at(h("div", { style: { width: "300px", height: "300px", borderRadius: "68px", overflow: "hidden", mixBlendMode: "screen" } },
      h("div", { class: "band", style: { position: "absolute", inset: "-40% -120%", background: "linear-gradient(105deg, transparent 44%, rgba(255,255,255,0.22) 50%, transparent 56%)" } })), 960, 455);
    this.word = at(words("Sway", "h1 grad center", { fontSize: "156px", fontWeight: 700, letterSpacing: "-0.045em" }), 960, 738);
    this.tag = at(words("The edges of your trackpad, as controls.", "sub center", { fontSize: "38px" }), 960, 846);
    root.append(this.halo, this.icon, this.sheen, this.word, this.tag);
    this.band = this.sheen.querySelector(".band");
  },
  update(t) {
    const local = t - S.start;
    // Crossfade in from the morphing trackpad, then a soft spring settle.
    const appear = ep(t, S.start - 0.3, S.start + 0.02, ease.smooth);
    const settle = lerp(0.965, 1, spring(local + 0.1, 0.55, 0.6));
    // The dive: accelerate into the icon's surface.
    const dive = ease.in(prog(t, S.end - 1.55, S.end + 0.05));
    const scale = settle * lerp(1, 15, dive * dive);
    const iconO = appear * (1 - ease.smooth(prog(t, S.end - 0.38, S.end + 0.08)));
    tf(this.icon, { s: scale, o: iconO, blur: dive * 5 });
    this.icon.__finger(lerp(0.62, 1, spring(local, 0.7, 0.72)), 1 - ease.smooth(prog(t, S.end - 1.2, S.end - 0.7)));

    // A bloom of light behind the icon as it lands.
    const flash = Math.exp(-Math.max(0, local) * 2.4) * (local >= 0 ? 1 : 0);
    tf(this.halo, { s: lerp(0.6, 1.05, ep(t, S.start - 0.1, S.start + 1.4)) * (1 + dive * 4), o: (0.55 + flash * 0.9) * appear * (1 - dive) });

    // One sheen sweep across the glass.
    tf(this.sheen, { s: scale, o: appear * (1 - dive) });
    this.band.style.transform = `translateX(${lerp(-60, 60, ease.inOut(prog(t, S.start + 0.15, S.start + 1.2)))}%)`;

    reveal(this.word, t, S.start + 0.55, S.end - 1.75, { stagger: 0.0, dur: 1.1, rise: 0.22, blur: 22 });
    reveal(this.tag, t, S.start + 1.05, S.end - 1.8, { stagger: 0.04 });
    // The name gently tracks in.
    this.word.style.letterSpacing = `${lerp(0.02, -0.045, ease.settle(prog(t, S.start + 0.5, S.start + 2.2)))}em`;
  },
};
