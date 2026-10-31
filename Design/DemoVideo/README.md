# Sway demo film

A 96-second, 1080p60 demo of Sway, rendered frame by frame from HTML, CSS and
WebGL (three.js) in headless Chrome, with an original soundtrack synthesised in
code. Nothing is screen-recorded and no stock music is used, so the film can be
re-rendered identically after any edit.

```bash
cd Design/DemoVideo
npm install
node render.mjs                     # → build/DemoVideo/Sway-Demo.mp4 (about 3 minutes)
```

Other modes:

```bash
node render.mjs --serve             # scrub it live at http://127.0.0.1:4173/?scrub
node render.mjs --stills 9.5,52.3   # PNG stills → build/DemoVideo/stills/
node render.mjs --from 47.5 --to 60 # render one section
node soundtrack.mjs out.wav         # just the soundtrack
```

Requires Google Chrome (or set `CHROME_PATH`) and `ffmpeg` with libx264.

## How it fits together

- `src/timeline.js` is the score: scene boundaries, every gesture, and every
  sound cue. Both the picture and the soundtrack read it, so they never drift.
- `src/scenes/*.js` are the twelve scenes. Each `update(t)` is a pure function
  of time; `window.__seek(t)` in `src/main.js` draws any frame on demand.
- `src/gl.js` is the 3D trackpad: an extruded graphite slab in a dark studio,
  with Sway's swipe drawn onto its surface and a bloom pass.
- `soundtrack.mjs` synthesises the music (pad, arpeggio, sub bass, drums with
  sidechain) and the sound design (haptic ticks, taps, whooshes, the four-note
  sonic logo), then reverb, EQ and a soft limiter. About −14 LUFS.

| Time | Scene |
| --- | --- |
| 0:00 | The edges of a trackpad light up; the trackpad becomes the icon |
| 0:07 | Logo |
| 0:12 | 3D trackpad: volume and brightness with ticks and the indicator |
| 0:22 | Fine control, speed-sensitive levels, notches, haptics |
| 0:32 | 49 actions |
| 0:40 | Corner taps, tap and hold, palm rejection |
| 0:47 | Clipboard history: double-tap, slide, lift to paste |
| 1:00 | App profiles, docked profile, brightness follows the pointer |
| 1:07 | Per-app volume, device limits, Now Playing seek |
| 1:15 | Edge map, Night Shift, extra dim, tiling, and more |
| 1:22 | Idle cost and privacy |
| 1:27 | End card |

To change wording, edit the scene file; to retime, edit `src/timeline.js`.
