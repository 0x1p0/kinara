// 67.5–75 s. Sound, exactly how you want it: turn down only the app in
// front, cap headphones at a safe level, and seek with Now Playing.
import { h, at, tf, words, reveal, fade, glyph, indicator } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, SOUND, levelAt, BAR } from "../timeline.js";

const S = SCENES.find((s) => s.id === "sound");
const A = S.start, B = S.start + BAR, C = S.start + BAR * 2;

function appRow(icon, name, status) {
  const wave = h("svg", { width: 420, height: 80, viewBox: "0 0 420 80" });
  const level = h("div", { style: { width: "110px", textAlign: "right", font: "650 40px/1 var(--font)", fontVariantNumeric: "tabular-nums", letterSpacing: "-0.02em" } }, "0%");
  const el = h("div", { class: "glass", style: { width: "1040px", height: "138px", borderRadius: "30px", display: "flex", alignItems: "center", gap: "28px", padding: "0 40px" } },
    h("div", { style: { width: "78px", height: "78px", borderRadius: "19px", background: "linear-gradient(180deg,#46474c,#2a2b2f)", display: "grid", placeItems: "center", color: "#f1f2f5", boxShadow: "inset 0 1px 0 rgba(255,255,255,0.12)" } }, glyph(icon, 38)),
    h("div", { style: { width: "230px" } }, h("div", { style: { font: "650 36px/1.15 var(--font)", letterSpacing: "-0.02em" } }, name), h("div", { class: "small", style: { fontSize: "22px" } }, status)),
    wave, level);
  el.__wave = wave;
  el.__level = level;
  return el;
}

function drawWave(svg, t, amount, seed) {
  let bars = "";
  for (let j = 0; j < 38; j++) {
    const v = Math.abs(Math.sin(t * 5.3 + j * 0.62 + seed) * Math.sin(t * 2.1 + j * 1.31 + seed * 2)) * 0.75 + 0.25 * Math.abs(Math.sin(j * 0.9 + t * 9));
    const hh = Math.max(5, v * 74 * amount);
    bars += `<rect x="${j * 11}" y="${40 - hh / 2}" width="6" height="${hh}" rx="3" fill="#fff" opacity="${0.35 + amount * 0.6}"/>`;
  }
  svg.innerHTML = bars;
}

