import test from "node:test";
import assert from "node:assert/strict";
import { getReleaseDownload } from "../release.mjs";

const url =
  "https://github.com/0x1p0/sway-application/releases/download/v1.0.0/Kinara-1.0.0-macos-universal.dmg";
const release = {
  tag_name: "v1.0.0",
  assets: [
    { name: "Kinara-1.0.0-macos-universal.dmg", browser_download_url: url },
  ],
};
test("accepts the exact stable universal DMG", () =>
  assert.deepEqual(getReleaseDownload(release), { version: "v1.0.0", url }));
test("ignores missing, draft, prerelease, and malformed releases", () => {
  for (const value of [
    null,
    {},
    { ...release, draft: true },
    { ...release, prerelease: true },
    { ...release, tag_name: "v2.0.0-beta" },
    { ...release, assets: [] },
    { ...release, assets: {} },
    { ...release, assets: [null] },
  ])
    assert.equal(getReleaseDownload(value), null);
});
test("rejects foreign repositories and mismatched filenames", () => {
  for (const browser_download_url of [
    "https://example.com/app.dmg",
    url.replace("0x1p0", "someone"),
    `${url}?redirect=1`,
    url.replace("v1.0.0/", "v0.9.0/"),
  ]) {
    assert.equal(
      getReleaseDownload({
        ...release,
        assets: [{ ...release.assets[0], browser_download_url }],
      }),
      null,
    );
  }
});
