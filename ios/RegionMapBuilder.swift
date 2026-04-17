import CoreGraphics
import UIKit

// ──────────────────────────────────────────────────────────────────────────
// RegionMapBuilder
//
// Processes a coloring page image into a "region map" — a 2D grid where each
// pixel is labeled with a zone ID (1, 2, 3, ...) or 0 for outline/black pixels.
//
// Algorithm: Connected Component Labeling (CCL) with union-find.
//   1. Convert image to grayscale
//   2. Threshold: brightness > threshold → "white" (colorable), else "black" (outline)
//   3. Two-pass CCL: scan pixels left-to-right, top-to-bottom. Each connected group
//      of white pixels gets a unique ID. Union-find merges groups that touch.
//   4. Result: regionMap[y * width + x] = zone ID (0 for outlines)
//
// After building the region map, call precomputeCanvasMap() to create a
// canvas-resolution version with per-zone pixel indices for instant mask generation.
// ──────────────────────────────────────────────────────────────────────────

class RegionMapBuilder {
  // Image-resolution region data
  private(set) var width: Int = 0              // Image width in pixels
  private(set) var height: Int = 0             // Image height in pixels
  private(set) var regionMap: [Int32] = []     // Flat array: regionMap[y * width + x] = zone ID
  private(set) var regionCount: Int = 0        // Total number of zones found

  // Canvas-resolution pre-mapped data.
  // The boundary image (e.g., 1030x1207) is displayed scaled to fit the canvas (e.g., 360x360).
  // This pre-mapping converts image-space zone IDs to canvas-pixel-space for fast mask generation.
  private(set) var canvasPixelW: Int = 0       // Canvas width in physical pixels (points × scale)
  private(set) var canvasPixelH: Int = 0       // Canvas height in physical pixels
  // For each zone ID, stores the list of canvas pixel indices that belong to that zone.
  // This enables O(zone_size) mask generation instead of O(total_pixels).
  private(set) var regionPixelIndices: [Int32: [Int]] = [:]

  // MARK: - Build Region Map

  /// Processes the boundary image into a region map using connected component labeling.
  /// Call from a background queue — this is CPU-intensive for large images.
  ///
  /// - Parameters:
  ///   - image: The coloring page image (black outlines on white background)
  ///   - threshold: Grayscale threshold (0-255). Pixels brighter than this are "colorable".
  ///               Default 128 works for most coloring pages with clear black outlines.
  /// - Parameters:
  ///   - outlineDilation: Number of pixels to expand outlines before CCL.
  ///     Bridges small gaps in outlines so regions stay separate even if the
  ///     artist's lines don't fully close. Default 3 handles most cases.
  ///     Set to 0 to disable (only for perfectly closed outlines).
  func buildRegionMap(from image: UIImage, threshold: Int = 128, outlineDilation: Int = 3) {
    // CGImage gives us access to the raw pixel data at the image's native resolution
    guard let cgImage = image.cgImage else { return }

    let w = cgImage.width   // Pixel width (not points)
    let h = cgImage.height  // Pixel height
    width = w
    height = h

    // Step 1: Convert to grayscale pixel buffer.
    // CGContext with a grayscale color space renders any image format (JPEG, PNG, etc.)
    // into a simple 1-byte-per-pixel grayscale buffer.
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let context = CGContext(
      data: &pixels,      // Our buffer — CGContext writes directly into it
      width: w,
      height: h,
      bitsPerComponent: 8,  // 8 bits (1 byte) per pixel for grayscale
      bytesPerRow: w,        // One byte per pixel, w pixels per row
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue  // No alpha channel needed
    ) else { return }

    // Draw the image into our grayscale context — this does the color → grayscale conversion
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Step 2: Threshold to binary.
    // Pixels brighter than the threshold are "white" (colorable zones).
    // Pixels at or below the threshold are "black" (outlines/boundaries).
    let thresholdByte = UInt8(clamping: threshold)
    var isWhite = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) {
      isWhite[i] = pixels[i] > thresholdByte
    }

