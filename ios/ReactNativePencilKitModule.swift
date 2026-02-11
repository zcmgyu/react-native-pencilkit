import ExpoModulesCore
import Foundation
import PencilKit
import UIKit

public class ReactNativePencilKitModule: Module {
  // Single canvas view approach like the working example
  private var canvasView: PKCanvasView?
  private var toolPicker: PKToolPicker?
  private var undoManager: UndoManager?
  private var colorPickerViewController: UIColorPickerViewController?
  private var colorPickerDelegate: ColorPickerDelegate?
  private var toolPickerObserver: ToolPickerObserver?

  // Each module class must implement the definition function. The definition consists of components
  // that describes the module's functionality and behavior.
  // See https://docs.expo.dev/modules/module-api for more details about available components.
  public func definition() -> ModuleDefinition {
    // Sets the name of the module that JavaScript code will use to refer to the module. Takes a string as an argument.
    // Can be inferred from module's class name, but it's recommended to set it explicitly for clarity.
    // The module will be accessible from `requireNativeModule('ReactNativePencilKit')` in JavaScript.
    Name("ReactNativePencilKitModule")

    // Module lifecycle
    OnCreate {
      // Register this module instance with the view
      ReactNativePencilKitView.setModuleInstance(self)
    }

    // View manager for PencilKit canvas
    View(ReactNativePencilKitView.self) {
      Events("onDrawStart", "onDrawEnd", "onDrawChange", "onCanUndoChanged", "onCanRedoChanged")

      Prop("imagePath") { (view: ReactNativePencilKitView, imagePath: [String: Any]?) in
        view.setImagePath(imagePath)
      }
    }

    // Setup tool picker for a specific canvas
    AsyncFunction("setupToolPicker") { (viewTag: Int, toolConfig: [String: Any]?) in
      await MainActor.run {
        self.setupToolPicker(for: viewTag, toolConfig: toolConfig)
      }
    }

    // Clear drawing from canvas
    AsyncFunction("clearDrawing") { (_: Int) in
      await MainActor.run {
        self.clearDrawing()
      }
    }

    // Undo last drawing action
    AsyncFunction("undo") { (_: Int) in
      await MainActor.run {
        self.undoDrawing()
      }
    }

    // Redo last undone drawing action
    AsyncFunction("redo") { (_: Int) in
      await MainActor.run {
        self.redoDrawing()
      }
    }

    // Capture drawing as PNG image
    AsyncFunction("captureDrawing") { (_: Int) -> String in
      return await MainActor.run {
        self.captureDrawing()
      }
    }

    // Get canvas data as base64
    AsyncFunction("getCanvasDataAsBase64") { (_: Int) -> String in
      return await MainActor.run {
        self.getCanvasDataAsBase64()
      }
    }

    // Set canvas data from base64
    AsyncFunction("setCanvasDataFromBase64") { (_: Int, base64String: String) -> Bool in
      return await MainActor.run {
        self.setCanvasDataFromBase64(base64String: base64String)
      }
    }

    // Check if undo is possible
    AsyncFunction("canUndo") { (_: Int) -> Bool in
      return await MainActor.run {
        self.canPerformUndo()
      }
    }

    // Check if redo is possible
    AsyncFunction("canRedo") { (_: Int) -> Bool in
      return await MainActor.run {
        self.canPerformRedo()
      }
    }

    // Show color picker
    AsyncFunction("showColorPicker") { (_: Int) in
      await MainActor.run {
        self.showColorPicker()
      }
    }

    // Set canvas background color
    AsyncFunction("setCanvasBackgroundColor") { (_: Int, colorString: String) in
      await MainActor.run {
        self.setCanvasBackgroundColor(colorString)
      }
    }

    // Get canvas background color
    AsyncFunction("getCanvasBackgroundColor") { (_: Int) -> String in
      return await MainActor.run {
        self.getCanvasBackgroundColor()
      }
    }
  }

  // MARK: - Canvas Registration

