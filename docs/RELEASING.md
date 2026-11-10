# Releasing Kinara

How Kinara is signed, updated and published, and why each step is there. The short version is
in the [README](../README.md#security-and-release-engineering).

## Signing and permission continuity

Every release is signed by one persistent identity, so macOS carries the Accessibility
permission across updates. An ad-hoc signature identifies each build by its code hash, which is
why development builds need the permission granted again after every rebuild.

- **What the requirement pins:** the designated requirement pins both the bundle ID
  `com.trackpadcontrol.app` and the exact certificate in
  [`scripts/signing/Kinara.cer`](../scripts/signing/Kinara.cer). Release verification compares the
  embedded certificate bytes for every architecture. Don't relax this to a bundle-ID-only
  requirement: anyone could imitate that.
- **Keeping it stable:** don't casually replace the certificate. Permission continuity depends on
  it. The private identity, backup and migration notes are in
  [`scripts/signing/README.md`](../scripts/signing/README.md).
- **For local testing:** use `bash scripts/install-local.sh`. It signs with the persistent
  identity, moves the old copy to the Trash and installs the new one. Never install an ad-hoc
  build over a signed release.
- **If gestures stop working with Kinara switched on in Accessibility,** that entry belongs to a
  different build. Remove it, add `/Applications/Kinara.app` with **+**, and switch it on. Kinara
  never resets privacy permissions itself.

Tests check that two different universal binaries satisfy the same requirement after their
temporary keychains are removed. They don't grant Accessibility or prove retention on every macOS
version. Check that by installing two releases at the same path, granting access on the first,
and trying gestures after the second.

## Hardened Runtime and entitlements

Packaged builds enable Hardened Runtime and grant exactly three entitlements:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.cs.disable-library-validation` | Sparkle loads without a shared Developer ID team while releases are self-signed |
| `com.apple.security.automation.apple-events` | Now Playing reads Music or Spotify; macOS asks once per player |
| `com.apple.security.device.audio-input` | App volume's Core Audio process tap; macOS asks for System Audio Recording |

No debugger, JIT or unsigned-executable-memory exception is granted, and the runtime check rejects
any other entitlement.

## Notarization

The app is **self-signed and not notarized**. That doesn't remove Gatekeeper's first-launch
warning or give an Apple-verified publisher. Removing the warning needs an Apple Developer
Program membership, a **Developer ID Application** certificate and notarization. An Apple
Development certificate can't substitute.

[`scripts/notarize.sh`](../scripts/notarize.sh) signs a copy of `build/Kinara.app` with
Developer ID, inside out, the way Sparkle documents. It submits it to Apple's notary service,
staples the ticket and checks the result with `spctl`. Switching releases to Developer ID changes
Kinara's code identity: people re-enable Kinara in Accessibility once, and after that Developer ID
builds keep the permission. Once every release uses Developer ID, the library-validation
exception can go.

## In-app updates

Kinara checks the [GitHub Releases](https://github.com/0x1p0/kinara/releases) feed on
launch when it's due, then daily. It sends no token or sign-in. GitHub sees the request, the IP
address and Kinara's version in the user agent.

- **Scheduling:** one non-repeating timer, with no hourly polling. Failures back off for an
  hour, and turning automatic checks off cancels the timer.
- **Errors:** reported as errors, never as "up to date". Only stable numeric versions and exact
  HTTPS release links for this repository are accepted.
- **Installing:** happens only on request, through [Sparkle](https://sparkle-project.org). The
  feed and the archive must both match the Ed25519 public key shipped in the app. A signature
  failure never falls back to an unsigned update. Automatic downloads and system profiling are
  off.

## Publishing

Only the maintainer's account can update main, and main can't be deleted or force-pushed.
Pushing main runs **Checks**; pushing a new version tag runs **Release**. For a prepared
release, with a new, unused tag:

```bash
git switch main &&
git pull --ff-only origin main &&
git add README.md Kinara/Info.plist Kinara.xcodeproj/project.pbxproj releases/v1.0.0.md &&
git commit -m "Prepare Kinara 1.0.0 release" &&
git tag -a v1.0.0 -m "Kinara 1.0.0" &&
git push --atomic origin main v1.0.0
```

The chain stops at the first failure, commits before tagging, and pushes main and the tag
together, so a release can't target the previous commit. If a release run fails, leave its tag
alone and publish the fix under a new version.

The **Release** workflow runs four jobs:

1. **Build** runs the regressions and produces the universal app without secrets.
2. **Approve persistent app signing** waits for approval of the `release` environment. A fresh
   runner validates archive paths, signs the app without executing it, removes its temporary
   keychain, and seals the signed ZIP with a SHA-256 digest.
3. **Package signed app without keys** builds the DMG on another runner. Packaging tools never
   see a private key and can't change the signed ZIP that gets published.
4. **Approve, sign updates, and publish** waits for a **second approval**. Before touching the
   update key, a fresh runner checks the ZIP against the signer's digest and compares the DMG's
   app with it. CryptoKit then signs the ZIP and the feed, a separate verifier checks them, and
   the release starts as a draft. It becomes immutable only once all four files are uploaded.

Approve each step with **Review deployments → release → Approve and deploy**, after reviewing the
source and the earlier jobs.

- **Tooling and tags:** signing and packaging tools come from protected main, which must equal
  the tag's commit. If main moves while you wait, make a new version instead of moving a tag.
- **Artifacts** are selected by exact workflow artifact ID, never by name.
- **Secrets:** `KINARA_APP_SIGNING_IDENTITY` and `SPARKLE_PRIVATE_KEY` exist only in the `release`
  environment. Each reaches only its own signing step, on its own runner.
- **The update key** also lives in the login Keychain as Sparkle's own item (service
  `https://sparkle-project.org`), and only
  its public half is committed. Keep a secure backup and don't rotate it casually: installed apps
  trust it.

**Repository controls:** secret scanning and push protection, Dependabot alerts and security
updates, owner-only updates to main with history protection, maintainer-only release tags, and
blocked tag changes and deletions.

## Where downloads live

Kinara is open source, and its releases are hosted on the public repository's
[GitHub Releases](https://github.com/0x1p0/kinara/releases). The update feed (`SUFeedURL`), the
daily check (`UpdateChecker`), the website's download links and the link at the end of
`releases/INSTALL.txt` all point there. They work only while the repository is public: if it is
ever made private again, every Mac running Kinara stops seeing updates, so move the downloads
and the signed appcast to another host first and change those four places together.

## Packaging locally

```bash
bash scripts/package-release.sh v1.0.0
```

This needs Python 3.10+, Xcode 26+ and both signing identities in the Keychain. Artifacts land in
`build/releases/v1.0.0/`, and existing outputs are never overwritten. `KINARA_DEFER_UPDATE_SIGNING=1`
skips only the feed signature; the app identity is still required. For key-free development
builds use `bash scripts/build.sh`.

**Pinned dependencies:**

- **Sparkle 2.10.0** and its binary checksum are pinned in the Xcode package lockfile.
- **DMG tools** are pinned by SHA-256 and installed as verified wheels in `build/DmgTools`. They
  run only in the unprivileged packaging job, never in a signing job.
- **Dependabot** watches GitHub Actions and the DMG tools weekly. Review Sparkle's pin and
  advisories when preparing a release.

The DMG background is static artwork. Its Finder layout, app signature, shortcuts, instructions
and checksums are verified without opening Finder or launching Kinara.
