// 60–67.5 s. Sway knows what you're doing: the right edge becomes Tabs in a
// browser, Seek in a music app, Undo / redo in an editor. Then a display
// connects, the docked profile takes over, and brightness follows the pointer.
import { h, at, tf, words, reveal, fade, glyph } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, AWARE } from "../timeline.js";

const S = SCENES.find((s) => s.id === "aware");
const APPS = [
  { name: "Browser", action: "Tabs", icon: "window" },
  { name: "Music", action: "Seek", icon: "note" },
  { name: "Editor", action: "Undo / redo", icon: "doc" },
];

function windowCard(kind) {
  const bar = h("div", { style: { height: "50px", display: "flex", alignItems: "center", gap: "9px", padding: "0 18px", borderBottom: "1px solid rgba(255,255,255,0.07)", background: "rgba(255,255,255,0.03)" } },
    ...[0, 1, 2].map(() => h("span", { style: { width: "12px", height: "12px", borderRadius: "50%", background: "rgba(255,255,255,0.18)" } })),
    h("span", { style: { flex: 1, textAlign: "center", font: "600 19px var(--font)", color: "#8d8f96", marginRight: "50px" } }, kind));
  const line = (w, o = 0.14, hgt = 14, extra = {}) => h("div", { style: { width: w, height: `${hgt}px`, borderRadius: `${hgt / 2}px`, background: `rgba(255,255,255,${o})`, ...extra } });
  let body;
  if (kind === "Browser") {
    body = h("div", { style: { padding: "20px 24px", display: "grid", gap: "16px" } },
      h("div", { style: { display: "flex", gap: "8px" } }, ...["", "", ""].map((_, i) => h("div", { style: { flex: 1, height: "34px", borderRadius: "10px", background: `rgba(255,255,255,${i === 0 ? 0.13 : 0.05})` } }))),
      h("div", { style: { height: "150px", borderRadius: "16px", background: "linear-gradient(135deg, rgba(255,255,255,0.12), rgba(255,255,255,0.03))" } }),
      line("82%"), line("64%", 0.09), line("72%", 0.09));
  } else if (kind === "Music") {
    body = h("div", { style: { padding: "26px", display: "flex", gap: "26px" } },
      h("div", { style: { width: "220px", height: "220px", borderRadius: "18px", flex: "none", background: "radial-gradient(circle at 30% 25%, #c9d6ff 0%, #5d6c94 32%, #1d2230 70%)" } }),
      h("div", { style: { flex: 1, display: "grid", alignContent: "start", gap: "16px", paddingTop: "18px" } }, line("80%", 0.2, 20), line("55%", 0.1), h("div", { style: { height: "50px" } }), line("100%", 0.1, 8), line("40%", 0.25, 8, { marginTop: "-24px" })));
  } else {
    body = h("div", { style: { padding: "24px 26px", display: "grid", gap: "15px" } },
      ...[["16%", "60%"], ["8%", "70%"], ["8%", "46%"], ["16%", "30%"], ["0%", "54%"], ["8%", "66%"], ["8%", "38%"]].map(([indent, w], i) =>
        h("div", { style: { display: "flex", gap: "16px", alignItems: "center" } }, h("span", { style: { width: "24px", font: "500 15px var(--mono)", color: "#55575e", textAlign: "right" } }, String(i + 1)), h("div", { style: { width: indent } }), line(w, i % 3 === 0 ? 0.18 : 0.1, 13))));
  }
  return h("div", { class: "glass", style: { width: "620px", height: "410px", borderRadius: "24px", overflow: "hidden" } }, bar, body);
}

