# Boundary Coloring — Technical Design & Implementation

## Overview

Boundary coloring adds a "coloring book" mode to PencilKit where strokes are confined to individual regions of a coloring page. When the user touches a region and draws, the color stays within that region's boundaries — like the Lake coloring app.

## Architecture: "Always-Empty Canvas"

The final working architecture keeps the PKCanvasView always empty between strokes. Each completed stroke is rendered as a masked image and composited onto a display layer. This avoids all PencilKit API conflicts.

### View Hierarchy

```
contentView (UIView)
  ├── backgroundImageView    [0]  Coloring page image (.scaleAspectFit)
  ├── coloredLayer           [1]  UIImageView — accumulated committed strokes (masked per zone)
  └── canvasView             [2]  PKCanvasView — only the live, in-progress stroke
```

### Data Flow

```
Image Load (background thread):
  1. Threshold image → binary (outline vs colorable)
  2. Connected component labeling → regionMap (each pixel → zone ID)
  3. Distance transform erosion → erodedRegionMap (3px inward from boundaries)
  4. Pre-compute canvasRegionMap at screen pixel resolution
  5. Pre-compute per-region pixel indices for instant mask generation

Touch Down:
  1. ZoneTouchDetector.touchesBegan fires → captures point → immediately fails
  2. handleTouchAtPoint → converts to image pixels → looks up zone ID
  3. applyMaskForRegion → sets CALayer.mask on canvasView (cached, ~1ms)
  4. PencilKit starts stroke on empty canvas (uninterrupted by zone detection)

During Drawing:
  - PencilKit renders stroke on canvasView, clipped by CALayer.mask
  - Stroke is a temporary overlay — NOT in canvasView.drawing.strokes yet

Stroke Finalization (finger lift):
  1. canvasViewDidEndUsingTool fires (stroke NOT yet in drawing.strokes)
  2. canvasViewDrawingDidChange fires (stroke IS now in drawing.strokes)
  3. commitCurrentStroke():
     a. PKDrawing.image() → raw stroke image
     b. destinationIn blend with zone mask → masked stroke (no overflow)
     c. Composite onto coloredLayer.image
     d. canvasView.drawing = PKDrawing() → clear canvas for next stroke
  4. Canvas is empty again — ready for next touch in any zone

Zone Switch:
  - Only changes the CALayer.mask (instant, ~1ms)
  - NO drawing swap — canvas is already empty
  - PencilKit is never disrupted
```

### Key Components

**RegionMapBuilder** (`ios/RegionMapBuilder.swift`)
- Connected component labeling with union-find (O(n))
- Chebyshev distance transform for erosion (O(n), replaces O(n × erosion^2) neighborhood scan)
- Pre-computed canvas-resolution region map with per-region pixel indices
- Mask generation: only iterates region's own pixels (20-100x faster than full scan)
- Pre-computed UIBezierPaths per region (for potential PKStroke.mask use)

**ZoneTouchDetector** (private class in view file)
- Custom UIGestureRecognizer that immediately sets `state = .failed` after capturing touch point
- Does NOT hold the touch — PencilKit's gesture recognizers process it normally
- Critical: PencilKit's `didBeginUsingTool` fires BEFORE our detector, but that's OK because we only need the zone set before the stroke finalizes

**Commit System**
- Triggered in `canvasViewDrawingDidChange` when `strokeCount > previousStrokeCount`
- This is the ONLY reliable moment: stroke data is in `drawing.strokes` AND `currentRegionId` is still correct
- Uses `isCommitting` guard to prevent recursive delegate calls from canvas clear
- Undo: snapshot stack of coloredLayer images before each commit

## PencilKit Timing — Critical Discovery

PencilKit's delegate timing is non-obvious and drove most of the failed approaches:

