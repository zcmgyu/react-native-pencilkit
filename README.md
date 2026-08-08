## react-native-pencilkit

PencilKit-powered drawing canvas for **React Native / Expo** with Apple Pencil support, pan / zoom / rotate, undo/redo, background images, boundary coloring, and image/base64 export.

- **Platform**: iOS (PencilKit, iOS 13+) only
- **UI**: High-level React component that wraps a `PKCanvasView` with events and imperative methods.

### Features

- **Apple Pencil & touch drawing** using native `PencilKit`
- **Pan, zoom & rotate** — one finger draws, two fingers transform the page (pinch to zoom, twist to rotate, drag to move). The page is sized to the image's aspect ratio and fit-centered. Toggle with `pageTransformEnabled`; re-center/fit with `resetTransform()`
- **Background image support** via `imagePath={{ uri }}` (e.g. photos, templates)
- **Boundary coloring** — clip strokes to the region you touch on a coloring-page outline (see [docs/boundary-coloring.md](docs/boundary-coloring.md))
- **Undo / redo** with live `canUndo` / `canRedo` events
- **Export drawing** as base64 PNG with `captureDrawing()`
- **Export image + drawing** as base64 PNG with `captureImageWithDrawing()` - captures both background image and drawings together
- **Save / restore strokes** as base64 data with `getCanvasDataAsBase64()` and `setCanvasDataFromBase64()`
- **Save / restore coloring state** — persist the full coloring-mode picture *and* its undo/redo history with `getColoringData()` / `setColoringData()`, with an optional `maxUndoSteps` cap
- **Canvas background color** getters/setters and a native **color picker**
- **Default tool selection** - Set the initial tool when setting up the tool picker

---

### Installation

Using npm:

```bash
npm install rn-pencil-kit
```

Using Yarn:

```bash
yarn add rn-pencil-kit
```

#### Expo projects

- This package is built as an **Expo module**.
- Add it as a dependency and run a prebuild so the native module is linked:

```bash
npx expo prebuild
```

Then run as usual:

```bash
npm run ios
# or
npx expo run:ios
```

#### Bare React Native (non-Expo)

- Make sure you have `expo-modules-core` installed and configured.
- iOS autolinking should detect the module after you install the package.
- Then install pods:

```bash
cd ios
pod install
```

**Minimum iOS version**: PencilKit requires **iOS 13+**. Ensure your `Podfile` uses `platform :ios, '13.0'` or higher.

---

### Basic usage

```tsx
import React, { useRef, useEffect } from 'react';
import { View, StyleSheet } from 'react-native';
import {
  PencilKitView,
  PencilKitViewRef,
  NativeEvent,
  DrawStartEvent,
  DrawEndEvent,
  DrawChangeEvent,
  CanUndoChangedEvent,
  CanRedoChangedEvent,
} from 'react-native-pencilkit';

export function DrawingScreen() {
  const canvasRef = useRef<PencilKitViewRef>(null);

  useEffect(() => {
    // Setup tool picker with default tool after component mounts
    const timer = setTimeout(() => {
      canvasRef.current?.setupToolPicker({
        type: "watercolor", // Falls back to pencil on iOS < 17
        width: 20.0,
        color: "#000000",
      });
    }, 100);
    return () => clearTimeout(timer);
  }, []);

  const handleDrawStart = (_event: NativeEvent<DrawStartEvent>) => {
    // User started drawing
  };

  const handleDrawEnd = (_event: NativeEvent<DrawEndEvent>) => {
    // User finished drawing
  };

  const handleDrawChange = (event: NativeEvent<DrawChangeEvent>) => {
    // Access stroke data as base64
    const { data } = event.nativeEvent;
    console.log('Drawing changed:', data);
  };

  const handleCanUndoChanged = (event: NativeEvent<CanUndoChangedEvent>) => {
    console.log('Can undo:', event.nativeEvent.canUndo);
  };

  const handleCanRedoChanged = (event: NativeEvent<CanRedoChangedEvent>) => {
    console.log('Can redo:', event.nativeEvent.canRedo);
  };

  return (
    <View style={styles.container}>
      <PencilKitView
        ref={canvasRef}
        style={styles.canvas}
        onDrawStart={handleDrawStart}
        onDrawEnd={handleDrawEnd}
        onDrawChange={handleDrawChange}
        onCanUndoChanged={handleCanUndoChanged}
        onCanRedoChanged={handleCanRedoChanged}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#f8f6f2',
  },
  canvas: {
    width: 320,
    height: 320,
    backgroundColor: '#ffffff',
  },
});
```

