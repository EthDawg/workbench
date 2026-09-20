import AppKit

typealias ScreenshotLauncher = (@escaping (Error?) -> Void) -> Void

struct ScreenshotHandoffState {
    private(set) var isActive = false
    private var began: TimeInterval?
    private var pausesAutoFade = false

    mutating func begin(at time: TimeInterval, autoFade: Bool) -> Bool {
        guard !isActive, time.isFinite else { return false }
        isActive = true; began = time; pausesAutoFade = autoFade
        return true
    }

    mutating func finish(at time: TimeInterval) -> TimeInterval? {
        guard isActive else { return nil }
        isActive = false
        defer { began = nil; pausesAutoFade = false }
        guard pausesAutoFade, let began, time.isFinite else { return nil }
        return max(0, time - began)
    }
}

enum ScreenshotHandoffError: LocalizedError {
    case applicationUnavailable

    var errorDescription: String? {
        "Apple Screenshot could not be opened. Press Shift-Command-5 to open it manually."
    }
}

enum SystemScreenshot {
    static let applicationURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")

    static func launch(completion: @escaping (Error?) -> Void) {
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            completion(ScreenshotHandoffError.applicationUnavailable)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                if let error { completion(error); return }
                guard let application else { completion(ScreenshotHandoffError.applicationUnavailable); return }
                ScreenshotTerminationWaiter(application: application, completion: completion).start()
            }
        }
    }
}

private final class ScreenshotTerminationWaiter {
    private let application: NSRunningApplication
    private let completion: (Error?) -> Void
    private var observer: NSObjectProtocol?
    private var finished = false

    init(application: NSRunningApplication, completion: @escaping (Error?) -> Void) {
        self.application = application
        self.completion = completion
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observer = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [self] notification in
            guard let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  terminated.processIdentifier == application.processIdentifier else { return }
            finish()
        }
        if application.isTerminated { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        completion(nil)
    }
}
