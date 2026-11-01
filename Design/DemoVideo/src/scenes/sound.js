// After the mixer: cap headphones at a safe level, then seek with Now Playing.
import { h, at, tf, words, reveal, fade, glyph } from "../ui.js";
import { prog, ease, lerp, spring, ep, clamp, SCENES, SOUND, levelAt, BAR } from "../timeline.js";

const S = SCENES.find((s) => s.id === "sound");
const B = S.start, C = S.start + BAR;

export default {
  id: "sound",
  pre: 0.5,
  post: 0.5,
  mount(root) {

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
    root.append(this.head, this.speakers, this.now, this.t2, this.s2, this.t3, this.s3);
  },
  update(t, { bg }) {
    const part = (a, b) => {
      const pin = ease.settle(prog(t, a - 0.05, a + 0.65));
      const pout = ease.leave(prog(t, b - 0.4, b - 0.05));
      return { o: pin * (1 - pout), y: (1 - pin) * 50 - pout * 30, blur: (1 - pin) * 12 + pout * 10 };
    };
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
