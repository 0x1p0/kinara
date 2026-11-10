const DOWNLOAD_ROOT =
  "https://github.com/0x1p0/sway-application/releases/download/";

// Never replace a working download with a prerelease, foreign URL, or missing DMG.
export function getReleaseDownload(release) {
  if (
    !release ||
    release.draft ||
    release.prerelease ||
    !/^v\d+\.\d+\.\d+$/.test(release.tag_name) ||
    !Array.isArray(release.assets)
  )
    return null;
  const version = release.tag_name.slice(1);
  const filename = `Kinara-${version}-macos-universal.dmg`;
  const expected = `${DOWNLOAD_ROOT}${release.tag_name}/${filename}`;
  const asset = release.assets.find(
    (item) => item?.name === filename && item.browser_download_url === expected,
  );
  return asset ? { version: release.tag_name, url: expected } : null;
}
