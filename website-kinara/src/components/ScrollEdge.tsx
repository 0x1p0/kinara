'use client';
import { useEffect, useRef } from 'react';
import { gsap } from 'gsap';
import { onScroll, prefersReducedMotion } from '@/engine';

/** Kinara's edge light, on the page. While you scroll, a line of light travels the edges of the
 * window: down the left, along the bottom, up the right and back along the top, one lap from the
 * top of the page to the end, rounding each corner. It looks like the app's EdgeGlow (a 4 pt core,
 * ends fading, glowing inward) and fades once you stop. One rounded-rect path, stroked three
 * times for core, glow and haze (the last two blurred); a dash keeps only the lit part, and a
 * radial mask fades its ends. Mask and blurs cover only a box around the light, so the rest of the
 * window is never repainted. Off under reduced motion. */
const LENGTH = 200;   // the lit part, in px along the edge
const INSET = 2;      // from the window's edge, so the core shows in full
const RADIUS = 14;    // the corners, close to a macOS window's

export function ScrollEdge() {
  const ref = useRef<SVGSVGElement>(null);
  useEffect(() => {
    const svg = ref.current;
    if (!svg || prefersReducedMotion()) return;
    const paths = Array.from(svg.querySelectorAll<SVGPathElement>('path'));
    const fade = svg.querySelector<SVGRadialGradientElement>('radialGradient')!;
    const mask = svg.querySelector<SVGMaskElement>('mask')!;
    const area = mask.querySelector('rect')!;
    const blurs = Array.from(svg.querySelectorAll<SVGFilterElement>('filter'));
    let perimeter = 1;
    let start = 0;

    const layout = () => {
      const w = innerWidth, h = innerHeight;
      const x0 = INSET, y0 = INSET, x1 = w - INSET, y1 = h - INSET, r = RADIUS;
      svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
      // Down the left edge first, so the first scroll moves the light the way the page moves.
      const d = `M${x0} ${y0 + r}V${y1 - r}A${r} ${r} 0 0 0 ${x0 + r} ${y1}H${x1 - r}` +
        `A${r} ${r} 0 0 0 ${x1} ${y1 - r}V${y0 + r}A${r} ${r} 0 0 0 ${x1 - r} ${y0}H${x0 + r}` +
        `A${r} ${r} 0 0 0 ${x0} ${y0 + r}Z`;
      for (const p of paths) p.setAttribute('d', d);
      perimeter = paths[0].getTotalLength() || 1;
      // At the top of the page the light hangs from the top-left corner.
      start = LENGTH / 2;
      for (const p of paths) p.style.strokeDasharray = `${LENGTH} ${perimeter - LENGTH}`;
      fade.setAttribute('r', String(LENGTH / 2));
      place(lastProgress);
    };

    let lastProgress = 0;
    const place = (progress: number) => {
      lastProgress = progress;
      const along = (start + Math.min(1, Math.max(0, progress)) * perimeter) % perimeter;
      const point = paths[0].getPointAtLength(along);
      const offset = String(-((along - LENGTH / 2 + perimeter) % perimeter));
      for (const p of paths) p.style.strokeDashoffset = offset;
      fade.setAttribute('cx', String(point.x));
      fade.setAttribute('cy', String(point.y));
      // Mask and blur only the light's neighbourhood.
      const box = LENGTH / 2 + 48;
      for (const el of [mask, area, ...blurs]) {
        el.setAttribute('x', String(point.x - box));
        el.setAttribute('y', String(point.y - box));
        el.setAttribute('width', String(box * 2));
        el.setAttribute('height', String(box * 2));
      }
    };

    layout();
    addEventListener('resize', layout);
    let shown = false;
    let rest: gsap.core.Tween | null = null;
    const off = onScroll(({ progress, velocity }) => {
      place(progress);
      // Smooth scrolling creeps for a while after the wheel stops; only real movement keeps it lit.
      if (Math.abs(velocity) < 0.6) return;
      if (!shown) {
        shown = true;
        gsap.to(svg, { opacity: 1, duration: 0.18, ease: 'power1.out', overwrite: 'auto' });
      }
      // Like lifting a finger: a moment after the page settles, the light lets go.
      rest?.kill();
      rest = gsap.delayedCall(0.25, () => {
        shown = false;
        gsap.to(svg, { opacity: 0, duration: 0.35, ease: 'power1.in', overwrite: 'auto' });
      });
    });
    return () => {
      off();
      rest?.kill();
      gsap.killTweensOf(svg);
      removeEventListener('resize', layout);
    };
  }, []);
  return (
    <svg ref={ref} className="scroll-edge" aria-hidden="true" focusable="false">
      <defs>
        <radialGradient id="scroll-edge-fade" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="100">
          <stop offset="0" stopColor="#fff" />
          <stop offset="0.55" stopColor="#fff" />
          <stop offset="1" stopColor="#000" />
        </radialGradient>
        <mask id="scroll-edge-mask" maskUnits="userSpaceOnUse" x="0" y="0" width="0" height="0">
          <rect x="0" y="0" width="0" height="0" fill="url(#scroll-edge-fade)" />
        </mask>
        <filter id="scroll-edge-haze" filterUnits="userSpaceOnUse" x="0" y="0" width="0" height="0">
          <feGaussianBlur stdDeviation="11" />
        </filter>
        <filter id="scroll-edge-glow" filterUnits="userSpaceOnUse" x="0" y="0" width="0" height="0">
          <feGaussianBlur stdDeviation="3.5" />
        </filter>
      </defs>
      <g mask="url(#scroll-edge-mask)">
        <path className="scroll-edge__haze" filter="url(#scroll-edge-haze)" />
        <path className="scroll-edge__glow" filter="url(#scroll-edge-glow)" />
        <path className="scroll-edge__core" />
      </g>
    </svg>
  );
}
