import AppKit
import AVFoundation
import CoreImage
import SwiftUI

final class ProfileCameraTests {
    private final class Capture: ProfileCameraCapturing {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var starts: [(String?, @MainActor (ProfileCameraEvent) -> Void)] = []
        var photos: [@MainActor (Result<NSImage, ProfileCameraIssue>) -> Void] = []
        var stops = 0
        func start(sourceID: String?, receive: @escaping @MainActor (ProfileCameraEvent) -> Void) { starts.append((sourceID, receive)) }
        func takePhoto(completion: @escaping @MainActor (Result<NSImage, ProfileCameraIssue>) -> Void) { photos.append(completion) }
        func stop() { stops += 1 }
    }
    @MainActor private final class Fixture {
        let capture = Capture()
        var permissions: [@MainActor (AVAuthorizationStatus) -> Void] = []
        var deadlines: [(TimeInterval, @MainActor () -> Void)] = []
        var cancelled = 0
        lazy var camera = ProfileCamera(capture: capture, authorize: { [unowned self] in permissions.append($0) }, schedule: { [unowned self] seconds, action in
            deadlines.append((seconds, action))
            return { [weak self] in self?.cancelled += 1 }
        })
        func start() { camera.start(); permissions.last?(.authorized) }
        func live() {
            start()
            capture.starts.last?.1(.sources([ProfileCameraSource(id: "camera-a", name: "Test camera")], selected: "camera-a"))
            capture.starts.last?.1(.frame)
        }
    }
    func testPermissionIsExplicitAndLateApprovalCannotReopen() {
        MainActor.assumeIsolated {
            let f = Fixture()
            XCTAssertEqual(f.camera.state, .idle)
            XCTAssertEqual(f.permissions.count, 0)
            XCTAssertEqual(f.capture.starts.count, 0)
            f.camera.start()
            XCTAssertEqual(f.camera.state, .permission)
            XCTAssertTrue(f.camera.isPresented)
            XCTAssertFalse(f.camera.canTakePhoto)
            f.camera.cancel()
            f.permissions[0](.authorized)
            XCTAssertEqual(f.camera.state, .idle)
            XCTAssertEqual(f.capture.starts.count, 0, "A dismissed permission request never starts hardware")
            f.camera.start()
            f.permissions[0](.denied)
            XCTAssertEqual(f.camera.state, .permission, "An old refusal cannot end a new visit")
            f.permissions[1](.authorized)
            XCTAssertEqual(f.capture.starts.count, 1)
            XCTAssertEqual(f.camera.state, .starting)
            f.camera.cancel()
        }
    }
    func testDeniedAndRestrictedAccessKeepAnExitWithoutOpeningHardware() {
        MainActor.assumeIsolated {
            for (status, issue) in [(AVAuthorizationStatus.denied, ProfileCameraIssue.denied), (.restricted, .restricted)] {
                let f = Fixture(); f.camera.start(); f.permissions[0](status)
                XCTAssertEqual(f.camera.state, .failed(issue))
                XCTAssertEqual(f.capture.starts.count, 0)
                XCTAssertFalse(f.camera.canTakePhoto)
                XCTAssertTrue(f.camera.isPresented)
                f.camera.cancel()
                XCTAssertEqual(f.camera.state, .idle)
            }
        }
    }
    func testStartupTimeoutRetryAndLateEvents() {
        MainActor.assumeIsolated {
            let f = Fixture(); f.start()
            XCTAssertEqual(f.deadlines.last?.0, 10)
            f.deadlines[0].1()
            XCTAssertEqual(f.camera.state, .failed(.timedOut))
            XCTAssertGreaterThan(f.capture.stops, 1)
            f.capture.starts[0].1(.frame)
            XCTAssertEqual(f.camera.state, .failed(.timedOut))
            f.camera.retry(); f.permissions.last?(.authorized)
            f.capture.starts[0].1(.failed(.interrupted))
            XCTAssertEqual(f.camera.state, .starting)
            f.capture.starts[1].1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            f.camera.cancel()
        }
    }
    func testOnlyFreshFramesEnableTheShutterAndOldDeadlinesCannotFailNewFrames() {
        MainActor.assumeIsolated {
            let f = Fixture(); f.start()
            var saved = 0
            f.camera.takePhoto { _ in saved += 1 }
            XCTAssertEqual(f.capture.photos.count, 0)
            f.capture.starts[0].1(.frame)
            XCTAssertTrue(f.camera.canTakePhoto)
            XCTAssertEqual(f.deadlines.last?.0, 5)
            f.deadlines[0].1()
            XCTAssertEqual(f.camera.state, .live, "A queued startup deadline cannot end a live preview")
            let earlierFrame = f.deadlines.count - 1
            f.capture.starts[0].1(.frame)
            f.deadlines[earlierFrame].1()
            XCTAssertEqual(f.camera.state, .live, "An earlier frame's deadline cannot end a refreshed preview")
            f.deadlines.last?.1()
            XCTAssertEqual(f.camera.state, .failed(.timedOut))
            XCTAssertFalse(f.camera.canTakePhoto)
            XCTAssertEqual(saved, 0)
        }
    }
    func testPhotoHandsOffOnceAfterStoppingAndCancelDropsLatePhoto() {
        MainActor.assumeIsolated {
            let f = Fixture(); f.live()
            let image = NSImage(size: NSSize(width: 32, height: 32))
            var images: [NSImage] = []
            f.camera.takePhoto { images.append($0) }
            XCTAssertEqual(f.camera.state, .takingPhoto)
            f.camera.takePhoto { images.append($0) }
            XCTAssertEqual(f.capture.photos.count, 1)
            let stopsBefore = f.capture.stops
            f.capture.photos[0](.success(image))
            XCTAssertEqual(f.camera.state, .idle)
            XCTAssertGreaterThan(f.capture.stops, stopsBefore)
            XCTAssertEqual(images.count, 1)
            XCTAssertTrue(images.first === image)
            f.capture.photos[0](.success(image))
            XCTAssertEqual(images.count, 1)
            f.live(); f.camera.takePhoto { images.append($0) }; f.camera.cancel()
            f.capture.photos[1](.success(image))
            XCTAssertEqual(images.count, 1, "Cancel never hands an old photo to the editor")
            XCTAssertEqual(f.camera.state, .idle)
        }
    }
    func testSwitchCameraRejectsOldPhotoAndDisconnectionRequiresExplicitRetry() {
        MainActor.assumeIsolated {
            let f = Fixture(); f.live()
            var saved = 0
            f.camera.takePhoto { _ in saved += 1 }
            f.camera.start(sourceID: "camera-b"); f.permissions.last?(.authorized)
            XCTAssertEqual(f.capture.starts.last?.0, "camera-b")
            f.capture.photos[0](.success(NSImage(size: NSSize(width: 4, height: 4))))
            XCTAssertEqual(saved, 0)
            f.capture.starts[0].1(.frame)
            XCTAssertEqual(f.camera.state, .starting)
            f.capture.starts.last?.1(.frame)
            f.capture.starts.last?.1(.failed(.interrupted))
            XCTAssertEqual(f.camera.state, .failed(.interrupted))
            XCTAssertEqual(f.capture.starts.count, 2, "An interruption never silently switches the camera")
            f.camera.retry(); f.permissions.last?(.authorized)
            XCTAssertEqual(f.capture.starts.last?.0, "camera-b")
            f.camera.cancel()
        }
    }
    func testPhotoFailureAndTimeoutLeaveTheProfileUnchanged() {
        MainActor.assumeIsolated {
            for timedOut in [false, true] {
                let f = Fixture(); f.live()
                var saved = 0
                f.camera.takePhoto { _ in saved += 1 }
                if timedOut { f.deadlines.last?.1() } else { f.capture.photos[0](.failure(.unreadable)) }
                XCTAssertEqual(f.camera.state, .failed(timedOut ? .timedOut : .unreadable))
                f.capture.photos[0](.success(NSImage(size: NSSize(width: 4, height: 4))))
                XCTAssertEqual(saved, 0)
                f.camera.cancel()
                XCTAssertFalse(f.camera.isPresented)
            }
        }
    }
    func testProfileKeepsCameraInTheSameHostAndCancelReturnsWithoutSaving() {
        MainActor.assumeIsolated {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileCamera-" + UUID().uuidString)
            let library = PersonaLibrary(root: root)
            let defaults = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appendingPathComponent("ProfileCameraTests-" + UUID().uuidString).path)!
            defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
            let f = Fixture()
            var changed = 0
            let hosting = NSHostingView(rootView: LocalPersonaProfileView(library: library, defaults: defaults, changed: { changed += 1 }, camera: f.camera))
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 470, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            defer { window.close(); f.camera.cancel() }
            func settle() {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            settle(); f.start(); settle()
            XCTAssertEqual(f.camera.state, .starting, "Changing profile content must not run the sheet's dismissal cleanup")
            XCTAssertTrue(window.attachedSheet == nil, "The camera needs no second native sheet")
            f.capture.starts.last?.1(.frame); settle()
            XCTAssertEqual(f.camera.state, .live)
            XCTAssertTrue(f.camera.canTakePhoto)
            f.camera.cancel(); settle()
            XCTAssertEqual(f.camera.state, .idle)
            XCTAssertEqual(changed, 0)
            XCTAssertEqual(library.items.count, 0)
            XCTAssertTrue(defaults.string(forKey: LocalPersonaProfile.key) == nil)
        }
    }
    func testFrameConversionKeepsItsSizeAndOrientation() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer), kCVReturnSuccess)
        guard let buffer else { throw ProfileCameraIssue.unreadable }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<24 { for x in 0..<32 {
            let offset = y * stride + x * 4
            bytes[offset] = y < 12 ? 0 : 255
            bytes[offset + 1] = x < 16 ? 0 : 255
            bytes[offset + 2] = y < 12 ? 255 : 0
            bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let image = try ProfileCameraSession.photo(from: buffer, context: CIContext()).get()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        XCTAssertEqual(bitmap.pixelsWide, 32)
        XCTAssertEqual(bitmap.pixelsHigh, 24)
        let topLeft = bitmap.colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!
        let topRight = bitmap.colorAt(x: 29, y: 2)!.usingColorSpace(.deviceRGB)!
        let bottomLeft = bitmap.colorAt(x: 2, y: 21)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(topLeft.redComponent, 0.9)
        XCTAssertTrue(topLeft.blueComponent < 0.1)
        XCTAssertGreaterThan(topRight.greenComponent, 0.9)
        XCTAssertGreaterThan(bottomLeft.blueComponent, 0.9)
    }
    func testCameraLayouts() throws {
        let directory = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try MainActor.assumeIsolated {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, state) in [("permission", 0), ("starting", 1), ("live", 2), ("denied", 3), ("unavailable", 4), ("timeout", 5)] {
                    let f = Fixture()
                    f.camera.start()
                    if state > 0 { f.permissions.last?(state == 3 ? .denied : .authorized) }
                    if state == 2 {
                        f.capture.starts.last?.1(.sources([ProfileCameraSource(id: "a", name: "Built-in camera"), ProfileCameraSource(id: "b", name: "External camera")], selected: "a"))
                        f.capture.starts.last?.1(.frame)
                    }
                    if state == 4 { f.capture.starts.last?.1(.failed(.unavailable)) }
                    if state == 5 { f.deadlines.last?.1() }
                    let content = ProfileCameraView(camera: f.camera, captured: { _ in }, choosePhoto: {})
                        .padding(24).frame(width: 470)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                    let hosting = NSHostingView(rootView: content)
                    hosting.appearance = NSAppearance(named: appearance)
                    let size = hosting.fittingSize
                    XCTAssertEqual(size.width, 470)
                    XCTAssertTrue(size.height < 580, "Camera controls fit in the profile sheet")
                    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = hosting.appearance; window.contentView = hosting
                    defer { window.close(); f.camera.cancel() }
                    hosting.frame = CGRect(origin: .zero, size: size)
                    for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PersonaError.unreadableImage }
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
                    let suffix = appearance == .aqua ? "light" : "dark"
                    if let directory { try data.write(to: directory.appendingPathComponent("camera-\(name)-\(suffix).png")) }
                }
            }
        }
    }
}
