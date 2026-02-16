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
 * Tool type for inking and selection tools
 */
export type ToolType = 
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

/**
 * Tool configuration for setting default tool
 * 
 * Available inking tools:
 * - pen, marker, pencil: Available on iOS 13+
 * - monoline, fountainPen, watercolor, crayon: Available on iOS 17+
 * - reed: Available on iOS 26+
 * 
 * Fallback behavior:
 * - If the requested tool is not available, it will try the fallbackTool
 * - If fallbackTool is not available or not specified, it will use pen as the final fallback
 */
export interface ToolConfig {
  type: ToolType;
  width?: number; // For inking tools, default: 10.0 for most tools, 20.0 for marker
  color?: string; // Hex color string (e.g., "#000000" or "000000"), default: "#000000"
  eraserType?: "vector" | "bitmap"; // For eraser tool, default: "vector"
  fallbackTool?: ToolType; // Optional fallback tool if the requested tool is not available. If not specified or unavailable, defaults to pen
}

/**
 * Ref methods available on PencilKitView
 */
export interface PencilKitViewRef {
  setupToolPicker(toolConfig?: ToolConfig): Promise<void>;
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
