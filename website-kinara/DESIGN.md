# Kinara website: design

## Brief

- **Subject:** Kinara, a free, open-source macOS menu bar app (MIT License). It turns the edges and corners of a Mac trackpad into controls (53 actions).
- **Job:** get it downloaded. Show what it does, then send the visitor to the download or the source on GitHub.
- **Feedback that shaped it:**
  - A long, award-style site was too much: "no one's gonna look".
  - A short Apple-style page looked like a copy of edgebar.xyz.
  - A flat CSS trackpad looked cheap.
  - The demo film's look is the bar: "insanely good".
- **Assets:**
  - the app icon
  - real light and dark screenshots of the menu and settings
  - the 86-second demo film, its three.js trackpad and its stills
- **Placeholders** (`placeholder: true` in `src/data/site.ts`):
  - support email
  - production domain
- **Links that need the GitHub repository to be public:** the download (the latest release) and
  the source.

## Direction: an Apple product page

What the owner asked for, in order:
1. "Make it feel like those Apple websites."
2. Showcase the film grander.
3. Make it smoother.

Every decision below follows Apple's own product-page template, not an interpretation of it.

```
Hero:     Black stage. Gradient eyebrow, 80px SF Pro headline (600, -0.015em), blue pill + "Watch the film".
          The film's graphite trackpad in WebGL below.
Story:    The hero pins for 230% of scroll and plays one story on one progress value:
            - the pad rises
            - the right edge slides (volume HUD)
            - the left edge slides, and the scene dims with it
            - three corners are tapped (dip, ring, action pill)
            - "Now try it"
Gallery:  "Get the highlights." Film clips in 16:9 cards with Apple's dot nav and play/pause. The active clip plays and advances.
Cinema:   "See it in motion." A silent montage in a window that opens to edge-to-edge on scroll.
          Play swaps in the full film with sound, in place. The hero link scrolls here and plays.
Mixer:    Real UI, composited onto a Mac desktop (scripts/desktop-shots.py): wallpaper, menu bar, window chrome,
          simulated vibrancy. The raw offscreen renders are flat grey because macOS can't draw its materials offscreen.
Little:   "Answered in the corner you tapped." A live Mac screen (HTML/CSS, src/components/LittleThings.tsx)
          that answers taps the way the app does: a ported CornerBloom (bead to pill, SwiftUI springs),
          CornerLight and EdgeGlow, with the app's own holds. A guided loop (Double-tap, Rest, Undo, Edge light)
          plays in view; any touch, click, hover or Tab hands the screen to the visitor. Reduced motion: a still frame.
Details:  Bento tiles on #f5f5f7 (light) or #161617 on black (dark), with big gradient stats.
Download: Icon, "Free. Open source, for good.", Download pill, "View the source on GitHub" link,
          three reasons with line icons. The nav's blue pill reads Download and jumps here.
```

## System

- **Type:** the system SF Pro stack, at Apple's sizes and tracking.
  - 80 / 56 / 24 / 21 / 17 / 12 px
  - tracking -0.015em / -0.005em / .009em / .011em / -0.022em / -0.01em
- **Colour:**
  - Light: #fff page, #f5f5f7 alternate, #1d1d1f ink, #6e6e73 secondary.
  - Dark: #000 page, #161617 tiles, #f5f5f7 ink.
  - Actions: #0071e3 buttons; links #0066cc (light) and #2997ff (dark).
  - One gradient (#2ca2ff to #c564ff) for eyebrows and stats.
- **Nav:** Apple's 52px local nav, translucent. It turns dark over `.is-dark` sections, found with a 1px IntersectionObserver strip.
- **Light and dark, everywhere:**
  - Every section follows the theme, from the system and from the toggle, including the hero's 3D studio (`setTheme` in `src/hero3d/scene.js`: a light floor in light, the film's black in dark).
  - Cards, pills and HUDs use the `--glass-*` tokens, never fixed colours. A dark rule needs both forms: `@media (prefers-color-scheme: dark) { :root:not([data-theme='light']) … }` and a `:root[data-theme='dark'] …` twin.
  - Only media stays dark in both: the film and clip frames, like any video.
  - `.is-dark` still re-declares the dark tokens for a section that must be dark in both themes. No section uses it today, and the nav turns dark over one.
  - **Before shipping:** run `npm run check:theme` against a production build. It loads the page in all four states (system light or dark, toggle flipped from each), plus light and dark with Reduced Motion, and fails if any section, the nav at any depth, or a CSS rule doesn't follow the theme.

## Performance notes

- The trackpad's 2048px surface canvas is redrawn and re-uploaded only when something drawn on it changes (`surfaceKey`). Camera moves reuse it.
- DOM controls over the 3D pad are re-placed only when the story moves the camera, never on the idle drift. HUD width is cached, so there is no forced layout per frame.
- DPR is capped at 1.5 on desktop and 1.25 on phones. The scene boots on `requestIdleCallback`, after the intro.
- Measured scrolling through the story at 1440×900: 16.6 ms average frame, 17.6 ms p95, no frames over 33 ms.
- Clips and the film montage use `preload="none"` and play only on screen.

## 3D notes

- The camera has to stay nearly head-on (elevation ~32°, azimuth ~-3°).
  - The studio's strip lights only read on the graphite from that side.
  - At -15° azimuth or more the pad goes black on black.
- Posters: `node scripts/poster.mjs http://127.0.0.1:4400/` re-renders `public/media/hero-pad*.jpg` from the live scene, for loading and for browsers without WebGL.
- Highlight clips, the montage and the film poster are cut from `public/media/kinara-film.mp4` with ffmpeg.
