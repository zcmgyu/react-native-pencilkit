import CoreGraphics
import UIKit

/// Builds a region map from a boundary/outline image using connected component labeling.
/// Each enclosed white region gets a unique ID. Outline pixels (black) get ID 0.
class RegionMapBuilder {
  private(set) var width: Int = 0
  private(set) var height: Int = 0
  private(set) var regionMap: [Int32] = []
  private(set) var erodedRegionMap: [Int32] = []  // Pre-eroded for mask generation
  private(set) var regionCount: Int = 0

  // Canvas-resolution pre-mapped data (computed once, enables instant mask generation)
  private(set) var canvasPixelW: Int = 0
  private(set) var canvasPixelH: Int = 0
  private(set) var canvasRegionMap: [Int32] = []
  private(set) var regionPixelIndices: [Int32: [Int]] = [:]
  private(set) var regionBezierPaths: [Int32: UIBezierPath] = [:]  // Pre-computed clip paths per zone

  // MARK: - Build Region Map

  /// Processes the boundary image into a region map using connected component labeling.
  /// Call from a background queue — this is CPU-intensive for large images.
  func buildRegionMap(from image: UIImage, threshold: Int = 128) {
    guard let cgImage = image.cgImage else { return }

    let w = cgImage.width
    let h = cgImage.height
    width = w
    height = h

    // 1. Render image into grayscale pixel buffer
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let context = CGContext(
      data: &pixels,
      width: w,
      height: h,
      bitsPerComponent: 8,
      bytesPerRow: w,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    // 2. Threshold to binary: true = white/colorable, false = black/outline
    let thresholdByte = UInt8(clamping: threshold)
    var isWhite = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) {
      isWhite[i] = pixels[i] > thresholdByte
    }

    // 3. Two-pass connected component labeling with union-find (4-connectivity)
    var labels = [Int32](repeating: 0, count: w * h)
    var parent = [Int32]()  // union-find parent array
    var nextLabel: Int32 = 1

    // Reserve label 0 for outline pixels
    parent.append(0)

    // Pass 1: assign provisional labels
    for y in 0..<h {
      for x in 0..<w {
        let idx = y * w + x
        guard isWhite[idx] else { continue }

        let upLabel: Int32 = (y > 0 && isWhite[(y - 1) * w + x]) ? labels[(y - 1) * w + x] : 0
        let leftLabel: Int32 = (x > 0 && isWhite[y * w + (x - 1)]) ? labels[y * w + (x - 1)] : 0

        if upLabel == 0 && leftLabel == 0 {
          // New label
          labels[idx] = nextLabel
          parent.append(nextLabel)
          nextLabel += 1
        } else if upLabel != 0 && leftLabel == 0 {
          labels[idx] = upLabel
        } else if upLabel == 0 && leftLabel != 0 {
          labels[idx] = leftLabel
        } else {
          // Both neighbors labeled — union them
          let minLabel = min(upLabel, leftLabel)
          let maxLabel = max(upLabel, leftLabel)
          labels[idx] = minLabel
          union(&parent, minLabel, maxLabel)
        }
      }
    }

    // Pass 2: flatten labels
    // First, compress all paths
    for i in 1..<parent.count {
      _ = find(&parent, Int32(i))
    }

    // Remap root labels to sequential IDs
    var rootToSequential = [Int32: Int32]()
    var seqId: Int32 = 0
    for i in 1..<parent.count {
      let root = find(&parent, Int32(i))
      if rootToSequential[root] == nil {
        seqId += 1
        rootToSequential[root] = seqId
      }
    }

    // Apply to region map
    regionMap = [Int32](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      if labels[i] > 0 {
        let root = find(&parent, labels[i])
        regionMap[i] = rootToSequential[root] ?? 0
      }
    }

    regionCount = Int(seqId)

    // Erode using distance transform — O(n) instead of O(n × erosion²)
    // Erosion must be large enough to prevent brush overflow into neighbor zones.
    // A 20pt brush at typical canvas scale ≈ 35 image pixels half-width.
    // Using 20 pixels covers most brush sizes while keeping the gap hidden by outlines.
    // Keep pixels where distance > erosionRadius.
    let erosionRadius = 0
    let INF = w + h  // larger than any real distance
    var dist = [Int](repeating: 0, count: w * h)

    // Initialize: boundary pixels get 0, interior pixels get INF
    for i in 0..<(w * h) {
      if regionMap[i] == 0 {
        dist[i] = 0
      } else {
        let x = i % w
        let y = i / w
        let rid = regionMap[i]
        // Check 4 neighbors for boundary detection
        let atBoundary = x == 0 || y == 0 || x == w - 1 || y == h - 1
          || regionMap[(y - 1) * w + x] != rid
          || regionMap[(y + 1) * w + x] != rid
          || regionMap[y * w + (x - 1)] != rid
          || regionMap[y * w + (x + 1)] != rid
        dist[i] = atBoundary ? 0 : INF
      }
    }

    // Forward pass: top-left to bottom-right (Chebyshev distance)
    for y in 0..<h {
      for x in 0..<w {
        let i = y * w + x
        if dist[i] == 0 { continue }
        if y > 0 { dist[i] = min(dist[i], dist[(y - 1) * w + x] + 1) }
        if x > 0 { dist[i] = min(dist[i], dist[y * w + (x - 1)] + 1) }
        if y > 0 && x > 0 { dist[i] = min(dist[i], dist[(y - 1) * w + (x - 1)] + 1) }
        if y > 0 && x < w - 1 { dist[i] = min(dist[i], dist[(y - 1) * w + (x + 1)] + 1) }
      }
    }

    // Backward pass: bottom-right to top-left
    for y in stride(from: h - 1, through: 0, by: -1) {
      for x in stride(from: w - 1, through: 0, by: -1) {
        let i = y * w + x
        if dist[i] == 0 { continue }
        if y < h - 1 { dist[i] = min(dist[i], dist[(y + 1) * w + x] + 1) }
        if x < w - 1 { dist[i] = min(dist[i], dist[y * w + (x + 1)] + 1) }
        if y < h - 1 && x < w - 1 { dist[i] = min(dist[i], dist[(y + 1) * w + (x + 1)] + 1) }
        if y < h - 1 && x > 0 { dist[i] = min(dist[i], dist[(y + 1) * w + (x - 1)] + 1) }
      }
    }

    // Build eroded map: keep pixels with distance > erosionRadius
    erodedRegionMap = [Int32](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      if dist[i] > erosionRadius {
        erodedRegionMap[i] = regionMap[i]
      }
    }
  }

