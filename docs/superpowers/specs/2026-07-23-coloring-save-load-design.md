# Full-history save/load for coloring mode

**Date:** 2026-07-23
**Status:** Approved

## Problem

In boundary/coloring-book mode the "always-empty canvas" architecture clears
`canvasView.drawing` after every committed stroke (`commitCurrentStroke()` sets
`canvasView.drawing = PKDrawing()`). The real colored content lives elsewhere:

- `coloredLayer.image` — the current picture (a rasterized `UIImage`, may be `nil`)
- `coloredSnapshots: [UIImage?]` — the undo stack
- `redoSnapshots: [UIImage?]` — the redo stack

The existing save/load (`getCanvasDataAsBase64` / `setCanvasDataFromBase64`) only
serializes `canvasView.drawing.dataRepresentation()` — an empty `PKDrawing` in
coloring mode. So **save captures nothing and load restores nothing** for the
coloring-book use case.

Separately, `PKDrawing.dataRepresentation()` never captures the `UndoManager`
history, so even in plain drawing mode undo/redo history is lost on reload.

## Goals

1. Save coloring-mode data such that reload restores the picture **and** the full
   undo/redo history (undo/redo replay exactly as before).
2. Let the user choose undo depth: full history, or a bounded cap (e.g. 10 steps).

## Non-goals

- Plain (non-boundary) drawing mode: the existing PKDrawing save/load is unchanged.
- Preview image: `captureImageWithDrawing()` already returns a preview PNG and is
  called separately by the consumer. Not bundled into save data.

## Approach (chosen: A — dedicated coloring-state methods)

Add dedicated methods that serialize the app's own undo model. The existing
`getCanvasDataAsBase64` / `setCanvasDataFromBase64` (PKDrawing) stay untouched for
plain mode, so the two serialization formats never get confused.

## Serialization format (version 1)

A JSON container, then base64-encoded to a single string (matches the existing
string-based API):

```json
{
  "version": 1,
  "current": "<base64 PNG or ''>",
  "undo": ["<base64 PNG or ''>", "..."],
  "redo": ["<base64 PNG or ''>", "..."]
}
```

- Empty string `""` represents a `nil` snapshot (the first undo entry is
  legitimately `nil` — the blank state before any color). Preserving `nil`s keeps
  undo semantics exact.
- `undo` / `redo` arrays are in stack order (index 0 = bottom of stack).
- When an undo cap is active, `undo` (and therefore `redo`) carry at most
  `maxUndoSteps` entries.

## Components

### Native — `ReactNativePencilKitView`

- `serializeColoringState() -> String`
  PNG-encodes `coloredLayer?.image`, `coloredSnapshots`, `redoSnapshots` into the
  container above; returns base64, or `""` if not in boundary mode / no
  `coloredLayer`.
- `restoreColoringState(_ base64: String) -> Bool`
  Decodes, sets `coloredLayer.image`, repopulates both stacks, applies the current
  undo cap (trim), then calls `emitUndoRedoStateChanges()` so the JS undo/redo
  buttons refresh. Returns `false` on malformed data or if `coloredLayer` isn't
  ready.
- Undo depth cap:
  - Stored state `maxUndoSteps: Int = 0` (0 = unlimited).
  - `setMaxUndoSteps(_ value: Int)` setter (clamped to `>= 0`).
  - In `commitCurrentStroke()`, right after `coloredSnapshots.append(...)`: if
    `maxUndoSteps > 0 && coloredSnapshots.count > maxUndoSteps`, drop oldest
    entries from the front.
  - The same trim runs at the end of `restoreColoringState(...)`.

### Native — `ReactNativePencilKitModule`

- `AsyncFunction("getColoringData")` → `pencilKitView?.serializeColoringState()`
- `AsyncFunction("setColoringData")` → `pencilKitView?.restoreColoringState(_:)`
- `Prop("maxUndoSteps")` → `view.setMaxUndoSteps(value ?? 0)`

All on the main actor, mirroring existing patterns.

### TypeScript

- `PencilKitViewProps`: add `maxUndoSteps?: number` (default 0 = unlimited).
- `PencilKitViewRef`: add
  `getColoringData(): Promise<string>` and
  `setColoringData(base64: string): Promise<boolean>`,
  wired in `ReactNativePencilKitView.tsx` like the existing canvas-data methods.

### Example app

- `handleSaveCanvasData` / `handleLoadCanvasData` call the new coloring methods
  when `boundaryImage` is set; fall back to the existing PKDrawing methods
  otherwise.
- A control (Full history switch, or Full / 10-steps toggle) that sets the
  `maxUndoSteps` prop so both behaviors are visible live.

## Timing / edge cases

- `coloredLayer` only exists after `onBoundaryImageLoad`, so **load must happen
  after the boundary image has loaded.** `restoreColoringState` returns `false`
  (no crash) if called too early. The example calls it from a button, well after
  load — fine. Documented in the ref method.
- Trimming drops the *oldest* undo states: at a cap of 10 you can step back 10
  commits but not all the way to blank. Expected behavior for a bounded history.
- Save-file size grows with history depth (one PNG per snapshot). The undo cap is
  the main lever over size; PNG is required because the layer is transparent.

## Testing (manual, on-device)

No native test harness exists in this repo. Verify on device:

1. Load a boundary image, color 3 regions.
2. Tap **Save data**.
3. Reload (remove & re-add the boundary image, or restart the app).
4. Tap **Load data** → the picture returns.
5. Undo steps back through all 3 regions; redo steps forward again.
6. Set the cap to 10, color >10 regions, confirm undo stops after 10 steps and the
   save file is correspondingly smaller.
