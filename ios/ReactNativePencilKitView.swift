import ExpoModulesCore
import Foundation
import PencilKit
import UIKit

// MARK: - View hierarchy (zoom/pan keeps image + strokes aligned)

//
//  ReactNativePencilKitView (self)
//  └── scrollView (UIScrollView)           ← pan/zoom container; frame = bounds
//      └── contentView (UIView)            ← viewForZooming target; same size as canvas
//          ├── backgroundImageView?       ← [0] optional; .scaleAspectFit; behind canvas
//          └── canvasView (PKCanvasView)  ← [1] drawing surface; isScrollEnabled = false
//
//  • contentView is the single zoomable view so image and strokes scale/pan together.
//  • Canvas scroll/zoom is disabled; outer scrollView controls all pan/zoom.
//  • layoutSubviews: scrollView.frame = bounds, contentView.frame = origin zero + bounds.size,
//    scrollView.contentSize = bounds.size, subviews frame = contentView.bounds.
//
//  Reference: PlantUML4iPad SwiftUI+PencilKit (UIDrawingViewController)
// https://github.com/bsorrentino/PlantUML4iPad/blob/f66733a5113fc2d5d2e846b79158d8839abfd6c2/PlantUML/SwiftUI%2BPencilKit.swift#L2

public class ReactNativePencilKitView: ExpoView, PKCanvasViewDelegate, PKToolPickerObserver, UIScrollViewDelegate {
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let canvasView = PKCanvasView()
  private var backgroundImageView: UIImageView?

  // Boundary coloring — "always-empty canvas" architecture:
  // Canvas is cleared after each stroke (on lift). Touch always finds empty canvas = instant drawing.
  // Committed strokes live on coloredLayer as properly-masked images.
  private var boundaryImage: UIImage?
  private var regionMapBuilder: RegionMapBuilder?
  private var currentRegionId: Int32 = -1
  private var activeRegionIds: Set<Int32> = []
  private var zoneMaskCache: [Int32: CGImage] = [:]
  private var coloredSnapshots: [UIImage?] = []  // Undo stack (coloredLayer state before each commit)
  private var isCommitting = false  // Guard for commit-triggered delegate calls
  private var previousStrokeCount: Int = 0  // Track for detecting stroke finalization
  private var maskLayer: CALayer?
  private var coloredLayer: UIImageView?  // Shows all committed strokes (masked per zone)
  private var outlineImageView: UIImageView?
  private var debugMaskOverlay: UIImageView?
  private(set) var boundaryColoringEnabled: Bool = true
  private var boundaryThreshold: Int = 128
  private var boundaryDebug: Bool = false
  private let zoneTouchDetector = ZoneTouchDetector()

  // Static reference to module for communication
  private weak static var moduleInstance: ReactNativePencilKitModule?

