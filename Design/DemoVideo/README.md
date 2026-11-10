# Kinara demo film

A 96-second demo of Kinara at 60 fps, rendered frame by frame from HTML, CSS and
WebGL (three.js) in headless Chrome, with an original soundtrack synthesised in
code. Nothing is screen-recorded and no stock music is used, so the film can be
re-rendered identically after any edit. The master is 4K: the same 1920 × 1080
layout drawn at twice the pixel density, 3D included.

```bash
cd Design/DemoVideo
npm install
node render.mjs --scale 2 --workers 5 --out kinara-film-4k.mp4   # 4K master → build/DemoVideo/ (about 27 minutes)
node render.mjs                                      # 1080p, for a quick look (about 5 minutes)
```

The site's film, preview loop and clips are cut from the 4K master and scaled
down with Lanczos, so even the 1080p copies are supersampled:

```bash
bash tools/site-media.sh                                  # → website-kinara/public/media/
node tools/blips.mjs ../../build/DemoVideo/kinara-film-4k.mp4   # lists frames unlike both neighbours
```

Run the second after every render: a short run of suspects is fast motion, a
single frame with a high count is a glitch.

Other modes:

```bash
node render.mjs --serve             # scrub it live at http://127.0.0.1:4173/?scrub
node render.mjs --stills 9.5,52.3   # PNG stills → build/DemoVideo/stills/
node render.mjs --from 28.8 --to 38.4   # render one section
node render.mjs --stills 16 --query "scenes=corners&shot=screenTR"   # one scene, one fixed camera
node render.mjs --check 21.35,44    # draw frames twice, cold and warm, and compare them
node soundtrack.mjs out.wav         # just the soundtrack
```

Requires Google Chrome (or set `CHROME_PATH`) and `ffmpeg` with libx264.

## The idea

One studio, one trackpad, one screen. The film opens without a word: a finger
slides the trackpad's right edge in the dark, the screen's edge lights beside
it, and the film's own score rises with the volume. The left edge is
brightness, and the studio lights up with the screen. Then the hook: a groove
lands and the film admits that every app does that much. The tape stops (the
score itself slows to a halt), the lights drain with it, and in the dark and
the silence it asks what's different. A double-tap in the corner answers, and
the name lands on the next downbeat. From there every scene is cut on a
downbeat, and the film keeps hearing itself: the score stops when a corner tap
pauses the music, and ducks when the mixer's call comes in.

| Time | Scene |
| --- | --- |
| 0:00 | Open: the right edge is volume, the left edge is brightness |
| 0:09 | Hook: "Every app does that." The tape stops, the lights go out, "So what's different?" |
| 0:14 | The name, on the trackpad seen from above, which is the logo |
| 0:19 | Corners: a double-tap blooms a glass pill, the same tap undoes it, a resting finger previews |
| 0:26 | Clipboard history: double-tap, slide to choose, lift to paste |
| 0:36 | The screen answers in light: the edge light in every colour, then the ambient light's lap |
| 0:45 | The mixer: a fader per app, mute, solo, AirPods, and a call that lowers the rest |
| 0:55 | Every app gets its own edges |
| 1:02 | It feels built in: a tick for every 1%, notches, finer steps, haptics |
| 1:12 | 53 actions, then Night Shift, extra dim, tiling and palm rejection on the beat |
| 1:21 | Almost no battery, private by design, free and open source, and the end card with the links |

## How it fits together

- `src/timeline.js` is the score: scene boundaries, every gesture, and every
  sound cue. Both the picture and the soundtrack read it, so they never drift.
- `src/world.js` is the set: the graphite trackpad on a black gloss floor that
  mirrors it, and the screen floating behind. The screen is a lamp: it lights
  the trackpad, blooms, and reflects in the floor and in the trackpad's glass.
- `src/desktop.js` is the screen's picture: a desktop with Kinara's own
  feedback at the app's sizes and springs (`Kinara/CornerBloom.swift`,
  `Kinara/Overlay.swift`). It is real DOM, laid onto the 3D screen with the
  camera's matrix every frame, so its text is sharp at any distance. Close
  up, the whole screen is laid out larger (CSS zoom) so Chrome draws it at
  the size it is seen.
- `src/camera.js` holds the named shots and the track that moves between them.
- `src/scenes/*.js` are the eleven scenes. Each `update(t)` is a pure function of
  time; `window.__seek(t)` in `src/main.js` draws any frame on demand.
- `soundtrack.mjs` synthesises the music (pad, arpeggio, sub bass, drums with
  sidechain) and the sound design (haptic ticks, taps, whooshes, the four-note
  sonic logo), then reverb, EQ and a soft limiter. About −14 LUFS. The hook's
  tape stop is done to the rendered score itself: its playhead slows evenly to
  a halt, so pitch and tempo fall together.

## Capturing every frame whole

Three things in `render.mjs` keep a frame from being captured half-drawn,
which shows in the film as flicker:

- Chrome is told to finish every compositor stage before it draws, and gets a
  larger graphics memory budget. With the usual budget it drops some of the
  screen's large layers for a few frames in close shots.
- A page keeps one screen zoom for life. When the next frame needs another,
  the renderer opens a fresh page at that zoom (`?zoom=N`), because changing
  zoom in place leaves parts of the screen missing for a few frames.
- After seeking, the page gets two animation frames before the capture.

`--check` draws the given times twice, once straight after an unrelated frame
and once after the frame before, and reports any that differ.

To change wording, edit the scene file; to retime, edit `src/timeline.js`; to
reframe, edit the shot in `src/camera.js`.

`src/gl.js`, `src/hero.js`, `hero.html` and `render-hero.mjs` belong to the
website's hero, which borrowed the earlier film's trackpad.
