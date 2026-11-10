// Every app gets its own edges. The same right edge: volume on the desktop,
// tabs in the browser, the playhead in Music. The chip beside the trackpad
// names what the edge is right now, and the screen shows it doing it.
import { h, tf, at, glyph } from "../ui.js";
import { musicPlayer, quietWindow, browser } from "../windows.js";
import { caption, chip } from "../kit.js";
import { prog, ease, lerp, spring, clamp, env, levelAt, touchAt, APPS, scene } from "../timeline.js";
import { edgePoint, padPoint, ZONES, TEX } from "../world.js";

const S = scene("apps");
const NAMES = ["Finder", "Browser", "Music"];
const EDGE = [["speaker", "Volume"], ["tabs", "Tabs"], ["note", "Seek"]];

export default {
  id: "apps",
  mount(root, ctx, screen) {
    this.windows = [quietWindow({ x: 330, y: 190, w: 620, ht: 400, title: "Documents" }), (this.browser = browser({ x: 250, y: 180, w: 780, ht: 440 })), (this.player = musicPlayer({ x: 340, y: 230, w: 600, ht: 300 }))];
    screen.append(...this.windows);
    this.title = caption("Every app gets\nits own edges.", "h2 grad shadowed", 96, 900);
    this.icon = h("span", { style: { display: "grid", placeItems: "center" } });
    this.chip = at(chip(this.icon, "Volume"), 0, 0);
    this.eyebrow = at(h("div", { class: "eyebrow", style: { color: "#9a9ca3", fontSize: "17px" } }, "Right edge"), 0, 0);
    root.append(this.title, this.chip, this.eyebrow);
  },
  update(t, { pad, d, world }) {
    const [toBrowser, toMusic] = APPS.switches;
    const app = t >= toMusic ? 2 : t >= toBrowser ? 1 : 0;
    const since = t - (app === 2 ? toMusic : app === 1 ? toBrowser : S.start - 1);
    d.app = NAMES[app];
    pad.labels.o = 0;
    // Windows: the app in front springs forward as the last one drops away.
    this.windows.forEach((win, i) => {
      const front = i === app, arrive = front ? spring(since, 0.4, 0.8) : 0;
      const leaving = i === app - 1 ? 1 - ease.out(prog(since, 0, 0.25)) : 0;
      const o = front ? clamp(arrive * 2) : leaving;
      win.style.opacity = String(o);
      win.style.visibility = o > 0.004 ? "visible" : "hidden";
      win.style.transform = `translateY(${front ? (1 - clamp(arrive)) * 22 : 0}px) scale(${front ? lerp(0.95, 1, arrive) : lerp(0.97, 1, leaving)})`;
    });

    // The finger on the right edge, once per app.
    const g = APPS.swipes[app], touch = touchAt(g, t, 0.12, 0.25);
    const p = clamp((levelAt(g, t) - g.from) / (g.to - g.from));
    if (touch > 0.002) {
      const from = edgePoint("right", 0.3), to = edgePoint("right", lerp(0.3, 0.74, p));
      pad.contacts.push({ x: to.x, y: to.y, from, o: touch });
      d.edge = { side: "right", level: lerp(30, 74, p), o: touch, palette: "accent" };
    }
    pad.zones.right = 0.35 + 0.65 * touch;
    // What the edge does here.
    if (app === 0) { const o = env(t, g.down, g.lift + 0.45, 0.25, 0.25); if (o > 0) d.hud = { kind: "speaker", level: levelAt(g, t), o, scale: 1.7 }; }
    this.browser.__set(app === 1 ? levelAt(APPS.swipes[1], t) : 0);
    this.player.__set(app === 2 ? { seconds: 228 * levelAt(g, t), seeking: touch } : {});

    // The chip beside the trackpad's right edge.
    const [x, y] = world.project(padPoint(ZONES.right, TEX.h * 0.5));
    const flip = app === 0 ? 1 : spring(since, 0.32, 0.72);
    const shown = flip < 0.5 && app > 0 ? app - 1 : app;
    if (shown !== this.shown) { this.icon.innerHTML = ""; this.icon.append(glyph(EDGE[shown][0], 28)); this.chip.__label.textContent = EDGE[shown][1]; this.shown = shown; }
    const appear = ease.settle(prog(t, S.start + 0.15, S.start + 0.7));
    this.chip.style.left = `${x + 222}px`;
    this.chip.style.top = `${y + 10}px`;
    tf(this.chip, { s: lerp(0.86, 1, Math.abs(flip * 2 - 1)) * lerp(0.9, 1, appear), o: appear * clamp(Math.abs(flip * 2 - 1) * 1.6 + 0.1), y: (1 - appear) * 14 });
    this.eyebrow.style.left = `${x + 222}px`;
    this.eyebrow.style.top = `${y - 52}px`;
    tf(this.eyebrow, { o: appear });
    this.title.__words.forEach((w, i) => {
      const pin = ease.settle(prog(t, APPS.title + i * 0.05, APPS.title + i * 0.05 + 0.8));
      w.style.opacity = pin.toFixed(3);
      w.style.transform = `translateY(${(1 - pin) * 22}px)`;
      w.style.filter = pin < 0.99 ? `blur(${((1 - pin) * 12).toFixed(1)}px)` : "";
    });
  },
};
