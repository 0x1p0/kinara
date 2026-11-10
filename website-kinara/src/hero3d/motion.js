// Easing and gesture helpers, copied from the film's score (Design/DemoVideo/src/timeline.js)
// so the hero moves with exactly the film's curves.

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, p) => a + (b - a) * p;
/** 0 before a, 1 after b, linear between. */
export const prog = (t, a, b) => clamp((t - a) / (b - a));

/** CSS-style cubic-bezier easing, solved with Newton steps and bisection. */
export function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = (t) => ((ax * t + bx) * t + cx) * t;
  const sy = (t) => ((ay * t + by) * t + cy) * t;
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 6; i++) {
      const e = sx(t) - x;
      const d = dx(t);
      if (Math.abs(e) < 1e-6) return sy(t);
      if (Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    let lo = 0, hi = 1;
    t = x;
    for (let i = 0; i < 30; i++) {
      const v = sx(t);
      if (Math.abs(v - x) < 1e-6) break;
      if (x > v) lo = t; else hi = t;
      t = (lo + hi) / 2;
    }
    return sy(t);
  };
}

export const ease = {
  settle: bezier(0.16, 1, 0.3, 1), // Sway's HUD entrance: fast out, gentle settle
  leave: bezier(0.4, 0, 1, 1), // Sway's HUD exit
  inOut: bezier(0.65, 0, 0.35, 1),
  smooth: bezier(0.45, 0, 0.2, 1),
  out: bezier(0.22, 1, 0.36, 1),
  in: bezier(0.55, 0, 0.9, 0.4),
  expoOut: (p) => (p >= 1 ? 1 : 1 - Math.pow(2, -10 * p)),
  linear: (p) => p,
};

/** SwiftUI-style spring(response, dampingFraction), evaluated at seconds since start. */
export function spring(seconds, response = 0.4, damping = 0.8) {
  if (seconds <= 0) return 0;
  const w0 = (2 * Math.PI) / response;
  if (damping >= 1) return 1 - (1 + w0 * seconds) * Math.exp(-w0 * seconds);
  const wd = w0 * Math.sqrt(1 - damping * damping);
  const decay = Math.exp(-damping * w0 * seconds);
  return 1 - decay * (Math.cos(wd * seconds) + ((damping * w0) / wd) * Math.sin(wd * seconds));
}

/** Eased progress between a and b. */
export const ep = (t, a, b, curve = ease.settle) => curve(prog(t, a, b));

/** Deterministic pseudo-random numbers. */
export function seeded(seed = 1) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let r = Math.imul(s ^ (s >>> 15), 1 | s);
    r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------- gestures

/** A one-finger swipe: touch down, slide a level from → to, lift. */
export const swipe = (down, start, end, lift, from, to, curve = ease.inOut) => ({ down, start, end, lift, from, to, curve });
export const levelAt = (g, t) => lerp(g.from, g.to, g.curve(prog(t, g.start, g.end)));
/** Times at which a swipe's level crosses each multiple of step (for haptic ticks). */
export function crossings(g, step, notch = 50) {
  const out = [];
  let previous = Math.floor(g.from / step);
  for (let i = 1; i <= 400; i++) {
    const t = lerp(g.start, g.end, i / 400);
    const v = levelAt(g, t);
    const index = Math.floor(v / step);
    if (index !== previous) {
      const value = Math.max(index, previous) * step;
      out.push({ t, value, notch: Math.abs(value - notch) < 0.01 });
      previous = index;
    }
  }
  return out;
}

