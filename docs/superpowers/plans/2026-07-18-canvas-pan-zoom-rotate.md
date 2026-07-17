# Full-screen canvas with pan / zoom / rotate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PencilKit page a single movable object — fit-centered by default, with 1-finger drawing and 2-finger pan/zoom/rotate — plus a full-screen toggle in the example app, without breaking boundary coloring.

**Architecture:** Replace the `UIScrollView`/`contentView` pair with one `pageContainer: UIView` driven by an accumulated `CGAffineTransform` (scale + rotation) and `center` (translation). Three 2-touch gesture recognizers (pinch, rotation, pan) on the root view manipulate the page; 1-finger touches fall through to PencilKit. Boundary-coloring coordinate math is unchanged because it already works in canvas-local space.

**Tech Stack:** Swift / UIKit / PencilKit (Expo Modules API), TypeScript (expo-modules-core), React Native (example app).

## Global Constraints

- iOS-only. All native work is in `ios/`; no Android code.
- Follow existing file conventions: `Prop(...)`/`AsyncFunction(...)` in the module, `useImperativeHandle` ref pattern in `ReactNativePencilKitView.tsx`, viewTag-threaded async calls.
- No new npm dependencies.
- Zoom range: `0.5`–`5.0`. Rotation soft-snap threshold: `5°` (`5.0 * .pi / 180.0`). On-screen guard margin: `40` points. These are hardcoded constants, not props.
- New prop default: `pageTransformEnabled` defaults to `true`.
- TypeScript must pass `npm run build` (runs `tsc`). Native verification is a successful Xcode build via `npx expo run:ios` plus the manual checks each task lists (no unit-test framework exists for this native code, per the spec).
- Commit after every task.

---

## File Structure

- `src/ReactNativePencilKit.types.ts` — add prop `pageTransformEnabled` and ref method `resetTransform`.
- `src/ReactNativePencilKitView.tsx` — expose `resetTransform` on the ref.
- `ios/ReactNativePencilKitView.swift` — hierarchy swap, gesture layer, transform normalization, `resetTransform()`, `pageTransformEnabled`.
- `ios/ReactNativePencilKitModule.swift` — register `pageTransformEnabled` prop and `resetTransform` async function.
- `example/App.tsx` — full-screen toggle button + full-screen layout.

---

## Task 1: TypeScript API surface

**Files:**
- Modify: `src/ReactNativePencilKit.types.ts`
- Modify: `src/ReactNativePencilKitView.tsx`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - Prop `pageTransformEnabled?: boolean` on `PencilKitViewProps`.
  - Ref method `resetTransform(): Promise<void>` on `PencilKitViewRef`.
  - Native module call `ReactNativePencilKit.resetTransform(viewTag)` (implemented native-side in Task 5).

- [ ] **Step 1: Add the prop to `PencilKitViewProps`**

In `src/ReactNativePencilKit.types.ts`, inside `interface PencilKitViewProps`, add after the `boundaryDebug` line:

```ts
  /** Show debug overlay highlighting the active colorable region. Default: false. */
  boundaryDebug?: boolean;
  /** Enable 2-finger pan/zoom/rotate of the page. 1 finger always draws. Default: true. */
  pageTransformEnabled?: boolean;
```

- [ ] **Step 2: Add the ref method to `PencilKitViewRef`**

In the same file, inside `interface PencilKitViewRef`, add after `showColorPicker`:

```ts
  showColorPicker(): Promise<void>;
  /** Animate the page back to centered + aspect-fit (identity transform). */
  resetTransform(): Promise<void>;
```

- [ ] **Step 3: Implement `resetTransform` in the ref**

In `src/ReactNativePencilKitView.tsx`, inside the object returned by `useImperativeHandle`, add after the `showColorPicker` method (after its closing `},` on line ~213):

```ts
      resetTransform: async () => {
        if (
          Platform.OS === "ios" &&
          ReactNativePencilKit &&
          viewRef.current
        ) {
          const viewTag = findNodeHandle(viewRef.current);
          if (viewTag) {
            await ReactNativePencilKit.resetTransform(viewTag);
          }
        }
      },
```

- [ ] **Step 4: Typecheck**

