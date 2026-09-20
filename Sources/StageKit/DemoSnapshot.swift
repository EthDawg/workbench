import AppKit
import AVFoundation
import SwiftUI

enum DemoSnapshotError: LocalizedError {
    case unavailable, stale, changed, render, clipboard
    var errorDescription: String? {
        switch self {
        case .unavailable: return "No device frame is available. Connect your device and wait for live video."
        case .stale: return "The device frame is too old. Unlock or reconnect your device, then try again."
        case .changed: return "The device feed changed or ended. Wait for live video, then copy again."
        case .render: return "The scene snapshot could not be rendered. Nothing was copied."
        case .clipboard: return "The clipboard did not accept the snapshot. Try copying again."
        }
    }
}

/// One retained sample, never a recording. The lock joins capture-queue frame
/// replacement with immediate UI invalidation and the final clipboard commit.
final class DemoSnapshotStore {
    struct Frame {
        let sample: CMSampleBuffer
        let epoch: UInt64
        let source: String
        let receivedAt: Date
        let uptime: TimeInterval
    }
    static let maximumAge: TimeInterval = 1
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var source: String?
    private var session: ObjectIdentifier?
    private var latest: Frame?
    private let now: () -> TimeInterval
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    var currentEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return epoch
    }

    @discardableResult func activate(source: String, session: ObjectIdentifier? = nil) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1; self.source = source; self.session = session; latest = nil
        return epoch
    }
    func invalidate(source id: String? = nil, session: ObjectIdentifier? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let id, source != id { return }
        if let session, self.session != session { return }
        epoch &+= 1; source = nil; self.session = nil; latest = nil
    }
    func receive(_ sample: CMSampleBuffer, epoch token: UInt64, source id: String, receivedAt: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == token, source == id, CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        latest = Frame(sample: sample, epoch: token, source: id, receivedAt: receivedAt, uptime: now())
    }
    func frame(expectedEpoch: UInt64? = nil) throws -> Frame {
        lock.lock(); defer { lock.unlock() }
        if let expectedEpoch, expectedEpoch != epoch { throw DemoSnapshotError.changed }
        guard let latest else { throw DemoSnapshotError.unavailable }
        try validate(latest)
        return latest
    }
    private func validate(_ frame: Frame) throws {
        guard frame.epoch == epoch, frame.source == source else { throw DemoSnapshotError.changed }
        let age = now() - frame.uptime
        guard age.isFinite, age >= 0, age <= Self.maximumAge else { throw DemoSnapshotError.stale }
    }
    /// Validate again after conversion/rendering. A queued old callback cannot
    /// touch the clipboard after End, Reconnect or even same-device reselection.
    func commit(_ frame: Frame, connected: () -> Bool, write: () -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try validate(frame)
        guard connected() else { throw DemoSnapshotError.changed }
        guard write() else { throw DemoSnapshotError.clipboard }
    }
}

/// The production control is independently renderable with synthetic state;
/// inspection does not require a camera, clipboard or running device session.
struct DemoSnapshotControls: View {
    let canCopy: Bool
    let copying: Bool
    let notice: String?
    let copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: copy) {
                Label(copying ? "Copying snapshot…" : "Copy scene snapshot", systemImage: "doc.on.doc")
            }.disabled(!canCopy || copying)
                .help("Copy a fresh device frame with this scene’s branding. Uses the still backdrop; excludes controls and separate overlays.")
            Text(notice ?? "Still backdrop · no controls or separate overlays")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .frame(height: 42, alignment: .topLeading)
                .help(notice ?? "Snapshots use the still backdrop, without controls or separate overlays.")
        }.frame(height: 76, alignment: .topLeading)
    }
}

enum DemoSnapshotRendering {
    struct DeviceImage {
        let pixels: CGImage
        let displaySize: CGSize
    }
    // Match the preview's clean aperture and pixel aspect ratio. Conversion is
    // performed only on explicit Copy, off main; NSImage drawing stays on main.
    static func deviceImage(_ sample: CMSampleBuffer) throws -> DeviceImage {
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer) else { throw DemoSnapshotError.render }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              stride >= width * 4, stride <= 8192 * 4 + 4096,
              CVPixelBufferGetDataSize(buffer) >= stride * height else { throw DemoSnapshotError.render }
        let aperture = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        guard aperture.width > 0, aperture.height > 0,
              CGRect(x: 0, y: 0, width: width, height: height).contains(aperture),
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw DemoSnapshotError.render }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw DemoSnapshotError.render }
        // Capture is explicitly configured as BGRA. Copy only on request so the
        // image is immutable after the sample returns to AVFoundation's pool.
        let data = Data(bytes: address, count: stride * height)
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: data as CFData),
              let whole = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let pixels = whole.cropping(to: aperture) else { throw DemoSnapshotError.render }
        return DeviceImage(pixels: pixels, displaySize: size)
    }
    static func scene(_ scene: DemoScene, matching size: CGSize?) -> DemoScene {
        guard let size, size.width > 0, size.height > 0 else { return scene }
        var result = scene
        var viewport = scene.viewport ?? .legacy
        viewport.aspect = size.width / size.height
        result.viewport = (try? viewport.validated()) ?? viewport
        return result
    }
    /// Preserve the presentation's current canvas ratio, bounded to 4K on its
    /// longest edge. A resize never silently turns a window into a 16:9 export.
    static func canvasSize(_ size: CGSize) throws -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { throw DemoSnapshotError.render }
        let scale = min(2, 3840 / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
    static func writePNG(_ data: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
