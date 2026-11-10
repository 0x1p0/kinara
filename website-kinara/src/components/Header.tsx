'use client';
import { useEffect, useState } from 'react';
import { site } from '@/data/site';

/** Light or dark: follows the system until the visitor chooses, then remembers it here. */
function ThemeToggle() {
  const toggle = () => {
    const root = document.documentElement;
    const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    try { localStorage.setItem('kinara-theme', root.dataset.theme); } catch {}
  };
  return (
    <button type="button" className="theme" onClick={toggle} aria-label="Switch between light and dark">
      <svg className="moon" width="15" height="15" viewBox="0 0 24 24" aria-hidden="true"><path d="M19.5 14.6A8 8 0 0 1 9.4 4.5a8 8 0 1 0 10.1 10.1z" fill="currentColor" /></svg>
      <svg className="sun" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4" fill="currentColor" stroke="none" /><path d="M12 2.6v2.2M12 19.2v2.2M2.6 12h2.2M19.2 12h2.2M5.4 5.4l1.5 1.5M17.1 17.1l1.5 1.5M5.4 18.6l1.5-1.5M17.1 6.9l1.5-1.5" /></svg>
    </button>
  );
}

/** Apple's local nav: product name, a few links, a blue Download. It goes dark over dark sections. */
export function Header() {
  const [dark, setDark] = useState(false);
  useEffect(() => {
    const under = new Set<Element>();
    let io: IntersectionObserver | null = null;
    const watch = () => {
      io?.disconnect();
      under.clear();
      // A one-pixel line just under the bar: whichever section crosses it sets the bar's colour.
      io = new IntersectionObserver((entries) => {
        entries.forEach((e) => (e.isIntersecting ? under.add(e.target) : under.delete(e.target)));
        setDark(under.size > 0);
      }, { rootMargin: `-52px 0px ${-(innerHeight - 53)}px 0px` });
      const found = document.querySelectorAll('.is-dark, .lost');
      found.forEach((s) => io!.observe(s));
      if (!found.length) setDark(false);
    };
    watch();
    addEventListener('resize', watch);
    // Pages swap (and some, like the 404, stream in after hydration): look again when they do.
    let pending = 0;
    const mo = new MutationObserver(() => { clearTimeout(pending); pending = window.setTimeout(watch, 80); });
    mo.observe(document.body, { childList: true, subtree: true });
    return () => { io?.disconnect(); mo.disconnect(); clearTimeout(pending); removeEventListener('resize', watch); };
  }, []);

  return (
    <header className={`nav${dark ? ' is-dark' : ''}`}>
      <div className="nav__in">
        <a className="nav__brand" href="/" aria-label={`${site.name}, home`}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/media/kinara-icon-256.webp" alt="" width={22} height={22} />
          {site.name}
        </a>
        <a className="nav__link" href="/#highlights">Highlights</a>
        <a className="nav__link" href="/#mixer">Mixer</a>
        <a className="nav__link" href="/#details">Details</a>
        <a className="nav__link" href={site.sourceUrl}>Source</a>
        <a className="nav__link" href="/#faq">FAQ</a>
        <ThemeToggle />
        <a className="btn btn--sm" href="/#download" data-no-transition>Download</a>
      </div>
    </header>
  );
}
