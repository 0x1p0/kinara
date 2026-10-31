# Sway

[Explore Sway](https://sway-application.vercel.app/) · [Download for Mac](https://github.com/0x1p0/sway-application/releases/latest)

Sway puts volume, brightness, microphone controls, media, navigation, and shortcuts on the edges of your Mac's trackpad. The compact, monochrome menu bar panel keeps everyday controls close; edge assignments, setup, and diagnostics live in a separate settings window.

## Install

Download the DMG from [Releases](https://github.com/0x1p0/sway-application/releases),
quit any older running copy, and drag **Sway** onto **Applications** in the
installer window. Eject the disk, then open Sway from Applications. The
**First Launch** file inside the disk contains the same security guidance below.
Prefer a ZIP? Extract it and move `Sway.app` into Applications yourself.

### “Apple could not verify Sway”

The release is **self-signed with a persistent Sway identity, not Developer ID signed or notarized**. That
warning is expected for this distribution; a nicer installer does not remove it.
Only proceed if you trust the download. The preferred option is to try opening
the installed app, then choose **System Settings → Privacy & Security → Open
Anyway** and confirm. See [Apple's first-launch guidance](https://support.apple.com/en-us/102445).
Managed Macs may not permit an exception.

**Terminal alternative, for a trusted copy only:** first install Sway in
Applications and quit it. Open Terminal and run this exact command:

```bash
xattr -dr com.apple.quarantine "/Applications/Sway.app"
```

Then open Sway from Applications again. This removes the quarantine marker
from **only Sway.app and its contents**, bypassing the quarantine-based
first-launch check. It does **not** scan for malware, notarize the app, or
prove it is safe. Check the release checksum before using it. Never change the
path to your entire Applications or Downloads folder, and do not disable
Gatekeeper globally. If access is denied, use Open Anyway or contact your Mac's
administrator; do not bypass a managed-Mac policy. “No such xattr” means that
the specified item has no quarantine marker to remove.

To check the DMG, download its release's `SHA256SUMS.txt` into the same folder,
open Terminal in that folder, and run (adjust the version for older releases):

```bash
grep -F '  Sway-1.1.0-macos-universal.dmg' SHA256SUMS.txt | shasum -a 256 -c -
```

Expect `OK`. A checksum confirms a match to the release files, not independent
proof of safety. Do not open a download if the checksum fails or you distrust
its source.

## Start here

On first launch, a five-step **Welcome to Sway** guide walks through Sway one
calm screen at a time: what it does, Accessibility, a practice swipe, your
style (gesture preset, haptic strength, indicator), and where Sway lives in the
menu bar. macOS's Accessibility prompt appears only when you choose **Allow
Accessibility**, never by surprise at launch, and the guide notices the grant
by itself while it's on screen. The practice swipe uses the safe test: nothing
on your Mac changes. Skipping access keeps the sliders usable; the guide returns
on the next launch until access is ready. Revoked permission also returns the guide.

Use **Show menu bar controls** to reveal the real menu and highlight its icon.
If the icon is hidden or your menu bar is crowded, reopen **Sway from Spotlight
or Applications** to restore an existing Sway window or open separate controls.
The three-dot menu also has **Open Controls…**. Enable **Show in Dock while
windows are open** during setup or in **Settings → General** for Dock access to
open windows. Closing the last window hides the running Dock icon; Sway and its
menu bar controls keep running. Minimizing a window keeps Dock access so you can
restore it. This does not enable launch at login or change the saved Dock preference.
If you pinned Sway using macOS's **Keep in Dock**, uncheck that system option to
remove the pinned shortcut too. Revisit **Settings → About & help → Open guide…**
or **Getting Started…** in the three-dot menu at any time.
**Sway name** is also available as a menu bar display in Appearance settings.

1. Open Sway from the menu bar for brightness and volume sliders and quick gesture controls. Open **Settings** for edge assignments, narrower zones, and other preferences.
2. For trackpad gestures, grant Sway access in **System Settings → Privacy & Security → Accessibility**. Return to Sway and use **Check again** if needed.
3. In Settings, open **Palm protection → Test gestures safely** and click **Start test**. Begin with two fingers inside the left edge, then swipe up or down. Repeat at the right edge. While this test is running, Sway leaves volume, brightness, the pointer, and haptics unchanged.
4. Read the result: Sway shows the rule that accepted or stopped the gesture, the contact count, travel, straightness, and duration. Stop the test before using gestures to adjust your Mac.

By default, the left edge controls brightness and the right edge controls volume. Up increases the level; down decreases it. Every finger must start in the same enabled edge zone. Lift all fingers between attempts, especially after a rejected touch.

In two-finger mode, a normal scroll that has already started stays a normal
scroll until you lift. Sway does not take it over when delayed touch evidence
arrives or when you move toward an edge. Edge-control scroll suppression keeps
the complete inertia tail together instead of letting it scroll the page after
a fixed timeout. New scroll gestures clear previous ownership; mouse wheels
and phase-less precise input remain unaffected. The event tap drains pending
touch frames before choosing ownership at the actual scroll start, using
[macOS's scroll phases](https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property).

## A small menu, a separate settings window

### What’s new in the next release (1.2)

Not yet in a published download; this describes the current source.

**Feel.** Slide inward from the edge while swiping for **fine control**, like
scrubbing a video (a soft tap confirms it). **Speed-sensitive levels** make slow
swipes precise and quick flicks cover more range. **Notches** hold a level at
50% and at your favorite volume or brightness with a crisp tap. All three can
be turned off in Gestures and Haptics.

**More gestures.** A **bottom edge** (one finger, left/right). **Double-tap** and
**tap-and-hold** on edges and on four **corners**: both begin with a short,
still tap, which a resting palm doesn’t produce. Where a tap action exists,
tap-to-click there no longer clicks what’s under the pointer; pressing the
trackpad always clicks. **Layers** give each side edge more actions: hold ⌥
while swiping, or use the other finger count (1 instead of 2, or 2 instead of 1).

**Context.** **App profiles** change only the edges you choose while an app is in
front; a **docked profile** applies while an external display is connected.
Order: app, then docked, then everyday. **Per-device volume limits** are
remembered by Core Audio device UID, so headphones can stay quieter.

**New actions (49 in total).** App volume (the front app only, macOS 14.2+),
switch audio output, seek in track, show now playing, tile window, Night Shift
warmth, True Tone, extra dim, Run a Shortcut, and show edge map. **Editing:**
copy, cut, paste, paste as plain text, paste previous item, clipboard history,
undo/redo, select all, and find. Plus new/close tab, reopen closed tab, lock
screen, and sleep displays.

**Clipboard history** exists only while an action that uses it is assigned. It
is event-driven: Sway reads the clipboard right after a copy it can see (⌘C/⌘X,
its own Copy and Cut, an app switch, or opening the history), never on a timer.
Up to 12 text items live in memory only, never on disk, and anything marked by
a password manager (nspasteboard.org concealed or transient types) is skipped.
Swipe to browse, lift to paste; a rejected or cancelled swipe pastes nothing. Custom
shortcuts and Shortcut names are now recorded **per edge**; edges without their
own recording keep using the original shared pair.

**Displays.** **Brightness follows the pointer**: Apple displays through
DisplayServices, other monitors over **DDC/CI** on Apple silicon where the
monitor supports it, otherwise the built-in display. With the lid closed, a
controllable external display is used. **Extra dim** continues below the
backlight minimum by scaling the display’s gamma; quitting Sway, or macOS when
any process exits, restores it.

**Delight.** A **Follow finger** indicator hugs the matching screen edge and moves
with your finger. A **Now Playing** display shows artwork and progress for media
actions. The Gestures and Taps pages show **live finger positions** on the map.
Hold an optional **edge map** shortcut to see what every edge does in the current
app and where each assignment comes from. **Scroll the menu bar icon** for volume
(⌥ for brightness). The **volume click** follows macOS’s “Play feedback when
volume is changed”. **Export and import** your settings, including profiles;
login and setup state never travel. **`sway://` links** let Shortcuts and scripts
pause, resume or toggle gestures, set volume or brightness within your limits,
or show the edge map; links can’t change assignments.

**A complete redesign.** Settings opens on an **Overview** with Sway's status,
a live map of every zone (click one to edit it), quick toggles, and suggestions
for what to set up next. A grouped sidebar, a master switch with live status,
and refined cards run throughout. The menu bar panel gains a status line, device
names under each level, and quick tiles for the edge map, pausing, and Settings.

**Lighter at idle.** The input tap no longer receives pointer movement; a second
tap exists only while a one-finger gesture holds the pointer, so moving the
mouse never wakes Sway. A paused, icon-only profile measured about 0.015% of
one CPU core and 12.3 MB of physical memory on Apple silicon (one short sample,
not a guarantee).

**Honest limits.** DDC, per-app volume and Now Playing were built against
macOS interfaces that the automated tests can’t exercise with real hardware;
they fail closed and report unavailability rather than pretending. DDC isn’t
available on Intel Macs or through many docks, DisplayLink adapters and TVs,
and ambiguous multi-monitor setups are reported unsupported rather than
guessed. Now Playing reads Music and Spotify through Apple Events (macOS asks
once per player and Sway never launches a player); other players appear only
where macOS still exposes them. Night Shift and True Tone use private
CoreBrightness clients, checked by method signature before every use.

### Expanded edge actions in 1.1.0

Version 1.1.0 adds **26 assignable actions, plus Off**.
Open **Settings → Gestures**, then click
either edge’s action button to browse or search the categorized action library.
Both side edges and the optional top edges use the same library. Existing
brightness/volume assignments stay unchanged when upgrading.

| Category | Actions |
| --- | --- |
| Display & keyboard | Built-in display brightness; keyboard backlight |
| Audio & microphone | Output volume; input gain; speaker mute; microphone hardware mute |
| Media | Previous/next track; play/pause |
| Navigation | Tabs; back/forward; app zoom; page up/down; document start/end |
| Windows & desktops | Switch desktops; Mission Control; App Exposé; show desktop; switch apps; cycle app windows; full screen; minimize window; hide app |
| Tools & shortcuts | Spotlight; screenshot toolbar; Emoji & Symbols; custom up/down shortcuts |

Each option explains its directions and requirements. For horizontal top-edge
swipes, right corresponds to up and left corresponds to down. Reverse direction
applies to both levels and commands. Keyboard lighting, tabs, zoom, pages, and
window cycling step as you move, with distance thresholds and rate limiting;
other commands fire once until all fingers lift. No command backlog or idle
repeat timer is created. Commands stop if the foreground app changes. Safe test
mode never executes an action, changes hardware, or sends a shortcut.

**Microphone controls are not a universal privacy switch.** Gain and hardware
mute affect only macOS’s current default input, not other devices or an app’s
own mute state. These controls never open a recording stream. (The separate
App volume action routes one app’s sound through a Core Audio process tap,
after macOS’s System Audio Recording permission; it is never recorded, saved,
or sent.) Raising or lowering input
gain never unmutes the device. Hardware mute is offered only if the driver
provides a readable, writable mute control, and feedback follows readback.
Unsupported devices are clearly marked; gain zero is never called “muted.”
Device changes cancel pending adjustments instead of retargeting them.

Keyboard lighting uses the native illumination media keys; a read-only private
CoreBrightness capability check hides it when no backlit keyboard is detected.
macOS version, hardware, or ambient-light policy can still prevent changes.
Media keys go to the active media app. Navigation/window tools use standard
macOS shortcuts; apps, keyboard layouts, and remapped/disabled shortcuts can
change their behavior. Sway does not claim the destination app completed an
unacknowledged key request. Screenshot tools open the native toolbar; Sway
does not capture the screen itself.

For an app-specific command, choose **Custom shortcuts** and record the up/right
and down/left combinations in the section that appears below the edge controls.
The pair is shared by edges assigned to Custom shortcuts; these are sent key
combinations, not globally registered hotkeys. Configure the target shortcut
first and avoid destructive commands. The menu bar stays compact; browsing the
larger action library happens in Settings.

The menu bar panel is for frequent adjustments, not a dashboard. Advanced configuration and live contact evidence are kept in the settings window:

Use **Find a setting** to filter categories by words such as typing, haptics, login, or updates. The setup guide is always available at the bottom of the sidebar.

| Category | What you can do |
| --- | --- |
| **Gestures** | Choose Everyday, Precise, or One finger; assign actions and per-edge shortcuts; set feel (fine control, speed, sensitivity, direction); add ⌥ and finger-count layers and optional top and bottom edges. |
| **Taps & corners** | Assign double-tap and tap-and-hold actions to edges and corners, and set corner size. |
| **Profiles** | Override edges for specific apps, or while an external display is connected. |
| **Palm protection** | Tune intent checks, typing protection, and activation distance. Expand Test gestures safely for live evidence without changing device levels. |
| **Volume & brightness** | Set comfort limits, per-device volume limits, favorite levels, brightness following the pointer, and extra dim. |
| **Haptics** | Choose tap style, spacing, gesture-start feedback, notches, and the volume click. |
| **Appearance** | Set theme, menu bar display and scrolling, the on-screen indicator (including Follow finger), and the Now Playing display. |
| **General** | Configure Dock access, excluded apps, pause and edge map shortcuts, launch at login, `sway://` links, and settings export/import. |
| **Software updates** | Check, download, and install signed updates. |
| **About & help** | Reopen setup, see the version, or reset gesture preferences. |

The three-dot button expands quick options inside the same panel, without opening a second popup window. The native panel resizes to fit all options; click again to collapse it. The standalone Controls window resizes the same way.

Pause gestures when you want normal trackpad behavior. Direct sliders remain useful when edge gestures are paused. The settings window can stay open while you work in another app or test physical gestures; the compact menu closes on outside clicks, application switches, or Escape. Its old Keep Open option has been removed. Settings opens focused on the first click. The separate controls window opened from Spotlight or the Dock stays open like a normal window.

### Choose your haptics

Open **Settings → Haptics**. Choose **Soft**, **Standard**, or
**Crisp**, then click **Try this tap** while keeping a finger on your Force Touch
trackpad. Choose **2%, 5%, or 10%** level steps for more or fewer taps, and switch
the gesture-start tap on or off. A start tap confirms gesture acceptance, not a
hardware level change; step taps follow confirmed device readbacks. Reaching a
comfort limit can also tap, even when it is less than one full step away.

These styles select Apple's native haptic patterns, not a physical-strength
slider. macOS, trackpad support, and system preferences determine what you feel;
the system may suppress a tap, especially without finger contact. See
[Apple's haptic feedback documentation](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer).
The preview changes neither volume nor brightness and is disabled during the
safe gesture test. Style and spacing changes apply to your next swipe.
Previously disabled haptics stay disabled after upgrading; switching gesture
presets preserves your haptic choices. An explicit **Reset gestures** restores
Standard, 5% steps, and the start tap.

Taps request immediate delivery instead of waiting for a drawing pass. Feedback
is limited to one request per 80 ms, with no pulse queue or idle timer. Small
back-and-forth jitter does not repeatedly cross a fixed percentage boundary;
spacing is measured from the last tap. Fast swipes may skip intermediate taps,
and late results after a gesture ends do not trigger them. These are scheduling
guarantees, not a promise of identical physical strength on every Mac.

Side-edge widths can be set from **1% to 40%**, and top-edge height from **1% to 30%**. The display and recognizer use the same configured size: a 1% zone is genuinely narrow, not an enlarged invisible activation area. Narrower zones give pointing more room but require more precise touchdown; try them in Palm protection’s safe test before choosing a daily setup.

On macOS 26 and later, the panel uses the system popover's own Liquid Glass, and the floating volume/brightness indicators embed their readout in Apple's native `NSGlassEffectView`. There is no opaque custom backing or second glass layer under the native surface. Earlier supported versions use native translucent material. Reduce Transparency deliberately uses an opaque surface for contrast; Reduce Motion skips the indicator's exit fade. The interface follows the system appearance by default and uses semantic foreground colors instead of colored dashboard tiles. This follows [Apple's Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), including respecting system accessibility choices.

The indicator window is created on first use. Its readout follows the latest value directly, with at most 60 visual updates per second; it does not restart a fill animation for each touch sample. Window ordering and display lookup occur when the indicator appears, not on every sample. The hide deadline extends without allocating a new hide timer per sample, and no indicator timer runs after it is hidden. These are implementation properties, not a claim of zero memory or guaranteed hardware latency: macOS, the audio device, and the compositor still have a cost.

The default menu-bar icon and optional volume readout use hardware notifications, not a permanent polling timer. Open controls refresh display and permission state once per second; closing the menu and settings window stops that refresh. An explicitly selected **Brightness** or **Both** menu-bar readout uses a two-second brightness fallback because DisplayServices does not expose a public scalar-change listener. The menu's SwiftUI view hierarchy is created when opened and released when closed; closing Settings releases that window's view hierarchy too. These lifecycle choices reduce unnecessary background work, but are not measured idle CPU/RAM figures or a promise that an enabled gesture monitor consumes no resources.

### Choosing a gesture setup

- **Everyday** uses two fingers and balanced intent checks. This is the starting point for most people.
- **Precise** uses narrower zones, slower adjustments, stricter movement checks, and a longer delay after typing.
- **One finger** allows single-finger edge gestures. Optional pointer holding starts only after a gesture is accepted.

Top-edge gestures require one-finger mode. Horizontal top gestures use separately assigned left and right halves; vertical top gestures use a single action. Left and right side zones remain available. Selecting a preset changes gesture settings, not your current volume or brightness.

Comfort limits apply to both gesture adjustments and direct sliders. On outputs that support hardware mute, **Mute audio** preserves the saved volume level and works with a positive minimum volume. Other outputs use a zero-volume fallback, which is unavailable when the minimum is above zero. Use **Reset gestures** to restore gesture-related defaults without clearing your excluded apps, shortcut, or appearance.

## Palm protection: evidence you can inspect

Sway does not claim that macOS labels every contact as a finger or a palm. It accepts a gesture only after checking observable touch data:

- Stable contact identities and the required number of contacts.
- Touchdown inside one enabled edge, with both fingers in the same zone.
- Enough contact samples, elapsed time, and movement along the intended axis.
- Consistent direction and path straightness before activation.
- Per-finger movement, so one moving finger alongside a resting contact is insufficient.
- Recent typing, extra contacts, replaced fingers, stale frames, and implausible position jumps.

A rejected contact stays rejected until every finger lifts. Settings changes and interruptions cancel the current gesture. Reversing direction at a limit responds immediately without having to retrace movement beyond that limit.

The **Palm protection → Test gestures safely** section reports these checks directly. Its counts are accepted/stopped gestures, not a claimed palm-classification accuracy. Try deliberate swipes, resting a hand at the edge, typing with a hand on the trackpad, entering an edge from the center, and adding or lifting a finger mid-swipe. Behavior still needs checking on the actual trackpad you use; automated traces cannot prove palm-rejection accuracy for every hand and device. Touch data is processed locally and is not saved by Sway.

## Requirements and device support

- macOS 13 Ventura or later. App volume needs macOS 14.2 or later.
- A compatible Apple Multi-Touch trackpad for edge gestures.
- Accessibility access for gesture monitoring and interception.
- A software-controllable audio output for volume, and a supported display for brightness: the built-in display, an Apple display, or (on Apple silicon) a monitor that accepts DDC/CI brightness commands.

Sway uses the private macOS MultitouchSupport framework. Availability and touch behavior may change with macOS or hardware updates. The panel reports unavailable devices and failed writes instead of presenting a simulated successful adjustment.

## Build and run locally

With Xcode 26 or later selected as your developer toolchain:

```bash
bash scripts/build.sh
```

The script makes an optimized Release build for the current Mac's architecture with a macOS 13 deployment target, treats compiler warnings as errors, and writes an ad-hoc signed app to `build/Sway.app`. It does not replace an installed copy or start gesture monitoring. Open that app when ready to test it. You can also build the `Sway` scheme in `Sway.xcodeproj`.

### In-app updates

Sway checks the public [GitHub Releases](https://github.com/0x1p0/sway-application/releases)
feed on launch when due, then daily while running. **Settings → Software updates**
has an automatic-check switch, a **Check now** button, the last successful check,
and a release link. **Software Updates…** in the three-dot menu opens a compact
update window directly. A newer stable version adds a small dot to Sway's menu icon, an update
link in its menu, and a badge if you use its Dock icon.

Checks fetch release metadata without a token or account sign-in. GitHub receives
your network request, IP address, and Sway version in its user-agent. There is no
hourly polling loop: one nonrepeating timer schedules the next check; failures
back off for an hour. Disabling automatic checks cancels their timer and any
automatic request. Manual checks still work. Errors are reported rather than
called “up to date.” Only stable numeric versions and exact HTTPS release links
for this repo are accepted. Sway never silently downloads or installs software.

When a newer release is available, click **Install update…**. The native
[Sparkle](https://sparkle-project.org/documentation/) flow shows release notes,
downloads the update with your confirmation, verifies it, and offers to install
and relaunch. The feed and archive must both match the Ed25519 public key shipped
in Sway; signature failures never fall back to unsigned updates. The installer
starts only when requested, with automatic downloads and system profiling off.
No second periodic updater runs alongside the daily metadata check.

**Install the current release manually once from this repository.** Copies from the previous
repository still point to its now-private update feed and cannot discover this
release. Future signed releases from this repository can be installed directly. Keep Sway
in Applications, not on its mounted DMG. Installation in a protected location
may require macOS authorization. Update signing is separate from Developer ID
signing/notarization: the first-install warning remains.

### Keeping Accessibility permission across updates

Starting with **1.0.13**, releases use the same certificate-bound app identity
and bundle identifier. Earlier ad-hoc signatures identified each build by its
code hash, so macOS could not reliably carry permission across updates. The
new identity removes that cause; it does not override permission revocation,
administrator policy, or OS changes. See [Apple's code-identity explanation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

**Upgrading from 1.0.10 or earlier may require one final grant.** If Sway is
enabled in Accessibility but gestures do not work, remove only its old entry,
then use **+** to add `/Applications/Sway.app` and enable it. Return to Sway and
choose **Check again**. Quit and reopen once if macOS still reports the old
state. This help is also available in the setup guide and permission card.
Sway never resets TCC or changes another app's permissions automatically.
Users do not need to install or trust a certificate.

Tests verify that two different universal binaries satisfy the same identity
requirement after their temporary signing keychains are removed. These tests
do **not** grant Accessibility or prove end-to-end retention on every macOS
version. Validate that separately using two installed releases at the same
path, allowing access on the first and checking gestures after the second.
Do not replace a release with an ad-hoc development build during that test.

If the installed Xcode build service is unavailable, an explicit compiler fallback uses the same selected SDK:

```bash
bash scripts/build.sh --direct
```

The fallback packages the executable, metadata, and app icon and verifies the local signature. It builds the current architecture; set `SWAY_ARCH=arm64` or `SWAY_ARCH=x86_64` to choose another supported architecture. The Xcode path also supports `SWAY_ARCH=universal` for Apple Silicon and Intel in one app. These builds are ad-hoc signed, not notarized or signed with a Developer ID. Review any macOS security prompt; these scripts do not remove quarantine attributes or disable security checks.

## Publish a release

The repository began with the 1.0.7 source as one initial commit; old
Git history and release notes are not included. **Only the maintainer's account
can update main**, including direct pushes. A PR is optional; Checks runs after
every push to main and on PRs. Main still cannot be deleted or force-pushed.
Release tests and manual signing approval remain mandatory.

Pushing main runs **Checks**; pushing a new version tag runs **Release**.
For a prepared release, use this pattern from the project directory with its
new, unused version tag (1.1.0 is the version shown here). It
stops at the first failure, commits before tagging, and pushes main and the tag
together so the release cannot accidentally target the previous commit:

```bash
git switch main &&
git pull --ff-only origin main &&
git add README.md Sway/Info.plist Sway.xcodeproj/project.pbxproj releases/v1.1.0.md &&
git commit -m "Prepare Sway 1.1.0 release" &&
git tag -a v1.1.0 -m "Sway 1.1.0" &&
git push --atomic origin main v1.1.0
```

The v1.0.7 build failed because a verification tool was missing. The v1.0.8
tag was pushed before the fix merged and still points to 1.0.7 source, so its
version check correctly stopped publication. Both tags stay unchanged; use
the new version tag on the corrected source, not a rerun of either old tag.
The v1.0.11 run stopped in its disposable app-signing test and did not publish.
Its tag also stays unchanged. Version 1.0.12 explicitly registers the temporary
signing Keychain, restores the original search list, and reports safe diagnostic
categories if a signing tool fails. The pinned certificate and both private
signing identities are unchanged.
Version 1.0.12 passed Checks, built the universal app, and signed it successfully,
but packaging stopped because its fresh runner had no `build` directory.
Version 1.0.13 makes packaging create its own staging parent and adds
clean-checkout regression tests to both workflows. The failed tags stay unchanged;
use the new tag rather than rerunning a workflow with the old packaging script.
For later releases, update the app/project version and build number, add
matching release notes, and use that new version consistently in this chain.

Follow the run in [Actions](https://github.com/0x1p0/sway-application/actions):

1. **Build** runs regressions and produces the universal app without secrets.
2. **Approve persistent app signing** waits for release-environment approval.
   A fresh runner validates archive paths, signs the app without executing it,
   removes its temporary keychain, and seals the signed ZIP with a SHA-256 digest.
3. **Package signed app without keys** creates the DMG on another runner.
   Packaging dependencies receive neither private key and cannot change the
   signer-produced ZIP that will be published.
4. **Approve, sign updates, and publish** waits for a **second approval**. Before
   accessing the update key, a fresh runner checks the ZIP against the app
   signer's digest and compares the complete DMG app with that ZIP. Apple's
   CryptoKit then signs the opaque ZIP and feed; a separate verifier checks
   signatures and versions. Publication begins as a draft and becomes immutable
   only after all four download files are uploaded.

For both approvals use **Review deployments → release → Approve and deploy**
after reviewing the source and preceding jobs. Self-approval is allowed for
this single-maintainer repository; administrator bypass remains disabled.
Signing and packaging tools come from protected main, which must still equal
the tag's commit. If main advances while waiting, prepare a new version/tag
instead of moving an existing tag. Artifacts are selected by exact workflow
artifact IDs, never by a loosely matched name.

**SWAY_APP_SIGNING_IDENTITY** and **SPARKLE_PRIVATE_KEY** exist only in the
approval-protected **release environment**, not at repository scope. Each is
provided only to its own signing step, on separate runners. Environment
approval, protected source, fresh runners, and pinned actions reduce risk;
they do not make a compromised maintainer account or malicious approved source
safe. The public app certificate and backup/migration details are documented
in [scripts/signing/README.md](scripts/signing/README.md). Do not casually
replace this certificate; permission continuity depends on keeping it stable.

The existing key also remains in the login Keychain under account
**sway-app-0x1p0**. Only the public key is committed. Keep a secure backup;
do not rotate it casually because installed apps trust that key. The native
signer accepts Sparkle's current 32-byte seed export format and verifies that
it derives the app's public key before writing any signatures.

Repository controls include secret scanning and push protection, dependency
alerts/security updates, owner-only main updates with history protection, maintainer-only creation of
release tags, and blocked tag changes/deletions. Immutability applies to
**published releases in this repository**. No old releases or Git history are
copied here. The repository intentionally stays public so its download and
update URLs work. GitHub-hosted runners remain subject to account allowances
and billing settings.

To build and verify the downloads locally without publishing:

```bash
bash scripts/package-release.sh v1.1.0
```

Packaging requires Python 3.10+, Xcode 26+, and access to both Keychain signing
identities. Artifacts appear under **build/releases/v1.1.0/**; existing outputs
are never overwritten. **SWAY_DEFER_UPDATE_SIGNING=1** skips the update-feed
signature only; it still requires the persistent app identity. For key-free
development builds use `bash scripts/build.sh`, not release packaging.

Sparkle 2.10.0 and its binary checksum are pinned through the Xcode package
lockfile. DMG dependencies are pinned with SHA-256 hashes and installed as
verified wheels in build/DmgTools. These dependencies run only in the
unprivileged packaging job, never either signing job. Dependabot checks GitHub Actions
and DMG dependencies weekly; Sparkle's Xcode package pin and advisories still
need review when preparing releases.

The DMG background is static artwork, not live Liquid Glass. Its saved Finder
layout, app signature, shortcuts, instructions, and checksums are verified
without opening Finder or launching Sway.

### macOS signing limitations

Packaged Sway now enables **Hardened Runtime** and verifies its signature
settings. Self-signed distribution needs one exception:
**com.apple.security.cs.disable-library-validation**, so Sparkle can load
without a shared Developer ID team identity. Two resource entitlements back
specific features: **com.apple.security.automation.apple-events** (Now Playing
reads Music or Spotify; macOS asks per app) and
**com.apple.security.device.audio-input** (App volume’s process tap; macOS asks
for System Audio Recording). No debugger, JIT, or unsigned executable-memory
exception is granted, and the runtime check rejects any other entitlement.

The app remains **self-signed and unnotarized**. This does not remove the
initial Gatekeeper warning, provide Apple-verified publisher identity, or
sandbox the app's Accessibility access. Full distribution signing requires a
Developer ID Application certificate and notarization credentials; an Apple
Development certificate is not a substitute. See
[Sparkle's signing guidance](https://sparkle-project.org/documentation/) and
[Apple's first-launch guidance](https://support.apple.com/en-us/102445).

## Verify the interface

Run the deterministic gesture, native bridge, settings, and controller regressions first:

```bash
bash scripts/test-gestures.sh
bash scripts/test-settings.sh
bash scripts/test-haptics.sh
bash scripts/test-updates.sh
bash scripts/test-update-signing.sh
bash scripts/test-presentation.sh
bash scripts/test-audio.sh
bash scripts/test-brightness.sh
bash scripts/test-controls.sh
bash scripts/test-ddc.sh
bash scripts/test-app-volume.sh
bash scripts/test-now-playing.sh
ruby Tests/runtime_verification_regressions.rb
python3 Tests/app_signing_regressions.py
python3 Tests/app_archive_regressions.py
ruby Tests/release_policy_regressions.rb
```

These feed synthetic contact sequences into the recognizer, validate native record handling, and check settings normalization, controller scheduling, and control-model behavior using isolated preferences and test backends. They do not change system levels, register shortcuts, or enable launch at login. They cover gesture intent and rejection rules; they are not a substitute for testing your physical trackpad.

Runtime-verification regressions sign disposable copies of a system executable
and check them using only macOS system tools. They reject missing Hardened
Runtime, unsigned files, and missing, wrongly typed, or extra entitlements.
No test copy is executed, and no installed executable is modified.

Update regressions use mock HTTP responses with no network or browser launches.
Signing tests use disposable keys to verify that altered feeds, archives, public
keys, URLs, and versions fail validation. Release packaging also verifies the
actual signed feed and ZIP against the public key shipped in the app.
After building, `bash scripts/test-updater-bundle.sh` loads the packaged Sparkle
framework in an isolated app fixture and verifies manual-update readiness and
security configuration. It never requests a download or installation. A full
installed-app update/relaunch still needs testing against a published newer
release; these checks do not claim to simulate that entire interaction.
Presentation tests check native first-click controls and menu actions, update-button
styling, menu-safe outside dismissal, monitor cleanup, setup completion/migration,
repeated popover expansion/collapse, and window-driven Dock presence.
For the bounded native focus test, run `bash scripts/test-presentation.sh --live`
in a graphical session and click **Run focus test** in its safe preview window.
It verifies activation, keyboard focus, minimized-window recovery, and outside-click
delivery, then closes its windows. It does not run
the production app, request permissions, or change hardware or saved preferences.

To measure the paused background lifecycle on your Mac:

```bash
bash scripts/profile-idle.sh
```

This builds an optimized, separate executable from the production sources and runs the real app delegate with temporary in-memory overrides: gestures paused, icon-only menu, no shortcut, no welcome panel, no Dock icon, and automatic update checks disabled. Input to the profile process is ignored so its controls cannot be opened accidentally. It does not adjust hardware, inspect the screen, or change saved Sway preferences. After a three-second warm-up, it samples process CPU time and physical memory footprint across three five-second intervals, then terminates through the app's normal cleanup path. The profiling process has a 25-second runtime limit; compilation is separate from the measurement. Run it in a normal macOS graphical login session.

The result is a short paused/icon-only lower-bound sample from an unbundled harness, not an active gesture benchmark or before/after comparison. OS framework caches, device configuration, user activity, and measurement overhead can affect results; a running app cannot use zero RAM.

One earlier verified run (before automatic updates and the new setup flow) on the development Mac (arm64, macOS 27.0, build 26A428) observed **0.1050% average CPU** across 15.001 sampled seconds, using one CPU core as 100%, and **11.75–11.81 MiB physical footprint**. Its three CPU intervals were 0.2988%, 0.0123%, and 0.0038%. The production and profile preference domains were unchanged after the sample. Those numbers apply only to the paused/icon-only conditions above; active gestures, open controls, Liquid Glass compositing, and an installed bundled build were not measured by this run.

Render the interface:

```bash
bash scripts/render-ui.sh
```

After rendering, run `build/UIRender/RenderUI --verify-native-presentation` in a
graphical session to check the actual popover's visible bounds while expanding
and collapsing in light/dark mode, plus native Dock open/minimize/restore/close
behavior. It briefly shows its own safe preview windows, then closes them; it
never launches production Sway or changes its preferences or hardware levels.

This compiles a separate render executable and saves the compact panel, every settings category, and both floating indicator orientations in light and dark appearances under `build/UIRender/`. Fixtures cover paused gestures, Reduce Transparency, 1% zones, the optional top edge, and every scrolled section. The panel is measured at its real fitting height rather than cropped to an assumed height. Views sit in native windows over a quiet neutral backdrop so material contrast can be reviewed. The indicator fixtures verify that the readout is embedded through `NSGlassEffectView.contentView`, without a clipping ancestor.

The renderer uses the actual SwiftUI hierarchy with isolated temporary preferences and fixed preview values. It never launches Sway's app delegate or enables trackpad monitoring. Native rendering requires a macOS graphical session, and build tools may need their normal compiler permissions. The selected material is OS-dependent: macOS 13–15 uses the fallback, while macOS 26+ selects native Liquid Glass. AppKit's bitmap cache can omit or flatten native glass, so use the reduced-transparency PNGs for reliable layout and contrast inspection. A preview-only override selects the same opaque surface used for Reduce Transparency; it does not change your system accessibility preference. Static PNGs do not verify live compositing or animation; check the actual menu against a light and a dark desktop.

For safe live compositing inspection, the renderer also creates `build/UIRender/Sway UI Preview.app`. This opens the same compact controls in a real native menu-bar popover with preview-only values, not the running Sway app. Quit the preview after inspection. Its quick sliders cannot change hardware levels.

`build/UIRender/Sway Indicator Preview.app` opens actual native indicator windows over contrasting light and dark backdrops. These use the production indicator's AppKit content and glass hierarchy, at fixed sample values; they do not monitor the trackpad, change levels, or load the production app delegate. The backdrop stripes help reveal real refraction. Static PNGs alone cannot prove that effect. Quit this preview with Command-Q after inspection.

When checking the running app, verify the following with the physical hardware:

1. Move a slider, check the actual device level, then use Undo. Try mute/restore with a zero minimum volume.
2. Grant Accessibility access, run a safe test, and compare intentional swipes with resting contacts and typing.
3. Change finger count or zone settings during a touch; lift all fingers and begin again.
4. Pause and resume, try a timed pause, and confirm an excluded app passes gestures through.
5. Change the audio output, connect a display, and check that unsupported controls show an honest unavailable state.
6. Check the compact menu and settings categories in both themes, scroll longer settings pages, and use keyboard navigation. Try Reduce Transparency and Reduce Motion in macOS Accessibility settings.
7. With two-finger gestures enabled, scroll normally in the center, continue toward an edge, then lift and make a deliberate edge swipe. The normal scroll must not freeze or adjust a level. Flick an edge control and wait for inertia to finish; the page must not jump afterward. Quickly alternate center scrolling and edge swipes, and confirm a mouse wheel still scrolls normally.

## Source layout

- `ContentView.swift`: compact menu bar controls, separate settings pages, and test visualization.
- `AppDelegate.swift`: menu bar lifecycle, pause session, panel behavior, and system feedback.
- `TrackpadSettings.swift`: stored preferences and gesture presets.
- `PalmRejectionManager.swift`: deterministic touch recognizer and live evidence.
- `TrackpadMonitor.swift`: hardware frames, event interception, and gesture application.
- `MultitouchBridge.h/.c`: contact copying and private-framework lifecycle.
- `VolumeController.swift` and `BrightnessController.swift`: device support checks and verified adjustment requests.
- `OSDOverlay.swift`: on-screen feedback.
- `HapticFeedback.swift`: selectable native tap patterns and bounded, timer-free gesture feedback.
- `ExcludedAppsManager.swift`, `HotkeyManager.swift`, and `LoginItemManager.swift`: supporting menu bar features. `UpdateChecker.swift` provides optional daily GitHub checks with validated release links. `InAppUpdater.swift` connects user-requested installation to Sparkle. `AppPresentation.swift` handles first-click hosting, window focus, and visible-only popover dismissal.

## License

MIT
