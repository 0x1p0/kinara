// Global motion for Kinara: runs once on the client, before the first page initialises.
import { gsap } from 'gsap';
import { CustomEase } from 'gsap/CustomEase';
import { ease, setTransition } from '@/engine';

gsap.registerPlugin(CustomEase);

export function setupMotion() {
  // Kinara's own HUD curve: fast out, gentle settle. The site's motion verb.
  CustomEase.create('settle', 'M0,0 C0.16,1 0.3,1 1,1');

  // Page transition: a sweep of light crosses the window from the right edge, like a finger.
  setTransition({
    leave: (c) => {
      const panel = c.querySelector<HTMLElement>('.curtain__panel')!;
      const line = c.querySelector<HTMLElement>('.curtain__edge')!;
      const state = { x: 100 };
      return gsap.timeline()
        .set(c, { autoAlpha: 1 })
        .to(state, {
          x: 0, duration: 0.75, ease: ease.inOut,
          onUpdate: () => {
            panel.style.clipPath = `inset(0 0 0 ${state.x}%)`;
            gsap.set(line, { x: (state.x / 100) * innerWidth });
          },
        });
    },
    enter: (c) => {
      const panel = c.querySelector<HTMLElement>('.curtain__panel')!;
      const line = c.querySelector<HTMLElement>('.curtain__edge')!;
      const state = { x: 0 };
      return gsap.timeline()
        .to(state, {
          x: 100, duration: 0.85, ease: ease.inOut,
          onUpdate: () => {
            panel.style.clipPath = `inset(0 ${state.x}% 0 0)`;
            gsap.set(line, { x: (1 - state.x / 100) * innerWidth });
          },
        })
        .set(c, { autoAlpha: 0 });
    },
  });

}
