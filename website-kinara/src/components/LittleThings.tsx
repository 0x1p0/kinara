'use client';
import { useRef, useState } from 'react';
import { prefersReducedMotion } from '@/engine';
import { usePage } from '@/engine/next';
import { touches } from '@/data/site';

// A live Mac screen that answers taps the way Kinara does. The state machines below are ports of
// the app's own (Kinara/CornerBloom.swift): CornerBloom (one glass shape, bead → pill), CornerLight
// (a line of light hugging the tapped corner) and EdgeGlow (a light that follows a slide), with the
// same springs, holds and fades. Sizes are the app's points, scaled by --u (glass) and --lu (light).

type Corner = 'tl' | 'tr' | 'bl' | 'br';
type Edge = 'left' | 'right' | 'top' | 'bottom';
type Region = Corner | Edge;
const CORNERS: Corner[] = ['tl', 'tr', 'bl', 'br'];
const EDGES: Edge[] = ['left', 'right', 'top', 'bottom'];
const demo = touches.demo;

// ------------------------------------------------------------------ SF Symbol stand-ins (24 × 24)
const ICONS: Record<string, string> = {
  playpause: '<path d="M2.6 5.6v12.8a.6.6 0 0 0 .92.5l9.3-6.4a.6.6 0 0 0 0-1L3.52 5.1a.6.6 0 0 0-.92.5z" fill="currentColor"/><rect x="14.4" y="5.2" width="3" height="13.6" rx="1.1" fill="currentColor"/><rect x="19.3" y="5.2" width="3" height="13.6" rx="1.1" fill="currentColor"/>',
  play: '<path d="M6.5 4.4v15.2a.9.9 0 0 0 1.37.77l12.4-7.6a.9.9 0 0 0 0-1.54L7.87 3.63a.9.9 0 0 0-1.37.77z" fill="currentColor"/>',
  pause: '<rect x="5.6" y="4.2" width="4.4" height="15.6" rx="1.3" fill="currentColor"/><rect x="14" y="4.2" width="4.4" height="15.6" rx="1.3" fill="currentColor"/>',
  mission: '<g fill="none" stroke="currentColor" stroke-width="2"><rect x="2.5" y="4" width="8.6" height="6.8" rx="1.6"/><rect x="12.9" y="4" width="8.6" height="6.8" rx="1.6"/><rect x="6" y="13.2" width="12" height="6.8" rx="1.6"/></g>',
  desktop: '<g fill="none" stroke="currentColor" stroke-width="2"><rect x="2.5" y="4" width="19" height="16" rx="2.6"/><path d="M2.5 8.2h19"/></g><rect x="7.5" y="15.3" width="9" height="2.2" rx="1.1" fill="currentColor"/>',
  muteapp: '<circle cx="12" cy="12" r="9.6" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M7.4 10.2h1.9l2.9-2.6v8.8l-2.9-2.6H7.4z" fill="currentColor"/><path d="M14.2 9.6l3.6 4.8M17.8 9.6l-3.6 4.8" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>',
  muted: '<path d="M3.5 9.2h3.3L11.4 5v14l-4.6-4.2H3.5a.9.9 0 0 1-.9-.9V10.1a.9.9 0 0 1 .9-.9z" fill="currentColor"/><path d="M15 9.2l5.6 5.6M20.6 9.2L15 14.8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  unmuted: '<path d="M3.5 9.2h3.3L11.4 5v14l-4.6-4.2H3.5a.9.9 0 0 1-.9-.9V10.1a.9.9 0 0 1 .9-.9z" fill="currentColor"/><path d="M14.6 9a4.3 4.3 0 0 1 0 6M17.4 6.4a8 8 0 0 1 0 11.2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  undo: '<path d="M8.6 5.2L4 9.6l4.6 4.4" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><path d="M4.6 9.6h9.6a5.4 5.4 0 0 1 0 10.8h-3.4" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>',
};
const svg = (name: string) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] ?? ''}</svg>`;

// ------------------------------------------------------------------ motion: SwiftUI's curves
function bezier(x1: number, y1: number, x2: number, y2: number) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = (t: number) => ((ax * t + bx) * t + cx) * t;
  const dx = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x: number) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - x, d = dx(t);
      if (Math.abs(e) < 1e-6 || Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    t = Math.min(1, Math.max(0, t));
    return ((ay * t + by) * t + cy) * t;
  };
}
const easeOut = bezier(0, 0, 0.58, 1);
const easeIn = bezier(0.42, 0, 1, 1);
const easeInOut = bezier(0.42, 0, 0.58, 1);

type Motion = { spring: [response: number, damping: number] } | { tween: [seconds: number, curve: (x: number) => number] };
const spring = (response: number, damping: number): Motion => ({ spring: [response, damping] });
const tween = (seconds: number, curve = easeOut): Motion => ({ tween: [seconds, curve] });
const now = () => performance.now() / 1000;

/** One animated number. Springs keep their velocity when retargeted, like SwiftUI's. */
class Val {
  v: number;
  vel = 0;
  goal: number;
  private from = 0;
  private start = 0;
  private m: Motion | null = null;
  constructor(v: number, private wake: () => void, private eps = 0.001) { this.v = this.goal = v; }
  to(goal: number, m: Motion | null) {
    this.goal = goal;
    if (!m) { this.v = goal; this.vel = 0; this.m = null; this.wake(); return; }
    if ('tween' in m) this.vel = 0;
    this.m = m;
    this.from = this.v;
    this.start = now();
    this.wake();
  }
  get busy() { return this.m !== null; }
  step(t: number, dt: number) {
    const m = this.m;
    if (!m) return;
    if ('spring' in m) {
      // SwiftUI's spring(response:dampingFraction:) for a unit mass.
      const [r, z] = m.spring;
      const k = (2 * Math.PI / r) ** 2, c = (4 * Math.PI * z) / r;
      for (let left = dt; left > 1e-6; left -= 1 / 240) {
        const h = Math.min(left, 1 / 240);
        this.vel += (-k * (this.v - this.goal) - c * this.vel) * h;
        this.v += this.vel * h;
      }
      if (Math.abs(this.v - this.goal) < this.eps && Math.abs(this.vel) < this.eps * 20) { this.v = this.goal; this.vel = 0; this.m = null; }
    } else {
      const [d, curve] = m.tween;
      const p = (t - this.start) / d;
      if (p >= 1) { this.v = this.goal; this.m = null; } else if (p > 0) this.v = this.from + (this.goal - this.from) * curve(p);
    }
  }
}

/** Named one-shot timers, like the app's DispatchWorkItems. */
class Timers {
  private ids = new Map<string, number>();
  set(key: string, seconds: number, fn: () => void) {
    this.cancel(key);
    this.ids.set(key, window.setTimeout(() => { this.ids.delete(key); fn(); }, Math.max(0, seconds) * 1000));
  }
  cancel(key: string) { const id = this.ids.get(key); if (id !== undefined) { clearTimeout(id); this.ids.delete(key); } }
  cancelPrefix(prefix: string) { [...this.ids.keys()].filter((k) => k.startsWith(prefix)).forEach((k) => this.cancel(k)); }
  clear() { this.ids.forEach((id) => clearTimeout(id)); this.ids.clear(); }
}

type Caption = { title: string; body: string };
type Api = { go: (i: number) => void; toggle: () => void };

export function LittleThings() {
  const root = useRef<HTMLElement>(null);
  const [chapter, setChapter] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [caption, setCaption] = useState<Caption>(touches.chapters[0]);
  const [live, setLive] = useState(false);
  const [hint, setHint] = useState(touches.hint.pointer);
  const api = useRef<Api>({ go: () => {}, toggle: () => {} });

  usePage(() => {
    const section = root.current!;
    const screen = section.querySelector<HTMLElement>('.lt-screen')!;
    const island = screen.querySelector<HTMLElement>('.lt-isl')!;
    const content = island.querySelector<HTMLElement>('.lt-isl__content')!;
    const probe = screen.querySelector<HTMLElement>('.lt-probe')!;
    const lights = Object.fromEntries(CORNERS.map((c) => [c, screen.querySelector<SVGSVGElement>(`.lt-light[data-corner="${c}"]`)!])) as Record<Corner, SVGSVGElement>;
    const glowEl = screen.querySelector<HTMLElement>('.lt-glow')!;
    const pad = section.querySelector<HTMLElement>('.lt-pad')!;
    const dot = pad.querySelector<HTMLElement>('.lt-pad__dot')!;
    const reduced = prefersReducedMotion();
    const touchFirst = matchMedia('(hover: none)').matches;
    setHint(touchFirst ? touches.hint.touch : touches.hint.pointer);
    const timers = new Timers();
    const offs: (() => void)[] = [];

    // ---------------------------------------------------------------- the frame loop
    const vals: Val[] = [];
    let raf = 0, last = 0;
    const wake = () => { if (!raf) { last = now(); raf = requestAnimationFrame(frame); } };
    const val = (v: number, eps?: number) => { const x = new Val(v, wake, eps); vals.push(x); return x; };
    function frame() {
      // Springs keep real time on a slow frame (the timers that end each phase do), in 1/240 s steps.
      const t = now(), dt = Math.min(0.25, t - last);
      last = t;
      vals.forEach((v) => v.step(t, dt));
      render();
      raf = vals.some((v) => v.busy) ? requestAnimationFrame(frame) : 0;
    }
    offs.push(() => cancelAnimationFrame(raf));

    // One point of the app, in CSS pixels at this screen size: u for glass, lu for light.
    const bar = screen.querySelector<HTMLElement>('.lt-bar')!;
    let u = 1, lu = 1;
    const box = { w: 0, h: 0, bar: 0 };
    const measure = () => {
      u = probe.offsetWidth / 100 || 1;
      lu = probe.offsetHeight / 100 || 1;
      box.w = screen.clientWidth; box.h = screen.clientHeight; box.bar = bar.offsetHeight;
    };
    measure();

    // ---------------------------------------------------------------- CornerBloom
    type Phase = 'hidden' | 'armed' | 'bloom' | 'preview' | 'leaving';
    const BEAD = 20, ARMED_LIFE = 0.45, RESULT_WINDOW = 2;
    const W = val(BEAD * u, 0.05), H = val(BEAD * u, 0.05), S = val(0.15, 0.0005), O = val(0, 0.002);
    const bloom = {
      phase: 'hidden' as Phase,
      anchor: 'tr' as Corner,
      title: null as string | null,
      icon: 'playpause',
      detail: null as string | null,
      bloomUntil: 0,
      firedAt: -Infinity,
      placement: null as Corner | null,
      layer: null as HTMLElement | null,
      contentShownAt: 0,
    };
    const expanded = () => bloom.phase === 'bloom' || bloom.phase === 'preview';
    const present = () => bloom.phase !== 'hidden' && bloom.phase !== 'leaving';

    /** The pill's words. While they're on screen a change crossfades; otherwise it just swaps. */
    function setWords(title: string | null, icon: string, detail: string | null) {
      bloom.title = title; bloom.icon = icon; bloom.detail = detail;
      const el = document.createElement('div');
      el.className = `lt-pill${detail ? ' has-detail' : ''}`;
      el.innerHTML = `<span class="lt-pill__ico">${svg(icon)}</span><span class="lt-pill__text"><b></b>${detail ? '<small></small>' : ''}</span>`;
      el.querySelector('b')!.textContent = title ?? '';
      if (detail) el.querySelector('small')!.textContent = detail;
      const old = bloom.layer;
      const visible = expanded() && now() - bloom.contentShownAt > 0.14 && !reduced;
      if (old && visible) {
        old.classList.add('is-out');
        window.setTimeout(() => old.remove(), 260);
        el.classList.add('is-in');
      } else {
        content.querySelectorAll('.lt-pill').forEach((n) => n.remove());
      }
      content.append(el);
      bloom.layer = el;
    }
    const wordsWidth = () => bloom.layer?.offsetWidth ?? BEAD * u;

    function setPhase(phase: Phase, m: Motion | null) {
      const was = expanded();
      bloom.phase = phase;
      const open = expanded();
      if (open && !was) bloom.contentShownAt = now();
      island.classList.toggle('is-open', open);
      island.classList.toggle('is-preview', phase === 'preview');
      island.classList.toggle('is-hidden', phase === 'hidden');
      // One shape throughout: a bead when armed, a pill when expanded.
      W.to(open ? wordsWidth() : BEAD * u, m);
      H.to(open ? (bloom.detail ? 50 : 44) * u : BEAD * u, m);
      S.to(present() || reduced ? 1 : 0.15, m);
      O.to(present() ? 1 : 0, m);
    }
    function presentAt(c: Corner) {
      timers.cancel('bloom.hiding');
      if (bloom.anchor !== c || bloom.phase === 'hidden') {
        bloom.anchor = c;
        island.dataset.corner = c;
        setPhase('hidden', null);
      }
    }
    function arm(c: Corner) {
      if (bloom.phase === 'bloom') return;
      presentAt(c);
      setPhase('armed', reduced ? tween(0.12) : spring(0.24, 0.72));
      scheduleLeave(ARMED_LIFE);
    }
    function fire(c: Corner, title: string | null, icon: string, detail: string | null) {
      presentAt(c);
      bloom.placement = c;
      setWords(title, icon, detail);
      // A little overshoot, like liquid finding its shape.
      setPhase(title === null ? 'armed' : 'bloom', reduced ? tween(0.15) : spring(0.42, 0.72));
      const hold = title === null ? 0.35 : detail === null ? 1.5 : 2.5;
      bloom.firedAt = now();
      bloom.bloomUntil = bloom.firedAt + hold;
      scheduleLeave(hold);
    }
    function preview(c: Corner, title: string, icon: string, detail: string) {
      if (bloom.phase === 'bloom') return;
      presentAt(c);
      setWords(title, icon, detail);
      timers.cancel('bloom.leaving');
      setPhase('preview', reduced ? tween(0.15) : spring(0.34, 0.8));
    }
    function endPreview() { if (bloom.phase === 'preview') scheduleLeave(0); }
    function absorb(text: string, icon: string, detail: string | null, placement: Corner) {
      const recent = now() - bloom.firedAt <= RESULT_WINDOW;
      const showingTap = bloom.phase === 'bloom' && bloom.title !== null;
      if (!showingTap || !(placement === bloom.placement || recent)) return false;
      // The pill resizes to the new words in the same motion.
      setWords(text, icon, detail);
      setPhase('bloom', reduced ? tween(0.15) : spring(0.38, 0.82));
      const remaining = Math.max(detail === null ? 1.4 : 2.5, bloom.bloomUntil - now());
      bloom.bloomUntil = now() + remaining;
      scheduleLeave(remaining);
      return true;
    }
    /** Backwards out: the words go, the pill draws back into the bead, the bead sinks into the corner. */
    function scheduleLeave(delay: number) {
      timers.set('bloom.leaving', delay, () => {
        if (expanded() && !reduced) {
          setPhase('armed', spring(0.34, 0.86));
          timers.set('bloom.hiding', 0.24, sink);
        } else sink();
      });
    }
    function sink() {
      setPhase('leaving', reduced ? tween(0.15) : tween(0.2, easeIn));
      timers.set('bloom.hiding', 0.24, () => {
        if (bloom.phase !== 'leaving') return;
        setPhase('hidden', null);
        bloom.placement = null;
      });
    }
    function resetBloom() {
      timers.cancelPrefix('bloom.');
      setPhase('hidden', null);
    }

    // ---------------------------------------------------------------- CornerLight
    const intensity = val(0, 0.002), spread = val(0, 0.001);
    let lightCorner: Corner = 'tr';
    const light = {
      present(c: Corner) {
        timers.cancelPrefix('light.');
        if (lightCorner !== c) { lightCorner = c; intensity.to(0, null); spread.to(0, null); }
      },
      flash(c: Corner, strength: number, reach: number) {
        light.present(c);
        spread.to(reduced ? reach : 0, null);
        intensity.to(strength, tween(0.1));
        if (!reduced) spread.to(reach, tween(0.32));
        timers.set('light.fade', 0.22, () => intensity.to(0, tween(0.55, easeIn)));
      },
      /** A finger resting on the spot: the light stays on, softly, until released. */
      hold(c: Corner) {
        light.present(c);
        intensity.to(0.5, tween(0.3));
        spread.to(0.7, tween(0.3));
      },
      release() { if (intensity.v > 0 || intensity.goal > 0) intensity.to(0, tween(0.4, easeIn)); },
    };

    // ---------------------------------------------------------------- EdgeGlow
    const glowAlpha = val(0, 0.002);
    let glowEdge: Edge | null = null, glowShown = false, glowAlong = 0.5;
    const glow = {
      /** `along` is the finger's 0…1 position along the edge, top to bottom or left to right. */
      update(edge: Edge, along: number) {
        if (glowEdge !== edge) { glowEdge = edge; glowEl.dataset.edge = edge; }
        glowAlong = along;
        const vertical = edge === 'left' || edge === 'right';
        const len = 180 * lu;
        // The visible frame: below the menu bar.
        const lo = vertical ? box.bar : 0, hi = vertical ? box.h : box.w;
        const at = Math.min(Math.max(lo + along * (hi - lo) - len / 2, lo), hi - len);
        glowEl.style.translate = vertical ? `0 ${at}px` : `${at}px 0`;
        if (glowShown) return;
        glowShown = true;
        glowAlpha.to(1, tween(0.18, easeInOut));
      },
      end() {
        if (!glowShown) return;
        glowShown = false;
        glowAlpha.to(0, tween(0.35, easeInOut));
      },
    };

    // ---------------------------------------------------------------- drawing
    let lastCorner: Corner | null = null;
    function render() {
      island.style.width = `${W.v}px`;
      island.style.height = `${H.v}px`;
      island.style.transform = `scale(${S.v})`;
      island.style.opacity = `${Math.max(0, Math.min(1, O.v))}`;
      if (lastCorner && lastCorner !== lightCorner) lights[lastCorner].style.opacity = '0';
      lastCorner = lightCorner;
      const el = lights[lightCorner], path = el.firstElementChild!.nextElementSibling as SVGPathElement;
      const s = Math.max(0, Math.min(1, spread.v));
      // Trimmed outward from the corner, which sits halfway along the path.
      path.setAttribute('stroke-dasharray', `${s} 2`);
      path.setAttribute('stroke-dashoffset', `${-(0.5 - s / 2)}`);
      el.style.opacity = s < 0.004 ? '0' : `${Math.max(0, Math.min(1, intensity.v))}`;
      glowEl.style.opacity = `${glowAlpha.v}`;
    }

    // ---------------------------------------------------------------- the trackpad picture
    // The app's tour picture: a tinted zone where the finger is, and a dot that presses.
    const padShow = (r: Region, along?: number) => {
      timers.cancel('pad.clear');
      pad.dataset.region = r;
      pad.classList.add('is-on');
      if (along !== undefined) pad.style.setProperty('--along', `${along}`);
    };
    const padPress = () => { if (!reduced) dot.animate([{ scale: '1' }, { scale: '0.8' }, { scale: '1' }], { duration: 160, easing: 'ease-in-out' }); };
    const padClear = (after = 0) => timers.set('pad.clear', after, () => pad.classList.remove('is-on'));

    // ---------------------------------------------------------------- what the app does with a tap
    const desk = { mc: false, desktop: false, muted: false, playing: false };
    const syncDesk = () => {
      screen.classList.toggle('is-mc', desk.mc);
      screen.classList.toggle('is-desktop', desk.desktop);
      screen.classList.toggle('is-muted', desk.muted);
      screen.classList.toggle('is-playing', desk.playing);
    };
    const seen = new Set<Corner>();
    let lastTap: { c: Corner; at: number } | null = null;
    const corner = (c: Corner) => demo.corners[c];
    const restDetail = (c: Corner) => corner(c).hold ? `${demo.doubleTap} · ${demo.tapHold}: ${corner(c).hold}` : demo.doubleTap;
    /** The first time a spot fires, where to change it; after that, how to undo it. */
    const hintFor = (c: Corner, undoing: boolean) => {
      if (!seen.has(c)) { seen.add(c); return `${corner(c).name} ${demo.tapLabel} · ${demo.settings}`; }
      return undoing ? null : demo.again;
    };

    let speak: (key: 'armed' | 'fired' | 'undone') => void = () => {};
    function firstTap(c: Corner) {
      padShow(c); padPress();
      arm(c);
      // Heard you: a faint flicker in that corner, waiting for the second tap.
      light.flash(c, 0.5, 0.4);
      speak('armed');
      padClear(0.7);
    }
    function secondTap(c: Corner, resultDelay = 0.6) {
      padShow(c); padPress();
      const undoing = !!lastTap && lastTap.c === c && now() - lastTap.at <= 2;
      light.flash(c, 1, 1);
      fire(c, undoing ? demo.undone : corner(c).action, undoing ? 'undo' : corner(c).icon, hintFor(c, undoing));
      perform(c, resultDelay);
      lastTap = undoing ? null : { c, at: now() };
      speak(undoing ? 'undone' : 'fired');
      padClear(0.6);
    }
    function perform(c: Corner, resultDelay: number) {
      if (c === 'tl') { desk.mc = !desk.mc; if (desk.mc) desk.desktop = false; }
      if (c === 'br') { desk.desktop = !desk.desktop; if (desk.desktop) desk.mc = false; }
      if (c === 'bl') {
        desk.muted = !desk.muted;
        absorb(desk.muted ? demo.muted : demo.unmuted, desk.muted ? 'muted' : 'unmuted', null, c);
      }
      if (c === 'tr') {
        desk.playing = !desk.playing;
        const playing = desk.playing;
        // The track arrives once Now Playing answers, into the same pill.
        timers.set('result', resultDelay, () => absorb(demo.track, playing ? 'play' : 'pause', `${playing ? demo.playing : demo.paused} · ${demo.artist}`, c));
      }
      syncDesk();
    }
    function restShow(c: Corner) {
      padShow(c);
      preview(c, corner(c).action, corner(c).icon, restDetail(c));
      light.hold(c);
    }
    function restHide() { endPreview(); light.release(); padClear(); }

    // ---------------------------------------------------------------- the guided loop
    let token = 0, inView = false, auto = !reduced, index = 0, still = false;
    const CANCEL = Symbol('cancel');
    const wait = (s: number, t: number) => new Promise<void>((res, rej) => {
      timers.set(`script.${Math.random()}`, s, () => (t === token ? res() : rej(CANCEL)));
    });
    const glide = (edge: Edge, from: number, to: number, seconds: number, t: number) => new Promise<void>((res, rej) => {
      const start = now();
      const step = () => {
        if (t !== token) { rej(CANCEL); return; }
        const p = Math.min(1, (now() - start) / seconds), k = easeInOut(p), at = from + (to - from) * k;
        glow.update(edge, at);
        padShow(edge, at);
        if (p < 1) requestAnimationFrame(step); else res();
      };
      step();
    });

    const scripts: ((t: number) => Promise<void>)[] = [
      async (t) => { // Double-tap: a bead, then a pill, then the song in the same pill.
        if (desk.playing) { desk.playing = false; syncDesk(); }
        await wait(0.35, t);
        firstTap('tr');
        await wait(0.26, t);
        secondTap('tr', 0.95);
        await wait(4.1, t);
      },
      async (t) => { // Rest: the finger stays, the pill previews, nothing runs.
        padShow('br');
        await wait(0.7, t);
        restShow('br');
        await wait(2.2, t);
        restHide();
        await wait(1, t);
      },
      async (t) => { // Undo: Mission Control, then the same double-tap again.
        seen.add('tl');
        if (desk.mc) { desk.mc = false; syncDesk(); }
        await wait(0.35, t);
        firstTap('tl');
        await wait(0.26, t);
        secondTap('tl');
        await wait(1.45, t);
        firstTap('tl');
        await wait(0.26, t);
        secondTap('tl');
        await wait(2.6, t);
      },
      async (t) => { // Edge light: a slide up the right edge and back.
        padShow('right', 0.72);
        await glide('right', 0.72, 0.22, 1.25, t);
        await wait(0.2, t);
        await glide('right', 0.22, 0.5, 0.8, t);
        await wait(0.15, t);
        glow.end();
        padClear();
        await wait(1, t);
      },
    ];

    function cancelScript() {
      token++;
      timers.cancelPrefix('script.');
    }
    /** Hand the stage to the visitor: stop the loop and clear what it was showing. */
    function takeOver() {
      clearStill();
      if (auto) { auto = false; setPlaying(false); }
      setLive(true);
      cancelScript();
      if (scripted) { resetBloom(); light.release(); glow.end(); padClear(); scripted = false; }
    }
    let scripted = false;
    async function run(from: number, loop: boolean) {
      cancelScript();
      clearStill();
      const t = token;
      setLive(false);
      try {
        for (let i = from; ; i = (i + 1) % scripts.length) {
          index = i;
          setChapter(i);
          setCaption(touches.chapters[i]);
          scripted = true;
          await scripts[i](t);
          scripted = false;
          if (!loop) return;
        }
      } catch (e) {
        if (e !== CANCEL) throw e;
      }
    }
    const resume = () => { if (auto && inView) run(index, true); };

    speak = (key) => {
      if (scripted) return;
      setCaption(touches.states[key]);
    };

    // ---------------------------------------------------------------- the still frame (reduced motion)
    function showStill() {
      still = true;
      screen.classList.add('is-still');
      desk.playing = true;
      syncDesk();
      seen.add('tr');
      presentAt('tr');
      bloom.placement = 'tr';
      setWords(demo.track, 'play', `${demo.playing} · ${demo.artist}`);
      setPhase('bloom', null);
      light.present('tr');
      intensity.to(0.9, null);
      spread.to(1, null);
      glow.update('right', 0.62);
      glowAlpha.to(1, null);
      padShow('tr');
      setCaption(touches.chapters[0]);
    }
    function clearStill() {
      if (!still) return;
      still = false;
      screen.classList.remove('is-still');
      resetBloom();
      intensity.to(0, null);
      glow.end();
      glowAlpha.to(0, null);
      padClear();
    }

    // ---------------------------------------------------------------- input: corners
    const zones = [...screen.querySelectorAll<HTMLElement>('.lt-hit')];
    let pending: { c: Corner; at: number } | null = null;
    const tap = (c: Corner) => {
      takeOver();
      if (pending && pending.c === c && now() - pending.at <= ARMED_LIFE) { pending = null; secondTap(c); }
      else { pending = { c, at: now() }; firstTap(c); }
    };
    zones.forEach((zone) => {
      const region = zone.dataset.region as Region;
      if ((CORNERS as string[]).includes(region)) {
        const c = region as Corner;
        let down: { at: number; x: number; y: number; id: number } | null = null;
        let resting = false, restAt = { x: 0, y: 0 }, quiet = false;
        const startRest = (seconds: number) => timers.set('rest', seconds, () => { resting = true; takeOver(); restShow(c); });
        const stopRest = () => { timers.cancel('rest'); if (resting) { resting = false; restHide(); } };
        const on = (type: string, fn: (e: PointerEvent) => void) => { zone.addEventListener(type, fn as EventListener); offs.push(() => zone.removeEventListener(type, fn as EventListener)); };
        on('pointerdown', (e) => {
          if (e.button !== 0) return;
          down = { at: now(), x: e.clientX, y: e.clientY, id: e.pointerId };
          // A click is a tap, not a rest: the preview gives way to the bead.
          if (e.pointerType === 'mouse') { timers.cancel('rest'); quiet = true; resting = false; }
          else startRest(0.7);
        });
        on('pointerup', (e) => {
          if (!down || e.pointerId !== down.id) return;
          const short = now() - down.at < 0.35 && Math.hypot(e.clientX - down.x, e.clientY - down.y) < 12;
          down = null;
          if (resting) { stopRest(); return; }
          timers.cancel('rest');
          if (short) tap(c);
        });
        on('pointercancel', () => { down = null; stopRest(); });
        // A mouse resting still on a corner is a finger resting on the trackpad's.
        on('pointermove', (e) => {
          if (e.pointerType !== 'mouse' || e.buttons) return;
          if (Math.hypot(e.clientX - restAt.x, e.clientY - restAt.y) < 4) return;
          restAt = { x: e.clientX, y: e.clientY };
          if (quiet) { quiet = false; return; }
          if (!resting) startRest(0.55);
        });
        on('pointerleave', (e) => { if (e.pointerType === 'mouse') { quiet = false; stopRest(); } });
        // Keyboard: focus previews, Enter or Space double-taps.
        const focus = () => { if (zone.matches(':focus-visible')) { takeOver(); restShow(c); resting = true; } };
        const blur = () => stopRest();
        const click = (e: MouseEvent) => {
          if (e.detail !== 0) return;
          takeOver();
          if (resting) { timers.cancel('rest'); resting = false; endPreview(); light.release(); }
          firstTap(c);
          timers.set('kbd', 0.26, () => secondTap(c));
        };
        zone.addEventListener('focus', focus);
        zone.addEventListener('blur', blur);
        zone.addEventListener('click', click);
        offs.push(() => { zone.removeEventListener('focus', focus); zone.removeEventListener('blur', blur); zone.removeEventListener('click', click); });
      } else {
        // ------------------------------------------------------------ input: edges
        const edge = region as Edge;
        const vertical = edge === 'left' || edge === 'right';
        const alongOf = (e: PointerEvent) => {
          const r = screen.getBoundingClientRect();
          return vertical ? (e.clientY - r.top) / r.height : (e.clientX - r.left) / r.width;
        };
        let dragging = -1;
        const move = (e: PointerEvent) => {
          if (e.pointerType !== 'mouse' && dragging !== e.pointerId) return;
          if (!glowShown) { takeOver(); setCaption(touches.chapters[3]); }
          const at = Math.min(1, Math.max(0, alongOf(e)));
          glow.update(edge, at);
          padShow(edge, at);
        };
        const end = () => { dragging = -1; glow.end(); padClear(); };
        const down = (e: PointerEvent) => {
          if (e.pointerType === 'mouse') return;
          dragging = e.pointerId;
          zone.setPointerCapture(e.pointerId);
          move(e);
        };
        const up = (e: PointerEvent) => { if (e.pointerType !== 'mouse') end(); };
        const leave = (e: PointerEvent) => { if (e.pointerType === 'mouse') end(); };
        // Keyboard: a slide along this edge, played for you.
        const click = async (e: MouseEvent) => {
          if (e.detail !== 0) return;
          takeOver();
          setCaption(touches.chapters[3]);
          const t = token;
          try {
            await glide(edge, 0.75, 0.25, 1.1, t);
            await glide(edge, 0.25, 0.5, 0.7, t);
            glow.end(); padClear(0.2);
          } catch (err) { if (err !== CANCEL) throw err; }
        };
        const focus = () => { if (zone.matches(':focus-visible')) { takeOver(); setCaption(touches.chapters[3]); glow.update(edge, 0.5); padShow(edge, 0.5); } };
        const blur = () => { cancelScript(); glow.end(); padClear(); };
        zone.addEventListener('pointermove', move);
        zone.addEventListener('pointerdown', down);
        zone.addEventListener('pointerup', up);
        zone.addEventListener('pointercancel', up);
        zone.addEventListener('pointerleave', leave);
        zone.addEventListener('click', click);
        zone.addEventListener('focus', focus);
        zone.addEventListener('blur', blur);
        offs.push(() => {
          zone.removeEventListener('pointermove', move); zone.removeEventListener('pointerdown', down); zone.removeEventListener('pointerup', up);
          zone.removeEventListener('pointercancel', up); zone.removeEventListener('pointerleave', leave); zone.removeEventListener('click', click);
          zone.removeEventListener('focus', focus); zone.removeEventListener('blur', blur);
        });
      }
    });

    // ---------------------------------------------------------------- controls, size, visibility
    api.current = {
      go: (i) => { run(i, auto && !reduced); },
      toggle: () => {
        auto = !auto;
        setPlaying(auto);
        if (auto) run(index, true);
        else { cancelScript(); }
      },
    };
    setPlaying(auto);

    const ro = new ResizeObserver(() => {
      const before = `${u} ${box.w} ${box.h}`;
      measure();
      if (before === `${u} ${box.w} ${box.h}`) return;
      // Re-seat the settled shape at the new scale.
      const open = expanded();
      W.to(open ? wordsWidth() : BEAD * u, null);
      H.to(open ? (bloom.detail ? 50 : 44) * u : BEAD * u, null);
      if (glowEdge && (glowShown || still)) glow.update(glowEdge, glowAlong);
      render();
    });
    ro.observe(screen);
    offs.push(() => ro.disconnect());

    const io = new IntersectionObserver(([e]) => {
      const was = inView;
      inView = e.isIntersecting;
      if (inView && !was) resume();
      if (!inView && was && scripted) { cancelScript(); resetBloom(); light.release(); glow.end(); padClear(); scripted = false; }
    }, { threshold: 0.45 });
    io.observe(screen);
    offs.push(() => io.disconnect());

    island.dataset.corner = 'tr';
    screen.classList.remove('is-still', 'is-playing');
    content.querySelectorAll('.lt-pill').forEach((n) => n.remove());
    if (reduced) showStill();
    else { resetBloom(); render(); }

    return () => { token++; timers.clear(); offs.forEach((o) => o()); };
  });

  const corners = CORNERS.map((c) => ({ id: c, ...demo.corners[c] }));
  return (
    <section ref={root} id="little-things" className="section lt" aria-labelledby="lt-title">
      <div className="wrap head">
        <p className="t-eyebrow grad">{touches.eyebrow}</p>
        <h2 id="lt-title" className="t-headline" data-split="lines">{touches.title}</h2>
        <p className="t-intro" data-reveal="up">{touches.lead}</p>
      </div>

      <div className="lt-stage" data-reveal="up">
        <div className="lt-display">
          <div className="lt-screen is-still is-playing" role="group" aria-label={demo.label}>
            <div className="lt-desk" aria-hidden="true">
              <div className="lt-bar">
                <b>{demo.menu[0]}</b>
                {demo.menu.slice(1).map((m) => <span key={m}>{m}</span>)}
                <i className="lt-bar__right"><span className="lt-bar__kinara" /><span className="lt-bar__wifi" /><span className="lt-bar__batt" />{demo.clock}</i>
              </div>
              <div className="lt-win lt-win--safari">
                <div className="lt-win__bar">
                  <span className="lt-lights"><i /><i /><i /></span>
                  <span className="lt-tab"><span className="lt-tab__fav" /><span className="lt-tab__name">{demo.tab}</span><span className="lt-tab__snd" dangerouslySetInnerHTML={{ __html: svg('unmuted') }} /><span className="lt-tab__mute" dangerouslySetInnerHTML={{ __html: svg('muted') }} /></span>
                </div>
                <div className="lt-video"><span className="lt-video__sun" /><span className="lt-video__hills" /><span className="lt-video__bar"><i /></span></div>
              </div>
              <div className="lt-win lt-win--music">
                <span className="lt-art" />
                <span className="lt-track"><b>{demo.track}</b><small>{demo.artist}</small></span>
                <span className="lt-ctl">
                  <span className="lt-ctl__pp lt-ctl__play" dangerouslySetInnerHTML={{ __html: svg('play') }} />
                  <span className="lt-ctl__pp lt-ctl__pause" dangerouslySetInnerHTML={{ __html: svg('pause') }} />
                </span>
                <span className="lt-prog"><i /></span>
              </div>
            </div>

            {corners.map((c) => (
              <svg key={c.id} className="lt-light" data-corner={c.id} viewBox="0 0 162 162" aria-hidden="true">
                <defs>
                  <radialGradient id={`lt-g-${c.id}`} gradientUnits="userSpaceOnUse" cx={c.id.includes('r') ? 162 : 0} cy={c.id.startsWith('t') ? 0 : 162} r="150">
                    <stop offset="0" stopColor="#fff" />
                    <stop offset="0.5" stopColor="#fff" stopOpacity="0.75" />
                    <stop offset="1" stopColor="#fff" stopOpacity="0" />
                  </radialGradient>
                </defs>
                <path d={LIGHT_PATHS[c.id]} pathLength={1} fill="none" stroke={`url(#lt-g-${c.id})`} strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="1 2" strokeDashoffset="0" />
              </svg>
            ))}
            <div className="lt-glow" data-edge="right" aria-hidden="true"><i /></div>

            <div className="lt-isl" data-corner="tr" aria-hidden="true">
              <div className="lt-isl__content">
                <div className="lt-pill has-detail">
                  <span className="lt-pill__ico" dangerouslySetInnerHTML={{ __html: svg('play') }} />
                  <span className="lt-pill__text"><b>{demo.track}</b><small>{demo.playing} · {demo.artist}</small></span>
                </div>
              </div>
            </div>
            <span className="lt-probe" aria-hidden="true" />

            {corners.map((c) => (
              <button key={c.id} type="button" className="lt-hit" data-region={c.id}
                aria-label={`${c.name}, ${demo.tapLabel}: ${c.action}`} />
            ))}
            {EDGES.map((e) => (
              e === 'left' || e === 'right'
                ? <button key={e} type="button" className="lt-hit" data-region={e} aria-label={demo.edges[e]} />
                : <span key={e} className="lt-hit" data-region={e} aria-hidden="true" />
            ))}
          </div>
        </div>

        <div className="lt-under">
          <div className="lt-pad" data-region="tr" aria-hidden="true">
            <span className="lt-pad__zone"><span className="lt-pad__dot" /></span>
          </div>
          <div className="lt-cap" aria-live={live ? 'polite' : 'off'}>
            <b>{caption.title}</b>
            <span>{caption.body || hint}</span>
          </div>
          <div className="lt-nav">
            <div className="lt-chips" role="group" aria-label={demo.chapters}>
              {touches.chapters.map((ch, i) => (
                <button key={ch.id} type="button" className={`lt-chip${i === chapter && !live ? ' is-on' : ''}`}
                  aria-pressed={i === chapter && !live} onClick={() => api.current.go(i)}>{ch.label}</button>
              ))}
            </div>
            <button type="button" className="lt-play" onClick={() => api.current.toggle()} aria-label={playing ? demo.pause : demo.play}>
              {playing
                ? <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><rect x="2" y="1" width="3.5" height="12" rx="1" fill="currentColor" /><rect x="8.5" y="1" width="3.5" height="12" rx="1" fill="currentColor" /></svg>
                : <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 1.2v11.6L12.6 7z" fill="currentColor" /></svg>}
            </button>
          </div>
        </div>
        <p className="t-small lt-hint">{hint}</p>
      </div>

      <div className="wrap">
        <ul className="mx__points" data-reveal="up">
          {touches.points.map((p) => <li key={p.title}><b>{p.title}</b><span>{p.body}</span></li>)}
        </ul>
        <p className="t-small mx__note">{touches.note}</p>
      </div>
    </section>
  );
}

/** The light's path in its 162-point square (reach 150 + 12), from one edge, around the screen's
 * 12-point corner, to the other, inset 1.5: CornerLightShape, in SVG's y-down space. */
const LIGHT_PATHS: Record<Corner, string> = {
  tl: 'M162 1.5H13.5A12 12 0 0 0 1.5 13.5V162',
  tr: 'M0 1.5H148.5A12 12 0 0 1 160.5 13.5V162',
  bl: 'M162 160.5H13.5A12 12 0 0 1 1.5 148.5V0',
  br: 'M0 160.5H148.5A12 12 0 0 0 160.5 148.5V0',
};
