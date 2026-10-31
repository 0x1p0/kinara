import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
const root = new URL("../", import.meta.url);
const html = readFileSync(new URL("index.html", root), "utf8");
const css = readFileSync(new URL("styles.css", root), "utf8");
test("one main heading, no duplicate IDs, and working fragment targets", () => {
  assert.equal([...html.matchAll(/<h1\b/g)].length, 1);
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const [, id] of html.matchAll(/href="#([^"]+)"/g))
    assert.ok(ids.includes(id), `Missing #${id}`);
});
test("local assets exist and external links point to the public project", () => {
  for (const [, path] of html.matchAll(/(?:src|href)="(\/[^"#]+)"/g))
    assert.ok(existsSync(fileURLToPath(new URL(path.slice(1), root))), path);
  for (const [, href] of html.matchAll(/href="(https:[^"]+)"/g))
    assert.ok(href.startsWith("https://github.com/0x1p0") || href === "https://sway-application.vercel.app/", href);
});
test("native controls, explicit demo labels, and reduced-motion support remain", () => {
  assert.equal([...html.matchAll(/type="range"/g)].length, 2);
  assert.equal([...html.matchAll(/<details\b/g)].length, 18);
  assert.match(html, /Your Mac’s settings won’t change/);
  assert.match(html, /not notarized by Apple/);
  assert.match(html, /Made with care by/);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
});
test("static downloads and release notes match the current app version", () => {
  const plist = readFileSync(new URL("../Sway/Info.plist", root), "utf8");
  const version = plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)</)[1];
  const links = [...html.matchAll(/href="([^"]+\.dmg)"/g)].map((match) => match[1]);
  assert.equal(links.length, 2);
  for (const link of links) assert.equal(link, `https://github.com/0x1p0/sway-application/releases/download/v${version}/Sway-${version}-macos-universal.dmg`);
  assert.ok(html.includes(`releases/tag/v${version}`));
  assert.doesNotMatch(html, /v1\.0\.14/);
});
test("the static action library matches every shipped native action", () => {
  const swift = readFileSync(new URL("../Sway/TrackpadSettings.swift", root), "utf8");
  const native = [...swift.split("var id:")[0].matchAll(/case ([^\n]+)/g)]
    .flatMap((match) => match[1].split(",").map((item) => item.trim().split(/\s|=/)[0]))
    .filter((item) => item !== "disabled").sort();
  const web = [...html.matchAll(/data-action-id="([^"]+)"/g)].map((match) => match[1]).sort();
  assert.equal(web.length, 36);
  assert.deepEqual(web, native);
  assert.equal(new Set(web).size, 36);
});
test("catalog stays usable without JavaScript and clearly describes its limits", () => {
  assert.match(html, /id="library-toolbar" hidden/);
  assert.equal([...html.matchAll(/class="action-group"/g)].length, 6);
  assert.match(html, /never opens a recording stream/);
  assert.match(html, /Other inputs and app mute buttons stay separate/);
  assert.match(html, /Browsing here doesn’t change Sway/);
  assert.match(html, /id="action-count" role="status" aria-live="polite"/);
  assert.match(css, /\[hidden\]\s*\{\s*display: none !important/);
});
