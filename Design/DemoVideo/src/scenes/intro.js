// 0–7.5 s. Darkness, a trackpad, and a line of light tracing its edges. The
// light rises up the right edge as Sway's swipe, then the trackpad folds into
// the app icon (the icon *is* a trackpad).
import { h, at, tf, words, reveal } from "../ui.js";
import { prog, ease, lerp, spring, ep } from "../timeline.js";

// Fractions shared with the icon, so the trackpad morphs into it seamlessly.
export const TRACK = { top: 0.153, bottom: 0.847, tipLow: 0.813, tipHigh: 0.388, iconX: 0.812 };

function perimeter(w, hgt, r) {
  const x = w / 2, y = hgt / 2;
  return `M0,${-y} H${x - r} A${r},${r} 0 0 1 ${x},${-y + r} V${y - r} A${r},${r} 0 0 1 ${x - r},${y} H${-x + r} A${r},${r} 0 0 1 ${-x},${y - r} V${-y + r} A${r},${r} 0 0 1 ${-x + r},${-y} Z`;
}

export default {
  id: "intro",
  pre: 0,
  post: 0.3,
  mount(root) {
    this.wrap = at(h("div", { style: { width: "1920px", height: "1080px", transformStyle: "preserve-3d" } }), 960, 540);
    this.wrap.innerHTML = `
    <svg width="1920" height="1080" viewBox="-960 -540 1920 1080" style="overflow:visible">
      <defs>
        <linearGradient id="padFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#17181b"/><stop offset="1" stop-color="#0c0c0e"/></linearGradient>
        <linearGradient id="padIcon" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3a3a3e"/><stop offset="0.55" stop-color="#1e1e21"/><stop offset="1" stop-color="#121214"/></linearGradient>
        <linearGradient id="padStreak" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#eef3ff" stop-opacity="0.95"/><stop offset="1" stop-color="#9fb0d6" stop-opacity="0.12"/></linearGradient>
        <radialGradient id="padGlow"><stop offset="0" stop-color="#e6edff" stop-opacity="0.6"/><stop offset="0.35" stop-color="#c9d6ff" stop-opacity="0.18"/><stop offset="1" stop-color="#c9d6ff" stop-opacity="0"/></radialGradient>
        <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="9"/></filter>
        <filter id="softer" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="22"/></filter>
      </defs>
      <g class="pad">
        <rect class="shadow" fill="#000" opacity="0.7" filter="url(#softer)"/>
        <rect class="body" fill="url(#padFill)"/>
        <rect class="iconbody" fill="url(#padIcon)" opacity="0"/>
        <rect class="rim" fill="none" stroke="#fff" stroke-opacity="0.09" stroke-width="2"/>
        <rect class="track left" fill="#fff" opacity="0"/>
        <rect class="track right" fill="#fff" opacity="0"/>
        <path class="comet glow" fill="none" stroke="#dfe7ff" stroke-width="12" stroke-linecap="round" filter="url(#soft)"/>
        <path class="comet core" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round"/>
        <rect class="streak" fill="url(#padStreak)"/>
        <circle class="glow2" fill="url(#padGlow)"/>
        <circle class="tip" fill="#fff"/>
      </g>
    </svg>`;
    root.append(this.wrap);
    const q = (s) => this.wrap.querySelector(s);
    this.el = { pad: q(".pad"), shadow: q(".shadow"), body: q(".body"), icon: q(".iconbody"), rim: q(".rim"), left: q(".track.left"), right: q(".track.right"), glow: q(".comet.glow"), core: q(".comet.core"), streak: q(".streak"), glow2: q(".glow2"), tip: q(".tip") };
    this.line1 = at(words("Every trackpad has edges.", "h2 grad center"), 960, 168);
    this.line2 = at(words("Until now, they did nothing.", "h2 grad center"), 960, 168);
    root.append(this.line1, this.line2);
  },
  update(t, { bg }) {
    const e = this.el;
    const morph = ease.inOut(prog(t, 6.25, 7.5));
    const w = lerp(900, 300, morph), hh = lerp(560, 300, morph), r = lerp(50, 72, morph);
    const cy = lerp(95, -85, morph);
    const tilt = lerp(lerp(40, 30, ease.smooth(prog(t, 0, 6.3))), 0, morph);
    const push = lerp(lerp(1, 1.05, ease.smooth(prog(t, 0, 6.3))), 1, morph);
    this.wrap.style.transform = `translate(-50%, -50%) translateY(${cy}px) rotateX(${tilt}deg) scale(${push})`;
    this.wrap.style.opacity = String(ep(t, 0.15, 1.4) * (1 - prog(t, 7.4, 7.65)));

    const set = (el, a) => { for (const [k, v] of Object.entries(a)) el.setAttribute(k, typeof v === "number" ? v.toFixed(2) : v); };
    const box = { x: -w / 2, y: -hh / 2, width: w, height: hh, rx: r };
    set(e.body, box);
    set(e.icon, { ...box, opacity: morph });
    set(e.rim, { ...box, "stroke-opacity": lerp(0.09, 0.14, morph) });
    set(e.shadow, { x: -w / 2 + 10, y: -hh / 2 + 34, width: w - 20, height: hh, rx: r, opacity: 0.75 });

    // A comet of light traces the whole edge once.
    const path = perimeter(w, hh, r);
    const length = 2 * (w + hh) - 8 * r + 2 * Math.PI * r;
    const travel = ease.inOut(prog(t, 0.75, 3.35)) * (length * 1.18);
    const segment = length * 0.17;
    const cometO = Math.min(ep(t, 0.75, 1.1), 1 - prog(t, 3.0, 3.45));
    for (const el of [e.glow, e.core]) set(el, { d: path, "stroke-dasharray": `${segment} ${length * 2}`, "stroke-dashoffset": segment - travel, opacity: cometO * (el === e.glow ? 0.8 : 1) });

    // Quiet tracks, then the swipe rising up the right one.
    const inset = lerp(0.07, 0.188, morph);
    const trackW = lerp(30, 21, morph);
    const tracksO = ep(t, 3.2, 4.2) * lerp(0.07, 0.055, morph);
    const ty0 = -hh / 2 + hh * TRACK.top, ty1 = -hh / 2 + hh * TRACK.bottom;
    const lx = -w / 2 + w * inset, rx = w / 2 - w * inset;
    set(e.left, { x: lx - trackW / 2, y: ty0, width: trackW, height: ty1 - ty0, rx: trackW / 2, opacity: tracksO });
    set(e.right, { x: rx - trackW / 2, y: ty0, width: trackW, height: ty1 - ty0, rx: trackW / 2, opacity: tracksO });

    const rise = spring(t - 3.75, 1.15, 0.86);
    const p = lerp(0, 0.62, rise);
    const tipY = -hh / 2 + hh * lerp(TRACK.tipLow, TRACK.tipHigh, p);
    const tipO = ep(t, 3.6, 3.95);
    const pulse = 1 + 0.06 * Math.sin((t - 4) * 2.4) * ep(t, 5, 6);
    set(e.streak, { x: rx - trackW / 2, y: tipY - trackW / 2, width: trackW, height: Math.max(trackW, ty1 - tipY + trackW / 2), rx: trackW / 2, opacity: tipO });
    set(e.glow2, { cx: rx, cy: tipY, r: lerp(210, 80, morph) * pulse, opacity: tipO });
    set(e.tip, { cx: rx, cy: tipY, r: lerp(17, 12.5, morph), opacity: tipO });

    reveal(this.line1, t, 1.45, 3.85);
    reveal(this.line2, t, 4.15, 6.2);
    bg.style.setProperty("--by", "60%");
    bg.style.setProperty("--ba", String(0.25 + 0.3 * ep(t, 0.5, 4)));
  },
};
