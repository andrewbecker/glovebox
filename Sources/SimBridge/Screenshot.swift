import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct Screenshot: Sendable {
    public enum Format: String, Sendable {
        case png, jpeg

        var type: UTType { self == .png ? .png : .jpeg }
        public var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
    }

    public let data: Data
    public let format: Format
    /// Size of the encoded image in pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Size of the screen in points.
    public let pointSize: CGSize
}

/// Which capture path served. The fallback takes about 0.5 s a capture
/// against tens of milliseconds (2026-10-23), and is otherwise invisible.
public enum CaptureStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fast = 0
    nonisolated(unsafe) private static var fallback = 0
    nonisolated(unsafe) private static var reasons: [String] = []

    /// Captures served from the framebuffer and by `simctl io screenshot`,
    /// with each distinct reason the framebuffer failed.
    public static var snapshot: (fast: Int, fallback: Int, reasons: [String]) {
        lock.withLock { (fast, fallback, reasons) }
    }

    static func recordFast() { lock.withLock { fast += 1 } }

    static func recordFallback(reason: String) {
        let first = lock.withLock {
            fallback += 1
            guard !reasons.contains(reason) else { return false }
            reasons.append(reason)
            return true
        }
        if first { Log.notice("screenshots fell back to simctl io screenshot: \(reason)") }
    }
}

extension DeviceSession {
    /// Captures the active display: straight from its framebuffer IOSurface
    /// (about 10 ms), or with `simctl io screenshot` if that fails.
    ///
    /// - Parameter scale: output pixels per point. 1 (the default) makes image
    ///   pixels equal points, so coordinates read off the image can be tapped.
    public func screenshot(scale: Double = 1, format: Screenshot.Format = .jpeg, quality: Double = 0.8) async throws -> Screenshot {
        let display = try display()
        do {
            // GLOVEBOX_CAPTURE=simctl forces the fallback, to test it.
            if Self.forceSimctlCapture { throw SimBridgeError("GLOVEBOX_CAPTURE=simctl is set") }
            let shot = try framebufferScreenshot(display, scale: scale, format: format, quality: quality)
            CaptureStats.recordFast()
            return shot
        } catch {
            CaptureStats.recordFallback(reason: SimBridgeError.message(for: error))
            return try await simctlScreenshot(display, scale: scale, format: format, quality: quality)
        }
    }

    static let forceSimctlCapture = ProcessInfo.processInfo.environment["GLOVEBOX_CAPTURE"] == "simctl"

    /// Records `shot` as the latest image the agent was sent, and returns
    /// whether it is byte for byte the image sent before it. Encoding is
    /// deterministic, so an unchanged screen at the same scale gives the
    /// same bytes, and an interaction need not send it again.
    public func recordSent(_ shot: Screenshot) -> Bool {
        var hasher = Hasher()
        shot.data.withUnsafeBytes { hasher.combine(bytes: $0) }
        let hash = hasher.finalize()
        defer { lastAttachedScreenshot = hash }
        return lastAttachedScreenshot == hash
    }

    private func framebufferScreenshot(_ display: Display, scale: Double, format: Screenshot.Format, quality: Double) throws -> Screenshot {
        guard let surface = display.screen.framebuffer else {
            throw SimBridgeError("The display has no framebuffer yet. Wait for the simulator to finish booting.")
        }
        guard surface.pixelFormat == 0x4247_5241 /* 'BGRA' */ else {
            throw SimBridgeError("Unsupported framebuffer pixel format \(String(surface.pixelFormat, radix: 16)).")
        }
        return try Self.screenshot(of: try Self.image(from: surface), display: display, scale: scale, format: format, quality: quality)
    }

    /// The slow path: simctl writes a PNG of the main display, which is
    /// decoded and scaled the same way.
    private func simctlScreenshot(_ display: Display, scale: Double, format: Screenshot.Format, quality: Double) async throws -> Screenshot {
        // A path, not "-": Xcode 26.6's simctl wrote a file named "-".
        let path = NSTemporaryDirectory() + "glovebox-capture-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await Simctl.run(["io", udid, "screenshot", "--type=png", path], timeout: .seconds(20))
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SimBridgeError("simctl io screenshot wrote no readable image.") }
        return try Self.screenshot(of: image, display: display, scale: scale, format: format, quality: quality)
    }

    private static func screenshot(of image: CGImage, display: Display, scale: Double, format: Screenshot.Format,
                                   quality: Double) throws -> Screenshot {
        let points = display.size
        // Beyond the device scale there are no more pixels to show.
        let scale = scale.isFinite ? min(max(scale, 0.05), display.scale) : 1
        let width = max(1, Int((points.width * scale).rounded()))
        let height = max(1, Int((points.height * scale).rounded()))
        let output = (display.rotation == 0 && width == image.width && height == image.height)
            ? image : try render(image, rotation: display.rotation, width: width, height: height)
        return Screenshot(data: try encode(output, format: format, quality: quality), format: format,
                          pixelWidth: width, pixelHeight: height, pointSize: points)
    }

    private static func image(from surface: IOSurface) throws -> CGImage {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: surface.baseAddress, width: surface.width, height: surface.height,
                                      bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: space,
                                      bitmapInfo: bitmapInfo),
              let image = context.makeImage()  // copies the pixels
        else { throw SimBridgeError("Could not read the framebuffer.") }
        return image
    }

    /// Scales the framebuffer image to `width` x `height` and turns it
    /// upright, undoing the interface's `rotation` in the framebuffer.
    private static func render(_ image: CGImage, rotation: Int, width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw SimBridgeError("Could not allocate the resized screenshot.") }
        context.interpolationQuality = .high
        // Core Graphics turns positive angles counterclockwise, and undoing a
        // rotation of 90 means turning the image clockwise.
        let sideways = rotation == 90 || rotation == 270
        let drawn = sideways ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(rotation) * .pi / 180)
        context.draw(image, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
        guard let resized = context.makeImage() else { throw SimBridgeError("Could not resize the screenshot.") }
        return resized
    }

    private static func encode(_ image: CGImage, format: Screenshot.Format, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw SimBridgeError("Could not create the \(format.rawValue) encoder.")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, format == .jpeg ? properties : nil)
        guard CGImageDestinationFinalize(destination) else { throw SimBridgeError("Could not encode the screenshot.") }
        return data as Data
    }
}
