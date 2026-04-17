import ExpoModulesCore
import Foundation
import PencilKit
import UIKit

// MARK: - View hierarchy
//
// This is a UIKit view (NOT SwiftUI). It uses UIView subclasses arranged in a tree.
// ExpoView is Expo's base class for native views exposed to React Native.
//
//  ReactNativePencilKitView (self — the root view exposed to React Native)
//  └── scrollView (UIScrollView)           ← handles pan/zoom gestures
//      └── contentView (UIView)            ← the zoomable container; all children scale together
//          ├── backgroundImageView?       ← [0] shows the coloring page image (.scaleAspectFit)
//          ├── coloredLayer?              ← [1] UIImageView holding all committed/baked strokes
//          ├── canvasView (PKCanvasView)  ← [2] Apple's drawing canvas — only holds the LIVE stroke
//          └── debugMaskOverlay?          ← [3] semi-transparent green tint for debugging zones
//
// Why this order matters:
//   - backgroundImageView is behind everything (the coloring page outline)
//   - coloredLayer sits above the background, showing previously drawn & committed strokes
//   - canvasView is on top so PencilKit receives touch events for drawing
//   - debugMaskOverlay is optional, only shown when boundaryDebug=true

// This class conforms to multiple protocols:
//   - PKCanvasViewDelegate: receives drawing events (stroke start/end/change)
//   - PKToolPickerObserver: notified when the tool picker changes (currently unused but required)
//   - UIScrollViewDelegate: provides the zoomable view for pinch-to-zoom
public class ReactNativePencilKitView: ExpoView, PKCanvasViewDelegate, PKToolPickerObserver, UIScrollViewDelegate {

  // Core views — always present
  private let scrollView = UIScrollView()
  private let contentView = UIView()           // The single zoomable child inside scrollView
  private let canvasView = PKCanvasView()       // Apple's PencilKit drawing surface
  private var backgroundImageView: UIImageView? // Optional background image (coloring page)

  // ──────────────────────────────────────────────────────────────────────────
  // Boundary coloring state
  //
  // Architecture: "Always-Empty Canvas"
  //   1. User touches a zone → ZoneTouchDetector detects it → mask is applied to canvasView
  //   2. User draws a stroke → PencilKit renders it on the canvas, clipped by the mask
  //   3. User lifts finger → stroke is finalized in PKDrawing.strokes
  //   4. commitCurrentStroke() renders the stroke as an image, masks it to the zone,
  //      composites it onto coloredLayer, then clears the canvas
  //   5. Canvas is now empty → ready for the next touch in ANY zone (no swap needed)
  //
  // This avoids the fundamental PencilKit limitation: setting canvasView.drawing = X
  // during a touch kills the active stroke. By keeping the canvas always empty between
  // strokes, we never need to swap drawings.
  // ──────────────────────────────────────────────────────────────────────────

  private var boundaryImage: UIImage?            // The original coloring page image
  private var regionMapBuilder: RegionMapBuilder? // Processes the image into zone regions
  private var currentRegionId: Int32 = -1        // Which zone the user is currently drawing in (-1 = none)
  private var zoneMaskCache: [Int32: CGImage] = [:] // CGImage masks per zone (generated once, reused)

  // Undo/redo: we store snapshots of the entire coloredLayer image.
  // Each commit pushes the previous state. Undo pops it back.
  private var coloredSnapshots: [UIImage?] = []  // Undo stack
  private var redoSnapshots: [UIImage?] = []     // Redo stack (cleared on new stroke)

  // Guard flag: when true, delegate callbacks from canvasView are ignored.
  // This prevents infinite loops when we clear the canvas after committing a stroke,
  // because clearing triggers canvasViewDrawingDidChange which would try to commit again.
  private var isCommitting = false

  // Tracks how many strokes are in canvasView.drawing.strokes.
  // When this increases in canvasViewDrawingDidChange, a stroke was finalized → time to commit.
  // IMPORTANT: PencilKit adds the stroke to drawing.strokes AFTER canvasViewDidEndUsingTool,
  // so canvasViewDrawingDidChange is the ONLY reliable place to detect stroke finalization.
  private var previousStrokeCount: Int = 0

  private var maskLayer: CALayer?                // The active CALayer.mask on canvasView
  private var coloredLayer: UIImageView?         // Accumulates committed strokes as a composited image
  private var debugMaskOverlay: UIImageView?     // Shows active zone tint when debug mode is on