export default {
  id: "aware",
  pre: 0.5,
  post: 0.5,
  mount(root) {
    this.title = at(words("Every app gets its own edges.", "h2 grad center"), 960, 128);
    this.sub = at(h("div", { class: "sub center" }, "Profiles switch the moment you change apps."), 960, 206);
    this.windows = APPS.map((a) => at(windowCard(a.name), 660, 650));
    // The mini trackpad with the right edge's current action.
    this.chipLabel = h("span", {}, "Volume");
    this.chipIcon = h("span", {});
    this.chip = h("div", { class: "pill light", style: { position: "absolute", right: "122px", top: "50%", transform: "translateY(-50%)", fontSize: "27px" } }, this.chipIcon, this.chipLabel);
    this.pad = at(h("div", { style: { width: "560px", height: "350px", borderRadius: "30px", background: "linear-gradient(180deg,#18191c,#111214)", border: "1px solid rgba(255,255,255,0.1)", boxShadow: "0 40px 90px rgba(0,0,0,0.55)" } },
      h("div", { class: "strip", style: { position: "absolute", right: "12px", top: "40px", bottom: "40px", width: "84px", borderRadius: "18px", background: "rgba(255,255,255,0.08)", display: "grid", placeItems: "center", color: "#eef3ff" } }, glyph("speaker", 28)),
      h("div", { style: { position: "absolute", left: "12px", top: "40px", bottom: "40px", width: "84px", borderRadius: "18px", background: "rgba(255,255,255,0.035)", display: "grid", placeItems: "center", color: "#8d8f96" } }, glyph("sun", 28)),
      this.chip), 1395, 640);
    this.inApp = at(h("div", { class: "pill dark", style: { fontSize: "24px", padding: "12px 22px" } }, h("span", { style: { color: "#8d8f96" } }, "In"), h("span", { class: "appname" }, "Browser")), 1395, 410);

    // Docked: laptop + external display.
    const screen = (w, hh) => h("div", { class: "screen", style: { width: `${w}px`, height: `${hh}px`, borderRadius: "14px", border: "10px solid #1b1c1f", background: "linear-gradient(160deg,#2a2e3a 0%,#15171d 60%,#0e0f12 100%)", boxShadow: "0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)", position: "relative", overflow: "hidden" } },
      h("div", { style: { position: "absolute", left: 0, right: 0, top: 0, height: "18px", background: "rgba(255,255,255,0.06)" } }),
      h("div", { class: "lift", style: { position: "absolute", inset: 0, background: "#dfe6ff", opacity: 0 } }));
    this.laptopScreen = screen(500, 320);
    this.laptop = at(h("div", { style: { display: "grid", justifyItems: "center" } }, this.laptopScreen, h("div", { style: { width: "600px", height: "16px", borderRadius: "0 0 14px 14px", background: "linear-gradient(180deg,#2c2d31,#1a1b1e)", marginTop: "-2px" } })), 560, 600);
    this.monitorScreen = screen(720, 430);
    this.monitor = at(h("div", { style: { display: "grid", justifyItems: "center" } }, this.monitorScreen, h("div", { style: { width: "90px", height: "70px", background: "linear-gradient(180deg,#26272b,#1a1b1e)" } }), h("div", { style: { width: "240px", height: "12px", borderRadius: "6px", background: "#2a2b2f" } })), 1340, 560);
    this.cable = at(h("svg", { width: 300, height: 200, viewBox: "0 0 300 200", style: { overflow: "visible" } }, h("path", { class: "c", d: "M0 150 C 90 150, 150 175, 210 120 S 290 60, 300 40", fill: "none", stroke: "rgba(255,255,255,0.28)", "stroke-width": 4, "stroke-linecap": "round" })), 960, 640);
    this.knob = h("div", { style: { position: "absolute", top: "3px", left: "3px", width: "30px", height: "30px", borderRadius: "50%", background: "#fff", boxShadow: "0 2px 6px rgba(0,0,0,0.4)" } });
    this.switch = h("div", { style: { position: "relative", width: "62px", height: "36px", borderRadius: "18px", background: "rgba(255,255,255,0.18)" } }, this.knob);
    this.docked = at(h("div", { class: "pill dark", style: { fontSize: "26px", gap: "18px", padding: "14px 18px 14px 26px" } }, glyph("display", 28), "Docked profile", this.switch), 960, 905);
    this.pointer = at(h("div", { style: { color: "#fff", filter: "drop-shadow(0 4px 8px rgba(0,0,0,0.6))" } }, glyph("pointer", 46)), 560, 600);
    this.hud = at(h("div", { class: "pill dark", style: { fontSize: "22px", gap: "14px", padding: "14px 20px" } }, glyph("sun", 26), h("div", { style: { width: "190px", height: "8px", borderRadius: "4px", background: "rgba(255,255,255,0.15)", position: "relative", overflow: "hidden" } }, h("div", { class: "f", style: { position: "absolute", left: 0, top: 0, bottom: 0, width: "50%", background: "#fff", borderRadius: "4px" } }))), 560, 690);
    this.title2 = at(words("Docked? It switches too.", "h2 grad center"), 960, 128);
    this.sub2 = at(h("div", { class: "sub center" }, "Plug in a display and your docked profile takes over."), 960, 206);
    this.title3 = at(words("Brightness follows your pointer.", "h2 grad center"), 960, 128);
    this.sub3 = at(h("div", { class: "sub center" }, "Built-in, Apple displays, and DDC monitors."), 960, 206);
    root.append(...this.windows, this.pad, this.inApp, this.laptop, this.cable, this.monitor, this.docked, this.hud, this.pointer, this.title, this.sub, this.title2, this.sub2, this.title3, this.sub3);
  },
  update(t, { bg }) {
    const partOut = ease.leave(prog(t, AWARE.dock - 0.45, AWARE.dock - 0.05));
    reveal(this.title, t, AWARE.title, AWARE.dock - 0.45, { rise: 0.3 });
    fade(this.sub, t, AWARE.title + 0.3, AWARE.dock - 0.45);

    // Which app is in front, with a card-shuffle when it changes.
    let active = -1;
    APPS.forEach((_, i) => { if (t >= AWARE.apps[i] - 0.1) active = i; });
    const depthOf = (i, a) => (a < 0 ? 2 - i * 0.5 + 0.5 : (i - a + 3) % 3);
    this.windows.forEach((w, i) => {
      let depth = depthOf(i, -1), bump = 0;
      for (let k = 0; k < APPS.length; k++) {
        const p = ease.inOut(prog(t, AWARE.apps[k] - 0.3, AWARE.apps[k] + 0.3));
        if (p <= 0) break;
        const from = depthOf(i, k - 1), to = depthOf(i, k);
        depth = lerp(from, to, p);
        if (to < from && p < 1) bump = Math.sin(Math.PI * p);
      }
      const enter = ease.settle(prog(t, S.start - 0.2 + i * 0.12, S.start + 0.7 + i * 0.12));
      tf(w, { x: -depth * 64 + bump * 360 - partOut * 220, y: -depth * 52 + (1 - enter) * 80, s: (1 - depth * 0.07) * lerp(0.94, 1, enter), ry: bump * -12, o: enter * clamp(1 - depth * 0.33) * (1 - partOut), blur: depth * 1.6 + (1 - enter) * 10 + partOut * 8 });
      w.style.zIndex = String(10 - Math.round(depth * 2 + (bump > 0.5 ? -4 : 0)));
    });
    const padIn = ease.settle(prog(t, S.start + 0.1, S.start + 0.9));
    tf(this.pad, { y: (1 - padIn) * 60, o: padIn * (1 - partOut), x: partOut * 220, blur: (1 - padIn) * 10 + partOut * 8 });
    tf(this.inApp, { y: (1 - padIn) * 40, o: padIn * (1 - partOut) * ep(t, AWARE.apps[0] - 0.2, AWARE.apps[0] + 0.2), x: partOut * 220 });
    // The chip dips and changes as each app takes over.
    let dip = 0;
    for (const s of AWARE.apps) dip = Math.max(dip, 1 - Math.abs(t - s) / 0.22);
    dip = ease.smooth(clamp(dip));
    const app = APPS[Math.max(0, active)];
    this.chipLabel.textContent = active < 0 ? "Volume" : app.action;
    this.chipIcon.innerHTML = "";
    this.chipIcon.append(glyph(active < 0 ? "speaker" : app.icon, 28));
    this.chip.style.opacity = String(1 - dip * 0.85);
    this.chip.style.filter = dip > 0.02 ? `blur(${dip * 8}px)` : "";
    this.chip.style.transform = `translateY(-50%) scale(${lerp(1, 0.86, dip)})`;
    this.inApp.querySelector(".appname").textContent = app.name;

    // Docked.
    const dockIn = spring(t - AWARE.dock, 0.55, 0.78);
    const sceneOut = ease.leave(prog(t, S.end - 0.6, S.end - 0.1));
    const laptopIn = ease.settle(prog(t, AWARE.dock - 0.2, AWARE.dock + 0.5));
    tf(this.laptop, { y: (1 - laptopIn) * 50, o: laptopIn * (1 - sceneOut), blur: (1 - laptopIn) * 10 + sceneOut * 8 });
    tf(this.monitor, { x: (1 - clamp(dockIn)) * 520, o: (t >= AWARE.dock ? clamp(dockIn * 1.6) : 0) * (1 - sceneOut), blur: (1 - clamp(dockIn)) * 10 + sceneOut * 8 });
    const cable = ease.inOut(prog(t, AWARE.dock + 0.15, AWARE.dock + 0.55));
    const path = this.cable.querySelector(".c");
    path.setAttribute("stroke-dasharray", "420 420");
    path.setAttribute("stroke-dashoffset", String(420 * (1 - cable)));
    tf(this.cable, { o: (1 - sceneOut) * (cable > 0 ? 1 : 0) });
    const on = ease.inOut(prog(t, AWARE.dock + 0.5, AWARE.dock + 0.75));
    this.knob.style.left = `${3 + on * 26}px`;
    this.switch.style.background = `rgba(255,255,255,${0.18 + on * 0.62})`;
    this.knob.style.background = on > 0.5 ? "#16171a" : "#fff";
    tf(this.docked, { y: (1 - ep(t, AWARE.dock + 0.2, AWARE.dock + 0.7)) * 30, o: ep(t, AWARE.dock + 0.2, AWARE.dock + 0.6) * (1 - sceneOut) });

    // Brightness follows the pointer to the display it's on.
    const move = ease.inOut(prog(t, AWARE.pointer + 0.25, AWARE.pointer + 0.85));
    const px = lerp(560, 1340, move), py = lerp(590, 545, move) - Math.sin(move * Math.PI) * 90;
    tf(this.pointer, { x: px - 560, y: py - 600, o: ep(t, AWARE.pointer - 0.2, AWARE.pointer + 0.05) * (1 - sceneOut) });
    const onMonitor = move > 0.6;
    const hudIn = (t0) => ease.settle(prog(t, t0, t0 + 0.3));
    const hudA = hudIn(AWARE.pointer + 0.0) * (1 - ease.leave(prog(t, AWARE.pointer + 0.45, AWARE.pointer + 0.62)));
    const hudB = hudIn(AWARE.pointer + 0.9);
    const level = onMonitor ? lerp(0.35, 0.82, ease.inOut(prog(t, AWARE.pointer + 1.0, AWARE.pointer + 1.55))) : 0.6;
    this.hud.querySelector(".f").style.width = `${level * 100}%`;
    const hx = onMonitor ? 1340 : 560, hy = onMonitor ? 690 : 690;
    tf(this.hud, { x: hx - 560, y: (hy - 690) + (1 - (onMonitor ? hudB : hudA)) * 20, o: (onMonitor ? hudB : hudA) * (1 - sceneOut) });
    this.monitorScreen.querySelector(".lift").style.opacity = String(onMonitor ? (level - 0.35) * 0.35 : 0);

    reveal(this.title2, t, AWARE.dock + 0.05, AWARE.pointer - 0.35, { rise: 0.3 });
    fade(this.sub2, t, AWARE.dock + 0.3, AWARE.pointer - 0.35);
    reveal(this.title3, t, AWARE.pointer - 0.1, S.end - 0.45, { rise: 0.3 });
    fade(this.sub3, t, AWARE.pointer + 0.2, S.end - 0.45);
    bg.style.setProperty("--by", "52%");
    bg.style.setProperty("--ba", "0.5");
  },
};