```
Touch Down:
  1. PKCanvasView's internal recognizers fire → didBeginUsingTool
  2. ZoneTouchDetector.touchesBegan fires → zone detection
  (Order: PencilKit first, our detector second)

During Drawing:
  3. canvasViewDrawingDidChange fires (stroke path growing)
  BUT: the stroke is NOT in drawing.strokes during drawing
       It's a temporary visual overlay managed by PencilKit internally

Finger Lift:
  4. canvasViewDidEndUsingTool fires
  BUT: stroke is STILL not in drawing.strokes at this point!

  5. canvasViewDrawingDidChange fires
  NOW: stroke IS in drawing.strokes (count increases)
  This is the only reliable commit point.
```

## Failed Approaches & Why

### 1. CALayer.mask Only (Accumulated Mask)
**Approach:** Keep all strokes on one canvas. Use accumulated mask revealing all touched zones.
**Problem:** Strokes physically extend across zone boundaries in PKDrawing data. When a neighbor zone is activated, overflow from previous zones becomes visible. With blending tools (watercolor, marker), this creates color mixing at boundaries.
**Verdict:** Works for display clipping but can't prevent overflow between zones.

### 2. Baking in canvasViewDidEndUsingTool
**Approach:** Render canvas to image on finger lift, composite to coloredLayer, clear canvas.
**Problem:** `canvasViewDidEndUsingTool` fires BEFORE the stroke is added to `drawing.strokes`. The render captures an empty canvas. Canvas is "cleared" but was already empty.
**Verdict:** Wrong timing — stroke data not available at this delegate point.

### 3. UILongPressGestureRecognizer for Zone Detection
**Approach:** Use `UILongPressGestureRecognizer(minimumPressDuration: 0)` with `shouldRecognizeSimultaneouslyWith` returning true.
**Problem:** The recognizer enters `.began` → `.changed` → `.ended` lifecycle, competing with PencilKit's internal recognizers. This caused `canvasViewDidEndUsingTool` to fire at the WRONG time (on the NEXT touch instead of finger lift). Confirmed by logs showing `didEndUsingTool` with the next zone's region ID.
**Verdict:** Active gesture recognizer lifecycle interferes with PencilKit's delegate timing.

### 4. Per-Zone Drawing Swap (Synchronous)
**Approach:** Store separate PKDrawing per zone. On zone switch, save current drawing, load new zone's drawing via `canvasView.drawing = newDrawing`.
**Problem:** Setting `canvasView.drawing` resets PencilKit's internal stroke state. The touch that triggered the zone change cannot also start a stroke. User must tap to select zone, then tap again to draw.
**Verdict:** Drawing swap kills the active touch/stroke — fundamental PencilKit limitation.

### 5. Per-Zone Drawing Swap (Deferred)
**Approach:** Same as #4 but swap on `DispatchQueue.main.async` (next run loop). PencilKit starts stroke first, then swap happens.
**Problem:** The swap still kills the in-progress stroke. User sees stroke start then disappear. Inconsistent behavior depending on timing.
**Verdict:** Deferred swap is equally disruptive — just delayed by one frame.

### 6. Per-Zone Drawing Swap in ZoneTouchDetector.touchesBegan
**Approach:** Do the swap synchronously inside the touch detector's `touchesBegan`, before PencilKit processes the touch.
**Problem:** PencilKit's `didBeginUsingTool` fires BEFORE our touch detector (gesture recognizer ordering). By the time we swap, PencilKit has already started processing the touch on the old drawing.
**Verdict:** Cannot guarantee our code runs before PencilKit's touch processing.

### 7. PKStroke.mask (Per-Stroke UIBezierPath)
**Approach:** Keep all strokes on one canvas. After each stroke, set `PKStroke.mask` to the zone's UIBezierPath. PencilKit natively clips each stroke.
**Problem:** Setting `PKStroke.mask` requires creating a new PKStroke and replacing it via `canvasView.drawing = PKDrawing(strokes: modified)`. This is another drawing swap which disrupts PencilKit. Also, the mask UIBezierPath from rasterized regions has thousands of rectangles — performance concern.
**Verdict:** Can't modify strokes without the disruptive drawing swap.

