export const DURATION: number;
export type HeroRect = { x: number; y: number; w: number; h: number };
export interface HeroScene {
  resize(w: number, h: number, dpr: number): void;
  render(t: number, rect: HeroRect): void;
  corner(): [number, number, number];
  /** Light or dark studio, to follow the page's theme. */
  setTheme(dark: boolean): void;
  dispose(): void;
}
export function createHero(canvas: HTMLCanvasElement, options?: { surfaceScale?: number; samples?: number }): HeroScene;