  // Props from React Native
  private(set) var boundaryColoringEnabled: Bool = true  // Toggle boundary mode on/off
  private var boundaryThreshold: Int = 128               // Grayscale threshold for outline detection
  private var boundaryDebug: Bool = false                 // Show debug overlay

  // Custom gesture recognizer that detects the touch point and immediately fails,
  // so PencilKit's own gesture recognizers can process the touch without interference.
  // See ZoneTouchDetector class at the bottom of this file.
  private let zoneTouchDetector = ZoneTouchDetector()

  // ──────────────────────────────────────────────────────────────────────────
  // Module communication
  // ──────────────────────────────────────────────────────────────────────────

  // `weak static` reference so the view can call methods on the module (e.g., register itself).
  // `weak` prevents a retain cycle since the module also holds a reference to this view.
  private weak static var moduleInstance: ReactNativePencilKitModule?

  // EventDispatchers send events to React Native (JavaScript side).
  // They are wired up in the module's View() definition.
  let onDrawStart = EventDispatcher()
  let onDrawEnd = EventDispatcher()
  let onDrawChange = EventDispatcher()
  let onCanUndoChanged = EventDispatcher()
  let onCanRedoChanged = EventDispatcher()
  let onBoundaryImageLoad = EventDispatcher()

  // Called once when the view is created. Sets up the view hierarchy.
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupScrollView()
    setupCanvasView()
  }

  // MARK: - Setup

  private func setupScrollView() {
    scrollView.delegate = self               // We implement UIScrollViewDelegate for zoom
    scrollView.minimumZoomScale = 1.0        // No zoom out beyond 1x
    scrollView.maximumZoomScale = 5.0        // Allow 5x zoom in
    scrollView.backgroundColor = .gray       // Visible when canvas is smaller than scroll view
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    addSubview(scrollView)                   // Add scrollView as a child of this view
  }

  private func setupCanvasView() {
    // .anyInput allows both Apple Pencil AND finger drawing
    canvasView.drawingPolicy = .anyInput
    canvasView.overrideUserInterfaceStyle = .light  // Force light mode for consistent appearance
    canvasView.isMultipleTouchEnabled = true
    canvasView.isOpaque = false              // Transparent so coloredLayer shows through
    canvasView.backgroundColor = UIColor.clear
    canvasView.delegate = self               // We implement PKCanvasViewDelegate
    canvasView.isUserInteractionEnabled = true

    // Disable canvas's built-in scroll/zoom — our outer scrollView handles that instead.
    // This way the background image and canvas zoom/pan together as one unit.
    canvasView.isScrollEnabled = false
    canvasView.minimumZoomScale = 1.0
    canvasView.maximumZoomScale = 1.0

    canvasView.drawing = PKDrawing()         // Start with an empty drawing

    // Build the view hierarchy: contentView contains the canvas (and later, other layers)
    contentView.backgroundColor = .white
    contentView.addSubview(canvasView)
    scrollView.addSubview(contentView)

    // Set up the zone touch detector.
    // When the user touches the canvas, this fires BEFORE PencilKit starts its stroke.
    // It detects which zone was touched and applies the correct mask.
    // Then it immediately fails (state = .failed) so PencilKit gets the touch uninterrupted.
    zoneTouchDetector.onTouchDown = { [weak self] point in
      self?.handleTouchAtPoint(point)
    }
    canvasView.addGestureRecognizer(zoneTouchDetector)
  }

  // MARK: - Layout

  // Called by UIKit whenever the view's bounds change (e.g., rotation, resize).
  // We update all child frames to match the new size.
  override public func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds                               // Fill the entire view
    let contentSize = bounds.size
    contentView.frame = CGRect(origin: .zero, size: contentSize)
    scrollView.contentSize = contentSize                    // Tell scrollView how big the content is
    canvasView.frame = contentView.bounds                   // Canvas fills the content area
    backgroundImageView?.frame = contentView.bounds         // Background image fills the content area
    coloredLayer?.frame = contentView.bounds                // Colored layer fills the content area
    debugMaskOverlay?.frame = contentView.bounds            // Debug overlay fills the content area
    maskLayer?.frame = canvasView.bounds                    // Mask matches canvas size
  }

  // Called when this view is added to or removed from a parent view.
  // We register/unregister with the module so it can communicate with us.
  override public func didMoveToSuperview() {
    super.didMoveToSuperview()
    if superview != nil {
      // View was added — register with module
      ReactNativePencilKitView.moduleInstance?.registerCanvasView(canvasView)
      ReactNativePencilKitView.moduleInstance?.registerPencilKitView(self)
    } else {
      // View was removed — unregister
      ReactNativePencilKitView.moduleInstance?.unregisterCanvasView()
    }
  }

  // Called by the module during its OnCreate lifecycle to establish the communication link.
  static func setModuleInstance(_ module: ReactNativePencilKitModule) {
    moduleInstance = module
  }

  // MARK: - Background Image Props

  // Called when the React Native `imagePath` prop changes.
  // Loads the image asynchronously on a background thread, then sets it on the main thread.
  func setImagePath(_ imagePath: [String: Any]?) {
    guard let imagePath = imagePath,
          let uriString = imagePath["uri"] as? String,
          let url = URL(string: uriString)
    else {
      clearBackgroundImage()
      return
    }

    // Load image off the main thread to avoid blocking the UI
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let data = try? Data(contentsOf: url),
            let image = UIImage(data: data)
      else {
        DispatchQueue.main.async { self?.clearBackgroundImage() }
        return
      }
      // UIKit views must be modified on the main thread
      DispatchQueue.main.async { self?.setBackgroundImage(image) }
    }
  }

  // Inserts the image as a UIImageView at the bottom of contentView's subview stack.
  private func setBackgroundImage(_ image: UIImage) {
    backgroundImageView?.removeFromSuperview()   // Remove old image if any
    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit      // Maintain aspect ratio, fit within bounds
    imageView.frame = contentView.bounds
    contentView.insertSubview(imageView, at: 0)  // Insert at index 0 = behind everything
    backgroundImageView = imageView
    canvasView.backgroundColor = .clear          // Make canvas transparent so image shows through
  }

  private func clearBackgroundImage() {
    backgroundImageView?.removeFromSuperview()
    backgroundImageView = nil
    canvasView.backgroundColor = .white          // Restore white background when no image
  }

  // MARK: - Boundary Coloring Props

  // Called when the React Native `boundaryImagePath` prop changes.
  // Loads the coloring page image, builds a region map (connected component labeling),
  // and pre-computes the canvas-resolution pixel indices for fast mask generation.
  func setBoundaryImagePath(_ path: [String: Any]?) {
    guard let path = path,
          let uriString = path["uri"] as? String,
          let url = URL(string: uriString)
    else {
      clearBoundaryImage()
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let data = try? Data(contentsOf: url),
            let image = UIImage(data: data)
      else {
        DispatchQueue.main.async {
          self?.clearBoundaryImage()
          self?.onBoundaryImageLoad(["success": false, "error": "Failed to load boundary image"])
        }
        return
      }

      // Build the region map on the background thread (CPU-intensive).
      // This identifies each enclosed white area as a separate "zone" with a unique ID.
      let builder = RegionMapBuilder()
      builder.buildRegionMap(from: image, threshold: self?.boundaryThreshold ?? 128)

      // Pre-compute a canvas-resolution lookup table.
      // Maps each screen pixel to a zone ID, enabling instant mask generation later.
      let canvasSize = self?.canvasView.bounds.size ?? CGSize(width: 360, height: 360)
      let scale = UIScreen.main.scale
      builder.precomputeCanvasMap(canvasSize: canvasSize, scale: scale)

      // Switch to main thread to update UI state
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.boundaryImage = image
        self.regionMapBuilder = builder
        self.currentRegionId = -1
        self.applyBoundaryColoring()
        // Notify React Native that the image loaded successfully
        self.onBoundaryImageLoad([
          "success": true,
          "regionCount": builder.regionCount,
          "width": image.size.width,
          "height": image.size.height,
        ])
      }
    }
  }

  // Toggle boundary coloring on/off from React Native prop.
  func setBoundaryColoringEnabled(_ enabled: Bool) {
    boundaryColoringEnabled = enabled
    if enabled {
      // Re-apply mask if we have a boundary image and a selected zone
      if boundaryImage != nil && maskLayer == nil && currentRegionId > 0 {
        applyMaskForRegion(currentRegionId)
      }
    } else {
      // Remove mask — strokes are no longer clipped to zones
      canvasView.layer.mask = nil
      maskLayer = nil
    }
  }

  // Change the grayscale threshold used to separate outlines from colorable areas.
  // Pixels darker than this value are considered "outline" (non-colorable).
  func setBoundaryThreshold(_ threshold: Int) {
    let clamped = max(0, min(255, threshold))
    guard clamped != boundaryThreshold else { return }
    boundaryThreshold = clamped

    // Rebuild region map with new threshold on background thread
    guard let image = boundaryImage else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let builder = RegionMapBuilder()
      builder.buildRegionMap(from: image, threshold: clamped)
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.regionMapBuilder = builder
        self.currentRegionId = -1
        self.canvasView.layer.mask = nil
        self.maskLayer = nil
        self.updateDebugOverlay()
      }
    }
  }

  // Toggle debug overlay — shows a green tint on the active zone.
  func setBoundaryDebug(_ debug: Bool) {
    boundaryDebug = debug
    updateDebugOverlay()
  }

  // MARK: - Boundary Coloring Core

  // Sets up the view hierarchy for boundary coloring mode.
  // Creates the coloredLayer if it doesn't exist, and ensures the background image is set.
  private func applyBoundaryColoring() {
    guard let image = boundaryImage else { return }

    // If no background image is set, use the boundary image as background
    if backgroundImageView == nil {
      setBackgroundImage(image)
    }

    // Create the coloredLayer — a UIImageView that holds all committed strokes.
    // It sits above the background but below the canvas in the view hierarchy.
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
  }

  // Returns a cached CGImage mask for a zone. Generates it on first use (~1ms).
  // The mask is an RGBA image where the zone's pixels have alpha=255 (visible)
  // and everything else has alpha=0 (hidden). Used as canvasView.layer.mask.
  private func canvasMask(for regionId: Int32, builder: RegionMapBuilder) -> CGImage? {
    if let cached = zoneMaskCache[regionId] { return cached }
    guard let mask = builder.generateCanvasMask(forRegions: [regionId]) else { return nil }
    zoneMaskCache[regionId] = mask
    return mask
  }

  // Applies a CALayer.mask to the canvasView, clipping all drawing to the specified zone.
  // CALayer.mask uses the alpha channel of the mask image: alpha=255 = visible, alpha=0 = hidden.
  // This is what confines strokes to a single zone while drawing.
  private func applyMaskForRegion(_ regionId: Int32) {
    guard boundaryColoringEnabled,
          let builder = regionMapBuilder,
          regionId > 0
    else { return }

    currentRegionId = regionId

    // Get or generate the mask CGImage for this zone
    guard let maskCGImage = canvasMask(for: regionId, builder: builder) else { return }

    // Create a new CALayer to use as the mask.
    // .resize stretches the mask to fill the canvas (mask is already at exact canvas pixel size).
    let newMask = CALayer()
    newMask.frame = canvasView.bounds
    newMask.contents = maskCGImage
    newMask.contentsGravity = .resize
    canvasView.layer.mask = newMask  // This clips all canvas rendering to the zone
    maskLayer = newMask              // Keep a reference so we can update its frame in layoutSubviews

    updateDebugOverlay()
  }

  // MARK: - Commit Stroke

  // This is the heart of the "always-empty canvas" architecture.
  //
  // When a stroke is finalized (detected in canvasViewDrawingDidChange):
  //   1. Get the raw stroke image from PKDrawing.image() — this is reliable and view-independent
  //   2. Mask the stroke image to the current zone using Core Graphics destinationIn blend
  //      (destinationIn keeps destination pixels only where source alpha > 0)
  //   3. Composite the masked stroke onto the coloredLayer
  //   4. Clear the canvas so it's empty for the next stroke
  //
  // The canvas clear (step 4) triggers canvasViewDrawingDidChange, but the isCommitting
  // guard prevents re-entry.
  private func commitCurrentStroke() {
    guard boundaryColoringEnabled,
          currentRegionId > 0,
          canvasView.drawing.strokes.count > 0,
          let builder = regionMapBuilder,
          let zoneMask = canvasMask(for: currentRegionId, builder: builder)
    else { return }

    // Save the current coloredLayer state for undo.
    // When undo is pressed, we restore this snapshot.
    coloredSnapshots.append(coloredLayer?.image)
    // New action invalidates the redo stack
    redoSnapshots = []

    let size = canvasView.bounds.size
    let scale = UIScreen.main.scale  // e.g., 3.0 on iPhone 15 Pro (3x Retina)

    // Step 1: Get raw stroke image from PKDrawing — the ONLY reliable way to render strokes.
    // PKDrawing.image(from:scale:) renders all strokes in the drawing into a UIImage.
    // Unlike drawHierarchy or CALayer.render, this doesn't depend on the view's display state.
    let strokeImage = canvasView.drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)

    // Step 2: Mask the stroke to the current zone.
    // We draw the stroke into a graphics context, then draw the zone mask on top
    // with .destinationIn blend mode. This keeps stroke pixels only where the mask has alpha > 0.
    UIGraphicsBeginImageContextWithOptions(size, false, scale)  // false = transparent background
    strokeImage.draw(at: .zero)
    UIImage(cgImage: zoneMask, scale: scale, orientation: .up)
      .draw(at: .zero, blendMode: .destinationIn, alpha: 1.0)
    let maskedStroke = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    // Step 3: Composite the masked stroke onto the coloredLayer.
    // Draw the existing coloredLayer image first, then the new masked stroke on top.
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    coloredLayer?.image?.draw(at: .zero)  // Previous strokes (may be nil on first commit)
    maskedStroke?.draw(at: .zero)          // New stroke on top
    coloredLayer?.image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    // Step 4: Clear the canvas.
    // This is safe because the finger is already lifted (stroke was finalized).
    // The isCommitting flag prevents the resulting canvasViewDrawingDidChange from re-entering.
    isCommitting = true
    canvasView.drawing = PKDrawing()
    isCommitting = false
  }

  // MARK: - Undo / Redo / Clear

  // Whether there are committed strokes that can be undone.
  var canUndoCommitted: Bool {
    return boundaryColoringEnabled && !coloredSnapshots.isEmpty
  }

  // Whether there are undone strokes that can be redone.
  var canRedoCommitted: Bool {
    return boundaryColoringEnabled && !redoSnapshots.isEmpty
  }

  // Undo: restore the coloredLayer to its previous state (before the last commit).
  // Returns true if undo was performed, false if nothing to undo.
  func undoCommittedStroke() -> Bool {
    guard boundaryColoringEnabled, !coloredSnapshots.isEmpty else { return false }
    // Push current state to redo stack before restoring
    redoSnapshots.append(coloredLayer?.image)
    coloredLayer?.image = coloredSnapshots.removeLast()
    emitUndoRedoStateChanges()
    return true
  }

  // Redo: restore the coloredLayer to the state before the last undo.
  func redoCommittedStroke() -> Bool {
    guard boundaryColoringEnabled, !redoSnapshots.isEmpty else { return false }
    // Push current state to undo stack before restoring
    coloredSnapshots.append(coloredLayer?.image)
    coloredLayer?.image = redoSnapshots.removeLast()
    emitUndoRedoStateChanges()
    return true
  }

  // Clear all committed strokes and reset undo/redo stacks.
  func clearAllCommitted() {
    coloredSnapshots = []
    redoSnapshots = []
    coloredLayer?.image = nil
    emitUndoRedoStateChanges()
  }

  // Tears down all boundary coloring state. Called when the boundary image is removed.
  private func clearBoundaryImage() {
    canvasView.layer.mask = nil
    maskLayer = nil
    debugMaskOverlay?.removeFromSuperview()
    debugMaskOverlay = nil
    coloredLayer?.removeFromSuperview()
    coloredLayer = nil
    boundaryImage = nil
    regionMapBuilder = nil
    currentRegionId = -1
    coloredSnapshots = []
    redoSnapshots = []
    zoneMaskCache = [:]
    previousStrokeCount = 0
  }

  // Creates or removes the green debug overlay that highlights the active zone.
  private func updateDebugOverlay() {
    debugMaskOverlay?.removeFromSuperview()
    debugMaskOverlay = nil

    guard boundaryDebug,
          let builder = regionMapBuilder,
          currentRegionId > 0,
          let debugImage = builder.generateDebugOverlay(forRegion: currentRegionId)
    else { return }

    let overlay = UIImageView(image: debugImage)
    overlay.contentMode = .scaleAspectFit
    overlay.frame = contentView.bounds
    overlay.isUserInteractionEnabled = false  // Touches pass through
    let insertIndex = backgroundImageView != nil ? 1 : 0
    contentView.insertSubview(overlay, at: insertIndex)
    debugMaskOverlay = overlay
  }

  // MARK: - Zone Touch Detection

  // Called by ZoneTouchDetector when the user touches the canvas.
  // Converts the touch point to image pixel coordinates, looks up the zone ID,
  // and applies the appropriate mask.
  private func handleTouchAtPoint(_ point: CGPoint) {
    guard boundaryColoringEnabled,
          let builder = regionMapBuilder
    else { return }

    // Eraser should work across all zones — remove the mask entirely
    if canvasView.tool is PKEraserTool {
      canvasView.layer.mask = nil
      maskLayer = nil
      currentRegionId = -1
      return
    }

    // Convert the touch point (in canvas view coordinates) to image pixel coordinates.
    // This accounts for the aspect-fit scaling of the boundary image within the canvas.
    let pixelPoint = convertToImagePixel(point)
    let regionId = builder.regionAt(x: Int(pixelPoint.x), y: Int(pixelPoint.y))

    // Only apply mask if the touch is inside a colorable zone (not on an outline)
    if regionId > 0 {
      applyMaskForRegion(regionId)
    }
    // If regionId == 0, the touch is on an outline — keep the current mask
  }

  // Converts a point in canvas view coordinates to image pixel coordinates.
  // This is necessary because the boundary image is displayed with .scaleAspectFit,
  // which means it may be letterboxed/pillarboxed within the canvas.
  // We need to account for the offset and scale to map correctly.
  private func convertToImagePixel(_ canvasPoint: CGPoint) -> CGPoint {
    guard let image = boundaryImage else { return .zero }

    let viewSize = canvasView.bounds.size   // e.g., 360x360 points
    let imageSize = image.size               // e.g., 1030x1207 points (at scale 1.0)
    guard viewSize.width > 0, viewSize.height > 0 else { return .zero }

    // Calculate the aspect-fit rectangle: where the image actually renders within the view
    let imageAspect = imageSize.width / imageSize.height
    let viewAspect = viewSize.width / viewSize.height

    var renderRect: CGRect
    if imageAspect > viewAspect {
      // Image is wider than view — pillarboxed (bars on top/bottom)
      let w = viewSize.width
      let h = w / imageAspect
      renderRect = CGRect(x: 0, y: (viewSize.height - h) / 2, width: w, height: h)
    } else {
      // Image is taller than view — letterboxed (bars on left/right)
      let h = viewSize.height
      let w = h * imageAspect
      renderRect = CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: h)
    }

    guard renderRect.width > 0, renderRect.height > 0 else { return .zero }

    // Map from view coordinates to image pixel coordinates
    let scale = image.scale  // Usually 1.0 for downloaded images
    let pixelX = ((canvasPoint.x - renderRect.origin.x) / renderRect.width) * imageSize.width * scale
    let pixelY = ((canvasPoint.y - renderRect.origin.y) / renderRect.height) * imageSize.height * scale

    return CGPoint(x: pixelX, y: pixelY)
  }

  // MARK: - Export

  // Captures the entire contentView (background + colored strokes + canvas) as a PNG image.
  // Hides the debug overlay during capture so it doesn't appear in the export.
  func captureImageWithDrawing() -> String {
    let debugWasVisible = debugMaskOverlay?.isHidden == false
    debugMaskOverlay?.isHidden = true

    // UIGraphicsImageRenderer creates a bitmap context at the view's scale.
    // drawHierarchy renders the ENTIRE view hierarchy (all subviews) into it.
    let renderer = UIGraphicsImageRenderer(bounds: contentView.bounds)
    let image = renderer.image { _ in
      contentView.drawHierarchy(in: contentView.bounds, afterScreenUpdates: true)
    }

    if debugWasVisible {
      debugMaskOverlay?.isHidden = false
    }

    guard let imageData = image.pngData() else { return "" }
    return imageData.base64EncodedString()
  }

  // MARK: - PKCanvasViewDelegate
  //
  // These methods are called by PencilKit when the user interacts with the canvas.
  // The isCommitting guard prevents re-entry when we programmatically clear the canvas.

  // Called when the user starts drawing (finger/pencil touches down and begins a stroke).
  public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    guard !isCommitting else { return }
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawStart(["data": data])
  }

  // Called when the user stops drawing (finger/pencil lifts up).
  // IMPORTANT: At this point, the stroke is NOT yet in canvasView.drawing.strokes!
  // PencilKit adds it later, which triggers canvasViewDrawingDidChange.
  public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    guard !isCommitting else { return }
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawEnd(["data": data])
    emitUndoRedoStateChanges()
  }

  // Called when the drawing data changes — during stroke AND after stroke finalization.
  // This is the ONLY reliable place to commit strokes because:
  //   - The stroke IS in drawing.strokes at this point (unlike didEndUsingTool)
  //   - currentRegionId is still correct (the next touch hasn't changed it yet)
  public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !isCommitting else { return }

    let strokeCount = canvasView.drawing.strokes.count

    // Detect stroke finalization: stroke count increased since last check.
    // PencilKit adds the completed stroke to drawing.strokes AFTER didEndUsingTool fires.
    // This is the moment we commit: render the stroke masked to its zone, add to coloredLayer.
    if boundaryColoringEnabled && currentRegionId > 0 && strokeCount > previousStrokeCount {
      commitCurrentStroke()
    }

    // Update the count AFTER commit (commit clears the canvas, setting count back to 0)
    previousStrokeCount = canvasView.drawing.strokes.count

    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawChange(["data": data])
    emitUndoRedoStateChanges()
  }

  // MARK: - UIScrollViewDelegate

  // Tells the scroll view which subview to zoom. We zoom the contentView,
  // which contains the background image, colored layer, and canvas together.
  public func viewForZooming(in _: UIScrollView) -> UIView? {
    return contentView
  }

  // MARK: - PKToolPickerObserver
  //
  // These are required by the PKToolPickerObserver protocol.
  // Currently not used, but PencilKit requires the conformance.

  public func toolPickerFramesObscuredDidChange(_: PKToolPicker) {}
  public func toolPickerVisibilityDidChange(_: PKToolPicker) {}
  public func toolPickerIsRulerActiveDidChange(_: PKToolPicker) {}
  public func toolPickerSelectedToolDidChange(_: PKToolPicker) {}

  // MARK: - Helpers

  // Sends the current undo/redo availability to React Native.
  // Checks both PencilKit's native undo AND our custom committed-stroke undo.
  private func emitUndoRedoStateChanges() {
    let nativeUndo = canvasView.undoManager?.canUndo ?? false
    let nativeRedo = canvasView.undoManager?.canRedo ?? false
    onCanUndoChanged(["canUndo": nativeUndo || canUndoCommitted])
    onCanRedoChanged(["canRedo": nativeRedo || canRedoCommitted])
  }

  // First responder management — delegates to the canvasView.
  // This is needed so PencilKit can receive keyboard shortcuts and tool picker events.
  override public var canBecomeFirstResponder: Bool {
    return canvasView.canBecomeFirstResponder
  }

  override public func becomeFirstResponder() -> Bool {
    return canvasView.becomeFirstResponder()
  }

  override public func resignFirstResponder() -> Bool {
    return canvasView.resignFirstResponder()
  }
}

