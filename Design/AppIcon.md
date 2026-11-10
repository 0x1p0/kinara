# Kinara app icon

A graphite macOS tile that *is* a trackpad. A quiet track marks the left edge;
the right edge carries one luminous swipe: a streak of cool white light that
rises and ends in a bright fingertip. It reads as motion and as a level at
once: the edge of your trackpad, being used as a control. Strictly neutral
graphite, silver and white, with a faint cool tint in the light.

Drawn entirely from geometry by `Design/render-icon.swift` (Core Graphics, no
image generation). The tile follows Apple's macOS grid: an 824-point body on a
1024 canvas with continuous corners (radius 185), a soft top sheen, a hairline
rim that catches light, and a grounding shadow.

Small renditions (16, 32 and 64 px) are drawn separately: a bolder streak and
fingertip, without the quiet track or bloom, so the mark stays crisp where
downsampling would blur it.

Regenerate every asset-catalog size and the website icon with:

```bash
bash scripts/update-app-icon.sh
```

Pass a square PNG as the first argument to package external artwork instead.
Both the Xcode build and the direct-build fallback consume this asset set.

The menu bar uses the same idea as a template image (`SwayGlyph` in
`Sway/AppPresentation.swift`): a trackpad outline with a quiet left track and a
solid swipe on the right, dimmed while gestures are paused. Inside Kinara's
windows, logo spots show the app icon itself.
