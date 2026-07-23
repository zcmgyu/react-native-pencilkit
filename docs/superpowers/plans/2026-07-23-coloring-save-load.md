# Full-History Coloring Save/Load Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let coloring-book mode save its full state (picture + undo/redo history) and restore it on reload, with a user-selectable undo depth (full or capped).

**Architecture:** Add dedicated coloring-state serialization to the native view (`serializeColoringState` / `restoreColoringState`) that PNG-encodes `coloredLayer.image` plus the `coloredSnapshots`/`redoSnapshots` stacks into a versioned JSON→base64 blob. Expose it through the Expo module as `getColoringData`/`setColoringData` and a `maxUndoSteps` prop, surface both in the TS API, and wire the example app to use them in boundary mode. The existing PKDrawing save/load is left untouched for plain mode.

**Tech Stack:** Swift (PencilKit, UIKit, ExpoModulesCore), TypeScript (expo-modules-core), React Native example app.

## Global Constraints

- Serialization format is versioned: top-level `"version": 1` (Int). Copy verbatim.
- Empty string `""` in the blob means a `nil` snapshot — never conflate with a real image.
- `undo`/`redo` arrays are in stack order (index 0 = bottom of stack).
- `maxUndoSteps`: `0` = unlimited; positive `N` caps undo depth; negative clamps to `0`.
- The existing `getCanvasDataAsBase64` / `setCanvasDataFromBase64` (PKDrawing) must remain unchanged.
- No native test harness exists; Swift is verified via Xcode build + on-device manual test. TypeScript is verified via `tsc --noEmit`.

---

### Task 1: Native — coloring-state serialization + undo cap

**Files:**
- Modify: `ios/ReactNativePencilKitView.swift`

**Interfaces:**
- Consumes (existing state on the view): `coloredLayer: UIImageView?`, `coloredSnapshots: [UIImage?]`, `redoSnapshots: [UIImage?]`, `boundaryColoringEnabled: Bool`, `emitUndoRedoStateChanges()`.
- Produces (used by Task 2):
  - `func serializeColoringState() -> String`
  - `func restoreColoringState(_ base64: String) -> Bool`
  - `func setMaxUndoSteps(_ value: Int)`

- [ ] **Step 1: Add the undo-cap stored state + setter + trim helper.**

In `ios/ReactNativePencilKitView.swift`, add the stored property next to the other undo/redo state (near `redoSnapshots`, around line 59):

```swift
  // Undo-depth cap. 0 = unlimited (full history). A positive value caps the
  // number of undo snapshots kept; the oldest are dropped when exceeded.
  private var maxUndoSteps: Int = 0
```

Then add these methods in the `// MARK: - Undo / Redo / Clear` section (after `clearAllCommitted()`, around line 609):

```swift
  // Sets the maximum number of undo steps to retain (0 = unlimited).
  // Trims the current stack immediately so the cap takes effect right away.
  func setMaxUndoSteps(_ value: Int) {
    maxUndoSteps = max(0, value)
    trimUndoStackIfNeeded()
    emitUndoRedoStateChanges()
  }

  // Drops the oldest undo snapshots when a cap is active. No-op when unlimited.
  private func trimUndoStackIfNeeded() {
    guard maxUndoSteps > 0, coloredSnapshots.count > maxUndoSteps else { return }
    coloredSnapshots.removeFirst(coloredSnapshots.count - maxUndoSteps)
  }
```

- [ ] **Step 2: Apply the cap when a stroke is committed.**

In `commitCurrentStroke()`, immediately after the redo-stack reset (line 531, `redoSnapshots = []`), add the trim call:

```swift
    // Save the current coloredLayer state for undo.
    // When undo is pressed, we restore this snapshot.
    coloredSnapshots.append(coloredLayer?.image)
    // New action invalidates the redo stack
    redoSnapshots = []
    // Enforce the undo-depth cap (drops oldest snapshots when set).
    trimUndoStackIfNeeded()
```

- [ ] **Step 3: Add serialize + restore methods.**

Add a new section after `// MARK: - Undo / Redo / Clear` (before `clearBoundaryImage()` is fine, or after `// MARK: - Export`). Place it right after the `setMaxUndoSteps`/`trimUndoStackIfNeeded` methods:

