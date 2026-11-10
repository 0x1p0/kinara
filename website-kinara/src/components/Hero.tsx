'use client';
import { useRef } from 'react';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { prefersReducedMotion } from '@/engine';
import type { HeroRect as Rect, HeroScene } from '@/hero3d/scene';
import { usePage } from '@/engine/next';
import { FilmButton } from '@/components/FilmButton';
import { hero, site, story } from '@/data/site';

// The hero is the film's own 3D scene (src/hero3d), rendered live at the screen's resolution and
// driven by scroll: scroll moves a playhead through a choreographed 12-second sequence, and the
// shown pose follows it at no more than the film's own speed, so every move reads.
/** The dive (0 → 1.75 s) plays once on load; scroll scrubs from here to the end (12 s). */
const OPEN = 1.75;
const END = 12;
/** The shown pose never runs faster than real time. */
const MAX_SPEED = 1;
const IR = 16 / 9;
/** Where the settled pad sits in the camera's 16:9 picture (fractions of it; the right edge allows
 * for the lean during brightness). */
const PAD = { l: 0.21, r: 0.86, t: 0.3, b: 0.62 };
/** Each beat's window on the sequence clock (seconds). Captions and cards live only inside it. */
const BEATS = [
  { from: 2.25, to: 4.75 },
  { from: 4.95, to: 7.55 },
  { from: 7.75, to: 10.1 },
  { from: 10.15, to: 12.01 },
];
const clamp = (v: number) => Math.min(1, Math.max(0, v));
const lerp = (a: number, b: number, k: number) => a + (b - a) * k;
const smooth = (a: number, b: number, x: number) => { const t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t); };
/** 0 → 1 over the first 0.35 s of a window, 1 → 0 over its last 0.35 s. */
const inside = (t: number, win: { from: number; to: number }) => smooth(win.from, win.from + 0.35, t) * (1 - smooth(win.to - 0.35, win.to, t));

const clipRows = [
  { text: 'Meet at 7:30 by the north entrance.', from: 'Messages · Just now', icon: 'M4 11.5c0-4 3.6-7 8-7s8 3 8 7-3.6 7-8 7c-1 0-2-.1-2.9-.4L5 19.5l1.2-3.4C4.8 14.9 4 13.3 4 11.5z' },
  { text: 'Flight 1024 · Seat 14C · Boarding 6:05', from: 'Mail · 2 min ago', icon: 'M3.5 6h17v12.5h-17zM4.5 7.5l7.5 6 7.5-6' },
  { text: 'Image', from: '1440 × 900 · Safari · 4 min ago', icon: '', image: true },
  { text: 'The edges of your trackpad, as controls.', from: 'Notes · 6 min ago', icon: 'M6 4h12v16.5H6zM9 9h6M9 12.5h6M9 16h4' },
];