---

### Imperative API (ref methods)

The `PencilKitView` exposes a set of async methods through its ref:

```ts
export interface ToolConfig {
  type: 
    | "pen" 
    | "marker" 
    | "pencil" 
    | "monoline" 
    | "fountainPen" 
    | "watercolor" 
    | "crayon" 
    | "reed" 
    | "eraser" 
    | "lasso";
  width?: number; // For inking tools, default: 10.0 for most tools, 20.0 for marker
  color?: string; // Hex color string (e.g., "#000000" or "000000"), default: "#000000"
  eraserType?: "vector" | "bitmap"; // For eraser tool, default: "vector"
  fallbackTool?: ToolType; // Optional fallback tool if the requested tool is not available. If not specified or unavailable, defaults to pen
}

export interface PencilKitViewRef {
  setupToolPicker(toolConfig?: ToolConfig): Promise<void>;
  clearDrawing(): Promise<void>;
  undo(): Promise<void>;
  redo(): Promise<void>;
  captureDrawing(): Promise<string>; // base64 PNG (drawing only)
  captureImageWithDrawing(): Promise<string>; // base64 PNG (background image + drawing)
  getCanvasDataAsBase64(): Promise<string>;
  setCanvasDataFromBase64(base64String: string): Promise<boolean>;
  getColoringData(): Promise<string>; // base64: coloring picture + undo/redo history ("" if not in coloring mode)
  setColoringData(base64String: string): Promise<boolean>; // restore; call AFTER onBoundaryImageLoad
  canUndo(): Promise<boolean>;
  canRedo(): Promise<boolean>;
  setCanvasBackgroundColor(colorString: string): Promise<void>; // e.g. "#FFFFFF" or "FFFFFF"
  getCanvasBackgroundColor(): Promise<string>; // "RRGGBB"
  showColorPicker(): Promise<void>;
  resetTransform(): Promise<void>; // animate the page back to centered + fit (identity)
}
```

| **Method**                | **Parameters**      | **Return type**      | **Description**                              |
| ------------------------- | ------------------- | -------------------- | -------------------------------------------- |
| `setupToolPicker`        | `(toolConfig?: ToolConfig)` | `Promise<void>`      | Initialize and show the native tool picker with optional default tool   |
| `clearDrawing`           | `()`                | `Promise<void>`      | Clear all strokes from the canvas            |
| `undo`                   | `()`                | `Promise<void>`      | Undo the last drawing action                 |
| `redo`                   | `()`                | `Promise<void>`      | Redo the last undone drawing action          |
| `captureDrawing`         | `()`                | `Promise<string>`    | Capture the canvas drawing as a base64 PNG image (drawing only)     |
| `captureImageWithDrawing`| `()`                | `Promise<string>`    | Capture the background image + drawing as a base64 PNG image (complete visual output) |
| `getCanvasDataAsBase64`  | `()`                | `Promise<string>`    | Get the current drawing data as base64       |
| `setCanvasDataFromBase64`| `base64: string`    | `Promise<boolean>`   | Load a drawing from base64 data              |
| `getColoringData`        | `()`                | `Promise<string>`    | Serialize the full coloring-mode state (picture + undo/redo history) to base64. Returns `""` when not in boundary/coloring mode |
| `setColoringData`        | `base64: string`    | `Promise<boolean>`   | Restore coloring-mode state from `getColoringData()`. Call **after** `onBoundaryImageLoad`; returns `false` on malformed data or if the coloring layer isn't ready |
| `canUndo`                | `()`                | `Promise<boolean>`   | Check if undo is currently available         |
| `canRedo`                | `()`                | `Promise<boolean>`   | Check if redo is currently available         |
| `setCanvasBackgroundColor`| `color: string`    | `Promise<void>`      | Set canvas background color (`RRGGBB` / hex) |
| `getCanvasBackgroundColor`| `()`               | `Promise<string>`    | Get current background color as `RRGGBB`     |
| `showColorPicker`        | `()`                | `Promise<void>`      | Present the native iOS color picker          |
| `resetTransform`         | `()`                | `Promise<void>`      | Animate the page back to centered + aspect-fit (identity transform). Useful after resizing the canvas (e.g. entering/exiting full screen) |

