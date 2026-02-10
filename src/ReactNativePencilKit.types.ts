/**
 * Event payload for drawing start events
 */
export interface DrawStartEvent {
  data: string;
}

/**
 * Event payload for drawing end events
 */
export interface DrawEndEvent {
  data: string;
}

/**
 * Event payload for drawing change events
 */
export interface DrawChangeEvent {
  data: string;
}

/**
 * Event payload for can undo changed events
 */
export interface CanUndoChangedEvent {
  canUndo: boolean;
}

/**
 * Event payload for can redo changed events
 */
export interface CanRedoChangedEvent {
  canRedo: boolean;
}

/**
 * Native event wrapper for view component events
 */
export interface NativeEvent<T> {
  nativeEvent: T;
}

/**
 * Props for PencilKitView component
 */
export interface PencilKitViewProps {
  style?: any;
  imagePath?: { uri: string };
  onDrawStart?: (event: NativeEvent<DrawStartEvent>) => void;
  onDrawEnd?: (event: NativeEvent<DrawEndEvent>) => void;
  onDrawChange?: (event: NativeEvent<DrawChangeEvent>) => void;
  onCanUndoChanged?: (
    event: NativeEvent<CanUndoChangedEvent>
  ) => void;
  onCanRedoChanged?: (
    event: NativeEvent<CanRedoChangedEvent>
  ) => void;
}

/**
 * Ref methods available on PencilKitView
 */
export interface PencilKitViewRef {
  setupToolPicker(): Promise<void>;
  clearDrawing(): Promise<void>;
  undo(): Promise<void>;
  redo(): Promise<void>;
  captureDrawing(): Promise<string>;
  getCanvasDataAsBase64(): Promise<string>;
  setCanvasDataFromBase64(base64String: string): Promise<boolean>;
  canUndo(): Promise<boolean>;
  canRedo(): Promise<boolean>;
  setCanvasBackgroundColor(colorString: string): Promise<void>;
  getCanvasBackgroundColor(): Promise<string>;
  showColorPicker(): Promise<void>;
}
