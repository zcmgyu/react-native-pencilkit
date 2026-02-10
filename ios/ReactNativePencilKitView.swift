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

  // Static reference to module for communication
  private weak static var moduleInstance: ReactNativePencilKitModule?

  // Event handlers
  let onDrawStart = EventDispatcher()
  let onDrawEnd = EventDispatcher()
  let onDrawChange = EventDispatcher()
  let onCanUndoChanged = EventDispatcher()
  let onCanRedoChanged = EventDispatcher()

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
  }

  override public func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      ReactNativePencilKitView.moduleInstance?.registerCanvasView(canvasView)
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

  // MARK: - PKCanvasViewDelegate

  public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawStart([
      "data": data,
    ])
  }

  public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawEnd([
      "data": data,
    ])
    emitUndoRedoStateChanges()
  }

  public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    let data = canvasView.drawing.dataRepresentation().base64EncodedString()
    onDrawChange([
      "data": data,
    ])
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
    guard let undoManager = canvasView.undoManager else { return }

    let canUndo = undoManager.canUndo
    let canRedo = undoManager.canRedo

    onCanUndoChanged([
      "canUndo": canUndo,
    ])
    onCanRedoChanged([
      "canRedo": canRedo,
    ])
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