```swift
  // MARK: - Coloring State Save / Load

  // Serialization format version for the coloring-state blob.
  private static let coloringStateVersion = 1

  // Serializes the full coloring state — current picture plus the undo and redo
  // snapshot stacks — into a versioned JSON container, base64-encoded to a single
  // string. Each snapshot is a base64 PNG; an empty string represents a nil
  // snapshot (e.g. the blank state at the bottom of the undo stack).
  // Returns "" when not usable (boundary coloring disabled or no coloredLayer yet).
  func serializeColoringState() -> String {
    guard boundaryColoringEnabled, coloredLayer != nil else { return "" }

    func encode(_ image: UIImage?) -> String {
      guard let image = image, let data = image.pngData() else { return "" }
      return data.base64EncodedString()
    }

    let container: [String: Any] = [
      "version": ReactNativePencilKitView.coloringStateVersion,
      "current": encode(coloredLayer?.image),
      "undo": coloredSnapshots.map(encode),
      "redo": redoSnapshots.map(encode),
    ]

    guard let json = try? JSONSerialization.data(withJSONObject: container) else { return "" }
    return json.base64EncodedString()
  }

  // Restores a coloring state produced by serializeColoringState(). Repopulates the
  // undo/redo stacks and current picture, applies the current undo cap, and refreshes
  // the JS undo/redo availability. Returns false on malformed data or if coloredLayer
  // isn't ready — so this must be called AFTER the boundary image has loaded.
  @discardableResult
  func restoreColoringState(_ base64: String) -> Bool {
    guard coloredLayer != nil,
          let json = Data(base64Encoded: base64),
          let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    else { return false }

    func decode(_ value: Any?) -> UIImage? {
      guard let s = value as? String, !s.isEmpty,
            let data = Data(base64Encoded: s) else { return nil }
      return UIImage(data: data)
    }

    let currentImage = decode(obj["current"])
    let undo: [UIImage?] = (obj["undo"] as? [Any])?.map(decode) ?? []
    let redo: [UIImage?] = (obj["redo"] as? [Any])?.map(decode) ?? []

    coloredSnapshots = undo
    redoSnapshots = redo
    coloredLayer?.image = currentImage
    trimUndoStackIfNeeded()
    emitUndoRedoStateChanges()
    return true
  }
```

- [ ] **Step 4: Verify it compiles (Xcode).**

Run (from repo root):

```bash
cd example && npx expo run:ios --no-bundler 2>&1 | tail -30
```

Expected: the app builds and installs on a simulator/device with no Swift compile errors referencing `serializeColoringState`, `restoreColoringState`, or `setMaxUndoSteps`. (If `expo run:ios` is not set up in this environment, instead open `example/ios` in Xcode and Build — the deliverable is "Swift compiles".)

- [ ] **Step 5: Commit.**

```bash
git add ios/ReactNativePencilKitView.swift
git commit -m "feat(ios): coloring-state serialize/restore + undo-depth cap

Claude-Session: https://claude.ai/code/session_01G7nbEjF68u1QS7Zjx8V9Wk"
```

---

### Task 2: Native — expose module functions + prop

**Files:**
- Modify: `ios/ReactNativePencilKitModule.swift`

**Interfaces:**
- Consumes (from Task 1): `pencilKitView?.serializeColoringState()`, `pencilKitView?.restoreColoringState(_:)`, `view.setMaxUndoSteps(_:)`.
- Produces (used by Task 3, JS bridge names): AsyncFunction `getColoringData(viewTag) -> String`, AsyncFunction `setColoringData(viewTag, base64String) -> Bool`, Prop `maxUndoSteps: Int?`.

- [ ] **Step 1: Add the `maxUndoSteps` prop.**

In `ios/ReactNativePencilKitModule.swift`, inside the `View(ReactNativePencilKitView.self) { ... }` block, add after the `pageTransformEnabled` prop (line 61):

```swift
      Prop("maxUndoSteps") { (view: ReactNativePencilKitView, value: Int?) in
        view.setMaxUndoSteps(value ?? 0)
      }
```

- [ ] **Step 2: Add the two async functions.**

In the same file, after the `setCanvasDataFromBase64` AsyncFunction (line 118), add:

```swift
    // Get full coloring state (picture + undo/redo history) as base64
    AsyncFunction("getColoringData") { (_: Int) -> String in
      return await MainActor.run {
        self.pencilKitView?.serializeColoringState() ?? ""
      }
    }

    // Restore full coloring state from base64 (produced by getColoringData)
    AsyncFunction("setColoringData") { (_: Int, base64String: String) -> Bool in
      return await MainActor.run {
        self.pencilKitView?.restoreColoringState(base64String) ?? false
      }
    }
```

- [ ] **Step 3: Verify it compiles (Xcode).**

Run (from repo root):

```bash
cd example && npx expo run:ios --no-bundler 2>&1 | tail -30
```

Expected: builds with no Swift errors. (Fallback: Build in Xcode.)