  func registerCanvasView(_ canvas: PKCanvasView) {
    canvasView = canvas
  }

  func unregisterCanvasView() {
    canvasView = nil
    toolPicker = nil
    undoManager = nil
  }

  // MARK: - Private Methods

  private func setupToolPicker(for _: Int, toolConfig: [String: Any]?) {
    guard let canvasView = canvasView else {
      return
    }

    toolPicker = PKToolPicker()

    // Configure tool picker
    toolPicker?.setVisible(true, forFirstResponder: canvasView)
    toolPicker?.addObserver(canvasView)

    // Create and add tool picker observer
    toolPickerObserver = ToolPickerObserver()
    toolPicker?.addObserver(toolPickerObserver!)

    // Set default tool if provided
    if let toolConfig = toolConfig {
      let defaultTool = createToolWithFallback(from: toolConfig)
      toolPicker?.selectedTool = defaultTool
      canvasView.tool = defaultTool
    }

    // Make canvas view first responder
    canvasView.becomeFirstResponder()

    // Get the undo manager from canvas view
    undoManager = canvasView.undoManager
  }

  private func createToolWithFallback(from config: [String: Any]) -> PKTool {
    // Try to create the requested tool
    if let tool = createTool(from: config, toolType: config["type"] as? String) {
      return tool
    }

    // If requested tool failed, try fallback tool
    if let fallbackType = config["fallbackTool"] as? String {
      var fallbackConfig = config
      fallbackConfig["type"] = fallbackType
      if let fallbackTool = createTool(from: fallbackConfig, toolType: fallbackType) {
        return fallbackTool
      }
    }

    // Final fallback: use pen
    let width = config["width"] as? CGFloat ?? 10.0
    let colorString = config["color"] as? String ?? "#000000"
    let color = colorFromHexString(colorString)
    return PKInkingTool(.pen, color: color, width: width)
  }

  private func createTool(from config: [String: Any], toolType: String?) -> PKTool? {
    guard let toolType = toolType else {
      return nil
    }

    let width = config["width"] as? CGFloat ?? 10.0
    let colorString = config["color"] as? String ?? "#000000"
    let color = colorFromHexString(colorString)

    switch toolType.lowercased() {
    case "pen":
      return PKInkingTool(.pen, color: color, width: width)

    case "marker":
      let markerWidth = config["width"] as? CGFloat ?? 20.0
      return PKInkingTool(.marker, color: color, width: markerWidth)

    case "pencil":
      return PKInkingTool(.pencil, color: color, width: width)

    case "monoline":
      if #available(iOS 17.0, *) {
        return PKInkingTool(.monoline, color: color, width: width)
      } else {
        return nil // Not available, will trigger fallback
      }

    case "fountainpen":
      if #available(iOS 17.0, *) {
        return PKInkingTool(.fountainPen, color: color, width: width)
      } else {
        return nil // Not available, will trigger fallback
      }