Example usage:

```ts
const ref = useRef<PencilKitViewRef>(null);

// Show the native PencilKit tool picker with default pen tool
await ref.current?.setupToolPicker({
  type: "pen",
  width: 10.0,
  color: "#000000"
});

// Or setup without default tool (uses system default)
await ref.current?.setupToolPicker();

// Clear all strokes
await ref.current?.clearDrawing();

// Export drawing as image (base64 PNG - drawing only)
const base64Png = await ref.current?.captureDrawing();

// Export image + drawing as base64 PNG (includes background image if set)
const base64ImageWithDrawing = await ref.current?.captureImageWithDrawing();
// Use it: `data:image/png;base64,${base64ImageWithDrawing}`

// --- Coloring-mode save / restore (boundary coloring) ---

// Save: full coloring state incl. undo/redo history ("" if not in coloring mode)
const coloringState = await ref.current?.getColoringData();

// Restore: MUST run after the boundary image has loaded (onBoundaryImageLoad),
// otherwise the coloring layer isn't ready and it returns false.
<PencilKitView
  boundaryImagePath={{ uri }}
  boundaryColoringEnabled
  maxUndoSteps={20} // optional: cap history (0 = unlimited)
  onBoundaryImageLoad={async () => {
    await ref.current?.setColoringData(coloringState);
  }}
/>
```

### Setting Default Tool

You can set a default tool when calling `setupToolPicker()`. The tool selection follows a fallback chain:

1. **Try the requested tool** - If available on the current iOS version, use it
2. **Try the fallback tool** - If the requested tool is not available and `fallbackTool` is specified, try the fallback tool
3. **Use pen** - If both the requested tool and fallback tool are unavailable, use pen as the final fallback

This ensures your app works seamlessly across different iOS versions.