// MARK: - Zone Touch Detector
//
// A custom UIGestureRecognizer that captures the touch-down location and then
// immediately sets state = .failed. This is critical for the boundary coloring
// architecture:
//
//   1. When the user touches the canvas, this recognizer fires touchesBegan
//   2. We detect which zone was touched and apply the mask (via the onTouchDown callback)
//   3. We immediately set state = .failed, which means this recognizer "gives up" the touch
//   4. PencilKit's own gesture recognizers then process the same touch normally
//
// Why not UILongPressGestureRecognizer?
//   UILongPressGestureRecognizer enters .began → .changed → .ended states, which
//   interferes with PencilKit's internal gesture handling. This causes
//   canvasViewDidEndUsingTool to fire at the wrong time (on the NEXT touch instead
//   of on finger lift). Setting state = .failed immediately avoids all interference.

private class ZoneTouchDetector: UIGestureRecognizer {
  // Called by the view to handle zone detection
  var onTouchDown: ((CGPoint) -> Void)?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    // Get the touch location in the canvas view's coordinate system
    if let point = touches.first?.location(in: view) {
      onTouchDown?(point)  // Detect zone and apply mask — synchronous, instant
    }
    // Immediately fail — we don't want to "own" this touch.
    // PencilKit's recognizers will process it and start a stroke.
    state = .failed
  }
}
