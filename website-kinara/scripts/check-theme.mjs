// Light and dark, checked the way a visitor meets them. Run against a production build:
//
//   npm run build && npm run preview -- --port 4400   (in another terminal)
//   npm run check:theme                            (or: node scripts/check-theme.mjs <url>)
//
// Four states: the system in light, the system in dark, and the header toggle flipped from each;
// then light and dark again with Reduced Motion, where the page takes different paths.
// In every state, each page section's background and text, and the nav at several scroll depths,
// must match the theme in force. It also fails on CSS that follows the system's scheme without
// honouring the toggle. Exits 1 on any failure, so nothing that ignores the theme ships.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { chromium } from 'playwright';

const url = process.argv[2] ?? 'http://127.0.0.1:4400/';
const failures = [];

// ------------------------------------------------------------------ CSS
// Every dark rule written for the system scheme must step aside when the toggle says light.
const files = (dir) => readdirSync(dir).flatMap((f) => (statSync(join(dir, f)).isDirectory() ? files(join(dir, f)) : [join(dir, f)]));
for (const file of files(new URL('../src', import.meta.url).pathname).filter((f) => f.endsWith('.css'))) {
  const css = readFileSync(file, 'utf8');
  const query = /@media\s*\(prefers-color-scheme:\s*dark\)\s*\{/g;
  let m;
  while ((m = query.exec(css))) {
    let depth = 1, i = query.lastIndex;
    while (depth && i < css.length) depth += css[i] === '{' ? 1 : css[i] === '}' ? -1 : 0, i++;
    const body = css.slice(query.lastIndex, i - 1).replace(/\/\*[\s\S]*?\*\//g, '');
    for (const selector of body.match(/(^|})\s*([^{}]+)\{/g) ?? []) {
      const sel = selector.replace(/^}?\s*/, '').replace(/\{$/, '').trim();
      if (!/:root:not\(\[data-theme(=['"]light['"])?\]\)/.test(sel)) {
        const line = css.slice(0, m.index).split('\n').length;
        failures.push(`${file.split('/src/')[1]}:${line}: \`${sel}\` follows the system's dark scheme but ignores the toggle (scope it with :root:not([data-theme='light']) and add a :root[data-theme='dark'] twin)`);
      }
    }
  }
}

// ------------------------------------------------------------------ pages
const browser = await chromium.launch();
const states = [
  ...['light', 'dark'].flatMap((scheme) => [false, true].map((toggled) => ({ scheme, toggled, reduced: false }))),
  ...['light', 'dark'].map((scheme) => ({ scheme, toggled: false, reduced: true })),
];
for (const { scheme, toggled, reduced } of states) {
  {
    const expected = toggled ? (scheme === 'light' ? 'dark' : 'light') : scheme;
    const state = `system ${scheme}${toggled ? `, toggled to ${expected}` : ''}${reduced ? ', reduced motion' : ''}`;
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: scheme, reducedMotion: reduced ? 'reduce' : 'no-preference' });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(url, { waitUntil: 'networkidle' });
    await page.waitForTimeout(1500);
    if (toggled) {
      await page.locator('button.theme').first().click();
      await page.waitForTimeout(900);
    }
    const found = await page.evaluate(async () => {
      const rgb = (c) => (c.match(/[\d.]+/g) ?? []).map(Number);
      const lum = ([r, g, b]) => [r, g, b].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }).reduce((a, v, i) => a + v * [0.2126, 0.7152, 0.0722][i], 0);
      // The colour a section actually shows: its own background, or the first opaque one behind it.
      const shown = (el) => {
        for (let n = el; n; n = n.parentElement) {
          const c = rgb(getComputedStyle(n).backgroundColor);
          if (c.length >= 3 && (c[3] ?? 1) > 0.5) return lum(c);
        }
        return lum(rgb(getComputedStyle(document.documentElement).backgroundColor));
      };
      const sections = [...document.querySelectorAll('section, footer')].filter((s) => !s.parentElement.closest('section') && s.offsetHeight > 80);
      const out = sections.map((s) => ({ name: s.id || s.className.split(' ')[0] || s.tagName.toLowerCase(), bg: shown(s), ink: lum(rgb(getComputedStyle(s).color)) }));
      // The nav, at several depths of the page.
      const nav = document.querySelector('header.nav');
      const navs = [];
      for (const f of [0, 0.25, 0.5, 0.75, 1]) {
        window.scrollTo(0, f * (document.documentElement.scrollHeight - innerHeight));
        await new Promise((r) => setTimeout(r, 450));
        navs.push({ name: `nav at ${Math.round(f * 100)}%`, bg: lum(rgb(getComputedStyle(nav).backgroundColor)), ink: lum(rgb(getComputedStyle(nav).color)) });
      }
      return [...out, ...navs];
    });
    for (const { name, bg, ink } of found) {
      // The background must belong to the theme; the text must sit on the right side of it
      // (darker in light, lighter in dark) with at least 3:1 contrast, so grey secondary text passes.
      const okBg = expected === 'light' ? bg > 0.55 : bg < 0.2;
      const contrast = (Math.max(bg, ink) + 0.05) / (Math.min(bg, ink) + 0.05);
      const okInk = (expected === 'light' ? ink < bg : ink > bg) && contrast >= 3;
      if (!okBg) failures.push(`${state}: ${name} has a ${bg > 0.5 ? 'light' : 'dark'} background in the ${expected} theme`);
      if (!okInk) failures.push(`${state}: ${name} text doesn't read in the ${expected} theme (contrast ${contrast.toFixed(1)}:1)`);
    }
    for (const e of errors) failures.push(`${state}: page error: ${e}`);
    console.log(`${state}: checked ${found.length} surfaces`);
    await context.close();
  }
}
await browser.close();

if (failures.length) {
  console.error(`\n${failures.length} theme problem${failures.length > 1 ? 's' : ''}:\n- ${failures.join('\n- ')}`);
  process.exit(1);
}
console.log('\nLight and dark hold everywhere, from the system and from the toggle.');
