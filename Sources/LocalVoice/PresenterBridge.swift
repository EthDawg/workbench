import AppKit
import Combine
import Darwin
import PresenterKit

/// Each connection has one reader and one serial writer. No socket IO blocks UI.
final class PresenterPeer: @unchecked Sendable {
    let id = UUID()
    let fd: Int32
    private let writer = DispatchQueue(label: "workbench.browser.writer")
    private let lock = NSLock()
    private var stopped = false
    init(fd: Int32) { self.fd = fd; PresenterSocket.configure(fd) }
    func start(receive: @escaping @Sendable (PresenterMessage) -> Void, ended: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do { while true { receive(try PresenterSocket.readMessage(fd)) } } catch { }
            stop()
            writer.sync { self.lock.lock(); Darwin.close(self.fd); self.lock.unlock() }
            ended()
        }
    }
    func send(_ message: PresenterMessage) {
        writer.async { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            do { try PresenterSocket.write(PresenterWire.encode(message), to: fd) }
            catch { stopped = true; shutdown(fd, SHUT_RDWR) }
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true; shutdown(fd, SHUT_RDWR)
    }
}

final class PresenterListener {
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var path: String?
    func start(path: String, connected: @escaping @Sendable (PresenterPeer) -> Void) throws {
        // An edition lock prevents one Workbench process replacing another's socket.
        lockFD = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { stop(); throw PresenterError.unavailable }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { stop(); throw PresenterError.unsafePath }
            unlink(path)
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { stop(); throw PresenterError.unavailable }
        var address = try PresenterSocket.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 12) == 0 else { stop(); throw PresenterError.unavailable }
        self.path = path
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                guard PresenterSocket.sameUser(client) else { close(client); continue }
                connected(PresenterPeer(fd: client))
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source; source.resume()
    }
    func stop() {
        if let source { source.cancel(); self.source = nil } else if fd >= 0 { close(fd) }
        fd = -1
        if let path { unlink(path); self.path = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    deinit { stop() }
}

@MainActor
final class PresenterModel: ObservableObject {
    @Published private(set) var destinations: [PresenterDestination] = []
    @Published private(set) var enabled = false
    @Published var message: String?
    @Published private(set) var busy = false
    var onSwitch: (() -> Void)?
    var mayActivate: (() -> Bool)?
    let library: DemoLibraryModel
    let machineID: UUID
    private let defaults: UserDefaults
    private let socketPath: String?
    private let listener = PresenterListener()
    private var peers: [UUID: PresenterPeer] = [:]
    private var profiles: [UUID: (id: UUID, name: String)] = [:]
    private var observers = Set<AnyCancellable>()
    private var seen: [UUID: Set<UUID>] = [:]
    private var pending: (id: UUID, peer: UUID, deadline: Date, finish: (PresenterMessage) -> Void)?
    private var timer: Task<Void, Never>?
    private var generation = UUID()

    init(library: DemoLibraryModel, defaults: UserDefaults = .standard, socketPath: String? = nil) {
        self.library = library; self.defaults = defaults; self.socketPath = socketPath
        if let string = defaults.string(forKey: "browser.machineID"), let id = UUID(uuidString: string) { machineID = id }
        else { let id = UUID(); machineID = id; defaults.set(id.uuidString, forKey: "browser.machineID") }
        library.$resources.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &observers)
        if defaults.bool(forKey: "browser.enabled") { start() }
    }
    var connectedCount: Int { Set(profiles.values.map(\.id)).count }
    var extensionFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension", isDirectory: true) }
    func refresh() {
        destinations = library.resources.compactMap { resource in
            guard resource.kind == .link, let binding = resource.browserTarget, binding.machineID == machineID,
                  let url = PresenterURL.canonical(resource.content) else { return nil }
            let profile = profiles.values.first { $0.id == binding.profileID }
            return PresenterDestination(id: resource.id, title: resource.title, profileName: profile?.name ?? binding.profileName,
                profileID: binding.profileID, url: url, connected: profile != nil)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func enable() {
        do {
            try installHost()
            defaults.set(true, forKey: "browser.enabled"); start()
            if enabled { message = "Chrome connection enabled. Add the extension in each demo profile, then connect it." }
        } catch { message = error.localizedDescription }
    }
    func start() {
        guard !enabled else { return }
        do {
            let generation = UUID(); self.generation = generation
            let path = try socketPath ?? PresenterSocket.path(preview: Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true)
            try listener.start(path: path) { [weak self] peer in Task { @MainActor in
                guard let self, self.generation == generation else { peer.stop(); return }; self.accept(peer)
            } }
            enabled = true; refresh()
        } catch { listener.stop(); message = error.localizedDescription }
    }
    func stop() {
        generation = UUID()
        timer?.cancel(); timer = nil
        if let pending { self.pending = nil; var reply = PresenterMessage(id: pending.id, type: "result"); reply.ok = false; reply.error = "unavailable"; pending.finish(reply) }
        for peer in peers.values { peer.stop() }
        peers.removeAll(); profiles.removeAll(); seen.removeAll(); listener.stop(); enabled = false; busy = false; refresh()
    }
    func pause() { defaults.set(false, forKey: "browser.enabled"); stop(); message = "Chrome connection paused. Saved destinations are kept." }
    private func accept(_ peer: PresenterPeer) {
        guard enabled, peers.count < 12 else { peer.stop(); return }
        peers[peer.id] = peer
        peer.start(receive: { [weak self, weak peer] message in
            Task { @MainActor in guard let peer else { return }; self?.receive(message, from: peer) }
        }, ended: { [weak self, weak peer] in
            Task { @MainActor in guard let self, let peer else { return }; self.disconnected(peer.id) }
        })
        // Unauthenticated or stalled clients cannot occupy slots indefinitely.
        Task { [weak self, weak peer] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let peer, self.profiles[peer.id] == nil else { return }; peer.stop()
        }
    }
    private func disconnected(_ peerID: UUID) {
        peers.removeValue(forKey: peerID); profiles.removeValue(forKey: peerID); seen.removeValue(forKey: peerID)
        if let pending, pending.peer == peerID { finish(id: pending.id, ok: false, error: "offline") }
        refresh()
    }
    private func receive(_ request: PresenterMessage, from peer: PresenterPeer) {
        guard peers[peer.id] != nil else { return }
        if request.type == "focused" {
            guard let pending, pending.id == request.id, pending.peer == peer.id else { return }
            guard Date() <= pending.deadline else { finish(id: request.id, ok: false, error: "timeout"); return }
            let validStatus = ["focused", "opened"].contains(request.status ?? "")
            finish(id: request.id, ok: request.ok == true && validStatus, status: request.status, error: request.error ?? (validStatus ? nil : "invalid")); return
        }
        // Replayed writes/actions cannot create duplicate destinations or tabs.
        guard seen[peer.id]?.contains(request.id) != true else { peer.send(request.reply(ok: false, error: "invalid")); return }
        if (seen[peer.id]?.count ?? 0) >= 2000 { peer.stop(); return }
        seen[peer.id, default: []].insert(request.id)
        if request.type == "hello" {
            guard profiles[peer.id] == nil, let id = request.profileID, let name = request.profileName, PresenterURL.validName(name) else {
                peer.send(request.reply(ok: false, error: "invalid")); return
            }
            guard !profiles.values.contains(where: { $0.id == id }) else { peer.send(request.reply(ok: false, error: "duplicateProfile")); return }
            profiles[peer.id] = (id, name); refresh(); respond(request, to: peer); return
        }
        guard let profile = profiles[peer.id] else { peer.send(request.reply(ok: false, error: "unavailable")); return }
        switch request.type {
        case "list": refresh(); respond(request, to: peer)
        case "save":
            guard !busy, library.draft == nil, let title = request.title, PresenterURL.validName(title),
                  let value = request.url, let url = PresenterURL.canonical(value), url == value else {
                peer.send(request.reply(ok: false, error: busy || library.draft != nil ? "busy" : "invalid")); return
            }
            var item = DemoResource(kind: .link, title: title, content: url)
            if let id = request.destinationID {
                guard let old = library.resources.first(where: { $0.id == id }) else { peer.send(request.reply(ok: false, error: "missing")); return }
                guard old.kind == .link, old.browserTarget?.profileID == profile.id, old.browserTarget?.machineID == machineID else {
                    peer.send(request.reply(ok: false, error: "wrongProfile")); return
                }
                item = old; item.title = title; item.content = url
            }
            item.browserTarget = BrowserTarget(profileID: profile.id, profileName: profile.name, machineID: machineID)
            var reply = request.reply(ok: true); reply.destinationID = item.id
            var proposed = destinations.filter { $0.id != item.id }
            proposed.append(PresenterDestination(id: item.id, title: item.title, profileName: profile.name, profileID: profile.id, url: url, connected: true))
            reply.destinations = proposed
            guard proposed.count <= 250, (try? PresenterWire.encode(reply)) != nil else {
                peer.send(request.reply(ok: false, error: "capacity")); return
            }
            guard library.save(item) else { peer.send(request.reply(ok: false, error: "saveFailed")); return }
            refresh(); reply.destinations = destinations; peer.send(reply)
        case "activate":
            guard let id = request.destinationID else { peer.send(request.reply(ok: false, error: "invalid")); return }
            activate(id) { response in var reply = response; reply.id = request.id; peer.send(reply) }
        default: peer.send(request.reply(ok: false, error: "invalid"))
        }
    }
    private func respond(_ request: PresenterMessage, to peer: PresenterPeer) {
        var reply = request.reply(ok: true); reply.destinations = destinations
        if destinations.count > 250 || (try? PresenterWire.encode(reply)) == nil { reply = request.reply(ok: false, error: "capacity") }
        peer.send(reply)
    }
    func activate(_ id: UUID, completion: ((PresenterMessage) -> Void)? = nil) {
        refresh()
        let done: (PresenterMessage) -> Void = { [weak self] reply in
            self?.message = reply.ok == true ? nil : Self.explanation(reply.error)
            completion?(reply)
        }
        let request = PresenterMessage(type: "activate")
        guard !busy, mayActivate?() != false else { done(request.reply(ok: false, error: "busy")); return }
        guard let destination = destinations.first(where: { $0.id == id }) else { done(request.reply(ok: false, error: "missing")); return }
        guard let connection = profiles.first(where: { $0.value.id == destination.profileID }), let peer = peers[connection.key] else {
            done(request.reply(ok: false, error: "offline")); return
        }
        busy = true; message = nil
        let deadline = Date().addingTimeInterval(8)
        pending = (request.id, peer.id, deadline, done)
        var focus = PresenterMessage(id: request.id, type: "focus")
        focus.destinationID = id; focus.title = destination.title; focus.url = destination.url; focus.expiresAt = deadline.timeIntervalSince1970 * 1000
        onSwitch?(); peer.send(focus)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }; self?.finish(id: request.id, ok: false, error: "timeout")
        }
    }
    private func finish(id: UUID, ok: Bool, status: String? = nil, error: String? = nil) {
        guard let pending, pending.id == id else { return }
        self.pending = nil; timer?.cancel(); timer = nil; busy = false
        var reply = PresenterMessage(id: id, type: "result"); reply.ok = ok; reply.status = status; reply.error = error
        pending.finish(reply)
    }
    static func explanation(_ error: String?) -> String {
        switch error {
        case "offline": "Open the destination’s Chrome profile and choose Retry in its Workbench extension. Then switch again."
        case "missing": "This destination was removed. Save the current tab again in the Workbench extension."
        case "wrongProfile": "Update this destination from its paired Chrome profile."
        case "timeout": "Chrome did not confirm the switch. Check the destination before trying again."
        case "busy": "Finish the current recording, keyboard practice, switch or resource edit, then try again."
        case "permission": "Open this site in its Chrome profile and update the destination to allow access again."
        case "ambiguous": "Several tabs match. Open the right tab and update this destination in the Workbench extension."
        case "saveFailed": "The resource could not be saved. Check Saved resources in Workbench."
        case "duplicateProfile": "Two Chrome connections share a profile identity. Close the copied connection and reconnect the intended profile."
        case "capacity": "The Chrome destination list is too large. Remove unused destinations or shorten their saved addresses in Saved resources."
        case "changed": "The tab changed while switching. Open the right tab and update its destination in the Workbench extension."
        default: "The switch could not be confirmed. Open the destination’s Workbench extension and reconnect it."
        }
    }
    private func installHost() throws {
        #if APP_STORE
        throw VoiceError.message("Chrome connection is available in the direct Mac edition of Workbench.")
        #else
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("WorkbenchBrowserHost"),
              FileManager.default.isExecutableFile(atPath: executable.path), let folder = extensionFolder,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            throw VoiceError.message("Install the complete Workbench app before enabling Chrome connection.")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(PresenterWire.hostName + ".json")
        // Switching editions is an explicit Enable action, never an automatic launch write.
        let manifest: [String: Any] = ["name": PresenterWire.hostName, "description": "Workbench saved destinations", "path": executable.path,
                                      "type": "stdio", "allowed_origins": ["chrome-extension://\(PresenterWire.extensionID)/"]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #endif
    }
}
