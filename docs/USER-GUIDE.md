# Kinara user guide

Everything Kinara does, and where to find it. For how it works inside, see the
[README](../README.md).

## Install

Download the DMG from [Releases](https://github.com/0x1p0/kinara/releases), quit any
older running copy, and drag **Kinara** onto **Applications** in the installer window. Eject the
disk, then open Kinara from Applications. The **First Launch** file on the disk repeats the
security guidance below. If you'd rather use the ZIP, extract it and move `Kinara.app` into
Applications yourself.

### "Apple could not verify Kinara"

Releases are **self-signed with a persistent identity, not Developer ID signed or notarized**, so
macOS shows this warning. Only continue if you trust the download.

The preferred way: try to open the installed app, then choose **System Settings → Privacy &
Security → Open Anyway** and confirm. See
[Apple's first-launch guidance](https://support.apple.com/en-us/102445). Managed Macs may not
allow an exception.

**Terminal alternative, for a trusted copy only.** Install Kinara in Applications and quit it,
then run exactly:

```bash
xattr -dr com.apple.quarantine "/Applications/Kinara.app"
```

This removes the quarantine marker from **Kinara.app and its contents only**, skipping the
first-launch check. It doesn't scan for malware, notarize the app or prove it's safe. Never point
it at your whole Applications or Downloads folder, never turn Gatekeeper off globally, and never
use it to get around a managed Mac's policy. "No such xattr" means there was no marker to remove.

### Check the download

Put the release's `SHA256SUMS.txt` in the same folder as the DMG, open Terminal there and run
(adjust the version):

```bash
grep -F '  Kinara-1.0.0-macos-universal.dmg' SHA256SUMS.txt | shasum -a 256 -c -
```

Expect `OK`. A matching checksum shows the file is the one released, not that it's safe. Don't
open a download whose checksum fails.

## First launch

A five-step **Welcome to Kinara** guide covers what Kinara does, Accessibility, a practice slide,
your style (preset, haptics, indicator), and where Kinara lives in the menu bar.

- **Accessibility is only requested when you choose Allow Accessibility,** never by surprise at
  launch. The guide notices the grant on its own.
- **The practice slide is safe:** nothing on your Mac changes.
- **Skipping access still works:** the sliders stay usable, and the guide comes back on the next
  launch until access is ready. Losing the permission later brings it back too.

If the menu bar icon is hidden or the menu bar is crowded, open Kinara again from Spotlight or
Applications. While a window is open, Kinara shows in the Dock and ⌘-Tab. Closing the last window
hides it again, and Kinara keeps running.

By default the **left edge is brightness** and the **right edge is volume**: up raises, down
lowers. Lift your fingers between attempts, especially after a rejected touch.

## Settings

Settings has six pages. Each shows what most people need first; **Advanced…** at the bottom of a
page opens the rest.

| Page | On the page | In Advanced |
| --- | --- | --- |
| **Home** | Kinara's status, a map of your trackpad (click a spot to change it), quick toggles | |
| **Edges & corners** | Each edge and corner: what a slide, double-tap and tap-and-hold do, and the edge's width; slide with one or two fingers | Presets, top and bottom edges, second actions, corner taps, custom shortcuts, palm protection, the safe test |
| **Feel** | Haptics, what shows on screen, fine control, speed curve, the 50% notch, direction | Holding the pointer, haptic details, the indicator, the Now Playing card |
| **Sound & display** | Volume and brightness limits, mute at zero, brightness following the pointer, extra dim, every app's fader | Limits for the current output, favorite levels, mixer options |
| **Apps** | App profiles, a docked profile, apps where Kinara pauses | |
| **General** | Login, Dock, appearance, clipboard history, shortcuts, updates, help | Kinara links, settings export and import, troubleshooting |

## Gestures

### Presets

- **Everyday:** two fingers and balanced intent checks. The place to start.
- **Precise:** narrower zones, slower adjustment, stricter movement checks, and a longer pause
  after typing.
- **One finger:** single-finger edge slides. The pointer is held only after a slide is accepted.

A preset changes gesture settings, never your current volume or brightness.

### Edges, corners and layers

- **Side edges** slide up and down. Their width runs from 1% to 40% of the trackpad, and the
  recognizer uses exactly the width you see, so a 1% zone really is narrow.
- **The top edge** (one-finger mode only) can be one action or left and right halves; **the bottom
  edge** slides left and right. For horizontal slides, right counts as up.
- **Double-tap** and **tap-and-hold** work on edges and on the four corners. Both begin with a
  short, still tap, and palms are ignored outright. Where a tap action exists, tapping no longer
  clicks what's under the pointer there; pressing the trackpad always clicks.
- **Second actions** give each side edge more: hold ⌥ while sliding, or use the other finger
  count.
- **A tap on a level action** (volume, say) arms its side edge: the next slide there adjusts it,
  then the edge goes back to normal.
- **Repeating a tap soon after** undoes it where that makes sense (mute, Mission Control, paste
  with ⌘Z).

### Feel

- **Fine control:** slide inward from the edge while sliding to adjust in small steps, like
  scrubbing a video.
- **Speed curve:** slow slides are precise, quick flicks cover more range.
- **Notches** hold a level at 50% and at your favorite volume or brightness, with a crisp tap.
- **Haptics:** choose **Soft**, **Standard**, **Crisp** or **Strongest**, plus how far apart level
  ticks are (every 1%, 5% or 10%) and whether a slide's start ticks. A tick lands as the number on
  screen changes, in the same place every time; at 1% every number gets one. Soft, Standard and
  Crisp are Apple's native patterns, Strongest drives the trackpad's actuator directly. macOS and
  the trackpad decide what you actually feel.
- **Edge light colour:** your accent colour, Aurora, Sunset, Ember, Mint, Mono, or **By action**
  (blue for sound, gold for brightness, green for the microphone). Several colours drift slowly
  along the light. Every choice stays readable on white pages and on black.
- **Ambient light:** the light laps your screen's edges, slowly, until you press a key or click.
  Start it from Feel, put **Ambient light** on a corner double-tap, or use `kinara://ambient`. It
  follows you into full-screen apps; with Reduce Motion it's a still glow instead.

In two-finger mode, a scroll that has already started stays a scroll until you lift; Kinara never
takes it over halfway.

## Actions

There are **53 actions, plus Off**. Click any action button to browse or search the library.

| Category | Actions |
| --- | --- |
| Display & keyboard | Brightness; keyboard backlight; Night Shift warmth; True Tone; extra dim; ambient light |
| Audio & microphone | Volume; app volume; mute app in front; solo app in front; audio apps; switch audio output; input gain; speaker mute; microphone mute |
| Media | Previous/next track; play/pause; seek in track; show now playing |
| Editing | Copy; cut; paste; paste as plain text; paste previous item; clipboard history; undo/redo; select all; find |
| Navigation | Tabs; back/forward; app zoom; page up/down; document start/end; new/close tab; reopen closed tab |
| Windows & desktops | Switch desktops; Mission Control; App Exposé; show desktop; switch apps; cycle app windows; full screen; minimize; hide app; tile window |
| Tools & shortcuts | Spotlight; screenshot toolbar; Emoji & Symbols; run a Shortcut; show edge map; lock screen; sleep displays; custom shortcuts |

Each action explains its directions and requirements in the library.

- **Commands** fire once per slide. Steppers such as tabs, zoom and the keyboard backlight repeat
  as you move, with distance thresholds and rate limiting.
- **Stopping:** a command stops if the app in front changes, and nothing queues up behind it.
- **Keystrokes:** navigation and window actions send standard macOS shortcuts, so remapped or
  disabled shortcuts change what they do.
- **Screenshots:** the screenshot action opens macOS's own toolbar; Kinara never captures the
  screen.
- **Custom shortcuts** send the key combinations you record for each edge (one for up, one for
  down). They aren't global hotkeys. Avoid destructive commands.

**Microphone controls are not a universal privacy switch.** Gain and hardware mute act on
macOS's default input only, never on an app's own mute button. They never open a recording
stream. Hardware mute is offered only when the driver has a readable, writable mute control, and
gain zero is never called "muted".

## Sound and display

- **Comfort limits** apply to slides and sliders alike. Turn on **Own limits** for the current
  output (Sound & display → Advanced) and they're remembered per device, so headphones can stay
  quieter.
- **The mixer** (macOS 14.2+) gives every app that plays sound a fader in the menu bar panel and
  on the Sound & display page. You get mute and **solo**, a **per-app output**, optional
  **boost to 150%**, and **lower other apps during calls**. macOS asks once for System Audio
  Recording; Kinara never records, saves or sends audio.
- **The audio apps picker** opens with a tap: slide to choose an app, then lift to mute or unmute
  it, or slide right first to play only that app.
- **Brightness follows the pointer** across Apple displays and DDC/CI monitors (Apple silicon).
  **Extra dim** continues below the lowest backlight level, and quitting Kinara always restores
  normal brightness.

## Clipboard history

Clipboard history exists only while an action that uses it is assigned. Swipe to browse, lift to
paste; a cancelled swipe pastes nothing. In the picker, type to search, and ⌘1 to ⌘9 paste the
first nine.

- **What it keeps:** 10, 20, 50 or 100 copies, with pictures optional (up to 256 MB, oldest
  first).
- **Where:** in memory only, never on disk. **Clear History** empties it.
- **What it skips:** items a password manager marks as concealed or transient.

## Palm protection

Palms are ignored by their shape, typing or not, and fingertips beside a resting palm still work.
The [README](../README.md#gestures-and-palm-rejection) has the measurements.

To check it on your own trackpad, open **Edges & corners → Advanced → Test safely**. While the
test runs, Kinara changes nothing on your Mac and shows the rule that accepted or stopped each
touch, with its contact count, travel, straightness and duration. Try:

- deliberate slides
- a hand resting at the edge
- typing with a hand on the trackpad
- entering an edge from the middle
- adding or lifting a finger mid-slide

## More

- **Edge map:** hold the shortcut set in **General** to see what every edge does in the app in
  front, and where each assignment comes from.
- **Menu bar icon:** scroll it to change the volume (⌥ for brightness).
- **Kinara links:** `kinara://` links let Shortcuts and scripts pause or resume Kinara, set volume
  or brightness within your limits, show the edge map, or start and stop the ambient light. Links can't change your setup.
- **Export and import:** your settings, including profiles, travel in one file. Login and setup
  state never do.
- **Updates:** Kinara checks GitHub Releases once a day (you can turn this off), and installs only
  when you ask, through Sparkle's signed updates.
- **Diagnostic log:** `~/Library/Logs/Kinara/Kinara.log`, under **General → Advanced →
  Troubleshooting**.