Run: `npm run build`
Expected: builds with no TypeScript errors. (A native `resetTransform` isn't registered yet, but TS doesn't validate native calls — this passes.)

- [ ] **Step 5: Commit**

```bash
git add src/ReactNativePencilKit.types.ts src/ReactNativePencilKitView.tsx
git commit -m "feat: add pageTransformEnabled prop and resetTransform ref method (TS)"
```

---

## Task 2: Swap UIScrollView for pageContainer (no behavior change)

Pure refactor: remove the scroll view, introduce `pageContainer`, retarget every `contentView`/`scrollView` reference. After this task the canvas is a static, centered page (no pan/zoom yet) and drawing + boundary coloring still work.

**Files:**
- Modify: `ios/ReactNativePencilKitView.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `private let pageContainer = UIView()` holding the background/colored/canvas/debug subviews; `scrollView` and `contentView` no longer exist; `UIScrollViewDelegate` conformance and `viewForZooming` removed.

- [ ] **Step 1: Replace the stored views**

In `ios/ReactNativePencilKitView.swift`, replace lines 32–33:

```swift
  private let scrollView = UIScrollView()
  private let contentView = UIView()           // The single zoomable child inside scrollView
```

with:

```swift
  private let pageContainer = UIView()          // The single transformable object (background + strokes + canvas)
