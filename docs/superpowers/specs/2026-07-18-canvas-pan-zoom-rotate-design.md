# Full-screen canvas with pan / zoom / rotate

**Date:** 2026-07-18
**Status:** Approved design, pending implementation plan
**Scope:** iOS native (`react-native-pencilkit`) + example app

## Summary

Turn the PencilKit canvas into a large workspace where the coloring page (background
image + committed strokes + live drawing surface) is a single movable object. The page
is fit-and-centered by default and can be moved, pinch-zoomed, and rotated with two
fingers, while one finger continues to draw. The example app gains a full-screen toggle
button so the canvas can fill the entire screen.

Boundary coloring (region detection, per-zone masking, commit pipeline) must keep working
unchanged through any transform.

## Goals

- One finger draws; two fingers pan, pinch-zoom, and rotate the page simultaneously.
- Page is centered and aspect-fit by default (identity transform).
- Zoom range 0.5x–5x. At <1x the page is smaller than the viewport and can be dragged
  freely, but a guard keeps at least part of it on-screen so it can never be lost.
- Rotation is free (any angle) with a soft snap back to 0° when within ~5°.
- A full-screen button in the example app expands the canvas to cover the whole screen;
  exiting returns to the framed layout. Toggling re-fits the page to the new size.
- Boundary coloring keeps clipping strokes per-zone at any zoom/rotation/pan.

## Non-goals

- No rotation snapping to 90° steps (free + soft-snap-to-0° only).
- No visible in-canvas reset button (a `resetTransform()` ref method is exposed instead).
- No Android implementation (module is iOS-only today).
- No persistence of the transform across mounts.

## Current state (baseline)

`ios/ReactNativePencilKitView.swift` currently uses a `UIScrollView` for pan/zoom:

- Hierarchy: `self → scrollView → contentView → { backgroundImageView, coloredLayer,
  canvasView, debugMaskOverlay }`.
- `scrollView` zoom is 1.0x–5.0x; `viewForZooming` returns `contentView`, so all layers
  transform together. No rotation. Panning is effectively limited to the zoomed-in case.
- Boundary coloring is **transform-safe already**: zone detection uses
  `location(in: canvasView)` and `convertToImagePixel(_:)` works in canvas-*local* space
  (aspect-fit math), and the stroke commit pipeline
  (`commitCurrentStroke`) renders/masks/composites entirely in canvas-local coordinates.
  Nothing in the coloring path depends on the outer transform.

## Chosen approach: custom transform layer

Replace the `UIScrollView` with a single `pageContainer: UIView` driven by one
accumulated `CGAffineTransform`. Rejected alternative: keeping `UIScrollView` and nesting
a rotation container inside it — rotating content inside a scroll view corrupts its
`contentSize`/scroll-bounds math, making the pan guard and panning erratic when rotated.

A single transform is predictable, composes rotation with zoom cleanly, and requires
**no changes** to the boundary-coloring coordinate math because `location(in: canvasView)`
resolves through the inverse transform automatically.

## Design

### 1. View hierarchy

```
ReactNativePencilKitView (self)
└── pageContainer (UIView)              ← the single transformable object
    ├── backgroundImageView?  [0]
    ├── coloredLayer?         [1]
    ├── canvasView (PKCanvasView) [2]
    └── debugMaskOverlay?     [3]
```

- `pageContainer` replaces both `scrollView` and `contentView`.
- `layoutSubviews` sets `pageContainer.frame = bounds` (identity-centered) and sizes each
  child to `pageContainer.bounds` (same as today, just retargeted from `contentView`).
- All existing references to `contentView` retarget to `pageContainer`.
- `pageContainer.transform` carries pan/zoom/rotate. Default = `.identity` → page is
  centered and aspect-fit (background image already uses `.scaleAspectFit`).

### 2. Gesture layer

Three recognizers added to `self` (not `canvasView`), gated by `pageTransformEnabled`:

- `UIPinchGestureRecognizer` → scale.
- `UIRotationGestureRecognizer` → rotation.
- `UIPanGestureRecognizer` with `minimumNumberOfTouches = 2`, `maximumNumberOfTouches = 2`
  → translation.

A `UIGestureRecognizerDelegate` returns `true` from
`gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` for any pair among these three,
so pinch + rotate + 2-finger pan compose in one motion.

One-finger touches are never claimed by these recognizers (pinch/rotation are inherently
2-touch; pan requires 2 touches), so PencilKit drawing is unaffected for single-finger input.

**Preventing a stray stroke on 2-finger gestures:** when a transform gesture transitions
to `.began` (i.e. a second finger lands mid-stroke), cancel PencilKit's in-flight stroke by
toggling `canvasView.drawingGestureRecognizer.isEnabled` off/on (or setting its `state =
.cancelled`). This guarantees a two-finger gesture never leaves a stray dot. This is the
primary implementation risk and will be tuned during verification.

### 3. Transform math