export default {
  id: "sound",
  pre: 0.5,
  post: 0.5,
  mount(root) {
    this.t1 = at(words("Turn down just one app.", "h2 grad center"), 960, 150);
    this.s1 = at(h("div", { class: "sub center" }, "Per-app volume, right on an edge."), 960, 228);
    this.music = at(appRow("note", "Music", "Playing"), 880, 500);
    this.call = at(appRow("display", "Video call", "On a call"), 880, 668);
    this.ind = at(indicator("speaker", 1.3), 1655, 585);
    this.indLabel = at(h("div", { class: "pill dark", style: { fontSize: "20px", padding: "8px 16px" } }, "Music"), 1655, 840);

    this.t2 = at(words("Headphones never get too loud.", "h2 grad center"), 960, 150);
    this.s2 = at(h("div", { class: "sub center" }, "Set a volume limit for each device."), 960, 228);
    this.fill = h("div", { style: { position: "absolute", left: 0, top: 0, bottom: 0, borderRadius: "9px", background: "#fff" } });
    this.knob = h("div", { style: { position: "absolute", top: "50%", width: "40px", height: "40px", marginTop: "-20px", marginLeft: "-20px", borderRadius: "50%", background: "#fff", boxShadow: "0 4px 12px rgba(0,0,0,0.5)" } });
    this.limitMark = h("div", { style: { position: "absolute", left: "60%", top: "-26px", bottom: "-26px", width: "4px", marginLeft: "-2px", borderRadius: "2px", background: "#eef3ff" } });
    this.limitLabel = h("div", { class: "pill dark", style: { position: "absolute", left: "60%", top: "-86px", transform: "translateX(-50%)", fontSize: "21px", padding: "8px 16px" } }, glyph("lock", 20), "Limit 60%");
    this.headLevel = h("div", { style: { width: "120px", textAlign: "right", font: "650 44px/1 var(--font)", fontVariantNumeric: "tabular-nums" } }, "30%");
    const deviceRow = (icon, name, bar, value) => h("div", { class: "glass", style: { width: "1120px", height: "150px", borderRadius: "30px", display: "flex", alignItems: "center", gap: "34px", padding: "0 44px" } },
      h("div", { style: { width: "78px", height: "78px", borderRadius: "50%", background: "rgba(255,255,255,0.08)", display: "grid", placeItems: "center" } }, glyph(icon, 38)),
      h("div", { style: { width: "200px", font: "650 34px/1.2 var(--font)" } }, name), bar, value);
    this.head = at(deviceRow("headphones", "Headphones", h("div", { style: { position: "relative", width: "560px", height: "18px", borderRadius: "9px", background: "rgba(255,255,255,0.12)" } }, this.fill, this.limitMark, this.limitLabel, this.knob), this.headLevel), 960, 520);
    this.speakers = at(deviceRow("speaker", "Speakers", h("div", { style: { position: "relative", width: "560px", height: "18px", borderRadius: "9px", background: "rgba(255,255,255,0.12)" } }, h("div", { style: { position: "absolute", left: 0, top: 0, bottom: 0, width: "100%", borderRadius: "9px", background: "rgba(255,255,255,0.35)" } })), h("div", { class: "small", style: { width: "120px", textAlign: "right" } }, "Up to 100%")), 960, 700);

    this.t3 = at(words("Seek with a swipe.", "h2 grad center"), 960, 150);
    this.s3 = at(h("div", { class: "sub center" }, "Now Playing, with artwork, for Music and Spotify."), 960, 228);
    this.progressFill = h("div", { style: { position: "absolute", left: 0, top: 0, bottom: 0, borderRadius: "5px", background: "#fff" } });
    this.elapsed = h("span", {}, "1:10");
    this.remaining = h("span", {}, "-2:42");
    this.now = at(h("div", { class: "glass", style: { width: "940px", height: "320px", borderRadius: "40px", display: "flex", alignItems: "center", gap: "44px", padding: "0 44px" } },
      h("div", { style: { width: "240px", height: "240px", borderRadius: "26px", flex: "none", background: "radial-gradient(circle at 70% 22%, rgba(238,243,255,0.95) 0%, rgba(160,178,222,0.55) 14%, transparent 34%), radial-gradient(circle at 25% 80%, #4c5a80 0%, transparent 55%), linear-gradient(160deg, #2b3246, #0e1016 75%)", boxShadow: "0 24px 50px rgba(0,0,0,0.5)" } }),
      h("div", { style: { flex: 1 } },
        h("div", { class: "eyebrow", style: { fontSize: "17px", marginBottom: "14px" } }, "Now playing"),
        h("div", { style: { font: "680 52px/1.1 var(--font)", letterSpacing: "-0.03em" } }, "Night Drive"),
        h("div", { class: "sub", style: { fontSize: "30px", marginTop: "6px" } }, "Lumen · Afterglow"),
        h("div", { style: { position: "relative", height: "10px", borderRadius: "5px", background: "rgba(255,255,255,0.15)", marginTop: "38px" } }, this.progressFill),
        h("div", { style: { display: "flex", justifyContent: "space-between", font: "600 21px var(--font)", color: "#8d8f96", marginTop: "12px", fontVariantNumeric: "tabular-nums" } }, this.elapsed, this.remaining))), 960, 590);
    root.append(this.music, this.call, this.ind, this.indLabel, this.head, this.speakers, this.now, this.t1, this.s1, this.t2, this.s2, this.t3, this.s3);
  },
  update(t, { bg }) {
    const part = (a, b) => {
      const pin = ease.settle(prog(t, a - 0.05, a + 0.65));
      const pout = ease.leave(prog(t, b - 0.4, b - 0.05));
      return { o: pin * (1 - pout), y: (1 - pin) * 50 - pout * 30, blur: (1 - pin) * 12 + pout * 10 };
    };
    // A · per-app volume.
    const pa = part(A, B);
    const v = levelAt(SOUND.appSwipe, t);
    tf(this.music, { ...pa });
    tf(this.call, { ...pa, y: pa.y * 1.2, o: pa.o * ep(t, A - 0.05, A + 0.65) });
    drawWave(this.music.__wave, t, v / 100, 0.3);
    drawWave(this.call.__wave, t, 0.72, 1.7);
    this.music.__level.textContent = `${Math.round(v)}%`;
    this.call.__level.textContent = "72%";
    const g = SOUND.appSwipe;
    const hin = ease.settle(prog(t, g.down, g.down + 0.3)), hout = ease.leave(prog(t, g.lift + 0.45, g.lift + 0.67));
    tf(this.ind, { x: (1 - hin) * 40, o: hin * (1 - hout) * pa.o });
    this.ind.__set(v);
    tf(this.indLabel, { x: (1 - hin) * 40, o: hin * (1 - hout) * pa.o });
    reveal(this.t1, t, A - 0.05, B - 0.4, { rise: 0.3 });
    fade(this.s1, t, A + 0.25, B - 0.4);

    // B · device limits: the level stops at 60% with a nudge.
    const pb = part(B, C);
    const raw = levelAt(SOUND.limitSwipe, t);
    const hitAt = SOUND.limitSwipe.start + 0.43;
    const over = Math.max(0, raw - SOUND.limit);
    const nudge = t > hitAt ? Math.sin((t - hitAt) * 26) * Math.exp(-(t - hitAt) * 7) * 1.6 : 0;
    const shown = Math.min(raw, SOUND.limit) + Math.min(over, 4) * 0.25 + nudge;
    this.fill.style.width = `${shown}%`;
    this.knob.style.left = `${shown}%`;
    this.headLevel.textContent = `${Math.round(Math.min(raw, SOUND.limit))}%`;
    const flash = t > hitAt ? Math.exp(-(t - hitAt) * 2.5) : 0;
    this.limitMark.style.boxShadow = `0 0 ${30 * flash}px rgba(225,233,255,${flash})`;
    this.limitLabel.style.background = `rgba(${lerp(30, 242, flash)},${lerp(31, 242, flash)},${lerp(35, 244, flash)},0.94)`;
    this.limitLabel.style.color = flash > 0.5 ? "#141518" : "#f5f5f7";
    tf(this.head, { ...pb });
    tf(this.speakers, { ...pb, y: pb.y * 1.2 });
    reveal(this.t2, t, B - 0.05, C - 0.4, { rise: 0.3 });
    fade(this.s2, t, B + 0.25, C - 0.4);

    // C · Now Playing seek.
    const pc = part(C, S.end);
    tf(this.now, { ...pc, s: lerp(0.96, 1, ep(t, C - 0.15, C + 0.6)) });
    const p = levelAt(SOUND.seekSwipe, t);
    const total = 232;
    this.progressFill.style.width = `${p * 100}%`;
    const fmt = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
    this.elapsed.textContent = fmt(p * total);
    this.remaining.textContent = `-${fmt(total - p * total)}`;
    reveal(this.t3, t, C - 0.05, S.end - 0.4, { rise: 0.3 });
    fade(this.s3, t, C + 0.25, S.end - 0.4);
    bg.style.setProperty("--by", "50%");
    bg.style.setProperty("--ba", "0.5");
  },
};