```

- [ ] **Step 2: Drop the UIScrollViewDelegate conformance**

Replace the class declaration line (line 29):

```swift
public class ReactNativePencilKitView: ExpoView, PKCanvasViewDelegate, PKToolPickerObserver, UIScrollViewDelegate {
```

with:

```swift
public class ReactNativePencilKitView: ExpoView, PKCanvasViewDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate {
```

- [ ] **Step 3: Replace `setupScrollView()` with `setupPageContainer()`**

Replace the whole `setupScrollView()` method (lines 114–122):

```swift
  private func setupScrollView() {
    scrollView.delegate = self               // We implement UIScrollViewDelegate for zoom
    scrollView.minimumZoomScale = 1.0        // No zoom out beyond 1x
    scrollView.maximumZoomScale = 5.0        // Allow 5x zoom in
    scrollView.backgroundColor = .gray       // Visible when canvas is smaller than scroll view
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    addSubview(scrollView)                   // Add scrollView as a child of this view
  }
```

with:

```swift
  private func setupPageContainer() {
    backgroundColor = .gray                  // Shows around the page when it's zoomed out / moved
    pageContainer.backgroundColor = .white
    addSubview(pageContainer)
  }
```

- [ ] **Step 4: Update the initializer call**

Replace line 108 `setupScrollView()` with `setupPageContainer()`. The `init` becomes:

```swift
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupPageContainer()
    setupCanvasView()
  }
```

- [ ] **Step 5: Retarget the view hierarchy in `setupCanvasView()`**

In `setupCanvasView()`, replace lines 142–145:

```swift
    // Build the view hierarchy: contentView contains the canvas (and later, other layers)
    contentView.backgroundColor = .white
    contentView.addSubview(canvasView)
    scrollView.addSubview(contentView)
```

with:

```swift
    // Build the view hierarchy: pageContainer holds the canvas (and later, other layers)
    pageContainer.addSubview(canvasView)
```

- [ ] **Step 6: Rewrite `layoutSubviews()`**

Replace `layoutSubviews()` (lines 161–172) with:

```swift
  override public func layoutSubviews() {
    super.layoutSubviews()
    // Size the page to the view. Only recenter when untransformed — otherwise a
    // layout pass (e.g. full-screen resize) would fight the user's transform; the
    // JS side calls resetTransform() on such resizes.
    pageContainer.bounds = CGRect(origin: .zero, size: bounds.size)
    if pageContainer.transform.isIdentity {
      pageContainer.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    canvasView.frame = pageContainer.bounds                 // Canvas fills the page
    backgroundImageView?.frame = pageContainer.bounds
    coloredLayer?.frame = pageContainer.bounds
    debugMaskOverlay?.frame = pageContainer.bounds
    maskLayer?.frame = canvasView.bounds
  }
```

- [ ] **Step 7: Retarget `contentView` in `applyBoundaryColoring()`**

In `applyBoundaryColoring()` replace lines 349–357:

```swift
    if coloredLayer == nil {
      let layer = UIImageView()
      layer.frame = contentView.bounds
      layer.isUserInteractionEnabled = false   // Touches pass through to the canvas
      layer.backgroundColor = .clear           // Transparent so background shows through
      // Insert above background (index 0) but below canvas
      let insertIndex = backgroundImageView != nil ? 1 : 0
      contentView.insertSubview(layer, at: insertIndex)
      coloredLayer = layer
    }

    canvasView.backgroundColor = .clear
    contentView.backgroundColor = .white
```

with:

```swift
    if coloredLayer == nil {
      let layer = UIImageView()
      layer.frame = pageContainer.bounds
      layer.isUserInteractionEnabled = false   // Touches pass through to the canvas
      layer.backgroundColor = .clear           // Transparent so background shows through
      // Insert above background (index 0) but below canvas
      let insertIndex = backgroundImageView != nil ? 1 : 0
      pageContainer.insertSubview(layer, at: insertIndex)
      coloredLayer = layer
    }

    canvasView.backgroundColor = .clear
    pageContainer.backgroundColor = .white
```

- [ ] **Step 8: Retarget any remaining `contentView` references**

Search the file: `grep -n "contentView\|scrollView" ios/ReactNativePencilKitView.swift`.
Expected remaining hits are in `setBackgroundImage`/`captureImageWithDrawing` and the removed `viewForZooming`. Replace every `contentView` with `pageContainer`. Delete the `viewForZooming(in:)` method and its `// MARK: - UIScrollViewDelegate` comment block (lines 676–682):

```swift
  // MARK: - UIScrollViewDelegate

  // Tells the scroll view which subview to zoom. We zoom the contentView,
  // which contains the background image, colored layer, and canvas together.
  public func viewForZooming(in _: UIScrollView) -> UIView? {
    return contentView
  }
```

(Remove it entirely.) After this, `grep -n "contentView\|scrollView\|UIScrollView" ios/ReactNativePencilKitView.swift` must return nothing.

> Note: `setBackgroundImage` (around line 200–235, not shown here) inserts `backgroundImageView` into `contentView` and sets its frame to `contentView.bounds`. Retarget both to `pageContainer`. Verify with the grep above.

- [ ] **Step 9: Build and manually verify no regression**

Run: `cd example && npx expo run:ios`
Expected: app builds and launches. Verify:
- Drawing with one finger works.
- Loading a boundary image and tapping a region still clips strokes to that region.
- The page is centered. (Pinch-zoom no longer works — expected; added in Task 3.)

- [ ] **Step 10: Commit**

```bash
git add ios/ReactNativePencilKitView.swift
git commit -m "refactor: replace UIScrollView with pageContainer (no behavior change)"
```

---

## Task 3: Gesture transform layer (pan / zoom / rotate)

Add the three 2-touch recognizers and apply live transforms. No clamping yet (Task 4).

**Files:**
- Modify: `ios/ReactNativePencilKitView.swift`

**Interfaces:**
- Consumes: `pageContainer` (Task 2).
- Produces:
  - Stored `private let pinchGR = UIPinchGestureRecognizer()`, `rotationGR = UIRotationGestureRecognizer()`, `panGR = UIPanGestureRecognizer()`.
  - `private(set) var pageTransformEnabled: Bool = true` (consumed by Task 5's prop).
  - `private func cancelActiveStroke()`.
  - Gesture handlers `handlePinch/handleRotation/handlePan`.
  - `UIGestureRecognizerDelegate.gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`.

- [ ] **Step 1: Add stored recognizers and the enabled flag**

In the "Props from React Native" block, after `private var boundaryDebug: Bool = false` (line 81), add:

```swift
  private var boundaryDebug: Bool = false                 // Show debug overlay
  private(set) var pageTransformEnabled: Bool = true      // 2-finger pan/zoom/rotate on/off

  // 2-touch gesture recognizers that transform the page. 1-finger touches are never
  // claimed by these, so PencilKit drawing is unaffected.
  private let pinchGR = UIPinchGestureRecognizer()
  private let rotationGR = UIRotationGestureRecognizer()
  private let panGR = UIPanGestureRecognizer()
```

- [ ] **Step 2: Wire up the recognizers in `setupPageContainer()`**

Append to `setupPageContainer()` (after `addSubview(pageContainer)`):

```swift
    pinchGR.addTarget(self, action: #selector(handlePinch(_:)))
    rotationGR.addTarget(self, action: #selector(handleRotation(_:)))
    panGR.addTarget(self, action: #selector(handlePan(_:)))
    panGR.minimumNumberOfTouches = 2
    panGR.maximumNumberOfTouches = 2
    for gr in [pinchGR, rotationGR, panGR] as [UIGestureRecognizer] {
      gr.delegate = self
      addGestureRecognizer(gr)
    }
```

- [ ] **Step 3: Add the stroke-cancel helper and gesture handlers**

Add a new `// MARK: - Page Transform` section just before `// MARK: - UIScrollViewDelegate` was (now removed; put it before `// MARK: - PKToolPickerObserver`):

```swift
  // MARK: - Page Transform

  // Cancels any in-flight PencilKit stroke by bouncing its drawing recognizer.
  // Called when a 2-finger gesture begins so a transform never leaves a stray dot.
  private func cancelActiveStroke() {
    let g = canvasView.drawingGestureRecognizer
    g.isEnabled = false
    g.isEnabled = true
  }

  @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
    guard pageTransformEnabled else { return }
    switch g.state {
    case .began:
      cancelActiveStroke()
    case .changed:
      pageContainer.transform = pageContainer.transform.scaledBy(x: g.scale, y: g.scale)
      g.scale = 1.0
    case .ended, .cancelled:
      normalizeTransform()
    default:
      break
    }
  }

  @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
    guard pageTransformEnabled else { return }
    switch g.state {
    case .began:
      cancelActiveStroke()
    case .changed:
      pageContainer.transform = pageContainer.transform.rotated(by: g.rotation)
      g.rotation = 0
    case .ended, .cancelled:
      normalizeTransform()
    default:
      break
    }
  }

  @objc private func handlePan(_ g: UIPanGestureRecognizer) {
    guard pageTransformEnabled else { return }
    switch g.state {
    case .began:
      cancelActiveStroke()
    case .changed:
      let t = g.translation(in: self)
      pageContainer.center = CGPoint(x: pageContainer.center.x + t.x,
                                     y: pageContainer.center.y + t.y)
      g.setTranslation(.zero, in: self)
    case .ended, .cancelled:
      normalizeTransform()
    default:
      break
    }
  }
```

- [ ] **Step 4: Add a temporary no-op `normalizeTransform()`**

So the file compiles before Task 4 fills it in. Add right after `handlePan`:

```swift
  // Filled in by Task 4 (clamps + soft-snap + on-screen guard). No-op for now.
  private func normalizeTransform() {}
```

- [ ] **Step 5: Add the simultaneous-recognition delegate method**

Add to the (now `UIGestureRecognizerDelegate`) conformance, next to the transform section:

```swift
  public func gestureRecognizer(_ g: UIGestureRecognizer,
                                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    let mine: Set<ObjectIdentifier> = [ObjectIdentifier(pinchGR),
                                       ObjectIdentifier(rotationGR),
                                       ObjectIdentifier(panGR)]
    return mine.contains(ObjectIdentifier(g)) && mine.contains(ObjectIdentifier(other))
  }
```

- [ ] **Step 6: Build and manually verify**

Run: `cd example && npx expo run:ios`
Expected: builds and launches. Verify:
- Two fingers: pinch zooms, twist rotates, two-finger drag moves — simultaneously in one motion.
- One finger still draws; starting a 2-finger gesture does not leave a stray dot.
- Boundary coloring still clips strokes to the tapped region while zoomed/rotated.
- (No limits yet — you can zoom past 5x or lose the page; fixed in Task 4.)

- [ ] **Step 7: Commit**

```bash
git add ios/ReactNativePencilKitView.swift
git commit -m "feat: 2-finger pan/zoom/rotate gesture layer for the page"
```

---

## Task 4: Transform normalization (clamps, soft-snap, guard)

Fill in `normalizeTransform()` so scale, rotation, and translation stay sane.

**Files:**
- Modify: `ios/ReactNativePencilKitView.swift`

**Interfaces:**
- Consumes: `pageContainer`, `normalizeTransform()` stub (Task 3).
- Produces: `normalizeTransform()` (full) and `private func clampTranslation()`.

- [ ] **Step 1: Replace the `normalizeTransform()` stub**

Replace:

```swift
  // Filled in by Task 4 (clamps + soft-snap + on-screen guard). No-op for now.
  private func normalizeTransform() {}
```

with:

```swift
  // Constants
  private let minScale: CGFloat = 0.5
  private let maxScale: CGFloat = 5.0
  private let rotationSnapRadians: CGFloat = 5.0 * .pi / 180.0  // soft-snap within 5°
  private let onScreenMargin: CGFloat = 40.0                    // page always at least this visible

  // Normalizes the page transform after a gesture ends:
  //   - clamps scale to [minScale, maxScale]
  //   - soft-snaps rotation to 0° when within rotationSnapRadians
  //   - keeps the page partly on-screen (clampTranslation)
  private func normalizeTransform() {
    var t = pageContainer.transform

    // Current scale = magnitude of the transform's first column.
    let scale = sqrt(t.a * t.a + t.c * t.c)
    if scale > 0 {
      let clamped = min(max(scale, minScale), maxScale)
      if clamped != scale {
        let factor = clamped / scale
        t = t.scaledBy(x: factor, y: factor)
      }
    }

    // Soft-snap rotation to upright.
    let angle = atan2(t.b, t.a)
    if abs(angle) < rotationSnapRadians {
      t = t.rotated(by: -angle)
    }

    UIView.animate(withDuration: 0.2) {
      self.pageContainer.transform = t
      self.clampTranslation()
    }
  }

  // Keeps at least onScreenMargin points of the page's (transformed) bounding box
  // inside the view on each axis, so the page can never be dragged fully off-screen.
  private func clampTranslation() {
    let f = pageContainer.frame               // frame accounts for the current transform
    var center = pageContainer.center
    let minX = onScreenMargin - f.width / 2
    let maxX = bounds.width - onScreenMargin + f.width / 2
    let minY = onScreenMargin - f.height / 2
    let maxY = bounds.height - onScreenMargin + f.height / 2
    center.x = min(max(center.x, minX), maxX)
    center.y = min(max(center.y, minY), maxY)
    pageContainer.center = center
  }
```

- [ ] **Step 2: Build and manually verify**

Run: `cd example && npx expo run:ios`
Expected: builds and launches. Verify:
- Zoom stops at ~0.5x (out) and ~5x (in); releasing past the limit animates back.
- Rotating to a small angle then releasing snaps to upright; larger angles hold.
- Dragging the page far in any direction leaves at least a sliver (~40pt) on-screen; it can't disappear.

- [ ] **Step 3: Commit**

```bash
git add ios/ReactNativePencilKitView.swift
git commit -m "feat: clamp scale, soft-snap rotation, guard page on-screen"
```

---

## Task 5: Native `pageTransformEnabled` prop and `resetTransform` function

Wire the flag and reset into the Expo module so JS can drive them.

**Files:**
- Modify: `ios/ReactNativePencilKitView.swift`
- Modify: `ios/ReactNativePencilKitModule.swift`

**Interfaces:**
- Consumes: `pageTransformEnabled` flag and gesture recognizers (Task 3); `pageContainer` (Task 2).
- Produces:
  - `func setPageTransformEnabled(_ enabled: Bool)` on the view.
  - `func resetTransform()` on the view.
  - Module `Prop("pageTransformEnabled")` and `AsyncFunction("resetTransform")` (matches the JS call from Task 1).

- [ ] **Step 1: Add `setPageTransformEnabled` and `resetTransform` to the view**

In `ios/ReactNativePencilKitView.swift`, in the `// MARK: - Page Transform` section (after `handlePan`/before `normalizeTransform`), add:

```swift
  // Enables/disables the 2-finger transform gestures. When disabled, the page snaps
  // back to identity (centered + fit).
  func setPageTransformEnabled(_ enabled: Bool) {
    pageTransformEnabled = enabled
    pinchGR.isEnabled = enabled
    rotationGR.isEnabled = enabled
    panGR.isEnabled = enabled
    if !enabled { resetTransform() }
  }

  // Animates the page back to centered + aspect-fit (identity transform).
  func resetTransform() {
    UIView.animate(withDuration: 0.25) {
      self.pageContainer.transform = .identity
      self.pageContainer.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
    }
  }
```

- [ ] **Step 2: Register the prop in the module**

In `ios/ReactNativePencilKitModule.swift`, inside the `View(...) { ... }` block, after the `boundaryDebug` prop (lines 51–53), add:

```swift
      Prop("boundaryDebug") { (view: ReactNativePencilKitView, debug: Bool?) in
        view.setBoundaryDebug(debug ?? false)
      }

      Prop("pageTransformEnabled") { (view: ReactNativePencilKitView, enabled: Bool?) in
        view.setPageTransformEnabled(enabled ?? true)
      }
```

- [ ] **Step 3: Register the `resetTransform` async function**

Still in `ios/ReactNativePencilKitModule.swift`, add an `AsyncFunction` (place after the `showColorPicker` function block, ~line 131). It resolves the view from the stored `pencilKitView`:

```swift
    // Reset the page transform to centered + fit
    AsyncFunction("resetTransform") { (_: Int) in
      await MainActor.run {
        self.pencilKitView?.resetTransform()
      }
    }
```

- [ ] **Step 4: Build and manually verify**

Run: `cd example && npx expo run:ios`
Expected: builds and launches. Verify (temporarily, via the existing app or a quick prop tweak):
- Setting `pageTransformEnabled={false}` on `PencilKitView` disables 2-finger transform and the page stays centered.
- Calling `pencilKitRef.current.resetTransform()` (e.g. from an existing button handler for a quick test) recenters/re-fits a moved page.

- [ ] **Step 5: Commit**

```bash
git add ios/ReactNativePencilKitView.swift ios/ReactNativePencilKitModule.swift
git commit -m "feat: pageTransformEnabled prop and resetTransform native function"
```

---

## Task 6: Example app full-screen toggle

Add a full-screen button that expands the canvas to fill the screen and re-fits the page.

**Files:**
- Modify: `example/App.tsx`

**Interfaces:**
- Consumes: `PencilKitView` prop `pageTransformEnabled` and ref `resetTransform` (Tasks 1/5).
- Produces: full-screen UI state; no exports.

- [ ] **Step 1: Add full-screen state**

In `example/App.tsx`, with the other `useState` hooks (after line 66), add:

```ts
  const [boundaryRegionCount, setBoundaryRegionCount] = useState(0);
  const [isFullScreen, setIsFullScreen] = useState(false);
```

- [ ] **Step 2: Add a toggle handler that re-fits the page**

Near the other handlers (e.g. after `handleClear`, ~line 130), add:

```ts
  const handleToggleFullScreen = () => {
    setIsFullScreen((prev) => !prev);
    // Re-fit the page to the new canvas size after the layout settles.
    setTimeout(() => pencilKitRef.current?.resetTransform(), 50);
  };
```

- [ ] **Step 3: Add a full-screen button to the canvas toolbar**

In the `toolbarActions` `View` (after the clear/eraser `TouchableOpacity`, ~line 358), add:

```tsx
                <TouchableOpacity
                  style={styles.toolButton}
                  onPress={handleToggleFullScreen}
                  hitSlop={HIT_SLOP}
                >
                  <MaterialCommunityIcons
                    name={isFullScreen ? "fullscreen-exit" : "fullscreen"}
                    size={16}
                    color={COLORS.surface}
                  />
                </TouchableOpacity>
```

- [ ] **Step 4: Render a full-screen overlay when active**

Wrap the return so that when `isFullScreen` is true, the canvas renders in a screen-filling overlay instead of the scrollable layout. Immediately inside the top-level `return (`, before `<SafeAreaView ...>`, add the overlay branch:

```tsx
  if (isFullScreen) {
    return (
      <View style={styles.fullScreenContainer}>
        <PencilKitView
          key={canvasRerenderKey.toString()}
          ref={pencilKitRef}
          style={StyleSheet.absoluteFill}
          imagePath={backgroundImage ? { uri: backgroundImage } : undefined}
          boundaryImagePath={boundaryImage ? { uri: boundaryImage } : undefined}
          boundaryColoringEnabled={boundaryColoringEnabled}
          boundaryDebug={boundaryDebug}
          pageTransformEnabled
          onDrawStart={handleDrawStart}
          onDrawEnd={handleDrawEnd}
          onDrawChange={handleDrawChange}
          onCanUndoChanged={handleCanUndoChanged}
          onCanRedoChanged={handleCanRedoChanged}
          onBoundaryImageLoad={handleBoundaryImageLoad}
        />
        <TouchableOpacity
          style={styles.fullScreenExitButton}
          onPress={handleToggleFullScreen}
          hitSlop={HIT_SLOP}
        >
          <MaterialCommunityIcons name="fullscreen-exit" size={22} color={COLORS.surface} />
        </TouchableOpacity>
      </View>
    );
  }
```

> Note: because the same `pencilKitRef` mounts on a different `PencilKitView` instance in each branch, the drawing/canvas data does not carry across the toggle in this example. That is acceptable for the demo (the point is showing full-screen transform). Keep the `key` identical so the boundary image reloads consistently.

- [ ] **Step 5: Add `pageTransformEnabled` to the framed (non-full-screen) canvas**

On the existing framed `<PencilKitView>` (~line 362), add the prop next to `boundaryDebug`:

```tsx
          boundaryColoringEnabled={boundaryColoringEnabled}
          boundaryDebug={boundaryDebug}
          pageTransformEnabled
```

- [ ] **Step 6: Add the overlay styles**

In the `StyleSheet.create({...})`, add:

```ts
  fullScreenContainer: {
    flex: 1,
    backgroundColor: COLORS.ink,
  },
  fullScreenExitButton: {
    position: "absolute",
    top: 60,
    right: 20,
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: COLORS.accent,
    justifyContent: "center",
    alignItems: "center",
  },
```

- [ ] **Step 7: Typecheck the example**

Run: `cd example && npx tsc --noEmit`
Expected: no TypeScript errors.

- [ ] **Step 8: Build and manually verify**

Run: `cd example && npx expo run:ios`
Expected: builds and launches. Verify:
- Tapping the full-screen button expands the canvas to the whole screen; the page re-fits centered.
- Two-finger pan/zoom/rotate and one-finger draw both work in full screen.
- The exit button returns to the framed layout and re-fits the page.

- [ ] **Step 9: Commit**

```bash
git add example/App.tsx
git commit -m "feat(example): full-screen canvas toggle with page re-fit"
```

---

## Self-Review

**Spec coverage:**
- 1-finger draw / 2-finger transform → Task 3 (recognizers + delegate + stroke-cancel).
- Fit-centered by default → Task 2 (`layoutSubviews` centers identity transform).
- Zoom 0.5–5x, free move, on-screen guard → Task 4 (`normalizeTransform` + `clampTranslation`).
- Free rotation with soft-snap to 0° → Task 4.
- Boundary coloring unchanged → Task 2 (only `contentView`→`pageContainer` retarget; coordinate math untouched).
- `pageTransformEnabled` prop + `resetTransform()` method → Tasks 1 (TS) + 5 (native).
- Full-screen button in example, re-fits on toggle → Task 6.

**Placeholder scan:** No TBD/TODO; every code step shows full code. The Task 3 `normalizeTransform()` stub is intentional and explicitly replaced in Task 4.

**Type/name consistency:** `pageContainer`, `pageTransformEnabled`, `pinchGR`/`rotationGR`/`panGR`, `cancelActiveStroke()`, `normalizeTransform()`, `clampTranslation()`, `setPageTransformEnabled(_:)`, `resetTransform()` are used identically across tasks. JS `resetTransform` (Task 1) matches native `AsyncFunction("resetTransform")` (Task 5). Prop name `pageTransformEnabled` matches across TS types, native prop, and example usage.
