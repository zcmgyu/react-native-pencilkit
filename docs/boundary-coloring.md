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

## How Colorable Regions Are Detected

This is the foundation of boundary coloring. A coloring page (black outlines on white) is processed into a **region map** where each pixel knows which zone it belongs to. This happens once when the image loads, on a background thread.

### Step 1: Grayscale Conversion

The image (JPEG, PNG, any format) is rendered into an 8-bit grayscale pixel buffer using `CGContext` with `CGColorSpaceCreateDeviceGray()`. Each pixel becomes a single byte: 0 (black) to 255 (white).

### Step 2: Threshold (Binary Image)

Each pixel is classified based on a configurable threshold (default: 128):
- `pixel > 128` → **white** (colorable area)
- `pixel ≤ 128` → **black** (outline / boundary — not colorable)

The threshold is exposed as the `boundaryThreshold` prop. Higher values make outlines thicker (more pixels treated as black).

### Step 2.5: Outline Dilation (Gap Bridging)

If a coloring page has small gaps in its outlines (the artist's line didn't fully close a shape), CCL would treat both sides of the gap as ONE connected region — letting the user color across the gap into the neighbor.

**Fix:** Before CCL, expand (dilate) the black outline pixels by a configurable radius (default: 3 pixels). This bridges gaps smaller than 2 × radius pixels.

**Algorithm:** Chebyshev distance transform (O(n)):
1. Compute the distance from each white pixel to the nearest black (outline) pixel
2. White pixels with distance ≤ `outlineDilation` become black (added to the outline)

This effectively thickens all outlines before region detection, closing small gaps without significantly changing the region shapes. The `outlineDilation` parameter is passed to `buildRegionMap()` (default: 3).

### Step 3: Connected Component Labeling (CCL)

The key algorithm. Scans every white pixel and groups connected ones into **zones**, each with a unique ID.

**Two-pass algorithm with union-find (4-connectivity):**

**Pass 1** — Scan left-to-right, top-to-bottom:
- For each white pixel, check the pixel **above** and to the **left** (already processed)
- Neither labeled → assign a **new zone ID**
- One labeled → **copy** that zone ID
- Both labeled with different IDs → copy the smaller ID, **union** them (they're the same zone seen from two directions)

**Pass 2** — Flatten all labels:
- Union-find's `find()` with path compression resolves all chains so every pixel points directly to its root zone ID
- Remap to sequential IDs (1, 2, 3, ...) for clean output

**4-connectivity** means we check only up/down/left/right neighbors, not diagonals. Two zones that only touch at a corner are treated as **separate zones**.

**Result:** `regionMap[y * width + x] = zoneID` where 0 = outline, 1+ = colorable zone.

### Step 4: Canvas-Resolution Pre-mapping

The boundary image (e.g., 1030×1207 pixels) is displayed scaled to fit the canvas (e.g., 360×360 points × 3x = 1080×1080 pixels). We pre-compute a mapping from each **screen pixel** to its zone ID, accounting for aspect-fit scaling (letterbox/pillarbox offset).

For each canvas pixel: `imageX = (canvasPixelX - offsetX) / renderWidth * imageWidth`

The result is stored as **per-zone pixel index lists**: a dictionary where each zone ID maps to the list of canvas pixel indices that belong to it. This enables O(zone_size) mask generation instead of O(total_pixels).

### Step 5: Touch → Zone ID

When the user touches the canvas:
1. Get touch point in canvas coordinates (e.g., x: 150, y: 200)
2. Convert to image pixel coordinates using the inverse aspect-fit transform
3. Look up `regionMap[imageY * width + imageX]` → zone ID
4. If zone ID > 0 → apply that zone's mask. If 0 → on an outline, keep current mask.

### Data Flow

```
Image Load (background thread):
  1. Grayscale conversion (CGContext → 8-bit buffer)
  2. Threshold → binary (white = colorable, black = outline)
  2.5. Outline dilation → bridge small gaps in outlines (Chebyshev distance transform)
  3. Connected component labeling → regionMap (each pixel → zone ID)
  4. Canvas-resolution pre-mapping (screen pixel → zone ID, aspect-fit adjusted)
  5. Per-zone pixel index lists for instant mask generation

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
| `ios/RegionMapBuilder.swift` | NEW — CCL, canvas pre-mapping, mask generation |
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