  // MARK: - Region Lookup

  /// Returns the region ID at the given pixel coordinates. Returns 0 for outline pixels or out-of-bounds.
  func regionAt(x: Int, y: Int) -> Int32 {
    guard x >= 0, x < width, y >= 0, y < height else { return 0 }
    return regionMap[y * width + x]
  }

  // MARK: - Canvas Pre-mapping

  /// Pre-computes the eroded region map at canvas pixel resolution.
  /// Call once on background thread after buildRegionMap. Enables instant mask generation.
  func precomputeCanvasMap(canvasSize: CGSize, scale: CGFloat) {
    let pW = Int(canvasSize.width * scale)
    let pH = Int(canvasSize.height * scale)
    canvasPixelW = pW
    canvasPixelH = pH

    guard width > 0, height > 0, pW > 0, pH > 0 else { return }

    let imageW = CGFloat(width)
    let imageH = CGFloat(height)
    let imageAspect = imageW / imageH
    let canvasAspect = CGFloat(pW) / CGFloat(pH)

    let renderW: CGFloat, renderH: CGFloat, offsetX: CGFloat, offsetY: CGFloat
    if imageAspect > canvasAspect {
      renderW = CGFloat(pW)
      renderH = renderW / imageAspect
      offsetX = 0
      offsetY = (CGFloat(pH) - renderH) / 2
    } else {
      renderH = CGFloat(pH)
      renderW = renderH * imageAspect
      offsetX = (CGFloat(pW) - renderW) / 2
      offsetY = 0
    }

    canvasRegionMap = [Int32](repeating: 0, count: pW * pH)
    regionPixelIndices = [:]
    for py in 0..<pH {
      for px in 0..<pW {
        let imgX = Int((CGFloat(px) - offsetX) / renderW * imageW)
        let imgY = Int((CGFloat(py) - offsetY) / renderH * imageH)
        guard imgX >= 0, imgX < width, imgY >= 0, imgY < height else { continue }
        let rid = erodedRegionMap[imgY * width + imgX]
        canvasRegionMap[py * pW + px] = rid
        if rid > 0 {
          let idx = py * pW + px
          if regionPixelIndices[rid] == nil { regionPixelIndices[rid] = [] }
          regionPixelIndices[rid]?.append(idx)
        }
      }
    }

    // Pre-compute UIBezierPaths per region at POINT resolution (for PKStroke.mask)
    let pointW = Int(canvasSize.width)
    let pointH = Int(canvasSize.height)
    regionBezierPaths = [:]

    // Build a point-resolution region map (1 point = 1 pixel in this map)
    var pointRegionMap = [Int32](repeating: 0, count: pointW * pointH)
    for py in 0..<pointH {
      for px in 0..<pointW {
        let imgX = Int((CGFloat(px) - offsetX / scale) / (renderW / scale) * imageW)
        let imgY = Int((CGFloat(py) - offsetY / scale) / (renderH / scale) * imageH)
        guard imgX >= 0, imgX < width, imgY >= 0, imgY < height else { continue }
        pointRegionMap[py * pointW + px] = erodedRegionMap[imgY * width + imgX]
      }
    }

    // For each region, create a UIBezierPath from horizontal row spans
    var regionSpans: [Int32: [(y: Int, xStart: Int, xEnd: Int)]] = [:]
    for y in 0..<pointH {
      var x = 0
      while x < pointW {
        let rid = pointRegionMap[y * pointW + x]
        if rid > 0 {
          let startX = x
          while x < pointW && pointRegionMap[y * pointW + x] == rid { x += 1 }
          if regionSpans[rid] == nil { regionSpans[rid] = [] }
          regionSpans[rid]?.append((y: y, xStart: startX, xEnd: x))
        } else {
          x += 1
        }
      }
    }

    for (rid, spans) in regionSpans {
      let path = UIBezierPath()
      for span in spans {
        path.append(UIBezierPath(rect: CGRect(x: span.xStart, y: span.y, width: span.xEnd - span.xStart, height: 1)))
      }
      regionBezierPaths[rid] = path
    }
  }

