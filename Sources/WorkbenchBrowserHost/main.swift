import Foundation
import Darwin
import PresenterKit

// A transport adapter only. Workbench owns the library and routing decisions.
// Chrome owns launching/stopping this process. Never print URLs or payloads.
signal(SIGPIPE, SIG_IGN)
let origin = "chrome-extension://\(PresenterWire.extensionID)/"
guard CommandLine.arguments.dropFirst().first == origin else { exit(1) }
do {
    let preview = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true
    let fd = try PresenterSocket.connect(to: PresenterSocket.path(preview: preview))
    DispatchQueue.global().async {
        do {
            while true { try PresenterSocket.write(PresenterWire.encode(PresenterSocket.readMessage(fd)), to: STDOUT_FILENO) }
        } catch { exit(0) }
    }
    while true { try PresenterSocket.write(PresenterWire.encode(PresenterSocket.readMessage(STDIN_FILENO)), to: fd) }
} catch { exit(1) }
