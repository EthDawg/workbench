import AppKit
import SceneSyncKit

final class SceneMediaTests {
    private static let webP = Data(base64Encoded: "UklGRjoAAABXRUJQVlA4TC0AAAAvB0ABEB8gEEjaH3oNAUGR/6PNv4Cg6LrlAuZGg4K2bRiv/IHsAY7of8Cn0wUA")!

    private func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let result else { task.cancel(); throw NSError(domain: "SceneMediaTests", code: 1) }
        return try result.get()
    }

    func testSearchAndImageAddressesStayBounded() throws {
        let url = LogoWebImport.searchURL("  Acme & Co logo  ")!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "Acme & Co logo")
        XCTAssertEqual(query.first(where: { $0.name == "tbm" })?.value, "isch")
        XCTAssertEqual(LogoWebImport.searchURL(" \n"), nil)
        for value in ["file:///tmp/logo.png", "javascript:alert(1)", "blob:https://example.com/x", "https://user:secret@example.com/logo.png", "https:///", String(repeating: "a", count: 20_000)] {
            XCTAssertEqual(LogoWebImport.remoteURL(value), nil)
        }
        XCTAssertNotNil(LogoWebImport.remoteURL("https://example.com/logo.webp"))
        let dataURL = "data:image/webp;base64," + Self.webP.base64EncodedString()
        let image = try awaitResult { try await LogoWebImport.load(dataURL, name: "Synthetic logo") }
        XCTAssertEqual(image.png, try LogoImport.normalizedPNG(Self.webP))
        XCTAssertEqual(image.name, "Synthetic logo")
        XCTAssertThrowsError(try LogoWebImport.inlineImage("data:text/html;base64,SGVsbG8="))
        XCTAssertThrowsError(try LogoWebImport.inlineImage("data:image/png;base64,not-base64"))
        XCTAssertThrowsError(try awaitResult { try await LogoWebImport.load("data:image/png;base64,SGVsbG8=") })
    }

    func testDownloadsRejectOversizeHTMLAndInvalidBytes() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SceneLogoURLProtocol.self]
        let image = try awaitResult {
            try await LogoWebImport.load("https://logo.example/valid", name: "Synthetic", configuration: config)
        }
        XCTAssertEqual(image.png, try LogoImport.normalizedPNG(Self.webP))
        for path in ["html", "too-large-header", "too-large-body", "corrupt", "failure"] {
            XCTAssertThrowsError(try awaitResult {
                try await LogoWebImport.load("https://logo.example/" + path, configuration: config)
            })
        }
        let download = LogoImageDownload(configuration: config)
        let response = HTTPURLResponse(url: URL(string: "https://logo.example/start")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: config), task = session.dataTask(with: response.url!)
        defer { session.invalidateAndCancel() }
        var allowed: URLRequest?
        for index in 0..<6 {
            download.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://logo.example/next")!)) { allowed = $0 }
            XCTAssertEqual(allowed != nil, index < 5)
        }
        let unsafe = LogoImageDownload(configuration: config)
        unsafe.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "file:///tmp/logo.png")!)) { allowed = $0 }
        XCTAssertEqual(allowed, nil)
    }

    func testDownloadCancellationStopsTheOwnedRequest() throws {
        SceneLogoURLProtocol.resetPending()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SceneLogoURLProtocol.self]
        var result: Result<LogoImport.Image, Error>?
        let task = Task { @MainActor in
            do { result = .success(try await LogoWebImport.load("https://logo.example/pending", configuration: config)) }
            catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !SceneLogoURLProtocol.pendingStarted && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(SceneLogoURLProtocol.pendingStarted)
        task.cancel()
        while (result == nil || !SceneLogoURLProtocol.pendingStopped) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        else { XCTAssertTrue(false, "Cancellation must not return image bytes") }
        XCTAssertTrue(SceneLogoURLProtocol.pendingStopped)
    }

    func testWebLogoPreviewAndExplicitSavePreserveOtherScenes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneMedia-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.png")
        try LogoImport.normalizedPNG(Self.webP).write(to: source)
        let model = DemoScenes(root: root.appendingPathComponent("store"), systemIntegrationEnabled: false)
        try model.addImage(source, name: "Original scene")
        let original = model.selected!
        try model.addImage(source, name: "Another scene")
        let other = model.selected!, before = model.scenes
        let image = try awaitResult { try await LogoWebImport.load("data:image/webp;base64," + Self.webP.base64EncodedString(), name: "Chosen logo") }
        XCTAssertEqual(model.scenes, before, "Previewing must not save a logo or change selection")
        XCTAssertEqual(model.selectedID, other.id)
        XCTAssertTrue(model.savedLogos.isEmpty)
        try model.addLogo(image, to: original.id)
        XCTAssertNotNil(model.scenes.first(where: { $0.id == original.id })?.logo)
        XCTAssertEqual(model.scenes.first(where: { $0.id == other.id }), other)
        XCTAssertEqual(model.selectedID, other.id)
        XCTAssertEqual(model.savedLogos.first?.name, "Chosen logo")
        let after = model.scenes
        XCTAssertThrowsError(try model.addLogo(image, to: UUID()))
        XCTAssertEqual(model.scenes, after)
        XCTAssertEqual(try Data(contentsOf: source), try LogoImport.normalizedPNG(Self.webP))
        let reopened = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertNotNil(reopened.logoImage(for: reopened.scenes.first(where: { $0.id == original.id })!))
    }

    func testMotionPolicyReportsSuppressionAndCanvasPausesForEditing() throws {
        func state(requested: Bool = true, suspension: SceneMotionState? = nil, available: Bool = true,
                   visible: Bool = true, active: Bool = true, sleeping: Bool = false, reduce: Bool = false,
                   autoplay: Bool = true, power: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) -> SceneMotionState {
            SceneMotionState.resolve(requested: requested, suspension: suspension, available: available, visible: visible,
                                     active: active, sleeping: sleeping, reduceMotion: reduce, autoplay: autoplay, lowPower: power, thermal: thermal)
        }
        XCTAssertEqual(state(), .playing)
        XCTAssertEqual(state(requested: false), .off)
        XCTAssertEqual(state(suspension: .paused), .paused)
        XCTAssertEqual(state(suspension: .editing), .editing)
        XCTAssertEqual(state(available: false), .unavailable)
        XCTAssertEqual(state(visible: false), .hidden)
        XCTAssertEqual(state(active: false), .inactive)
        XCTAssertEqual(state(sleeping: true), .sleeping)
        XCTAssertEqual(state(reduce: true), .reduceMotion)
        XCTAssertEqual(state(autoplay: false), .autoplayDisabled)
        XCTAssertEqual(state(power: true), .lowPower)
        XCTAssertEqual(state(thermal: .serious), .thermal)
        XCTAssertEqual(state(thermal: .critical), .thermal)
        let canvas = SceneCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var scene = DemoScene(background: "synthetic.png", gentleMotion: true, showsPhone: false)
        canvas.receive(scene); canvas.image = NSImage(data: try LogoImport.normalizedPNG(Self.webP))!
        XCTAssertTrue(canvas.subviews.first is MovingSceneView, "The editor must use the actual motion renderer")
        canvas.previewPaused = true; XCTAssertEqual(canvas.motionState, .paused)
        canvas.previewPaused = false; canvas.layoutEditing = true; XCTAssertEqual(canvas.motionState, .editing)
        canvas.layoutEditing = false; canvas.previewCovered = true; XCTAssertEqual(canvas.motionState, .covered)
        canvas.previewCovered = false
        func event(_ kind: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: CGPoint(x: 50, y: 80), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown))
        XCTAssertTrue(canvas.isDragging); XCTAssertEqual(canvas.motionState, .editing)
        canvas.mouseUp(with: event(.leftMouseUp)); XCTAssertFalse(canvas.isDragging)
        XCTAssertTrue(canvas.motionState != .editing)
        canvas.mouseDown(with: event(.leftMouseDown)); scene.id = UUID(); canvas.receive(scene)
        XCTAssertFalse(canvas.isDragging)
        canvas.stopPreview(); XCTAssertEqual(canvas.motionState, .off)
    }
}

private final class SceneLogoURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = false
    private static var stopped = false
    static var pendingStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    static var pendingStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    static func resetPending() { lock.lock(); started = false; stopped = false; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "logo.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        let headers = path == "too-large-header" ? ["Content-Type": "image/png", "Content-Length": String(LogoImport.maximumBytes + 1)]
            : ["Content-Type": path == "html" ? "text/html" : "image/webp"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: path == "failure" ? 500 : 200,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if path == "pending" { Self.lock.lock(); Self.started = true; Self.lock.unlock(); return }
        if path == "too-large-body" {
            let chunk = Data(repeating: 0, count: 1024 * 1024)
            for _ in 0..<41 { client?.urlProtocol(self, didLoad: chunk) }
        } else {
            let bytes = path == "valid" ? Data(base64Encoded: "UklGRjoAAABXRUJQVlA4TC0AAAAvB0ABEB8gEEjaH3oNAUGR/6PNv4Cg6LrlAuZGg4K2bRiv/IHsAY7of8Cn0wUA")! : Data("not an image".utf8)
            client?.urlProtocol(self, didLoad: bytes)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if request.url?.lastPathComponent == "pending" { Self.lock.lock(); Self.stopped = true; Self.lock.unlock() }
    }
}