  // MARK: - Mask Generation

  /// Generates an alpha mask for multiple regions using the pre-eroded region map.
  /// Fast — just a linear scan with set lookup, no erosion computation.
  func generateMaskImage(forRegions regionIds: Set<Int32>) -> CGImage? {
    guard width > 0, height > 0 else { return nil }

    var maskData = Data(count: width * height * 4)
    maskData.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for i in 0..<(width * height) {
        if regionIds.contains(erodedRegionMap[i]) {
          let offset = i * 4
          base[offset] = 255     // R
          base[offset + 1] = 255 // G
          base[offset + 2] = 255 // B
          base[offset + 3] = 255 // A — visible
        }
      }
    }

    let provider = CGDataProvider(data: maskData as CFData)!
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  /// Generates a debug overlay image: semi-transparent green on the given region, transparent elsewhere.
  func generateDebugOverlay(forRegion regionId: Int32) -> UIImage? {
    guard width > 0, height > 0 else { return nil }

    var rgbaData = Data(count: width * height * 4)
    rgbaData.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for i in 0..<(width * height) {
        let offset = i * 4
        if regionMap[i] == regionId {
          base[offset] = 0x00      // R
          base[offset + 1] = 0xCC  // G
          base[offset + 2] = 0x00  // B
          base[offset + 3] = 0x4D  // A (~0.3 opacity)
        }
      }
    }

    let provider = CGDataProvider(data: rgbaData as CFData)!
    guard let cgImage = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else { return nil }

    return UIImage(cgImage: cgImage)
  }

  /// Generates a mask using pre-computed pixel indices. Only touches pixels in the requested regions.
  /// For a typical region (1-5% of canvas), this is 20-100x faster than scanning all pixels.
  func generateCanvasMask(forRegions regionIds: Set<Int32>) -> CGImage? {
    guard canvasPixelW > 0, canvasPixelH > 0 else { return nil }

    let total = canvasPixelW * canvasPixelH
    var maskData = Data(count: total * 4)
    maskData.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for rid in regionIds {
        guard let indices = regionPixelIndices[rid] else { continue }
        for idx in indices {
          let offset = idx * 4
          base[offset] = 255
          base[offset + 1] = 255
          base[offset + 2] = 255
          base[offset + 3] = 255
        }
      }
    }

    let provider = CGDataProvider(data: maskData as CFData)!
    return CGImage(
      width: canvasPixelW,
      height: canvasPixelH,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: canvasPixelW * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  // MARK: - Outline Image (white → transparent)

  /// Creates a version of the source image where white areas become transparent,
  /// keeping only the dark outlines visible. Used for the overlay on top of the canvas.
  func generateOutlineImage(from image: UIImage, threshold: Int = 128) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let w = cgImage.width
    let h = cgImage.height
    let thresholdByte = UInt8(clamping: threshold)

    // First, get grayscale brightness values (handles any source format reliably)
    let graySpace = CGColorSpaceCreateDeviceGray()
    var grayPixels = [UInt8](repeating: 0, count: w * h)
    guard let grayCtx = CGContext(
      data: &grayPixels,
      width: w,
      height: h,
      bitsPerComponent: 8,
      bytesPerRow: w,
      space: graySpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    grayCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Build RGBA output: dark pixels → black opaque, bright pixels → transparent
    var rgbaData = Data(count: w * h * 4)
    rgbaData.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for i in 0..<(w * h) {
        if grayPixels[i] <= thresholdByte {
          let offset = i * 4
          base[offset] = 0       // R
          base[offset + 1] = 0   // G
          base[offset + 2] = 0   // B
          base[offset + 3] = 255 // A
        }
        // else: all zeros = fully transparent (Data is zero-initialized)
      }
    }

    let provider = CGDataProvider(data: rgbaData as CFData)!
    guard let outlineCGImage = CGImage(
      width: w,
      height: h,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else { return nil }

    return UIImage(cgImage: outlineCGImage)
  }

  // MARK: - Union-Find

  private func find(_ parent: inout [Int32], _ x: Int32) -> Int32 {
    var x = x
    while parent[Int(x)] != x {
      parent[Int(x)] = parent[Int(parent[Int(x)])]  // path compression
      x = parent[Int(x)]
    }
    return x
  }

  private func union(_ parent: inout [Int32], _ a: Int32, _ b: Int32) {
    let rootA = find(&parent, a)
    let rootB = find(&parent, b)
    if rootA != rootB {
      // Smaller root becomes parent (simple heuristic)
      if rootA < rootB {
        parent[Int(rootB)] = rootA
      } else {
        parent[Int(rootA)] = rootB
      }
    }
  }
}