- [ ] **Step 4: Commit.**

```bash
git add ios/ReactNativePencilKitModule.swift
git commit -m "feat(ios): expose getColoringData/setColoringData + maxUndoSteps prop

Claude-Session: https://claude.ai/code/session_01G7nbEjF68u1QS7Zjx8V9Wk"
```

---

### Task 3: TypeScript API — types + ref wiring

**Files:**
- Modify: `src/ReactNativePencilKit.types.ts`
- Modify: `src/ReactNativePencilKitView.tsx`

**Interfaces:**
- Consumes (from Task 2): native module methods `getColoringData(viewTag)`, `setColoringData(viewTag, base64String)`, and the `maxUndoSteps` prop.
- Produces (used by Task 4): `PencilKitViewProps.maxUndoSteps?: number`, `PencilKitViewRef.getColoringData(): Promise<string>`, `PencilKitViewRef.setColoringData(base64String: string): Promise<boolean>`.

- [ ] **Step 1: Add the prop to `PencilKitViewProps`.**

In `src/ReactNativePencilKit.types.ts`, inside `PencilKitViewProps`, add after `pageTransformEnabled` (line 75):

```typescript
  /**
   * Maximum number of undo steps retained in coloring mode. 0 (default) keeps the
   * full history; a positive value caps it (oldest steps are dropped). A smaller
   * cap also reduces the size of getColoringData() output.
   */
  maxUndoSteps?: number;
```

- [ ] **Step 2: Add the ref methods to `PencilKitViewRef`.**

In the same file, inside `PencilKitViewRef`, add after `setCanvasDataFromBase64` (line 134):

```typescript
  /**
   * Serialize the full coloring-mode state (current picture + undo/redo history)
   * to a base64 string. Returns "" when not in boundary/coloring mode.
   */
  getColoringData(): Promise<string>;
  /**
   * Restore coloring-mode state produced by getColoringData(). Must be called
   * AFTER the boundary image has loaded (onBoundaryImageLoad). Returns false on
   * malformed data or if the coloring layer isn't ready.
   */
  setColoringData(base64String: string): Promise<boolean>;
```

- [ ] **Step 3: Wire the ref methods in the view component.**

In `src/ReactNativePencilKitView.tsx`, inside the `useImperativeHandle` object, add after the `setCanvasDataFromBase64` method (line 145, before `canUndo`):

```typescript
      getColoringData: async (): Promise<string> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.getColoringData(viewTag);
          }
        }
        return "";
      },
      setColoringData: async (
        base64String: string
      ): Promise<boolean> => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            return await ReactNativePencilKit.setColoringData(
              viewTag,
              base64String
            );
          }
        }
        return false;
      },
```

- [ ] **Step 4: Typecheck.**

Run (from repo root):

```bash
npx tsc --noEmit -p tsconfig.json
```

Expected: no errors.

- [ ] **Step 5: Commit.**

```bash
git add src/ReactNativePencilKit.types.ts src/ReactNativePencilKitView.tsx
git commit -m "feat: TS API for getColoringData/setColoringData + maxUndoSteps prop

Claude-Session: https://claude.ai/code/session_01G7nbEjF68u1QS7Zjx8V9Wk"
```

---

### Task 4: Example app — wire save/load + undo-depth control

**Files:**
- Modify: `example/App.tsx`

**Interfaces:**
- Consumes (from Task 3): `pencilKitRef.current.getColoringData()`, `pencilKitRef.current.setColoringData(...)`, the `maxUndoSteps` prop on `PencilKitView`.

- [ ] **Step 1: Add undo-cap state.**

In `example/App.tsx`, add near the other `useState` hooks (after `isFullScreen`, line 111):

```typescript
  const [limitUndo, setLimitUndo] = useState(false);
```

And add a constant near the top-level constants (after `HIT_SLOP`, line 38):

```typescript
const UNDO_CAP = 10;
```

- [ ] **Step 2: Route save through the coloring method in boundary mode.**

Replace `handleSaveCanvasData` (lines 272-285) with:

```typescript
  const handleSaveCanvasData = async () => {
    if (!pencilKitRef.current) return;
    try {
      const data = boundaryImage
        ? await pencilKitRef.current.getColoringData()
        : await pencilKitRef.current.getCanvasDataAsBase64();
      setSavedCanvasData(data);
      Alert.alert(
        "Saved",
        `Canvas data saved (${Math.round(data.length / 1024)} KB)`
      );
    } catch (_) {
      Alert.alert("Error", "Failed to save canvas data");
    }
  };
```

- [ ] **Step 3: Route load through the coloring method in boundary mode.**