```ts
// Pen tool with custom width and color
await ref.current?.setupToolPicker({
  type: "pen",
  width: 15.0,
  color: "#FF0000" // Red pen
});

// Marker tool
await ref.current?.setupToolPicker({
  type: "marker",
  width: 25.0,
  color: "#00FF00" // Green marker
});

// Pencil tool
await ref.current?.setupToolPicker({
  type: "pencil",
  width: 8.0,
  color: "#0000FF" // Blue pencil
});

// Monoline tool (iOS 17+, automatically falls back to pen on iOS < 17)
await ref.current?.setupToolPicker({
  type: "monoline",
  width: 12.0,
  color: "#FF00FF"
});

// Fountain pen tool (iOS 17+, automatically falls back to pen on iOS < 17)
await ref.current?.setupToolPicker({
  type: "fountainPen",
  width: 10.0,
  color: "#000000"
});

// Watercolor tool (iOS 17+, automatically falls back to pen on iOS < 17)
await ref.current?.setupToolPicker({
  type: "watercolor",
  width: 20.0,
  color: "#FF0000"
});

// Watercolor with custom fallback to marker (iOS 17+, falls back to marker on iOS < 17)
await ref.current?.setupToolPicker({
  type: "watercolor", // Requires iOS 17+
  fallbackTool: "marker", // Use marker instead of pen if watercolor not available
  width: 20.0,
  color: "#FF0000"
});

// Crayon tool (iOS 17+, automatically falls back to pen on iOS < 17)
await ref.current?.setupToolPicker({
  type: "crayon",
  width: 15.0,
  color: "#FFA500"
});

// Reed tool (iOS 26+, automatically falls back to pen on iOS < 26)
await ref.current?.setupToolPicker({
  type: "reed",
  width: 10.0,
  color: "#000000"
});

// Reed with multi-level fallback (iOS 26+ → iOS 17+ → pen)
await ref.current?.setupToolPicker({
  type: "reed", // Requires iOS 26+
  fallbackTool: "fountainPen", // Fallback to fountainPen (iOS 17+) if reed not available
  width: 10.0,
  color: "#000000"
  // Final fallback to pen happens automatically if fountainPen also unavailable
});

// Eraser tool (vector or bitmap)
await ref.current?.setupToolPicker({
  type: "eraser",
  eraserType: "vector" // or "bitmap"
});

// Lasso tool
await ref.current?.setupToolPicker({
  type: "lasso"
});

```

**Available tool types:**

**Inking Tools (iOS 13+):**
- `"pen"` - Pen tool for drawing
- `"marker"` - Marker tool (typically wider strokes, default width: 20.0)
- `"pencil"` - Pencil tool (default fallback tool)

**Advanced Inking Tools (iOS 17+):**
- `"monoline"` - Monoline tool (falls back to pencil on iOS < 17.0)
- `"fountainPen"` - Fountain pen tool (falls back to pencil on iOS < 17.0)
- `"watercolor"` - Watercolor brush tool (falls back to pencil on iOS < 17.0)
- `"crayon"` - Crayon tool (falls back to pencil on iOS < 17.0)

**Future Inking Tools (iOS 26+):**
- `"reed"` - Reed pen tool (falls back to pencil on iOS < 26.0)

**Other Tools:**
- `"eraser"` - Eraser tool (requires `eraserType`: `"vector"` or `"bitmap"`)
- `"lasso"` - Lasso selection tool

**Fallback Behavior:**

The fallback mechanism ensures your app works across different iOS versions. When configuring a tool:

1. **Try the requested tool** - If available on the current iOS version, use it
2. **Try the fallback tool** - If the requested tool is unavailable and `fallbackTool` is specified, try the fallback tool
3. **Use pen** - If both the requested tool and fallback tool are unavailable, use **pen** as the final fallback

**When to use `fallbackTool`:**
- Use newer tools (iOS 17+ or iOS 26+) but need compatibility with older iOS versions
- Prefer a specific alternative tool instead of the default pen fallback
- Match tool characteristics (e.g., `watercolor` → `marker` for wide strokes)

**iOS Version Requirements:**

| Tool | Minimum iOS Version | Recommended Fallback |
|------|-------------------|---------------------|
| `pen`, `marker`, `pencil` | iOS 13+ | N/A (always available) |
| `monoline`, `fountainPen`, `watercolor`, `crayon` | iOS 17+ | `"marker"` or `"pen"` |
| `reed` | iOS 26+ | `"fountainPen"`, `"marker"`, or `"pen"` |
| `eraser`, `lasso` | iOS 13+ | N/A (always available) |

---

### Props

```ts
export interface PencilKitViewProps {
  style?: any;
  imagePath?: { uri: string }; // background image
  pageTransformEnabled?: boolean; // 2-finger pan/zoom/rotate; default true
  onDrawStart?: (event: NativeEvent<DrawStartEvent>) => void;
  onDrawEnd?: (event: NativeEvent<DrawEndEvent>) => void;
  onDrawChange?: (event: NativeEvent<DrawChangeEvent>) => void;
  onCanUndoChanged?: (event: NativeEvent<CanUndoChangedEvent>) => void;
  onCanRedoChanged?: (event: NativeEvent<CanRedoChangedEvent>) => void;
}
```

