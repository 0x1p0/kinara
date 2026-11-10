'use client';
import { useRef, useState } from 'react';
import { gsap } from 'gsap';
import { prefersReducedMotion } from '@/engine';
import { usePage } from '@/engine/next';
import { highlights } from '@/data/site';

/** "Get the highlights": clips from the film in a snapping gallery. The clip in view plays; when
 * it ends the gallery moves on, and the dot under it fills as it plays, like Apple's. */
export function Highlights() {
  const root = useRef<HTMLElement>(null);
  const [active, setActive] = useState(0);
  const [playing, setPlaying] = useState(true);
  const api = useRef<{ go: (i: number) => void; toggle: () => void }>({ go: () => {}, toggle: () => {} });

  usePage(() => {
    const section = root.current!;
    const track = section.querySelector<HTMLElement>('.hl__track')!;
    const cards = [...track.querySelectorAll<HTMLElement>('.hl__card')];
    const videos = cards.map((c) => c.querySelector('video')!);
    const fills = [...section.querySelectorAll<HTMLElement>('.hl__dot i')];
    let index = 0, inView = false, auto = !prefersReducedMotion();

    const go = (i: number) => {
      const card = cards[(i + cards.length) % cards.length];
      track.scrollTo({ left: card.offsetLeft - (track.clientWidth - card.clientWidth) / 2, behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
    };
    const sync = () => {
      videos.forEach((v, i) => {
        if (i === index && inView && auto) { if (v.preload !== 'auto') v.preload = 'auto'; v.play().catch(() => {}); }
        else v.pause();
      });
    };
    const toggle = () => { auto = !auto; setPlaying(auto); sync(); };
    api.current = { go, toggle };
    setPlaying(auto);

    const cardIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        const i = cards.indexOf(e.target as HTMLElement);
        if (i === index) return;
        videos[index].currentTime = 0;
        index = i;
        setActive(i);
        sync();
      });
    }, { root: track, threshold: 0.6 });
    cards.forEach((c) => cardIO.observe(c));
    const sectionIO = new IntersectionObserver(([e]) => { inView = e.isIntersecting; sync(); }, { threshold: 0.35 });
    sectionIO.observe(section);

    const offs: (() => void)[] = [];
    videos.forEach((v, i) => {
      const end = () => { if (i === index && auto) go(i + 1); };
      v.addEventListener('ended', end);
      offs.push(() => v.removeEventListener('ended', end));
    });
    // The active dot fills with the clip's progress, on the shared clock.
    const tick = () => {
      if (!inView) return;
      const v = videos[index];
      if (v.duration) gsap.set(fills[index], { scale: `${v.currentTime / v.duration} 1` });
    };
    gsap.ticker.add(tick);
    return () => { cardIO.disconnect(); sectionIO.disconnect(); gsap.ticker.remove(tick); offs.forEach((o) => o()); videos.forEach((v) => v.pause()); };
  });

  return (
    <section ref={root} id="highlights" className="hl" aria-labelledby="hl-title">
      <div className="wide hl__title">
        <h2 id="hl-title" className="t-headline" data-split="lines">Get the highlights.</h2>
      </div>
      <div className="hl__track" tabIndex={-1}>
        {highlights.map((h, i) => (
          <figure key={h.id} className="hl__card" aria-roledescription="slide" aria-label={`${i + 1} of ${highlights.length}`}>
            <video src={`/media/clips/${h.id}.mp4`} poster={`/media/clips/${h.id}.jpg`} muted playsInline preload="none" aria-hidden="true" />
            <figcaption><p><strong>{h.title}</strong> {h.body}</p></figcaption>
          </figure>
        ))}
      </div>
      <div className="hl__nav">
        <div className="hl__dots" role="tablist" aria-label="Highlights">
          {highlights.map((h, i) => (
            <button key={h.id} type="button" role="tab" aria-selected={i === active} aria-label={h.title}
              className={`hl__dot${i === active ? ' is-on' : ''}`} onClick={() => api.current.go(i)}><i /></button>
          ))}
        </div>
        <button type="button" className="hl__play" onClick={() => api.current.toggle()} aria-label={playing ? 'Pause the highlights' : 'Play the highlights'}>
          {playing
            ? <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><rect x="2" y="1" width="3.5" height="12" rx="1" fill="currentColor" /><rect x="8.5" y="1" width="3.5" height="12" rx="1" fill="currentColor" /></svg>
            : <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 1.2v11.6L12.6 7z" fill="currentColor" /></svg>}
        </button>
      </div>
    </section>
  );
}
