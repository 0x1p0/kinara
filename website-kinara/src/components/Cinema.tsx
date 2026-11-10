'use client';
import { useRef, useState } from 'react';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { prefersReducedMotion, scrollToTarget } from '@/engine';
import { usePage } from '@/engine/next';

/** The film, shown big: a silent montage plays in a window that opens to the full screen as you
 * scroll, Apple style. Play swaps in the full 86-second film with sound, right there. The hero's
 * "Watch the film" scrolls here and starts it. */
export function Cinema() {
  const root = useRef<HTMLElement>(null);
  const [playing, setPlaying] = useState(false);
  const api = useRef({ play: () => {} });

  usePage(() => {
    const section = root.current!;
    const frame = section.querySelector<HTMLElement>('.cine__frame')!;
    const head = section.querySelector<HTMLElement>('.cine__head')!;
    const preview = section.querySelector<HTMLVideoElement>('.cine__preview')!;
    const reduced = prefersReducedMotion();
    const offs: (() => void)[] = [];
    let st: ScrollTrigger | null = null;

    // Where the window starts (a centred screen under the headline) and ends (edge to edge, or
    // a full-width 16:9 band on tall screens).
    const shape = (q: number) => {
      const w = innerWidth, h = innerHeight;
      const t = gsap.utils.interpolate(Math.max(h * 0.36, 230), w / h < 1.25 ? Math.max(0, (h - (w * 9) / 16) / 2) : 0, q);
      const b = gsap.utils.interpolate(h * 0.08, w / h < 1.25 ? Math.max(0, (h - (w * 9) / 16) / 2) : 0, q);
      const x = gsap.utils.interpolate(w < 735 ? w * 0.06 : w * 0.17, 0, q);
      const r = gsap.utils.interpolate(28, 0, q);
      frame.style.clipPath = `inset(${t}px ${x}px ${b}px ${x}px round ${r}px)`;
      gsap.set(preview, { scale: gsap.utils.interpolate(1.12, 1, q) });
    };

    if (!reduced) {
      st = ScrollTrigger.create({
        trigger: section, start: 'top top', end: '+=130%', pin: true, scrub: true, invalidateOnRefresh: true,
        onUpdate: (self) => {
          const q = gsap.parseEase('power2.inOut')(Math.min(1, self.progress / 0.75));
          shape(q);
          gsap.set(head, { autoAlpha: 1 - Math.min(1, self.progress / 0.35), y: -60 * Math.min(1, self.progress / 0.35) });
        },
        onRefresh: (self) => shape(gsap.parseEase('power2.inOut')(Math.min(1, self.progress / 0.75))),
      });
      offs.push(() => st?.kill());
    } else {
      frame.style.clipPath = 'none';
    }

    // The montage plays only while the section is on screen; the full film pauses when you leave.
    const io = new IntersectionObserver(([e]) => {
      const full = section.querySelector<HTMLVideoElement>('.cine__full');
      if (e.isIntersecting) { if (!full && !reduced) { preview.preload = 'auto'; preview.play().catch(() => {}); } }
      else { preview.pause(); full?.pause(); }
    }, { threshold: 0.2 });
    io.observe(section);
    offs.push(() => io.disconnect());

    const play = () => {
      if (st) scrollToTarget(st.start + (st.end - st.start) * 0.8);
      else section.scrollIntoView({ behavior: 'auto' });
      preview.pause();
      setPlaying(true);
    };
    api.current.play = play;
    const fromHero = () => play();
    addEventListener('kinara:film', fromHero);
    offs.push(() => removeEventListener('kinara:film', fromHero));
    return () => offs.forEach((o) => o());
  });

  return (
    <section ref={root} id="film" className="cine" aria-labelledby="film-title">
      <div className="cine__head">
        <p className="t-eyebrow grad">The film</p>
        <h2 id="film-title" className="t-hero">See it in motion.</h2>
      </div>
      <div className="cine__frame">
        <video className="cine__preview" src="/media/film-preview.mp4" poster="/media/film-preview.jpg" muted loop playsInline preload="none" aria-hidden="true" />
        {playing && <video className="cine__full" src="/media/kinara-film.mp4" poster="/media/film-poster.jpg" controls autoPlay playsInline aria-label="The Kinara film" />}
        {!playing && (
          <button type="button" className="cine__play" onClick={() => api.current.play()}>
            <span className="cine__disc" aria-hidden="true"><svg width="20" height="22" viewBox="0 0 20 22"><path d="M2 1.5v19L19 11z" fill="currentColor" /></svg></span>
            <span>Play the film<small>1 min 48 s, with sound</small></span>
          </button>
        )}
      </div>
    </section>
  );
}