| **Prop**             | **Type**                                          | **Description**                                                                                                                                              |
| -------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `style`              | `any`                                            | Style object for the canvas view                                                                                                                             |
| `imagePath`          | `{ uri: string }`                                | Optional background image. When unset, the canvas uses a white background. _Note:_ for local assets (e.g. `require('./assets/image.png')`), resolve the URI using [`resolveAssetSource()`](https://reactnative.dev/docs/image#resolveassetsource) before passing it. |
| `pageTransformEnabled` | `boolean`                                      | Enable 2-finger pan / zoom / rotate of the page (one finger always draws). Default `true`. Set `false` to lock the page. |
| `maxUndoSteps`       | `number`                                         | Maximum undo steps retained in coloring mode. `0` (default) keeps the full history; a positive value caps it (oldest steps dropped). A smaller cap also shrinks `getColoringData()` output. |
| `onDrawStart`        | `(event: NativeEvent<DrawStartEvent>) => void`   | Called when the user starts drawing                                                                                                                          |
| `onDrawEnd`          | `(event: NativeEvent<DrawEndEvent>) => void`     | Called when the user finishes a drawing gesture                                                                                                             |
| `onDrawChange`       | `(event: NativeEvent<DrawChangeEvent>) => void`  | Called whenever the drawing content changes                                                                                                                 |
| `onCanUndoChanged`   | `(event: NativeEvent<CanUndoChangedEvent>) => void` | Called whenever the availability of undo changes                                                                                                         |
| `onCanRedoChanged`   | `(event: NativeEvent<CanRedoChangedEvent>) => void` | Called whenever the availability of redo changes                                                                                                         |

- **Event payloads**:
  - `DrawStartEvent`, `DrawEndEvent`, `DrawChangeEvent` → `{ data: string }` (base64-encoded `PKDrawing` data).
  - `CanUndoChangedEvent` → `{ canUndo: boolean }`
  - `CanRedoChangedEvent` → `{ canRedo: boolean }`

- **Boundary-coloring props** (`boundaryImagePath`, `boundaryColoringEnabled`, `boundaryThreshold`, `boundaryOutlineDilation`, `boundaryDebug`, `onBoundaryImageLoad`) are documented in [docs/boundary-coloring.md](docs/boundary-coloring.md).

---

### Example app

This repo includes an Expo example demonstrating:

- **Default tool selection** - Uses watercolor as the default tool (with automatic fallback to pencil on iOS < 17)
- **Toolbar controls** (undo, redo, clear, color picker, full-screen toggle)
- **Pan / zoom / rotate** — two-finger gestures on the page, with a full-screen canvas mode
- **Boundary coloring** — pick a coloring-page outline and color within regions
- **Background image selection** using `expo-image-picker`
- **Saving canvas data** to base64 and sharing an exported PNG
- **Saving image + drawing** as base64 using `captureImageWithDrawing()`

To run it:

```bash
cd example
npm install
npm run ios
```

---

### Notes & limitations

- **iOS only**: This package depends on `PencilKit`, which is only available on Apple platforms.
- On Android and web, `PencilKitView` currently returns `null`. You may want to guard usage by checking `Platform.OS === 'ios'`.
- Make sure your project is configured with **iOS 13+** and uses the latest Xcode / CocoaPods versions that support PencilKit.

---

### Credits

- **Inspiration & reference implementation**: [`expo-pencilkit-ui`](https://github.com/tarikfp/expo-pencilkit-ui/tree/main) by `tarikfp`, which provides a similar Expo module for Apple PencilKit on iOS.

