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
 * Event payload for boundary image load events
 */
export interface BoundaryImageLoadEvent {
  success: boolean;
  regionCount?: number;
  width?: number;
  height?: number;
  /**
   * Fixed, human-readable label. Always "Failed to load boundary image" on failure —
   * kept stable for callers that match on it. It says nothing about the cause; read
   * `reason` for that.
   */
  error?: string;
  /**
   * Why it failed, specifically: a URL with no http(s) scheme (an unresolved relative
   * asset key — by far the most common cause), an HTTP status, a timeout, a transport
   * error, an empty body, or an undecodable payload with its byte count.
   *
   * Absent on builds before this field shipped, so treat it as optional and fall back
   * to `error`.
   */
  reason?: string;
  /** The URI the native side was actually handed, so a bad one is visible at a glance. */
  uri?: string;
}

/**
 * Props for PencilKitView component
 */
export interface PencilKitViewProps {
  style?: any;
  imagePath?: { uri: string };
  /** Path to a boundary/outline image for coloring book mode. Strokes are clipped to the region where the user touches. */
  boundaryImagePath?: { uri: string };
  /** Whether boundary coloring is enabled. Default: true when boundaryImagePath is set. */
  boundaryColoringEnabled?: boolean;
  /** Grayscale threshold (0-255) for converting boundary image to regions. Default: 128. */
  boundaryThreshold?: number;
  /**
   * Outline dilation (pixels) used when detecting colorable regions. Default: 0 — fills
   * sit flush against the outline (no gap). Increase (e.g. 2-3) to bridge small gaps in
   * imperfect outlines so color can't leak between adjacent regions.
   */
  boundaryOutlineDilation?: number;
  /** Show debug overlay highlighting the active colorable region. Default: false. */
  boundaryDebug?: boolean;
  /** Enable 2-finger pan/zoom/rotate of the page. 1 finger always draws. Default: true. */
  pageTransformEnabled?: boolean;
  /**
   * Maximum number of undo steps retained in coloring mode. 0 (default) keeps the
   * full history; a positive value caps it (oldest steps are dropped). A smaller
   * cap also reduces the size of getColoringData() output.
   */
  maxUndoSteps?: number;
  onDrawStart?: (event: NativeEvent<DrawStartEvent>) => void;
  onDrawEnd?: (event: NativeEvent<DrawEndEvent>) => void;
  onDrawChange?: (event: NativeEvent<DrawChangeEvent>) => void;
  onCanUndoChanged?: (
    event: NativeEvent<CanUndoChangedEvent>
  ) => void;
  onCanRedoChanged?: (
    event: NativeEvent<CanRedoChangedEvent>
  ) => void;
  onBoundaryImageLoad?: (event: NativeEvent<BoundaryImageLoadEvent>) => void;
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
  captureImageWithDrawing(): Promise<string>;
  getCanvasDataAsBase64(): Promise<string>;
  setCanvasDataFromBase64(base64String: string): Promise<boolean>;
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
  canUndo(): Promise<boolean>;
  canRedo(): Promise<boolean>;
  setCanvasBackgroundColor(colorString: string): Promise<void>;
  getCanvasBackgroundColor(): Promise<string>;
  showColorPicker(): Promise<void>;
  /** Animate the page back to centered + aspect-fit (identity transform). */
  resetTransform(): Promise<void>;
  /**
   * Show or hide the floating tool picker.
   *
   * PKToolPicker is hosted in its own UIWindow above the app's view hierarchy, so it
   * draws on top of presented modals such as the iOS share sheet. Hide it before
   * presenting one and show it again afterwards.
   */
  setToolPickerVisible(visible: boolean): Promise<void>;
}