  // Event handlers
  let onDrawStart = EventDispatcher()
  let onDrawEnd = EventDispatcher()
  let onDrawChange = EventDispatcher()
  let onCanUndoChanged = EventDispatcher()
  let onCanRedoChanged = EventDispatcher()
  let onBoundaryImageLoad = EventDispatcher()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupScrollView()
    setupCanvasView()
  }

  // MARK: - Setup (matches hierarchy above)

  private func setupScrollView() {
    scrollView.delegate = self
    scrollView.minimumZoomScale = 1.0
    scrollView.maximumZoomScale = 5.0
    scrollView.backgroundColor = .gray
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    addSubview(scrollView)
  }

  private func setupCanvasView() {
    // Configure canvas like the reference: opaque false, delegate, no built-in scroll when in container
    canvasView.drawingPolicy = .anyInput
    canvasView.overrideUserInterfaceStyle = .light
    canvasView.isMultipleTouchEnabled = true
    canvasView.isOpaque = false
    canvasView.backgroundColor = UIColor.clear
    canvasView.delegate = self
    canvasView.isUserInteractionEnabled = true
    // Disable canvas's own scroll/zoom so our scrollView controls pan/zoom for both image + canvas
    canvasView.isScrollEnabled = false
    canvasView.minimumZoomScale = 1.0
    canvasView.maximumZoomScale = 1.0

    canvasView.drawing = PKDrawing()

    // contentView hosts both background image and canvas (same frame) so they zoom/pan together
    contentView.backgroundColor = .white
    contentView.addSubview(canvasView)
    scrollView.addSubview(contentView)

    zoneTouchDetector.onTouchDown = { [weak self] point in
      self?.handleTouchAtPoint(point)
    }
    canvasView.addGestureRecognizer(zoneTouchDetector)
  }

  // MARK: - Layout (keep in sync with hierarchy)

  override public func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    let contentSize = bounds.size
    contentView.frame = CGRect(origin: .zero, size: contentSize)
    scrollView.contentSize = contentSize
    canvasView.frame = contentView.bounds
    backgroundImageView?.frame = contentView.bounds
    coloredLayer?.frame = contentView.bounds
    outlineImageView?.frame = contentView.bounds
    debugMaskOverlay?.frame = contentView.bounds
    maskLayer?.frame = canvasView.bounds
  }

  override public func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      ReactNativePencilKitView.moduleInstance?.registerCanvasView(canvasView)
      ReactNativePencilKitView.moduleInstance?.registerPencilKitView(self)
    } else {
      ReactNativePencilKitView.moduleInstance?.unregisterCanvasView()
    }
  }

  // Static method for module to register itself
  static func setModuleInstance(_ module: ReactNativePencilKitModule) {
    moduleInstance = module
  }

  // MARK: - Props

  func setImagePath(_ imagePath: [String: Any]?) {
    guard let imagePath = imagePath,
          let uriString = imagePath["uri"] as? String,
          let url = URL(string: uriString)
    else {
      clearBackgroundImage()
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let data = try? Data(contentsOf: url),
            let image = UIImage(data: data)
      else {
        DispatchQueue.main.async { self?.clearBackgroundImage() }
        return
      }

      DispatchQueue.main.async {
        self?.setBackgroundImage(image)
      }
    }
  }

  private func setBackgroundImage(_ image: UIImage) {
    backgroundImageView?.removeFromSuperview()
    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.frame = contentView.bounds
    contentView.insertSubview(imageView, at: 0)
    backgroundImageView = imageView
    canvasView.backgroundColor = .clear
  }

  private func clearBackgroundImage() {
    backgroundImageView?.removeFromSuperview()
    backgroundImageView = nil
    canvasView.backgroundColor = .white
  }

  // MARK: - Boundary Coloring Props

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

      // Build region map + pre-compute ALL zone masks on background thread
      let builder = RegionMapBuilder()
      builder.buildRegionMap(from: image, threshold: self?.boundaryThreshold ?? 128)

      // Pre-compute canvas-resolution region map (one-time O(n) mapping)
      let canvasSize = self?.canvasView.bounds.size ?? CGSize(width: 360, height: 360)
      let scale = UIScreen.main.scale
      builder.precomputeCanvasMap(canvasSize: canvasSize, scale: scale)

      DispatchQueue.main.async {
        guard let self = self else { return }
        NSLog("[PencilKit] Boundary image loaded: %dx%d, %d regions, canvas map %dx%d",
              Int(image.size.width), Int(image.size.height), builder.regionCount,
              builder.canvasPixelW, builder.canvasPixelH)
        self.boundaryImage = image
        self.regionMapBuilder = builder
        self.currentRegionId = -1
        self.applyBoundaryColoring()
        self.onBoundaryImageLoad([
          "success": true,
          "regionCount": builder.regionCount,
          "width": image.size.width,
          "height": image.size.height,
        ])
      }
    }
  }

  func setBoundaryColoringEnabled(_ enabled: Bool) {
    boundaryColoringEnabled = enabled
    if enabled {
      if boundaryImage != nil && maskLayer == nil && currentRegionId > 0 {
        applyMaskForRegion(currentRegionId)
      }
    } else {
      canvasView.layer.mask = nil
      maskLayer = nil
    }
  }

  func setBoundaryThreshold(_ threshold: Int) {
    let clamped = max(0, min(255, threshold))
    guard clamped != boundaryThreshold else { return }
    boundaryThreshold = clamped

    // Regenerate region map with new threshold
    guard let image = boundaryImage else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let builder = RegionMapBuilder()
      builder.buildRegionMap(from: image, threshold: clamped)
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.regionMapBuilder = builder
        self.currentRegionId = -1
        self.activeRegionIds = []
        self.canvasView.layer.mask = nil
        self.maskLayer = nil
        self.updateDebugOverlay()
      }
    }
  }

  func setBoundaryDebug(_ debug: Bool) {
    boundaryDebug = debug
    updateDebugOverlay()
  }

  // MARK: - Boundary Coloring Core

  private func applyBoundaryColoring() {
    guard let image = boundaryImage else { return }

    if backgroundImageView == nil {
      setBackgroundImage(image)
    }

    if coloredLayer == nil {
      let layer = UIImageView()
      layer.frame = contentView.bounds
      layer.isUserInteractionEnabled = false
      layer.backgroundColor = .clear
      let insertIndex = backgroundImageView != nil ? 1 : 0
      contentView.insertSubview(layer, at: insertIndex)
      coloredLayer = layer
    }

    canvasView.backgroundColor = .clear
    contentView.backgroundColor = .white
  }

  /// Returns a cached canvas mask for a single region, generating on first use (~1ms from pre-computed map).
  private func canvasMask(for regionId: Int32, builder: RegionMapBuilder) -> CGImage? {
    if let cached = zoneMaskCache[regionId] { return cached }
    guard let mask = builder.generateCanvasMask(forRegions: [regionId]) else { return nil }
    zoneMaskCache[regionId] = mask
    return mask
  }

  private func applyMaskForRegion(_ regionId: Int32) {
    guard boundaryColoringEnabled,
          let builder = regionMapBuilder,
          regionId > 0
    else { return }

    currentRegionId = regionId
    activeRegionIds.insert(regionId)

    // Just change the mask — canvas is always empty (cleared on previous lift)
    // No drawing swap = no PencilKit disruption = instant drawing
    guard let maskCGImage = canvasMask(for: regionId, builder: builder) else { return }
    let newMask = CALayer()
    newMask.frame = canvasView.bounds
    newMask.contents = maskCGImage
    newMask.contentsGravity = .resize
    canvasView.layer.mask = newMask
    maskLayer = newMask

    updateDebugOverlay()
  }

  // MARK: - Commit Stroke (on finger lift)

  /// Renders current canvas stroke masked to its zone, composites onto coloredLayer, clears canvas.
  /// Called from canvasViewDidEndUsingTool — safe because finger is already lifted.
  private func commitCurrentStroke() {
    guard boundaryColoringEnabled,
          currentRegionId > 0,
          canvasView.drawing.strokes.count > 0,
          let builder = regionMapBuilder,
          let zoneMask = canvasMask(for: currentRegionId, builder: builder)
    else { return }

    // Save coloredLayer state for undo
    coloredSnapshots.append(coloredLayer?.image)

    // Render stroke from PKDrawing (reliable, no view rendering)
    let size = canvasView.bounds.size
    let scale = UIScreen.main.scale
    let strokeImage = canvasView.drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)

    // Mask stroke to current zone + composite onto coloredLayer
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    coloredLayer?.image?.draw(at: .zero)
    // Draw masked stroke
    strokeImage.draw(at: .zero)
    UIImage(cgImage: zoneMask, scale: scale, orientation: .up)
      .draw(at: .zero, blendMode: .destinationIn, alpha: 1.0)
    // Oops — destinationIn affects everything drawn so far. Need separate pass.
    UIGraphicsEndImageContext()

    // Correct approach: mask stroke first, then composite
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    strokeImage.draw(at: .zero)
    UIImage(cgImage: zoneMask, scale: scale, orientation: .up)
      .draw(at: .zero, blendMode: .destinationIn, alpha: 1.0)
    let maskedStroke = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    coloredLayer?.image?.draw(at: .zero)
    maskedStroke?.draw(at: .zero)
    coloredLayer?.image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    // Clear canvas — safe, finger is lifted, no active touch
    isCommitting = true
    canvasView.drawing = PKDrawing()
    isCommitting = false

    NSLog("[PencilKit] Committed stroke to zone %d (undo stack: %d)", currentRegionId, coloredSnapshots.count)
  }

  // MARK: - Undo

  var canUndoCommitted: Bool {
    return !coloredSnapshots.isEmpty
  }

  func undoCommittedStroke() -> Bool {
    guard !coloredSnapshots.isEmpty else { return false }
    coloredLayer?.image = coloredSnapshots.removeLast()
    emitUndoRedoStateChanges()
    return true
  }

  private func clearBoundaryImage() {
    canvasView.layer.mask = nil
    maskLayer = nil
    outlineImageView?.removeFromSuperview()
    outlineImageView = nil
    debugMaskOverlay?.removeFromSuperview()
    debugMaskOverlay = nil
    boundaryImage = nil
    regionMapBuilder = nil
    currentRegionId = -1
    coloredLayer?.removeFromSuperview()
    coloredLayer = nil
    activeRegionIds = []
    coloredSnapshots = []
    zoneMaskCache = [:]
    previousStrokeCount = 0
  }

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
    overlay.isUserInteractionEnabled = false
    // Insert below canvas but above background
    let insertIndex = backgroundImageView != nil ? 1 : 0
    contentView.insertSubview(overlay, at: insertIndex)
    debugMaskOverlay = overlay
  }

  // MARK: - Touch Interception for Region Detection

  private func handleTouchAtPoint(_ point: CGPoint) {
    guard boundaryColoringEnabled,
          let builder = regionMapBuilder
    else { return }

    if canvasView.tool is PKEraserTool {
      canvasView.layer.mask = nil
      maskLayer = nil
      currentRegionId = -1
      return
    }

    let pixelPoint = convertToImagePixel(point)
    let regionId = builder.regionAt(x: Int(pixelPoint.x), y: Int(pixelPoint.y))

    if regionId > 0 {
      applyMaskForRegion(regionId)
    }
  }

  private func convertToImagePixel(_ canvasPoint: CGPoint) -> CGPoint {
    guard let image = boundaryImage else { return .zero }

    let viewSize = canvasView.bounds.size
    let imageSize = image.size
    guard viewSize.width > 0, viewSize.height > 0 else { return .zero }

    let imageAspect = imageSize.width / imageSize.height
    let viewAspect = viewSize.width / viewSize.height

    var renderRect: CGRect
    if imageAspect > viewAspect {
      let w = viewSize.width
      let h = w / imageAspect
      renderRect = CGRect(x: 0, y: (viewSize.height - h) / 2, width: w, height: h)
    } else {
      let h = viewSize.height
      let w = h * imageAspect
      renderRect = CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: h)
    }

    guard renderRect.width > 0, renderRect.height > 0 else { return .zero }

    let scale = image.scale
    let pixelX = ((canvasPoint.x - renderRect.origin.x) / renderRect.width) * imageSize.width * scale
    let pixelY = ((canvasPoint.y - renderRect.origin.y) / renderRect.height) * imageSize.height * scale

    return CGPoint(x: pixelX, y: pixelY)
  }

  // MARK: - UIGestureRecognizerDelegate


  // MARK: - Export (hide debug overlay)

  func captureImageWithDrawing() -> String {
    // Hide debug overlay for export
    let debugWasVisible = debugMaskOverlay?.isHidden == false
    debugMaskOverlay?.isHidden = true

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

  public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    guard !isCommitting else { return }
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawStart(["data": data])
  }

  public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    guard !isCommitting else { return }
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawEnd(["data": data])
    emitUndoRedoStateChanges()
  }

  public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !isCommitting else { return }

    let strokeCount = canvasView.drawing.strokes.count

    // Stroke finalized — PencilKit adds stroke to drawing.strokes AFTER didEndUsingTool.
    // This is the ONLY reliable moment: stroke data is available AND currentRegionId is still correct.
    if boundaryColoringEnabled && currentRegionId > 0 && strokeCount > previousStrokeCount {
      NSLog("[PencilKit] Stroke finalized (count %d→%d, region=%d) — committing",
            previousStrokeCount, strokeCount, currentRegionId)
      commitCurrentStroke()
    }

    previousStrokeCount = canvasView.drawing.strokes.count  // Update AFTER commit (which clears to 0)

    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawChange(["data": data])
    emitUndoRedoStateChanges()
  }

  // MARK: - UIScrollViewDelegate

  // Zoom the whole content (image + canvas) together so strokes stay aligned with the image.
  public func viewForZooming(in _: UIScrollView) -> UIView? {
    return contentView
  }

  // MARK: - PKToolPickerObserver

  public func toolPickerFramesObscuredDidChange(_: PKToolPicker) {
    // Handle tool picker frame changes if needed
  }

  public func toolPickerVisibilityDidChange(_: PKToolPicker) {
    // Handle tool picker visibility changes if needed
  }

  public func toolPickerIsRulerActiveDidChange(_: PKToolPicker) {
    // Handle ruler state changes if needed
  }

  public func toolPickerSelectedToolDidChange(_: PKToolPicker) {
    // Handle tool selection changes if needed
  }

  // MARK: - Helper Methods

  private func emitUndoRedoStateChanges() {
    let nativeUndo = canvasView.undoManager?.canUndo ?? false
    onCanUndoChanged(["canUndo": nativeUndo || canUndoCommitted])
    onCanRedoChanged(["canRedo": canvasView.undoManager?.canRedo ?? false])
  }

  // Override to allow becoming first responder
  override public var canBecomeFirstResponder: Bool {
    return canvasView.canBecomeFirstResponder
  }

  override public func becomeFirstResponder() -> Bool {
    return canvasView.becomeFirstResponder()
  }

  override public func resignFirstResponder() -> Bool {
    return canvasView.resignFirstResponder()
  }

  // MARK: - Helper Methods

  private func colorFromHexString(_ hexString: String) -> UIColor {
    var hexSanitized = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

    var rgb: UInt64 = 0
    Scanner(string: hexSanitized).scanHexInt64(&rgb)

    let red, green, blue, alpha: CGFloat

    if hexSanitized.count <= 6 {
      // RGB format
      red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
      green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
      blue = CGFloat(rgb & 0x0000FF) / 255.0
      alpha = 1.0
    } else {
      // RGBA format
      red = CGFloat((rgb & 0xFF00_0000) >> 24) / 255.0
      green = CGFloat((rgb & 0x00FF_0000) >> 16) / 255.0
      blue = CGFloat((rgb & 0x0000_FF00) >> 8) / 255.0
      alpha = CGFloat(rgb & 0x0000_00FF) / 255.0
    }

    return UIColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  private func hexStringFromColor(_ color: UIColor) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0

    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    let redInt = Int(red * 255.0)
    let greenInt = Int(green * 255.0)
    let blueInt = Int(blue * 255.0)

    return String(format: "%02X%02X%02X", redInt, greenInt, blueInt)
  }
}

// MARK: - Zone Touch Detector
// Fires synchronously in touchesBegan BEFORE PencilKit processes the touch.
// Does the zone switch (including drawing swap) then immediately fails,
// so PencilKit starts its stroke on the already-swapped canvas.

private class ZoneTouchDetector: UIGestureRecognizer {
  var onTouchDown: ((CGPoint) -> Void)?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    if let point = touches.first?.location(in: view) {
      onTouchDown?(point)  // Swap happens here, synchronously
    }
    state = .failed  // Release touch — PencilKit starts stroke on swapped canvas
  }
}

// MARK: - Color Picker Delegate Helper Class for Ref Methods

private class ColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
  private let onColorSelected: (UIColor) -> Void

  init(onColorSelected: @escaping (UIColor) -> Void) {
    self.onColorSelected = onColorSelected
    super.init()
  }

  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    onColorSelected(viewController.selectedColor)
    viewController.dismiss(animated: true)
  }

  func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
    onColorSelected(viewController.selectedColor)
  }
}