    // Step 2.5: Outline dilation — expand black (outline) pixels to bridge small gaps.
    //
    // Problem: If an outline has a small gap (e.g., the artist's line didn't fully close),
    // CCL will treat both sides of the gap as ONE connected region. The user could then
    // color across the gap into the neighbor region.
    //
    // Solution: Dilate (expand) the outline pixels by `outlineDilation` pixels in all
    // directions. This closes gaps smaller than 2 × outlineDilation pixels.
    //
    // Algorithm: Two-pass Chebyshev distance transform (O(n)):
    //   1. Compute distance from each white pixel to the nearest black pixel
    //   2. White pixels with distance <= outlineDilation become black (part of the outline)
    //
    // This is much faster than checking a neighborhood for each pixel (O(n) vs O(n × r²)).
    if outlineDilation > 0 {
      let INF = w + h
      var dist = [Int](repeating: 0, count: w * h)

      // Initialize: black pixels = 0, white pixels = INF
      for i in 0..<(w * h) {
        dist[i] = isWhite[i] ? INF : 0
      }

      // Forward pass (top-left to bottom-right)
      for y in 0..<h {
        for x in 0..<w {
          let i = y * w + x
          if dist[i] == 0 { continue }
          if y > 0 { dist[i] = min(dist[i], dist[(y-1) * w + x] + 1) }
          if x > 0 { dist[i] = min(dist[i], dist[y * w + (x-1)] + 1) }
          if y > 0 && x > 0 { dist[i] = min(dist[i], dist[(y-1) * w + (x-1)] + 1) }
          if y > 0 && x < w-1 { dist[i] = min(dist[i], dist[(y-1) * w + (x+1)] + 1) }
        }
      }

      // Backward pass (bottom-right to top-left)
      for y in stride(from: h-1, through: 0, by: -1) {
        for x in stride(from: w-1, through: 0, by: -1) {
          let i = y * w + x
          if dist[i] == 0 { continue }
          if y < h-1 { dist[i] = min(dist[i], dist[(y+1) * w + x] + 1) }
          if x < w-1 { dist[i] = min(dist[i], dist[y * w + (x+1)] + 1) }
          if y < h-1 && x < w-1 { dist[i] = min(dist[i], dist[(y+1) * w + (x+1)] + 1) }
          if y < h-1 && x > 0 { dist[i] = min(dist[i], dist[(y+1) * w + (x-1)] + 1) }
        }
      }

      // Pixels too close to an outline become outline themselves
      for i in 0..<(w * h) {
        if dist[i] <= outlineDilation {
          isWhite[i] = false
        }
      }
    }

    // Step 3: Two-pass connected component labeling with union-find.
    //
    // Pass 1: Scan left-to-right, top-to-bottom. For each white pixel:
    //   - Check the pixel above (up) and to the left (left)
    //   - If neither is labeled: assign a new label
    //   - If one is labeled: copy that label
    //   - If both are labeled with different IDs: copy the smaller, union them
    //
    // Pass 2: Flatten all labels to their root (resolves chains from unions)
    //
    // This uses 4-connectivity (up/down/left/right neighbors, not diagonals).
    // 4-connectivity means diagonal pixels are NOT considered connected,
    // which helps separate zones that only touch at corners.

    var labels = [Int32](repeating: 0, count: w * h)
    var parent = [Int32]()   // Union-find parent array: parent[i] = parent of label i
    var nextLabel: Int32 = 1

    parent.append(0)  // Label 0 = outline pixels (no parent needed)

    // Pass 1: assign provisional labels
    for y in 0..<h {
      for x in 0..<w {
        let idx = y * w + x
        guard isWhite[idx] else { continue }  // Skip outline pixels

        // Check the pixel above and to the left (already processed)
        let upLabel: Int32 = (y > 0 && isWhite[(y - 1) * w + x]) ? labels[(y - 1) * w + x] : 0
        let leftLabel: Int32 = (x > 0 && isWhite[y * w + (x - 1)]) ? labels[y * w + (x - 1)] : 0

        if upLabel == 0 && leftLabel == 0 {
          // No labeled neighbors — start a new zone
          labels[idx] = nextLabel
          parent.append(nextLabel)  // Initially, each label is its own parent
          nextLabel += 1
        } else if upLabel != 0 && leftLabel == 0 {
          // Only up neighbor is labeled — copy its label
          labels[idx] = upLabel
        } else if upLabel == 0 && leftLabel != 0 {
          // Only left neighbor is labeled — copy its label
          labels[idx] = leftLabel
        } else {
          // Both neighbors are labeled — use the smaller label and merge them.
          // The union operation makes them part of the same zone.
          labels[idx] = min(upLabel, leftLabel)
          union(&parent, min(upLabel, leftLabel), max(upLabel, leftLabel))
        }
      }
    }