    case "watercolor":
      if #available(iOS 17.0, *) {
        return PKInkingTool(.watercolor, color: color, width: width)
      } else {
        return nil // Not available, will trigger fallback
      }

    case "crayon":
      if #available(iOS 17.0, *) {
        return PKInkingTool(.crayon, color: color, width: width)
      } else {
        return nil // Not available, will trigger fallback
      }

    case "reed":
      if #available(iOS 26.0, *) {
        return PKInkingTool(.reed, color: color, width: width)
      } else {
        return nil // Not available, will trigger fallback
      }

    case "eraser":
      let eraserType = config["eraserType"] as? String ?? "vector"
      if eraserType.lowercased() == "bitmap" {
        return PKEraserTool(.bitmap)
      } else {
        return PKEraserTool(.vector)
      }

    case "lasso":
      return PKLassoTool()

    default:
      return nil // Unknown tool type, will trigger fallback
    }
  }

  private func clearDrawing() {
    canvasView?.drawing = PKDrawing()
  }

  private func undoDrawing() {
    guard let undoManager = undoManager else {
      return
    }

    if undoManager.canUndo {
      undoManager.undo()
    }
  }

  private func redoDrawing() {
    guard let undoManager = undoManager else {
      return
    }

    if undoManager.canRedo {
      undoManager.redo()
    }
  }

  private func captureDrawing() -> String {
    guard let canvasView = canvasView else {
      return ""
    }

    let renderer = UIGraphicsImageRenderer(bounds: canvasView.bounds)
    let image = renderer.image { _ in
      canvasView.drawHierarchy(in: canvasView.bounds, afterScreenUpdates: false)
    }

    guard let imageData = image.pngData() else {
      return ""
    }

    let base64String = imageData.base64EncodedString()
    return base64String
  }

  private func getCanvasDataAsBase64() -> String {
    guard let canvasView = canvasView else {
      return ""
    }

    let drawingData = canvasView.drawing.dataRepresentation()
    let base64String = drawingData.base64EncodedString()
    return base64String
  }

  private func setCanvasDataFromBase64(base64String: String) -> Bool {
    guard let canvasView = canvasView else {
      return false
    }

    guard let drawingData = Data(base64Encoded: base64String) else {
      return false
    }

    do {
      let drawing = try PKDrawing(data: drawingData)
      canvasView.drawing = drawing
      return true
    } catch {
      return false
    }
  }

  private func canPerformUndo() -> Bool {
    guard let undoManager = undoManager else {
      return false
    }

    return undoManager.canUndo
  }

  private func canPerformRedo() -> Bool {
    guard let undoManager = undoManager else {
      return false
    }

    return undoManager.canRedo
  }

  private func showColorPicker() {
    // Get the key window scene and root view controller
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let rootViewController = windowScene.windows.first?.rootViewController
    else {
      return
    }

    // Find the topmost presented view controller
    var topViewController = rootViewController
    while let presentedViewController = topViewController.presentedViewController {
      topViewController = presentedViewController
    }

    colorPickerViewController = UIColorPickerViewController()
    colorPickerDelegate = ColorPickerDelegate(module: self)
    colorPickerViewController?.delegate = colorPickerDelegate

    topViewController.present(colorPickerViewController!, animated: true)
  }

  private func setCanvasBackgroundColor(_ colorString: String) {
    let color = colorFromHexString(colorString)
    canvasView?.backgroundColor = color
  }

  private func getCanvasBackgroundColor() -> String {
    guard let canvasView = canvasView else {
      return "FFFFFF" // Default to white
    }

    return hexStringFromColor(canvasView.backgroundColor ?? UIColor.white)
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

  // MARK: - Color Picker Delegate Methods

  func colorPickerDidFinish(with color: UIColor) {
    canvasView?.backgroundColor = color
  }

  func colorPickerDidSelectColor(_ color: UIColor) {
    canvasView?.backgroundColor = color
  }
}

// MARK: - Tool Picker Observer Helper Class

private class ToolPickerObserver: NSObject, PKToolPickerObserver {
  func toolPickerFramesObscuredDidChange(_: PKToolPicker) {
    // Tool picker frames obscured changed
  }

  func toolPickerVisibilityDidChange(_: PKToolPicker) {
    // Tool picker visibility changed
  }

  func toolPickerIsRulerActiveDidChange(_: PKToolPicker) {
    // Tool picker ruler active changed
  }

  func toolPickerSelectedToolDidChange(_: PKToolPicker) {
    // Tool picker selected tool changed
  }
}

// MARK: - Color Picker Delegate Helper Class

private class ColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
  weak var module: ReactNativePencilKitModule?

  init(module: ReactNativePencilKitModule) {
    self.module = module
    super.init()
  }

  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    module?.colorPickerDidFinish(with: viewController.selectedColor)
    viewController.dismiss(animated: true)
  }

  func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
    module?.colorPickerDidSelectColor(viewController.selectedColor)
  }
}
