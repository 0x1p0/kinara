// Writes src/data/release.json: the newest release's disk image, read from GitHub, so the
// site's Download buttons fetch the DMG itself. Runs before every build and dev server.
// If GitHub can't be reached it keeps the last file; with no file at all it writes null,
// and the buttons fall back to the releases page.
import { readFile, writeFile } from 'node:fs/promises';

const out = new URL('../src/data/release.json', import.meta.url);
let release = null;
try {
  const response = await fetch('https://api.github.com/repos/0x1p0/kinara/releases/latest', {
    headers: { accept: 'application/vnd.github+json', 'user-agent': 'kinara-website-build' },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
  const latest = await response.json();
  const dmg = latest.assets.find((asset) => asset.name.endsWith('-macos-universal.dmg'));
  if (!dmg) throw new Error(`${latest.tag_name} has no universal disk image`);
  release = { version: latest.tag_name.replace(/^v/, ''), url: dmg.browser_download_url, bytes: dmg.size };
} catch (error) {
  console.warn(`Couldn't read the latest release: ${error.message}`);
  try {
    release = JSON.parse(await readFile(out, 'utf8'));
    if (release) console.warn(`Keeping Kinara ${release.version}.`);
  } catch {}
}
await writeFile(out, `${JSON.stringify(release, null, 2)}\n`);
console.log(release ? `Download: Kinara ${release.version}, ${(release.bytes / 1e6).toFixed(1)} MB` : 'Download: the releases page');