    // Pass 2: flatten all labels to their root.
    // After unions, some labels point to intermediate parents.
    // find() with path compression makes every label point directly to its root.
    for i in 1..<parent.count {
      _ = find(&parent, Int32(i))
    }

    // Remap root labels to sequential IDs (1, 2, 3, ...) for cleaner output.
    // Multiple provisional labels may share the same root after union.
    var rootToSequential = [Int32: Int32]()
    var seqId: Int32 = 0
    for i in 1..<parent.count {
      let root = find(&parent, Int32(i))
      if rootToSequential[root] == nil {
        seqId += 1
        rootToSequential[root] = seqId
      }
    }

    // Build the final region map: each pixel gets its sequential zone ID
    regionMap = [Int32](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      if labels[i] > 0 {
        let root = find(&parent, labels[i])
        regionMap[i] = rootToSequential[root] ?? 0
      }
    }

    regionCount = Int(seqId)
  }

  // MARK: - Region Lookup

  /// Returns the zone ID at the given image pixel coordinates.
  /// Returns 0 for outline pixels or out-of-bounds coordinates.
  func regionAt(x: Int, y: Int) -> Int32 {
    guard x >= 0, x < width, y >= 0, y < height else { return 0 }
    return regionMap[y * width + x]
  }

  // MARK: - Canvas Pre-mapping

  /// Pre-computes a mapping from canvas screen pixels to image zone IDs.
  ///
  /// The boundary image (e.g., 1030×1207) is displayed with .scaleAspectFit in the canvas
  /// (e.g., 360×360 points × 3x scale = 1080×1080 pixels). This method maps each canvas
  /// pixel to its corresponding image pixel and records the zone ID.
  ///
  /// The result is stored as `regionPixelIndices`: a dictionary where each zone ID maps
  /// to a list of canvas pixel indices that belong to it. This enables instant mask generation —
  /// to create a mask for zone 5, just set those specific pixels to white, instead of
  /// scanning all 1M+ pixels.
  ///
  /// Call once on a background thread after buildRegionMap().
  func precomputeCanvasMap(canvasSize: CGSize, scale: CGFloat) {
    // Convert from points to physical pixels (e.g., 360pt × 3x = 1080px)
    let pW = Int(canvasSize.width * scale)
    let pH = Int(canvasSize.height * scale)
    canvasPixelW = pW
    canvasPixelH = pH

    guard width > 0, height > 0, pW > 0, pH > 0 else { return }

    // Calculate the aspect-fit transform: how the image maps into the canvas.
    // Same logic as UIImageView with .scaleAspectFit.
    let imageW = CGFloat(width)
    let imageH = CGFloat(height)
    let imageAspect = imageW / imageH
    let canvasAspect = CGFloat(pW) / CGFloat(pH)

    let renderW: CGFloat, renderH: CGFloat, offsetX: CGFloat, offsetY: CGFloat
    if imageAspect > canvasAspect {
      // Image is wider than canvas → pillarboxed (bars on top/bottom)
      renderW = CGFloat(pW)
      renderH = renderW / imageAspect
      offsetX = 0
      offsetY = (CGFloat(pH) - renderH) / 2
    } else {
      // Image is taller than canvas → letterboxed (bars on left/right)
      renderH = CGFloat(pH)
      renderW = renderH * imageAspect
      offsetX = (CGFloat(pW) - renderW) / 2
      offsetY = 0
    }

    // For each canvas pixel, find the corresponding image pixel and record its zone ID.
    regionPixelIndices = [:]
    for py in 0..<pH {
      for px in 0..<pW {
        // Map canvas pixel → image pixel using the inverse of the aspect-fit transform
        let imgX = Int((CGFloat(px) - offsetX) / renderW * imageW)
        let imgY = Int((CGFloat(py) - offsetY) / renderH * imageH)
        guard imgX >= 0, imgX < width, imgY >= 0, imgY < height else { continue }

        let rid = regionMap[imgY * width + imgX]
        if rid > 0 {
          // This canvas pixel belongs to a zone — record its index
          let idx = py * pW + px
          if regionPixelIndices[rid] == nil { regionPixelIndices[rid] = [] }
          regionPixelIndices[rid]?.append(idx)
        }
      }
    }
  }

  // MARK: - Mask Generation

  /// Generates an RGBA mask image at canvas pixel resolution for the given zones.
  ///
  /// The mask has alpha=255 (opaque white) for pixels belonging to any of the requested zones,
  /// and alpha=0 (fully transparent) everywhere else. This is used as canvasView.layer.mask,
  /// where CALayer.mask uses the alpha channel to determine visibility.
  ///
  /// Uses pre-computed `regionPixelIndices` so it only touches the zone's own pixels,
  /// not all 1M+ pixels. For a typical zone (1-5% of the canvas), this is 20-100x faster.
  ///
  /// The mask data is wrapped in a CGDataProvider (via Data → CFData) to ensure the
  /// pixel buffer outlives the CGImage. Using local Swift arrays would cause the buffer
  /// to be deallocated, leaving the CGImage with dangling data.
  func generateCanvasMask(forRegions regionIds: Set<Int32>) -> CGImage? {
    guard canvasPixelW > 0, canvasPixelH > 0 else { return nil }

    let total = canvasPixelW * canvasPixelH
    // Data is zero-initialized = all pixels start as fully transparent (alpha=0)
    var maskData = Data(count: total * 4)  // 4 bytes per pixel: RGBA
    maskData.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      // For each requested zone, set its pixels to opaque white
      for rid in regionIds {
        guard let indices = regionPixelIndices[rid] else { continue }
        for idx in indices {
          let offset = idx * 4
          base[offset] = 255      // R
          base[offset + 1] = 255  // G
          base[offset + 2] = 255  // B
          base[offset + 3] = 255  // A = opaque (visible through mask)
        }
      }
    }

    // Create CGImage from the pixel data.
    // CGDataProvider retains the Data, ensuring it outlives the CGImage.
    let provider = CGDataProvider(data: maskData as CFData)!
    return CGImage(
      width: canvasPixelW,
      height: canvasPixelH,
      bitsPerComponent: 8,        // 8 bits per channel
      bitsPerPixel: 32,           // 4 channels × 8 bits = 32 bits per pixel
      bytesPerRow: canvasPixelW * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,   // No interpolation — we want sharp pixel boundaries
      intent: .defaultIntent
    )
  }

  /// Generates a debug overlay: semi-transparent green tint on the given zone.
  /// Used when boundaryDebug=true to visually highlight the active zone.
  func generateDebugOverlay(forRegion regionId: Int32) -> UIImage? {
    guard width > 0, height > 0 else { return nil }

    var rgbaData = Data(count: width * height * 4)
    rgbaData.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for i in 0..<(width * height) {
        if regionMap[i] == regionId {
          let offset = i * 4
          base[offset] = 0x00      // R = 0
          base[offset + 1] = 0xCC  // G = 204 (bright green)
          base[offset + 2] = 0x00  // B = 0
          base[offset + 3] = 0x4D  // A = 77 (~30% opacity)
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

  // MARK: - Union-Find
  //
  // A classic data structure for tracking connected components.
  // Each element has a "parent" pointer. find() follows the chain to the root.
  // union() merges two trees by making one root point to the other.
  // Path compression in find() keeps trees flat for near-O(1) lookups.

  /// Finds the root of element x, with path compression.
  /// Path compression: makes every node on the path point directly to the root,
  /// so future lookups are O(1).
  private func find(_ parent: inout [Int32], _ x: Int32) -> Int32 {
    var x = x
    while parent[Int(x)] != x {
      // Path compression: point directly to grandparent (halving)
      parent[Int(x)] = parent[Int(parent[Int(x)])]
      x = parent[Int(x)]
    }
    return x
  }

  /// Merges the trees containing a and b.
  /// Uses the smaller root as the new parent (simple heuristic to keep trees balanced).
  private func union(_ parent: inout [Int32], _ a: Int32, _ b: Int32) {
    let rootA = find(&parent, a)
    let rootB = find(&parent, b)
    if rootA != rootB {
      if rootA < rootB {
        parent[Int(rootB)] = rootA
      } else {
        parent[Int(rootA)] = rootB
      }
    }
  }
}