Maintain the accumulated transform on `pageContainer.transform`, updating live during each
gesture (using each recognizer's incremental delta and resetting the recognizer's
scale/rotation/translation to identity per callback, the standard pattern).

On gesture end, normalize:

- **Scale clamp:** total scale clamped to `[0.5, 5.0]`.
- **Rotation soft-snap:** if the total rotation is within ~5° of 0° (mod 360°), animate it
  to exactly 0°.
- **Translation guard:** clamp translation so the page's transformed bounding box always
  keeps a minimum margin (e.g. ≥ 40pt of the page, or ≥ 20% of the viewport's smaller
  dimension) intersecting the viewport. The page can go mostly off-screen but never fully
  disappear.

Clamp order: compute scale → rotation → translation, then apply the guard using the
resulting transformed frame.

### 4. Boundary coloring

No coordinate changes. Only mechanical retargeting from `contentView` to `pageContainer`
in `applyBoundaryColoring`, `layoutSubviews`, `captureImageWithDrawing`, and the colored-layer
insertion. `convertToImagePixel`, `handleTouchAtPoint`, `generateCanvasMask`,
`commitCurrentStroke`, and `ZoneTouchDetector` remain as-is.

### 5. API surface

TypeScript (`src/ReactNativePencilKit.types.ts`) and native module
(`ios/ReactNativePencilKitModule.swift`, `src/ReactNativePencilKitView.tsx`):

- **New prop** `pageTransformEnabled?: boolean` (default `true`). When `false`, the three
  gesture recognizers are disabled and the page stays at identity — restores the simpler
  fixed-canvas behavior.
- **New ref method** `resetTransform(): Promise<void>`. Animates `pageContainer.transform`
  back to `.identity` (centered + fit). Used by the example app when entering/exiting
  full screen so the page re-fits to the new size.

`minimumZoomScale`/`maximumZoomScale` and rotation-snap threshold are hardcoded to the
values above (0.5–5.0, ~5°); not exposed as props (YAGNI — can be promoted later).

### 6. Example app (`example/App.tsx`)

- Add `isFullScreen` state and a **full-screen toggle button** near the canvas toolbar.
- When `isFullScreen` is `true`, render the `PencilKitView` in an absolute, screen-filling
  container (`StyleSheet.absoluteFill` over a `Modal` or top-level `View`), hiding the
  header/sections, with a floating "exit full-screen" button.
- On toggle (both directions), call `pencilKitRef.current?.resetTransform()` so the page
  re-fits to the new canvas size.

### 7. Data flow

1. User places two fingers → pinch/rotation/pan recognizers begin → in-flight PencilKit
   stroke (if any) is cancelled → `pageContainer.transform` updates live.
2. Gesture ends → transform normalized (scale/rotation/translation clamps + soft-snap).
3. User draws with one finger → `ZoneTouchDetector` fires `handleTouchAtPoint` →
   `location(in: canvasView)` (transform-inverted by UIKit) → `convertToImagePixel` →
   zone lookup → mask applied → stroke drawn clipped to zone → committed to `coloredLayer`.
4. Full-screen toggle (JS) → layout changes → `resetTransform()` re-centers/fits.

### 8. Error handling & edge cases

- `pageTransformEnabled = false`: recognizers disabled; transform forced to identity.
- No boundary image: transform still works on background image / blank canvas.
- Rapid full-screen toggling: `resetTransform` is idempotent and animation-safe.
- Guard prevents the page from being dragged fully off-screen at any zoom.
- Second finger landing mid-stroke cancels that stroke (no stray dot).

## Testing / verification

Native gesture code cannot be meaningfully unit-tested, so verification is manual on the
iOS simulator/device via the example app:

1. One finger draws; two fingers pan/zoom/rotate simultaneously.
2. Zoom to 0.5x, drag the page around — it stays partly visible (guard holds).
3. Rotate slightly then release near upright — snaps to 0°.
4. With a boundary image loaded: while zoomed and rotated, tapping a region still clips
   the stroke to that region; committed strokes land in the correct zone.
5. Full-screen toggle expands/collapses the canvas and re-fits the page.
6. `pageTransformEnabled={false}` disables all transforms.

## Files touched

- `ios/ReactNativePencilKitView.swift` — hierarchy swap, gesture recognizers, transform
  math, `resetTransform`, `pageTransformEnabled`, `contentView`→`pageContainer` retarget.
- `ios/ReactNativePencilKitModule.swift` — register `pageTransformEnabled` prop and
  `resetTransform` async function.
- `src/ReactNativePencilKit.types.ts` — add prop + ref method types.
- `src/ReactNativePencilKitView.tsx` — expose `resetTransform` on the ref.
- `example/App.tsx` — full-screen toggle button + full-screen layout.

## Risks

- **Gesture arbitration with PencilKit** (primary): ensuring 2-finger gestures never draw
  and 1-finger always draws. Mitigation in §2; tuned during verification.
- **PencilKit under rotation:** live-stroke rendering inside a rotated host view. The
  commit pipeline is canvas-local so committed output is unaffected; live rendering to be
  confirmed on-device.
