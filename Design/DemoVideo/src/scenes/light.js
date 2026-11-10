// The screen answers in light. The edge beside the finger lights up, in any
// of Kinara's colours, and they change here on the beat. Then the ambient
// light: one soft light that laps the screen, for when you just want it to.
import { h, at, words, reveal } from "../ui.js";
import { musicPlayer, quietWindow } from "../windows.js";
import { caption, tapCorner } from "../kit.js";
import { PALETTES, css, paletteAt } from "../desktop.js";
import { prog, ease, lerp, clamp, path, env, LIGHT, scene } from "../timeline.js";
import { edgePoint } from "../world.js";

const S = scene("light");
const L = LIGHT;
const NAMES = { accent: "Accent", aurora: "Aurora", sunset: "Sunset", ember: "Ember", mint: "Mint", mono: "Mono" };
const ORDER = ["accent", "aurora", "sunset", "ember", "mint", "mono"];
const paint = (id) => (PALETTES[id].length === 1 ? css(PALETTES[id][0]) : `conic-gradient(from 210deg, ${[...PALETTES[id], PALETTES[id][0]].map((c) => css(c)).join(",")})`);

export default {
  id: "light",
  mount(root, ctx, screen) {
    screen.append(quietWindow({ x: 640, y: 150, w: 420, ht: 320, title: "Notes" }), (this.player = musicPlayer({ x: 190, y: 250, w: 540, ht: 280 })));
    this.title = caption("Your screen\nanswers in light.", "h2 grad shadowed", 1250, 860);
    // The colour swatches, as in Kinara's settings.
    this.swatches = ORDER.map((id) => h("div", { style: { width: "46px", height: "46px", borderRadius: "50%", background: paint(id), boxShadow: "inset 0 0 0 1.5px rgba(255,255,255,0.25), 0 6px 18px rgba(0,0,0,0.5)", position: "relative" } }));
    this.ring = h("div", { style: { position: "absolute", top: "50%", left: "0", width: "62px", height: "62px", margin: "-31px 0 0 -31px", borderRadius: "50%", border: "3px solid #fff", boxShadow: "0 0 18px rgba(255,255,255,0.35)" } });
    this.name = h("div", { style: { font: "640 44px/1 var(--font)", letterSpacing: "-0.025em", marginLeft: "26px", minWidth: "220px" } }, "Accent");
    this.row = h("div", { style: { position: "absolute", left: "1090px", top: "896px", display: "flex", alignItems: "center", gap: "20px", textShadow: "0 2px 30px rgba(0,0,0,0.8)" } },
      h("div", { style: { position: "relative", display: "flex", gap: "20px", alignItems: "center" } }, ...this.swatches, this.ring), this.name);
    this.eyebrow = h("div", { class: "eyebrow", style: { position: "absolute", left: "1092px", top: "836px", color: "#9a9ca3" } }, "Light colour");
    this.ambient = caption("Ambient light.", "h1 grad shadowed", 110, 900);
    this.ambientSub = h("div", { class: "sub", style: { position: "absolute", left: "114px", top: "968px", color: "#a0a2aa" } }, "A tap, and it laps your screen.");
    root.append(this.title, this.eyebrow, this.row, this.ambient, this.ambientSub);
  },
  update(t, { pad, d }) {
    d.app = "Music";
    const amb = ease.smooth(prog(t, L.ambient - 0.2, L.ambient + 1.2));
    d.mood = lerp(0.55, 1, amb);
    d.brightness = lerp(0.8, 0.5, amb);
    pad.env = lerp(0.6, 0.3, amb);
    pad.rim = lerp(1, 0.1, amb);
    pad.labels.o = 0;
    this.player.__set({ seconds: 130 + (t - S.start) });

    // The colour now, and the one it is changing to.
    let k = 0;
    while (k + 1 < L.palettes.length && L.palettes[k + 1][0] <= t) k++;
    const [changed, id] = L.palettes[k];
    const from = k > 0 ? L.palettes[k - 1][1] : id;
    const mix = k > 0 ? ease.out(prog(t, changed, changed + 0.28)) : 1;
    const tint = (() => { const a = paletteAt(PALETTES[from], 0.4), b = paletteAt(PALETTES[id], 0.4); return [lerp(a[0], b[0], mix), lerp(a[1], b[1], mix), lerp(a[2], b[2], mix)]; })();

    // The finger wanders the right edge.
    const touch = Math.min(ease.out(prog(t, L.down - 0.02, L.down + 0.14)), 1 - ease.smooth(prog(t, L.lift, L.lift + 0.3)));
    const level = path(L.level, t);
    if (touch > 0.002) {
      const at = edgePoint("right", level / 100), tail = edgePoint("right", path(L.level, t - 0.42) / 100);
      pad.contacts.push({ x: at.x, y: at.y, from: tail, o: touch, color: tint.map((c) => lerp(c, 255, 0.35)) });
      d.edge = { side: "right", level, o: touch, palette: from, to: id, mix };
    }
    pad.zones.right = 0.3 + 0.7 * touch;

    // The swatches: the ring springs to each colour as it is chosen.
    const rowO = env(t, L.palettes[1][0] - 0.5, L.lift + 0.25, 0.4, 0.3);
    this.row.style.opacity = this.eyebrow.style.opacity = String(rowO);
    this.row.style.transform = `translateY(${(1 - rowO) * 18}px)`;
    const slot = lerp(ORDER.indexOf(from), ORDER.indexOf(id), mix);
    this.ring.style.transform = `translateX(${23 + slot * 66}px)`;
    this.name.textContent = NAMES[mix > 0.5 ? id : from];
    this.swatches.forEach((el, i) => (el.style.transform = `scale(${1 + 0.12 * Math.max(0, 1 - Math.abs(slot - i))})`));

    // Ambient light: a tap, and it starts its lap.
    tapCorner(pad, "br", t, L.ambientTap);
    const on = ease.out(prog(t, L.ambient, L.ambient + 0.7)) * (1 - ease.smooth(prog(t, L.out, S.end)));
    if (on > 0.002) d.ambient = { o: on, lap: 0.02 + (t - L.ambient) / L.lap, palette: "aurora" };

    reveal(this.title, t, L.title, L.palettes[1][0] - 0.75, { rise: 0.25, dur: 0.8, outDur: 0.3 });
    reveal(this.ambient, t, L.ambient + 0.5, L.out - 0.15, { rise: 0.25, dur: 0.9, outDur: 0.3 });
    const sub = Math.min(ease.settle(prog(t, L.ambient + 1.0, L.ambient + 1.7)), 1 - ease.leave(prog(t, L.out - 0.2, L.out + 0.15)));
    this.ambientSub.style.opacity = String(clamp(sub));
    this.ambientSub.style.transform = `translateY(${(1 - ease.settle(prog(t, L.ambient + 1.0, L.ambient + 1.7))) * 14}px)`;
  },
};