export function Hero() {
  const root = useRef<HTMLElement>(null);

  usePage(() => {
    const section = root.current!;
    const canvas = section.querySelector<HTMLCanvasElement>('.seq')!;
    const poster = section.querySelector<HTMLImageElement>('.hero__poster')!;
    const copy = section.querySelector<HTMLElement>('.hero__copy')!;
    const beats = [...section.querySelectorAll<HTMLElement>('.beat')];
    const cards = beats.map((b) => b.querySelector<HTMLElement>('.k-card'));
    const rows = [...section.querySelectorAll<HTMLElement>('.k-clip__row')];
    const clipCard = section.querySelector<HTMLElement>('.k-clip')!;
    const music = section.querySelector<HTMLElement>('.k-mix__row--front')!;
    const hud = section.querySelector<HTMLElement>('.k-hud')!;
    const pills = [...section.querySelectorAll<HTMLElement>('.k-pill')];
    const reduced = prefersReducedMotion();
    section.classList.toggle('is-still', reduced);
    const offs: (() => void)[] = [];
    let dead = false;

    // ------------------------------------------------------------ the scene
    // three.js loads after first paint; until then (and without WebGL) the poster stands in.
    let gl: HeroScene | null = null;
    let sampled = false;
    import('@/hero3d/scene').then(({ createHero }) => {
      if (dead) return;
      try {
        // Multisampling at full Retina resolution is what costs frames; dense screens barely
        // need it, so they get 2× and standard ones 4×.
        gl = createHero(canvas, { surfaceScale: innerWidth < 760 ? 0.5 : 0.75, samples: devicePixelRatio >= 2 ? 2 : 4 });
        gl.setTheme(isDark());
        layout();
      } catch {
        poster.src = poster.dataset.fallback!;
        poster.removeAttribute('srcset');
        section.classList.add('is-fallback');
      }
    });
    offs.push(() => { gl?.dispose(); gl = null; });

    // ------------------------------------------------------------ light or dark studio
    // The studio follows the page: the toggle (data-theme) or, until it's used, the system.
    const isDark = () => {
      const t = document.documentElement.dataset.theme;
      return t ? t === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    };
    const retheme = () => {
      if (!gl) return;
      gl.setTheme(isDark());
      // Redraw now, and let the stage take the new studio's colour.
      sampled = false;
      lastShown = -1;
    };
    const themeWatch = new MutationObserver(retheme);
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    const scheme = matchMedia('(prefers-color-scheme: dark)');
    scheme.addEventListener('change', retheme);
    offs.push(() => { themeWatch.disconnect(); scheme.removeEventListener('change', retheme); });

    // ------------------------------------------------------------ framing
    // The camera's 16:9 picture can sit anywhere on the canvas (the studio carries on around it),
    // so the pad is framed like a shot. Two placements: under the headline (opening), and beside
    // the captions (story). Wide screens put the pad on the right with a caption column on the left;
    // narrow ones keep it centred, captions above and cards below.
    let w = 1, h = 1, side = false;
    // Up to 2× the CSS pixels, but no more than ~6.5 million in all, so large displays stay smooth.
    const density = () => Math.min(devicePixelRatio || 1, 2, Math.sqrt(6.5e6 / Math.max(1, w * h)));
    let open: Rect = { x: 0, y: 0, w: 1, h: 1 }, story: Rect = open;
    const rect: Rect = { ...open };
    const layout = () => {
      const r = canvas.getBoundingClientRect();
      w = r.width; h = r.height;
      gl?.resize(w, h, density());
      const base = w / h >= 1 ? Math.max(w, h * IR) : w * 1.45;
      const padH = (fw: number) => (PAD.b - PAD.t) * (fw / IR);
      // Opening: the settled pad sits just under the headline block.
      const below = copy.offsetTop + copy.offsetHeight + (w < 760 ? 28 : 40);
      const s0 = Math.max(0.5, Math.min(1, (h - 24 - below) / padH(base)));
      const ow = base * s0;
      open = { w: ow, h: ow / IR, x: (w - ow) / 2, y: below - PAD.t * (ow / IR) };
      // Story: on landscape screens a caption column on the left and the pad filling the space
      // to its right; otherwise stacked.
      const gutter = Math.max(32, w * 0.04);
      const col = Math.min(440, Math.max(340, w * 0.3));
      side = w >= 960 && w / h >= 1.1;
      section.classList.toggle('is-side', side);
      if (side) {
        const left = gutter + col + 40, right = w - gutter;
        const sw = Math.min(base * 0.86, (right - left) / (PAD.r - PAD.l)), sh = sw / IR;
        const sx = (left + right) / 2 - ((PAD.l + PAD.r) / 2) * sw;
        story = { w: sw, h: sh, x: sx, y: h * 0.56 - ((PAD.t + PAD.b) / 2) * sh };
        section.style.setProperty('--col', `${col}px`);
        section.style.setProperty('--side-x', `${gutter}px`);
      } else {
        // Centred between the caption (top) and the card (bottom).
        const top = 52 + h * 0.06 + (w < 760 ? 150 : 190), bottom = h - h * 0.06 - (w < 760 ? 250 : 300);
        const s1 = Math.max(0.45, Math.min(1, (bottom - top) / padH(base)));
        const fw = base * s1, fh = fw / IR;
        story = { w: fw, h: fh, x: (w - fw) / 2, y: (top + bottom) / 2 - ((PAD.t + PAD.b) / 2) * fh };
      }
      lastShown = -1;
    };

    const draw = (t: number) => {
      if (!gl) return;
      const k = reduced ? 0 : smooth(1.85, 2.7, t);
      rect.w = lerp(open.w, story.w, k); rect.h = rect.w / IR;
      rect.x = lerp(open.x, story.x, k); rect.y = lerp(open.y, story.y, k);
      gl.render(t, rect);
      if (!sampled) {
        // The stage around the canvas takes the render's own background, so there is no seam.
        const [r, g, b] = gl.corner();
        section.style.background = `rgb(${r} ${g} ${b})`;
        poster.style.visibility = 'hidden';
        sampled = true;
      }
    };

    // ------------------------------------------------------------ playhead
    // On load the dive plays once (unless the page opens scrolled); then scroll moves the
    // playhead from the opening to the end, and the shown pose glides after it.
    const intro = { t: reduced || scrollY > 40 ? OPEN : 0 };
    let progress = 0;
    if (!reduced) {
      const st = ScrollTrigger.create({
        trigger: section, start: 'top top', end: '+=800%', pin: true, invalidateOnRefresh: true,
        onUpdate: (self) => { progress = self.progress; },
      });
      offs.push(() => st.kill());
      if (intro.t < OPEN) {
        let started = false;
        const play = () => {
          if (started || dead) return;
          started = true;
          gsap.to(intro, { t: OPEN, duration: 3, ease: 'power2.inOut' });
        };
        const wait = gsap.delayedCall(1.4, play);
        const ready = () => { if (gl) play(); else if (!started) gsap.delayedCall(0.05, ready); };
        ready();
        offs.push(() => { wait.kill(); gsap.killTweensOf(intro); });
      }
    }
    const target = () => intro.t + progress * (END - OPEN);

    // ------------------------------------------------------------ overlays on the sequence clock
    const musicFill = music.querySelector<HTMLElement>('.k-mix__fill')!;
    const musicNum = music.querySelector<HTMLElement>('b')!;
    const hudFill = hud.querySelector<HTMLElement>('.k-hud__fill')!;
    const overlays = (t: number) => {
      if (!reduced) gsap.set(copy, { autoAlpha: 1 - smooth(1.8, 2.25, t), y: -32 * smooth(1.75, 2.3, t) });
      BEATS.forEach((b, i) => {
        const a = reduced ? 0 : inside(t, b);
        gsap.set(beats[i], { autoAlpha: a, y: (1 - a) * 14 });
        if (cards[i]) gsap.set(cards[i], { scale: 0.97 + 0.03 * a });
      });
      // Clipboard: the highlight follows the finger down the edge (3.0–4.2), then it pastes.
      const pick = Math.min(rows.length - 1, Math.floor(smooth(3.0, 4.2, t) * rows.length * 0.999));
      rows.forEach((r, i) => r.classList.toggle('is-on', i === pick));
      clipCard.classList.toggle('is-pasted', t > 4.3);
      // Per-app volume: Music follows the edge from 80% to 30% (5.2–6.8); the others hold.
      const v = 0.8 - 0.5 * smooth(5.2, 6.8, t);
      musicFill.style.scale = `${v} 1`;
      musicNum.textContent = `${Math.round(v * 100)}%`;
      // Brightness: 80% to 45% (8.0–9.5).
      hudFill.style.scale = `${0.8 - 0.35 * smooth(8.0, 9.5, t)} 1`;
      // Corners: each action appears beside its corner as it is tapped.
      const p1 = smooth(10.35, 10.6, t), p2 = smooth(10.95, 11.2, t), out = 1 - smooth(11.7, 12, t);
      // One place for every pill, centred over the pad, one at a time: the ripple shows the corner.
      const x = rect.x + ((PAD.l + PAD.r) / 2 - 0.03) * rect.w, top = rect.y + PAD.t * rect.h - 22;
      gsap.set(pills[0], { x, y: top, xPercent: -50, yPercent: -100, autoAlpha: p1 * (1 - p2) * out, scale: 0.92 + 0.08 * p1 });
      gsap.set(pills[1], { x, y: top, xPercent: -50, yPercent: -100, autoAlpha: p2 * out, scale: 0.92 + 0.08 * p2 });
    };

    let shown = target(), speed = 0, lastTime = 0, lastShown = -1;
    const ro = new ResizeObserver(layout);
    ro.observe(canvas);
    offs.push(() => ro.disconnect());
    layout();

    const tick = (time: number) => {
      const dt = Math.min(0.05, lastTime ? time - lastTime : 1 / 60);
      lastTime = time;
      // The shown pose follows the playhead, but never faster than the film itself: a quick
      // flick still plays every move at its own pace. It eases into motion and out of it.
      const goal = target();
      const want = Math.max(-MAX_SPEED, Math.min(MAX_SPEED, (goal - shown) * 3));
      speed += (want - speed) * (1 - Math.exp(-dt * 6));
      shown += speed * dt;
      if (Math.abs(goal - shown) < 0.001 && Math.abs(speed) < 0.02) { shown = goal; speed = 0; }
      // Draw only when the pose changes (or the layout did); a still page costs nothing.
      if (shown !== lastShown) { draw(shown); overlays(shown); lastShown = shown; }
    };
    gsap.ticker.add(tick);
    offs.push(() => gsap.ticker.remove(tick));

    return () => { dead = true; poster.style.visibility = ''; section.style.background = ''; offs.forEach((off) => off()); };
  });

  const ico = (d: string) => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>;

  const cards = [
    <div key="clip" className="k-card k-clip" aria-hidden="true">
      <div className="k-card__head">
        <span className="k-clip__search">{ico('M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM20 20l-4.6-4.6')}Search clipboard</span>
        <span className="k-clip__state"><i>4 copies</i><b>Pasted</b></span>
      </div>
      {clipRows.map((r) => (
        <div key={r.text} className="k-clip__row">
          {r.image ? <span className="k-app k-app--picture" /> : <span className="k-app">{ico(r.icon)}</span>}
          <span className="k-clip__text"><b>{r.text}</b><small>{r.from}</small></span>
        </div>
      ))}
      <div className="k-card__foot">Slide to choose · Lift to paste · Type to search</div>
    </div>,
    <div key="mix" className="k-card k-mix" aria-hidden="true">
      <div className="k-card__head"><span>Apps</span><span>Mixer</span></div>
      <div className="k-mix__row k-mix__row--front">
        <span className="k-app k-app--color" style={{ background: 'linear-gradient(180deg,#fb5c74,#fa233b)' }}>{ico('M9 18V6l10-2v12M9 18a2.5 2.5 0 1 1-2.5-2.5A2.5 2.5 0 0 1 9 18zm10-2a2.5 2.5 0 1 1-2.5-2.5A2.5 2.5 0 0 1 19 16z')}</span>
        <span className="k-mix__name">Music<small>In front</small></span><b>80%</b>
        <div className="k-mix__track"><div className="k-mix__fill" /></div>
      </div>
      <div className="k-mix__row">
        <span className="k-app k-app--color" style={{ background: 'linear-gradient(180deg,#5ee27d,#2fbf55)' }}>{ico('M15 10.5l5-3v9l-5-3M3.5 7h11v10h-11z')}</span>
        <span className="k-mix__name">FaceTime<small>On a call</small></span><b>100%</b>
        <div className="k-mix__track"><div className="k-mix__fill" style={{ scale: '1 1' }} /></div>
      </div>
      <div className="k-mix__row">
        <span className="k-app k-app--color" style={{ background: 'linear-gradient(180deg,#4fb4ff,#1677ff)' }}>{ico('M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM15.5 8.5l-2 5-5 2 2-5z')}</span>
        <span className="k-mix__name">Safari<small>Playing</small></span><b>70%</b>
        <div className="k-mix__track"><div className="k-mix__fill" style={{ scale: '0.7 1' }} /></div>
      </div>
    </div>,
    <div key="hud" className="k-card k-hud" aria-hidden="true">
      {ico('M12 7.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zM12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4')}
      <div className="k-hud__track"><div className="k-hud__fill" /></div>
    </div>,
  ];

  return (
    <section ref={root} className="hero" aria-labelledby="hero-title">
      {/* Until the scene draws: its opening frame (and, without WebGL, the settled pad). */}
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img className="hero__poster" src="/media/hero-dive.webp" srcSet="/media/hero-dive-m.webp 960w, /media/hero-dive.webp 1600w" sizes="100vw" width={1600} height={900} data-fallback="/media/hero-pad.webp" alt="Kinara's graphite trackpad, its edges lit" />
      <canvas className="seq" aria-hidden="true" />

      <div className="hero__copy">
        <p className="t-eyebrow grad" data-reveal="fade" data-intro>{hero.eyebrow}</p>
        <h1 id="hero-title" className="t-hero" data-split="lines" data-intro>{hero.title}</h1>
        <p className="t-intro" data-reveal="up" data-intro data-delay="0.2">{hero.lead}</p>
        <div className="ctas" data-reveal="up" data-intro data-delay="0.35">
          <a className="btn" href={site.downloadUrl} data-no-transition>Download</a>
          <FilmButton />
        </div>
        <p className="hero__price" data-reveal="fade" data-intro data-delay="0.5">{hero.price}</p>
      </div>

      <div className="beats">
        {story.map((b, i) => (
          <div key={b.title} className="beat">
            <div className="beat__text">
              <h2>{b.title}</h2>
              <p>{b.sub}</p>
            </div>
            {cards[i]}
          </div>
        ))}
      </div>
      <div className="k-corners" aria-hidden="true">
        <span className="k-pill"><span className="k-pill__ico">{ico('M8 4.5h8v3H8zM6 6h12v14H6z')}</span><span className="k-pill__text"><small>Top-right corner</small>Paste</span></span>
        <span className="k-pill"><span className="k-pill__ico">{ico('M3 5h8v6.5H3zM13 5h8v6.5h-8zM6.5 13.5h11V20h-11z')}</span><span className="k-pill__text"><small>Top-left corner</small>Mission Control</span></span>
      </div>
    </section>
  );
}
