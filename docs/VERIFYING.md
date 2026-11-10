# Verifying Kinara

How to check Kinara beyond reading the code: the automated suites, the offscreen renderer, the
idle profiler, and the checks only physical hardware can do. The [README](../README.md#testing)
lists what each suite covers.

## Automated suites

```bash
bash scripts/test-gestures.sh
bash scripts/test-palm-rejection.sh
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
bash scripts/test-mixer.sh
bash scripts/test-now-playing.sh
ruby Tests/runtime_verification_regressions.rb
python3 Tests/app_signing_regressions.py
python3 Tests/app_archive_regressions.py
python3 Tests/package_release_regressions.py
ruby Tests/release_policy_regressions.rb
```

These feed synthetic contact sequences into the recognizers, validate native record handling, and
check settings normalization, controller scheduling and the control model. They use isolated
preferences and test backends. They never change system levels, register shortcuts, enable launch
at login, or request a permission. They cover gesture intent and rejection rules; they are not a
substitute for your physical trackpad.

- **Runtime verification** signs disposable copies of a system executable and checks them with
  macOS tools only. It rejects a missing Hardened Runtime, unsigned files, and missing, wrongly
  typed or extra entitlements. No copy is executed, and no installed executable is changed.
- **Update suites** use mock HTTP with no network or browser. Signing tests use disposable keys to
  prove that altered feeds, archives, public keys, URLs and versions fail. Release packaging also
  checks the real signed feed and ZIP against the public key shipped in the app.
- **The updater bundle check** runs after a build: `bash scripts/test-updater-bundle.sh` loads the
  packaged Sparkle framework in an isolated app and checks manual-update readiness and security
  settings. It never downloads or installs anything. A full installed update and relaunch still
  needs a newer published release to test against.
- **The live focus test:** `bash scripts/test-presentation.sh --live`, in a graphical session.
  Click **Run focus test** in its preview window. It checks activation, keyboard focus,
  minimized-window recovery and outside-click delivery, then closes its windows, without running
  the production app.

## Idle footprint

```bash
bash scripts/profile-idle.sh
```

This builds a separate, optimized executable from the production sources and runs the real app
delegate with temporary in-memory overrides:

- gestures paused and an icon-only menu
- no shortcut, no welcome panel and no Dock icon
- automatic update checks off

Input to the profile process is ignored. It changes no hardware or saved preferences. After a
3-second warm-up, it samples CPU time and physical memory over three 5-second intervals, then
quits through the normal cleanup path, with a 25-second limit. Run it in a normal graphical
login session.

Read the result as a lower bound for a paused app, not an active-gesture benchmark. OS caches,
devices and activity all affect it, and a running app can't use zero memory.

**Recorded results:**

- **Most recent sample:** about 0.015% of one core and 12.3 MB of physical memory on Apple
  silicon.
- **An earlier, fully logged run** (arm64, macOS 27.0, build 26A428, before automatic updates and
  the new setup guide): **0.105% average CPU** over 15.001 s, with one core as 100%, and an
  **11.75–11.81 MiB** footprint. Its three intervals were 0.2988%, 0.0123% and 0.0038%. Saved
  preferences were unchanged afterwards.

## Rendering the interface

```bash
bash scripts/render-ui.sh
```

This compiles a separate render executable from the real SwiftUI views, with isolated temporary
preferences and fixed preview values, and saves every surface in light and dark under
`build/UIRender/`:

- **What it renders:** the menu panel, each Settings page and its Advanced sheet, the pickers,
  the action library, and both indicator orientations.
- **Fixture states:** paused gestures, Reduce Transparency, 1% zones, the optional top and bottom
  edges, and every scrolled section.

The panel is measured at its real fitting height rather than cropped. A layout audit fails the
run if any control extends past its card or window. The real settings window, including its
title bar and traffic lights, is captured offscreen as `kinara-settings-window-*.png`.

**Previews and glass:**

- **Glass in PNGs:** AppKit's bitmap cache can flatten native glass, so judge layout and contrast
  from the reduced-transparency renders.
- **Live compositing:** `build/UIRender/Kinara UI Preview.app` opens the same controls in a real
  menu-bar popover with preview-only values. Its sliders can't change hardware.
- **Indicator refraction:** `build/UIRender/Kinara Indicator Preview.app` shows real indicator
  windows over striped light and dark backdrops.
- **Native presentation check:** `build/UIRender/RenderUI --verify-native-presentation`, in a
  graphical session, checks the real popover's bounds while expanding and collapsing, and Dock
  open, minimize, restore and close.

None of these launch the production app or change its preferences or hardware levels.

## On physical hardware

1. Move a slider, check the actual device level, then undo. Try mute and restore with a zero
   minimum volume.
2. Grant Accessibility, run **Test safely**, and compare deliberate slides with resting contacts
   and typing.
3. Change finger count or zone width during a touch, then lift everything and start again.
4. Pause and resume, try a timed pause, and confirm a paused app passes gestures through.
5. Change the audio output and connect a display. Unsupported controls must say so plainly.
6. Check the menu panel and every Settings page in both themes, with keyboard navigation, and with
   Reduce Transparency and Reduce Motion on.
7. In two-finger mode, scroll normally in the middle, carry on toward an edge, then lift and make a
   deliberate edge slide. The scroll must never freeze or change a level. Flick an edge control
   and let the inertia finish; the page must not jump afterwards. Alternate quickly between the
   two, and check that a mouse wheel still scrolls normally.