Replace `handleLoadCanvasData` (lines 287-304) with:

```typescript
  const handleLoadCanvasData = async () => {
    if (pencilKitRef.current && savedCanvasData) {
      try {
        const ok = boundaryImage
          ? await pencilKitRef.current.setColoringData(savedCanvasData)
          : await pencilKitRef.current.setCanvasDataFromBase64(savedCanvasData);
        if (ok) {
          Alert.alert("Loaded", "Canvas data restored from saved data.");
        } else {
          Alert.alert("Error", "Failed to load canvas data");
        }
      } catch (_) {
        Alert.alert("Error", "Failed to load canvas data");
      }
    } else if (!savedCanvasData) {
      Alert.alert("No data", "Save canvas data first, then load.");
    }
  };
```

- [ ] **Step 4: Pass the `maxUndoSteps` prop to the view.**

In the `<PencilKitView ... />` element, add after `pageTransformEnabled` (line 428):

```tsx
                maxUndoSteps={limitUndo ? UNDO_CAP : 0}
```

- [ ] **Step 5: Add the undo-depth toggle in the coloring-book section.**

In the coloring-book section, inside the `boundaryImage ? (...)` block, add a new switch row after the "Debug overlay" switch row (after line 495, before the `boundaryRegionCount` hint):

```tsx
              <View style={styles.switchRow}>
                <Text style={styles.switchLabel}>Limit undo to {UNDO_CAP} steps</Text>
                <Switch
                  value={limitUndo}
                  onValueChange={setLimitUndo}
                  trackColor={{ true: c.accent }}
                />
              </View>
```

- [ ] **Step 6: Typecheck the example.**

Run (from repo root):

```bash
cd example && npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 7: Commit.**

```bash
git add example/App.tsx
git commit -m "feat(example): coloring save/load + undo-depth toggle

Claude-Session: https://claude.ai/code/session_01G7nbEjF68u1QS7Zjx8V9Wk"
```

---

### Task 5: End-to-end manual verification (on device/simulator)

**Files:** none (verification only).

This is the real end-to-end gate — the layers only integrate at runtime.

- [ ] **Step 1: Build & launch the example.**

```bash
cd example && npx expo run:ios
```

- [ ] **Step 2: Full-history round-trip.**
  1. Pick a coloring page (Boundary image), leave "Limit undo" OFF.
  2. Color 3 distinct regions.
  3. Tap **Save data** — note the KB size in the alert.
  4. Remove the boundary image, then re-add the same one (forces a fresh coloredLayer), OR restart the app if `savedCanvasData` is persisted.
  5. Tap **Load data** — the 3 colored regions reappear.
  6. Tap **Undo** three times — color is removed region-by-region back to blank.
  7. Tap **Redo** three times — color returns region-by-region.
  Expected: picture and full undo/redo history behave exactly as before the save.

- [ ] **Step 3: Capped-history behavior.**
  1. Turn **Limit undo to 10 steps** ON.
  2. Color more than 10 regions.
  3. Tap **Undo** repeatedly — it stops after 10 steps (cannot reach blank).
  4. Tap **Save data** — confirm the KB size is smaller than an equivalent uncapped save.

- [ ] **Step 4: Preview image still works.**
  Tap **Save image & drawing** — the shared PNG shows the background + colored regions (unchanged behavior).

- [ ] **Step 5: Plain-mode regression.**
  Remove the boundary image. Draw freely. **Save data** then **Load data** — strokes restore via the untouched PKDrawing path.

---

## Self-Review

**Spec coverage:**
- Serialization format v1 → Task 1 Step 3. ✓
- `serializeColoringState`/`restoreColoringState` → Task 1. ✓
- Undo cap (`maxUndoSteps`, setter, trim on commit + on restore) → Task 1 Steps 1-3. ✓
- Module functions + prop → Task 2. ✓
- TS props + ref → Task 3. ✓
- Example wiring + depth control → Task 4. ✓
- Preview unchanged / plain-mode unchanged → verified in Task 5 Steps 4-5. ✓
- Timing edge case (load after boundary image) → documented in Task 1 restore method + Task 3 JSDoc; exercised in Task 5 Step 2.4. ✓

**Placeholder scan:** No TBD/TODO; all code steps contain complete code. ✓

**Type consistency:** `serializeColoringState() -> String`, `restoreColoringState(_:) -> Bool`, `setMaxUndoSteps(_:)`, `getColoringData(): Promise<string>`, `setColoringData(base64String): Promise<boolean>`, `maxUndoSteps?: number` — names/signatures match across Tasks 1-4. ✓
