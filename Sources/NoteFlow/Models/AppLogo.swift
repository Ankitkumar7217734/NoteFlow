import AppKit

// Loads logo.png from the resource bundle and pre-processes it once:
//   1. Crops to the bounding box of non-transparent pixels, removing the
//      empty padding around the icon so it fills the available frame.
//   2. Applies a clean rounded-corner mask at 22% radius (matches the
//      macOS Big Sur+ "squircle" app-icon curvature).
// The processed image is cached and reused for both the Dock icon and the
// in-app top-left logo.
enum AppLogo {
    static let processed: NSImage = makeProcessed()

    /// Resolve `logo.png` without touching `Bundle.module`, whose generated
    /// accessor calls `fatalError` when the resource bundle is missing. Packaged
    /// `.app` builds must place `NoteFlow_NoteFlow.bundle` under `Contents/`
    /// (SwiftPM layout); older DMG scripts copied it into `Resources/` instead.
    private static func logoResourceURL() -> URL? {
        let bundleName = "NoteFlow_NoteFlow.bundle"
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            // Packaged .app: make-dmg.sh copies the bundle to Contents/.
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent(bundleName),
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName),
        ].compactMap { $0 }

        for base in candidates {
            let logoURL = base.appendingPathComponent("logo.png")
            if FileManager.default.fileExists(atPath: logoURL.path) {
                return logoURL
            }
        }
        return nil
    }

    private static func makeProcessed() -> NSImage {
        guard let url = logoResourceURL(),
              let raw = NSImage(contentsOf: url),
              let cgImage = raw.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSImage()
        }

        let cropped = cropToAlphaBounds(cgImage) ?? cgImage
        let rounded = applyRoundedCorners(cropped, radiusRatio: 0.22) ?? cropped
        return NSImage(cgImage: rounded, size: NSSize(width: rounded.width, height: rounded.height))
    }

    private static func cropToAlphaBounds(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let totalBytes = width * height * 4
        let alphaThreshold: UInt8 = 8

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let buffer = malloc(totalBytes) else { return nil }
        defer { free(buffer) }
        memset(buffer, 0, totalBytes)

        guard let ctx = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                if pixels[rowStart + x * 4 + 3] > alphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        ))
    }

    private static func applyRoundedCorners(_ image: CGImage, radiusRatio: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        let radius = CGFloat(min(width, height)) * radiusRatio
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
