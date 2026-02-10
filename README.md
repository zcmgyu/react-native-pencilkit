## react-native-pencilkit

PencilKit-powered drawing canvas for **React Native / Expo** with Apple Pencil support, zoom & pan, undo/redo, background images, and image/base64 export.

- **Platform**: iOS (PencilKit, iOS 13+) only
- **UI**: High-level React component that wraps a `PKCanvasView` with events and imperative methods.

### Features

- **Apple Pencil & touch drawing** using native `PencilKit`
- **Zoom & pan** with synchronized background image + strokes
- **Background image support** via `imagePath={{ uri }}` (e.g. photos, templates)
- **Undo / redo** with live `canUndo` / `canRedo` events
- **Export drawing** as base64 PNG with `captureDrawing()`
- **Save / restore strokes** as base64 data with `getCanvasDataAsBase64()` and `setCanvasDataFromBase64()`
- **Canvas background color** getters/setters and a native **color picker**

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
import React, { useRef } from 'react';
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
export interface PencilKitViewRef {
  setupToolPicker(): Promise<void>;
  clearDrawing(): Promise<void>;
  undo(): Promise<void>;
  redo(): Promise<void>;
  captureDrawing(): Promise<string>; // base64 PNG
  getCanvasDataAsBase64(): Promise<string>;
  setCanvasDataFromBase64(base64String: string): Promise<boolean>;
  canUndo(): Promise<boolean>;
  canRedo(): Promise<boolean>;
  setCanvasBackgroundColor(colorString: string): Promise<void>; // e.g. "#FFFFFF" or "FFFFFF"
  getCanvasBackgroundColor(): Promise<string>; // "RRGGBB"
  showColorPicker(): Promise<void>;
}
```

| **Method**                | **Parameters**      | **Return type**      | **Description**                              |
| ------------------------- | ------------------- | -------------------- | -------------------------------------------- |
| `setupToolPicker`        | `()`                | `Promise<void>`      | Initialize and show the native tool picker   |
| `clearDrawing`           | `()`                | `Promise<void>`      | Clear all strokes from the canvas            |
| `undo`                   | `()`                | `Promise<void>`      | Undo the last drawing action                 |
| `redo`                   | `()`                | `Promise<void>`      | Redo the last undone drawing action          |
| `captureDrawing`         | `()`                | `Promise<string>`    | Capture the canvas as a base64 PNG image     |
| `getCanvasDataAsBase64`  | `()`                | `Promise<string>`    | Get the current drawing data as base64       |
| `setCanvasDataFromBase64`| `base64: string`    | `Promise<boolean>`   | Load a drawing from base64 data              |
| `canUndo`                | `()`                | `Promise<boolean>`   | Check if undo is currently available         |
| `canRedo`                | `()`                | `Promise<boolean>`   | Check if redo is currently available         |
| `setCanvasBackgroundColor`| `color: string`    | `Promise<void>`      | Set canvas background color (`RRGGBB` / hex) |
| `getCanvasBackgroundColor`| `()`               | `Promise<string>`    | Get current background color as `RRGGBB`     |
| `showColorPicker`        | `()`                | `Promise<void>`      | Present the native iOS color picker          |

Example usage:

```ts
const ref = useRef<PencilKitViewRef>(null);

// Show the native PencilKit tool picker
await ref.current?.setupToolPicker();

// Clear all strokes
await ref.current?.clearDrawing();

// Export drawing as image (base64 PNG)
const base64Png = await ref.current?.captureDrawing();
```

---

### Props

```ts
export interface PencilKitViewProps {
  style?: any;
  imagePath?: { uri: string }; // background image
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
| `onDrawStart`        | `(event: NativeEvent<DrawStartEvent>) => void`   | Called when the user starts drawing                                                                                                                          |
| `onDrawEnd`          | `(event: NativeEvent<DrawEndEvent>) => void`     | Called when the user finishes a drawing gesture                                                                                                             |
| `onDrawChange`       | `(event: NativeEvent<DrawChangeEvent>) => void`  | Called whenever the drawing content changes                                                                                                                 |
| `onCanUndoChanged`   | `(event: NativeEvent<CanUndoChangedEvent>) => void` | Called whenever the availability of undo changes                                                                                                         |
| `onCanRedoChanged`   | `(event: NativeEvent<CanRedoChangedEvent>) => void` | Called whenever the availability of redo changes                                                                                                         |

- **Event payloads**:
  - `DrawStartEvent`, `DrawEndEvent`, `DrawChangeEvent` → `{ data: string }` (base64-encoded `PKDrawing` data).
  - `CanUndoChangedEvent` → `{ canUndo: boolean }`
  - `CanRedoChangedEvent` → `{ canRedo: boolean }`

---

### Example app

This repo includes an Expo example demonstrating:

- **Toolbar controls** (undo, redo, clear, color picker)
- **Background image selection** using `expo-image-picker`
- **Saving canvas data** to base64 and sharing an exported PNG

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