### 8. Large Erosion to Prevent Overflow
**Approach:** Erode each region's mask by 20+ pixels so strokes can never physically reach the neighbor zone.
**Problem:** Creates a visible gap between colored area and the outline. And wide brush strokes (20-30pt) still overflow beyond the erosion gap. Would need 30+ pixel erosion which is extremely visible.
**Verdict:** Cannot erode enough to prevent overflow from wide brushes without unacceptable visual artifacts.

### 9. drawHierarchy / CALayer.render for Baking
**Approach:** Capture the masked canvas via `drawHierarchy(afterScreenUpdates:)` or `CALayer.render(in:)`.
**Problem:** `drawHierarchy` is unreliable with `CALayer.mask` — sometimes captures empty/wrong content. Intermittent behavior ("sometimes keeps color, sometimes doesn't"). `afterScreenUpdates: true` causes timing issues; `false` may capture stale content.
**Verdict:** View-based rendering is unreliable for capturing masked PencilKit content.

### 10. PKDrawing.image() + destinationIn Blend (Wrong Timing)
**Approach:** Use `PKDrawing.image()` (reliable) with Core Graphics `destinationIn` blend mode for masking. Called in `canvasViewDidEndUsingTool`.
**Problem:** Correct rendering approach, but called at the wrong time (stroke not in drawing yet). See Failed Approach #2.
**Verdict:** Right technique, wrong timing. Moving to `canvasViewDrawingDidChange` fixed it.

## What Finally Worked

**PKDrawing.image() + destinationIn blend + commit in canvasViewDrawingDidChange**

The combination of:
1. `ZoneTouchDetector` (immediately fails — doesn't interfere with PencilKit)
2. Commit in `canvasViewDrawingDidChange` when `strokeCount > previousStrokeCount` (only moment stroke data is available AND zone ID is correct)
3. `PKDrawing.image()` for reliable stroke rendering (not view-based)
4. Core Graphics `destinationIn` blend for masking (not CALayer.mask for rendering)
5. `isCommitting` guard to prevent recursive delegates from canvas clear
6. Pre-computed canvas-resolution region map + per-region pixel indices for instant mask generation

## Performance

| Operation | Time | When |
|-----------|------|------|
| Image load + region map + canvas map | ~200-500ms | Once, background thread |
| Zone mask generation (first use) | ~1-3ms | Once per zone, cached |
| Zone switch (mask change) | <1ms | Each touch in new zone |
| Stroke commit (render + mask + composite) | ~15-40ms | After each stroke (async feel — finger already lifted) |
| Undo (pop snapshot) | <1ms | On undo button |

## Undo System

PencilKit's native UndoManager resets when `canvasView.drawing` is set (which happens during commit/clear). Custom undo:

- **coloredSnapshots**: Array of `UIImage?` — the coloredLayer state before each commit
- **Undo**: Pop last snapshot, restore `coloredLayer.image`
- **Redo**: Not supported (would need a separate redo stack)
- **Clear**: Reset all snapshots + coloredLayer + canvas

## Files Modified

| File | Purpose |
|------|---------|
| `ios/RegionMapBuilder.swift` | NEW — CCL, erosion, canvas map, mask generation |
| `ios/ReactNativePencilKitView.swift` | Boundary coloring logic, zone detection, commit system |
| `ios/ReactNativePencilKitModule.swift` | Props, events, undo wiring |
| `src/ReactNativePencilKit.types.ts` | TypeScript interfaces for new props |
| `example/App.tsx` | Coloring book demo section |

## Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `boundaryImagePath` | `{ uri: string }` | — | Coloring page outline image |
| `boundaryColoringEnabled` | `boolean` | `true` | Toggle boundary clipping |
| `boundaryThreshold` | `number` | `128` | Grayscale threshold for outline detection (0-255) |
| `boundaryDebug` | `boolean` | `false` | Show debug overlay for active region |
| `onBoundaryImageLoad` | callback | — | Fires with `{ success, regionCount, width, height }` |
