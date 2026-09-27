import AVFoundation
import Foundation

/// Synthetic audio and injected owners only. This never enumerates real audio
/// processes, requests permission, opens a tap/microphone or downloads a model.
@MainActor
enum MeetingChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Workbench-MeetingChecks-" + UUID().uuidString, isDirectory: true)
        try MeetingStore.createPrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ value: Bool, _ label: String) throws {
            guard value else { throw MeetingError.message("Meeting check failed: \(label)") }
            checks += 1
        }
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { checks += 1; return }
            throw MeetingError.message("Meeting check failed: \(label) did not reject")
        }

        let source = ProcessFixture()
        let detector = MeetingDetector(source: source)
        let now = Date(timeIntervalSince1970: 1_000)
        try expect(detector.evaluate(now: now) == nil && source.calls == 0, "default-off detection reads no metadata")
        detector.isEnabled = true
        source.values = [.init(pid: 123, bundleID: "us.zoom.xos", isRunningInput: false, isRunningOutput: true)]
        for _ in 0..<5 { _ = detector.evaluate(now: now) }
        try expect(detector.evaluate(now: now) == nil, "output/music alone never offers a call")
        source.values[0].isRunningInput = true
        try expect(detector.evaluate(now: now) == nil && detector.evaluate(now: now) == nil, "input activity is debounced")
        let offered = detector.evaluate(now: now)
        try expect(offered?.id == 123, "sustained known-app input offers a possibility")
        detector.dismiss(offered!, now: now)
        for _ in 0..<5 { _ = detector.evaluate(now: now) }
        try expect(detector.evaluate(now: now) == nil, "dismissal cooldown prevents repeated offers")
        try expect(detector.evaluate(now: now.addingTimeInterval(1_201)) != nil, "cooldown eventually expires")
        detector.isSuppressed = true
        let suppressedCalls = source.calls
        try expect(detector.evaluate(now: now) == nil && source.calls == suppressedCalls, "busy suppression reads no samples or metadata")
        detector.isSuppressed = false
        try expect(detector.evaluate(now: now.addingTimeInterval(1_201)) == nil, "suppression clears the old observation streak")
        detector.snooze(now: now)
        try expect(detector.evaluate(now: now.addingTimeInterval(2_000)) == nil, "snooze suppresses offers")
        detector.snoozedUntil = nil; detector.disable(offered!)
        for _ in 0..<4 { _ = detector.evaluate(now: now.addingTimeInterval(8_000)) }
        try expect(detector.evaluate(now: now.addingTimeInterval(8_000)) == nil, "per-app disable remains effective")
        source.values = [.init(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true),
                         .init(pid: 456, bundleID: "com.ethdawg.workbench.preview", isRunningInput: true, isRunningOutput: true),
                         .init(pid: 789, bundleID: "example.unknown", isRunningInput: true, isRunningOutput: true, name: "Synthetic app")]
        try expect(detector.availableApps().map(\.id) == [789], "manual picker excludes Workbench but accepts unknown audio apps")
        for _ in 0..<4 { _ = detector.evaluate(now: now) }
        try expect(detector.evaluate(now: now) == nil, "unknown apps and own PID cannot trigger offers")
        source.failure = true
        try expect(detector.availableApps().isEmpty && detector.lastError != nil, "metadata errors are visible rather than an absent-call claim")
        source.failure = false

        // Identifiers compare without case, and an app can own audio processes
        // not named `.helper`. Mac call services are never merged into an app.
        for (process, owner) in [("com.apple.MobilePhone", "com.apple.mobilephone"), ("com.microsoft.teams2.modulehost", "com.microsoft.teams2"),
                                 ("com.hnc.Discord.helper.Renderer", "com.hnc.Discord"), ("net.whatsapp.WhatsApp", "net.whatsapp.WhatsApp")] {
            try expect(MeetingAppCatalogue.known(process)?.bundleID == owner, "\(process) belongs to \(owner)")
        }
        try expect(MeetingAppCatalogue.known("com.apple.FaceTimeExtra") == nil && MeetingAppCatalogue.known("com.apple.avconferenced") == nil,
                   "only exact identifiers and an app's own processes match; call services are never merged into an app")
        let teams = MeetingDetector(source: source)
        teams.isEnabled = true
        source.values = [.init(pid: 900, bundleID: "com.microsoft.teams2", isRunningInput: false, isRunningOutput: false),
                         .init(pid: 901, bundleID: "com.microsoft.teams2.modulehost", isRunningInput: true, isRunningOutput: true, isUserFacingApp: false)]
        _ = teams.evaluate(now: now); _ = teams.evaluate(now: now)
        try expect(teams.evaluate(now: now)?.bundleID == "com.microsoft.teams2" && teams.availableApps().map(\.id) == [900],
                   "a new Teams call in its module host is offered as one Teams choice")

        source.values = [
            .init(pid: 800, bundleID: "com.apple.assistantd", isRunningInput: false, isRunningOutput: false,
                  isUserFacingApp: false),
            .init(pid: 811, bundleID: "com.google.Chrome.helper.audio", isRunningInput: true, isRunningOutput: true,
                  isUserFacingApp: false),
            .init(pid: 810, bundleID: "com.google.Chrome", isRunningInput: false, isRunningOutput: false),
            .init(pid: 812, bundleID: "com.google.Chrome.helper.renderer", isRunningInput: false, isRunningOutput: true,
                  isUserFacingApp: false),
            .init(pid: 820, bundleID: "example.player", isRunningInput: false, isRunningOutput: true, name: "Example Player"),
            .init(pid: 830, bundleID: "com.apple.avconferenced", isRunningInput: true, isRunningOutput: true, isUserFacingApp: false),
            .init(pid: 831, bundleID: "com.apple.TelephonyUtilities", isRunningInput: true, isRunningOutput: true, isUserFacingApp: false),
            .init(pid: 832, bundleID: "com.apple.WebKit.GPU", isRunningInput: true, isRunningOutput: true, isUserFacingApp: false),
            .init(pid: 840, bundleID: "example.menubar", isRunningInput: false, isRunningOutput: true, name: "Menu-bar Player")
        ]
        let choices = detector.availableApps()
        try expect(Set(choices.map(\.id)) == [810, 820, 830, 831, 832, 840],
                   "picker hides system clutter, groups browser helpers and retains manual call services and accessory apps")
        try expect(choices.first(where: { $0.id == 830 })?.bundleID == "com.apple.avconferenced"
            && choices.first(where: { $0.id == 831 })?.name == "Mac telephony service"
            && choices.first(where: { $0.id == 832 })?.name == "WebKit audio service (shared)",
            "manual audio-service labels preserve their actual process and bundle capture scope")
        source.values.reverse()
        try expect(detector.availableApps() == choices, "process enumeration order cannot change the selected app representative")
        detector.forgetObservations()
        _ = detector.evaluate(now: now); _ = detector.evaluate(now: now)
        try expect(detector.evaluate(now: now)?.id == 810,
                   "helper microphone activity offers the same app identifier as the manual picker")
        source.values.removeAll { $0.pid == 810 }
        try expect(detector.availableApps().first(where: { $0.bundleID == "com.google.Chrome" })?.id == 811,
                   "known audio helpers remain available when the main process has no CoreAudio object")
        source.values.removeAll { $0.bundleID.hasPrefix("com.google.Chrome") }
        detector.forgetObservations()
        _ = detector.evaluate(now: now); _ = detector.evaluate(now: now)
        try expect(detector.evaluate(now: now)?.id == 830,
                   "the calling service with two-way audio is the one manual service that raises an offer, because a call answered on this Mac runs there")
        source.values.removeAll { $0.bundleID == "com.apple.avconferenced" }
        detector.forgetObservations()
        for _ in 0..<4 { _ = detector.evaluate(now: now) }
        try expect(detector.evaluate(now: now) == nil,
                   "every other manual service, including Mac telephony and shared WebKit audio, stays manual even with two-way audio")

        // A FaceTime or iPhone call answered on this Mac runs in the calling
        // service, which Detect Meetings & Calls covers only with two-way audio.
        let calls = MeetingDetector(source: source)
        calls.isEnabled = true
        source.values = [.init(pid: 950, bundleID: "com.apple.avconferenced", isRunningInput: true, isRunningOutput: false, isUserFacingApp: false)]
        for _ in 0..<4 { _ = calls.evaluate(now: now) }
        try expect(calls.evaluate(now: now) == nil, "the calling service with only the microphone running is not offered")
        source.values[0].isRunningInput = false; source.values[0].isRunningOutput = true
        for _ in 0..<4 { _ = calls.evaluate(now: now) }
        try expect(calls.evaluate(now: now) == nil, "calling-service playback without input does not offer")
        source.values = [
            .init(pid: 950, bundleID: "com.apple.avconferenced", isRunningInput: true, isRunningOutput: false, isUserFacingApp: false),
            .init(pid: 951, bundleID: "com.apple.avconferenced", isRunningInput: false, isRunningOutput: true, isUserFacingApp: false)
        ]
        for _ in 0..<4 { _ = calls.evaluate(now: now) }
        try expect(calls.evaluate(now: now) == nil, "directions from different service processes cannot invent a two-way source")
        source.values.removeLast(); source.values[0].isRunningOutput = true
        try expect(calls.evaluate(now: now) == nil && calls.evaluate(now: now) == nil,
                   "calling-service activity needs the complete confirmation streak")
        source.values[0].isRunningOutput = false
        try expect(calls.evaluate(now: now) == nil, "losing one direction interrupts the service streak")
        source.values[0].isRunningOutput = true
        try expect(calls.evaluate(now: now) == nil && calls.evaluate(now: now) == nil,
                   "both directions must remain present for a fresh full streak")
        let call = calls.evaluate(now: now)
        try expect(call?.id == 950 && call?.bundleID == "com.apple.avconferenced"
                   && MeetingDetector.offerTitle(for: call!) == "Possible call on this Mac"
                   && MeetingDetector.offerText(for: call!).contains("FaceTime or phone call"),
                   "a two-way call on this Mac is offered as a call from its own source")
        calls.dismiss(call!, now: now)
        for _ in 0..<4 { _ = calls.evaluate(now: now) }
        try expect(calls.evaluate(now: now) == nil, "calling-service dismissal retains the usual cooldown")
        let afterCooldown = now.addingTimeInterval(1_201)
        try expect(calls.evaluate(now: afterCooldown)?.id == 950, "calling-service offers can return after cooldown")
        calls.snooze(now: afterCooldown)
        let readsBeforeSnooze = source.calls
        try expect(calls.evaluate(now: afterCooldown.addingTimeInterval(10)) == nil && source.calls == readsBeforeSnooze,
                   "snoozing a service offer stops metadata reads")
        calls.snoozedUntil = nil; calls.disable(call!)
        for _ in 0..<4 { _ = calls.evaluate(now: afterCooldown) }
        try expect(calls.evaluate(now: afterCooldown) == nil, "turning off offers for calls on this Mac is respected")

        for duration in [301.0, 1_801, 2_700, 3_600, 7_200, 600.1] {
            let windows = MeetingSegmentPlan.plan(totalSeconds: duration)
            try expect(abs(windows.reduce(0) { $0 + $1.seconds } - duration) < 0.001, "\(duration)-second plan retains complete duration")
            try expect(windows.allSatisfy { $0.seconds <= 600 && $0.seconds >= 0.5 && $0.bytes < 64 * 1024 * 1024 }, "\(duration)-second requests remain bounded")
        }
        try expect(MeetingSegmentPlan.plan(totalSeconds: .infinity).isEmpty, "non-finite duration is rejected")
        try expect(MeetingSegmentPlan.plan(totalSeconds: 0.1).isEmpty, "subminimum recording is not sent to recognizer")

        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        let base = manifest()
        let session = try MeetingStore.create(root: storeRoot, manifest: base)
        let manifestURL = session.appendingPathComponent(MeetingStore.manifestName)
        let permissions = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "manifest is private")
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: session.path)[.posixPermissions] as? NSNumber
        try expect(directoryPermissions?.intValue == 0o700, "session directory is private")
        try rejects("relative path traversal") { _ = try MeetingStore.safeURL(session: session, relative: "../other") }
        let symlink = session.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        try rejects("symlink traversal") { _ = try MeetingStore.safeURL(session: session, relative: "linked/file") }
        let outsideLink = root.appendingPathComponent("linked-session")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: session)
        try rejects("session root symlink") { _ = try MeetingStore.safeURL(session: outsideLink, relative: MeetingStore.manifestName) }
        let original = try Data(contentsOf: manifestURL)
        let corrupt = Data("{not valid".utf8)
        try MeetingStore.writePrivate(corrupt, to: manifestURL)
        try rejects("corrupt manifest") { _ = try MeetingStore.load(from: session) }
        try expect(try Data(contentsOf: manifestURL) == corrupt, "corrupt record remains unchanged")
        var future = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        future["formatVersion"] = 999
        let futureBytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        try MeetingStore.writePrivate(futureBytes, to: manifestURL)
        try rejects("future manifest") { _ = try MeetingStore.load(from: session) }
        try rejects("overwrite changed/future manifest") { try MeetingStore.save(base, at: session, replacing: base) }
        try expect(try Data(contentsOf: manifestURL) == futureBytes, "future record remains unchanged after load and save attempts")
        try expect(MeetingRecovery.scan(root: storeRoot).first?.isReadable == false, "unreadable recovery is visible")

        // Two distinct rates and staggered source starts establish chronological
        // overlap rather than local-then-remote concatenation.
        var mixManifest = manifest(state: .recording)
        let mixedSession = try MeetingStore.create(root: storeRoot, manifest: mixManifest)
        let remote = try audio(source: .remote, seconds: 2, rate: 48_000, value: 0.4, offset: 0, session: mixedSession)
        let local = try audio(source: .local, seconds: 2, rate: 16_000, value: 0.3, offset: 1, session: mixedSession)
        mixManifest = try MeetingRecovery.rebuildTracks(session: mixedSession, manifest: mixManifest)
        try expect(mixManifest.tracks.first(where: { $0.source == .local })?.startSeconds == 1, "restart recovers durable source offsets")
        try expect(mixManifest.seconds == 3 && mixManifest.gaps.count == 1, "interruption retains duration and an honest partial-audio note")
        let mixed = try MeetingMixer.writeSegments(tracks: [local, remote], session: mixedSession)
        let mixedURL = try MeetingStore.safeURL(session: mixedSession, relative: mixed[0].file)
        try expect(abs(try sample(mixedURL, at: 0.5) - 0.2) < 0.01, "remote audio occupies its original early time")
        try expect(abs(try sample(mixedURL, at: 1.5) - 0.35) < 0.01, "overlap mixes the two sources at the same time")
        try expect(abs(try sample(mixedURL, at: 2.5) - 0.15) < 0.01, "local audio retains its later end")
        let originals = [try Data(contentsOf: mixedSession.appendingPathComponent(remote.file)), try Data(contentsOf: mixedSession.appendingPathComponent(local.file))]
        _ = try MeetingMixer.writeSegments(tracks: [remote, local], session: mixedSession)
        try expect(originals[0] == (try Data(contentsOf: mixedSession.appendingPathComponent(remote.file))) && originals[1] == (try Data(contentsOf: mixedSession.appendingPathComponent(local.file))), "mix retry preserves original tracks")
        try MeetingStore.writePrivate(Data("changed segment".utf8), to: mixedURL)
        try rejects("changed segment overwrite") { _ = try MeetingMixer.writeSegments(tracks: [remote, local], session: mixedSession) }
        try expect(try Data(contentsOf: mixedURL) == Data("changed segment".utf8), "changed generated segment remains untouched")

        // An actual stream longer than 30 minutes is mixed in small blocks and
        // checkpointed across a failed request, without a short-capture owner.
        var long = manifest()
        let longSession = try MeetingStore.create(root: storeRoot, manifest: long)
        let longTrack = try audio(source: .remote, seconds: 1_861, rate: 16_000, value: 0.1, offset: 0, session: longSession)
        var nextLong = long; nextLong.tracks = [longTrack]; nextLong.seconds = 1_861
        try MeetingStore.save(nextLong, at: longSession, replacing: long); long = nextLong
        var attempts: [Int] = [], shouldFail = true, saved: [Transcript] = []
        let recognize: (URL) async throws -> String = { url in
            let index = Int(url.deletingPathExtension().lastPathComponent.suffix(4))!
            attempts.append(index)
            if index == 1 && shouldFail { shouldFail = false; throw MeetingError.message("Synthetic recognition failure") }
            return "segment \(index)"
        }
        let longProcessor = MeetingProcessor(session: longSession, transcribe: recognize,
                                             commit: { transcript, _, _ in saved = TranscriptHistory.adding(transcript, to: saved) })
        do { _ = try await longProcessor.run(); throw MeetingError.message("Expected a synthetic recognition failure") }
        catch { try expect(error.localizedDescription.contains("Synthetic recognition failure"), "recognizer failure is propagated") }
        let checkpoint = try MeetingStore.load(from: longSession)
        try expect(checkpoint.segments.count == 4 && checkpoint.segments[0].text != nil && checkpoint.segments[1].text == nil,
                   "long recording checkpoints the completed first segment")
        let result = try await longProcessor.run()
        try expect(result.committed && saved.count == 1 && saved[0].seconds == 1_861, "long retry saves one complete transcript")
        try expect(attempts == [0, 1, 1, 2, 3] && saved[0].text == "segment 0 segment 1 segment 2 segment 3", "retry skips completed recognition and retains order")
        _ = try await longProcessor.run()
        try expect(saved.count == 1 && attempts.count == 5, "committed retry does not recognize or commit again")

        let commitManifest = manifest()
        let commitSession = try MeetingStore.create(root: storeRoot, manifest: commitManifest)
        let commitTrack = try audio(source: .local, seconds: 1, rate: 16_000, value: 0.2, offset: 0, session: commitSession)
        var stopped = commitManifest; stopped.tracks = [commitTrack]; stopped.seconds = 1
        try MeetingStore.save(stopped, at: commitSession, replacing: commitManifest)
        var recognitionCount = 0, commits = 0, history: [Transcript] = []
        let failJournal = OnceFlag()
        var commitProcessor = MeetingProcessor(session: commitSession, transcribe: { _ in recognitionCount += 1; return "original synthetic wording" }, commit: { transcript, _, _ in
            commits += 1; history = TranscriptHistory.adding(transcript, to: history)
        }, writeManifest: { next, previous in
            if next.state == .committed, failJournal.take() { throw MeetingError.message("Synthetic post-history journal failure") }
            try MeetingStore.save(next, at: commitSession, replacing: previous)
        })
        do { _ = try await commitProcessor.run(); throw MeetingError.message("Expected a journal failure") }
        catch { try expect(error.localizedDescription.contains("Synthetic post-history"), "failed committed journal is reported") }
        try expect(try MeetingStore.load(from: commitSession).state == .recognized, "failed final checkpoint keeps recognized text for retry")
        _ = try await commitProcessor.run()
        try expect(history.count == 1 && history[0].id == commitManifest.id && recognitionCount == 1 && commits == 2,
                   "post-history failure retries the same ID without duplicate history or recognition")
        try expect(history[0].rawText == history[0].text && history[0].cleanupMethod == nil, "original wording is retained without cleanup")
        commitProcessor.writeManifest = nil

        // The real bounded writer records timestamp discontinuities as a stop,
        // rather than joining later samples onto an earlier time.
        let recording = manifest(state: .recording)
        let recorderSession = try MeetingStore.create(root: storeRoot, manifest: recording)
        let trackWriter = try MeetingTrackRecorder(source: .local, directory: recorderSession.appendingPathComponent("tracks"),
                                                  sampleRate: 16_000, timeline: MeetingCaptureTimeline())
        try trackWriter.open()
        let pcm = [Float](repeating: 0.25, count: 1_600), host = MeetingClock.now()
        pcm.withUnsafeBufferPointer { trackWriter.append($0.baseAddress!, count: pcm.count, hostTime: host) }
        pcm.withUnsafeBufferPointer { trackWriter.append($0.baseAddress!, count: pcm.count,
                                                        hostTime: host + AVAudioTime.hostTime(forSeconds: 2)) }
        let recorded = await Task.detached { trackWriter.close() }.value
        try expect(abs(recorded.seconds - 0.1) < 0.001 && trackWriter.failure != nil, "source discontinuity stops at the correct time")
        let restored = try MeetingRecovery.rebuildTracks(session: recorderSession, manifest: recording)
        try expect(restored.tracks.first?.seconds == recorded.seconds, "writer timing/audio survives close and recovery")

        try await lifecycleChecks(root: root, expect: expect)
        try await offerLifecycleChecks(root: root, expect: expect)
        checks += try MeetingRemovalChecks.run(root: root.appendingPathComponent("removal-checks"))
        print("Meeting checks passed (\(checks)): synthetic detection, source timing, >30-minute segmentation, recovery, cancellation and stable history commits. No live devices were used.")
    }

    private static func offerLifecycleChecks(root: URL, expect: (Bool, String) throws -> Void) async throws {
        let suite = "Workbench-MeetingOffers-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ProcessFixture()
        var permissions = 0, captures = 0, reviews = 0
        let model = MeetingModel(directory: root.appendingPathComponent("offers"), defaults: defaults,
            processSource: source, transcribe: { _ in "unused" },
            microphonePermission: { permissions += 1; return true },
            captureFactory: { captures += 1; return CaptureFixture() })
        var created = 0, closed = 0
        var visible = Set<Int>()
        var offers: [MeetingAudioApp] = []
        var actions: [MeetingOfferPanelController.Actions] = []
        var timers: [@MainActor () -> Void] = []
        var delays: [TimeInterval] = []
        let controller = MeetingOfferPanelController(model: model, present: { offer, callbacks in
            created += 1
            let id = created
            visible.insert(id); offers.append(offer); actions.append(callbacks)
            return { visible.remove(id); closed += 1 }
        }, schedule: { delay, callback in delays.append(delay); timers.append(callback) },
        review: { reviews += 1 })
        model.refreshDetection()
        try expect(created == 0 && source.calls == 0, "disabled offer controller reads no metadata and presents nothing")
        model.detectionEnabled = true
        source.values = [.init(pid: 91_001, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)]
        model.refreshDetection(); model.refreshDetection()
        try expect(created == 0, "passive offer waits for all three observations")
        model.refreshDetection()
        try expect(visible == [1] && created == 1 && closed == 0, "confirmed offer presents exactly one panel")
        model.refreshDetection(); model.refreshDetection()
        try expect(visible == [1] && created == 1 && closed == 0 && timers.count == 1,
                   "repeated Published offers retain the visible panel and its original timeout")
        actions[0].dismiss()
        model.refreshDetection()
        try expect(visible.isEmpty && closed == 1 && model.offer == nil && created == 1,
                   "Not now clears the panel and cooldown prevents its next poll from reopening")

        source.values = [.init(pid: 91_002, bundleID: "com.apple.avconferenced", isRunningInput: true, isRunningOutput: true, isUserFacingApp: false)]
        for _ in 0..<3 { model.refreshDetection() }
        timers[0]()
        try expect(visible == [2] && created == 2 && closed == 1,
                   "a dismissed offer's stale timer cannot hide a replacement")
        actions[1].review()
        try expect(visible.isEmpty && reviews == 1 && model.selectedAppID == 91_002 && model.purpose == "call" && captures == 0,
                   "Review selects the exact calling-service source and Call purpose without starting capture")

        // Phone.app's installed macOS bundle identifier is lowercase.
        source.values = [.init(pid: 91_003, bundleID: "com.apple.mobilephone", isRunningInput: true, isRunningOutput: true)]
        for _ in 0..<3 { model.refreshDetection() }
        try expect(visible == [3] && offers.last?.name == "Phone" && offers.last?.bundleID == "com.apple.mobilephone",
                   "real macOS Phone bundle identity produces a scoped metadata-only offer")
        timers[2]()
        try expect(visible.isEmpty && closed == 3, "the current timeout hides its own panel")
        for _ in 0..<3 { model.refreshDetection() }
        try expect(created == 3 && timers.count == 3, "a timed-out offer does not repeatedly reopen during one continuous activity")
        source.values = []; model.refreshDetection()
        source.values = [.init(pid: 91_003, bundleID: "com.apple.mobilephone", isRunningInput: true, isRunningOutput: true)]
        for _ in 0..<3 { model.refreshDetection() }
        timers[2]()
        try expect(visible == [4] && created == 4 && closed == 3,
                   "absent activity permits a new offer with the same PID and invalidates its old timer")
        source.values[0].pid = 91_004; model.refreshDetection()
        timers[3]()
        try expect(visible == [5] && offers.last?.id == 91_004 && closed == 4,
                   "a changed process replaces the panel and its predecessor cannot dismiss it")
        controller.close()
        timers[4](); model.refreshDetection()
        try expect(visible.isEmpty && closed == 5 && created == 5,
                   "closing the controller removes its panel and prevents stale timers or publications reopening it")
        actions[4].snooze()
        let callsBeforeSnooze = source.calls
        model.refreshDetection()
        try expect(model.offer == nil && source.calls == callsBeforeSnooze,
                   "Snooze suppresses further offer metadata polls")
        model.detectionEnabled = false
        await model.prepareForShutdown()
        try expect(permissions == 0 && captures == 0 && delays.allSatisfy { $0 == 20 },
                   "all offer paths preserve the timeout and never request microphone or capture access")
    }

    private static func lifecycleChecks(root: URL, expect: (Bool, String) throws -> Void) async throws {
        let suite = "Workbench-MeetingChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ProcessFixture()
        source.values = [.init(pid: 789, bundleID: "example.synthetic", isRunningInput: true, isRunningOutput: true, name: "Synthetic app")]
        var factories = 0, permissions = 0, recognition = 0, history: [Transcript] = []
        let capture = CaptureFixture()
        let model = MeetingModel(directory: root.appendingPathComponent("model"), defaults: defaults, processSource: source,
                                 transcribe: { _ in recognition += 1; return "synthetic meeting" },
                                 microphonePermission: { permissions += 1; return true }, captureFactory: { factories += 1; return capture })
        await Task.yield()
        model.useOffer(MeetingAudioApp(id: 950, name: "Mac calling service", bundleID: "com.apple.avconferenced"))
        try expect(model.selectedAppID == 950 && model.purpose == "call", "reviewing a call on this Mac records it as a Call")
        model.purpose = "meeting"; model.selectedAppID = nil
        try expect(!model.detectionEnabled && source.calls == 0 && factories == 0 && permissions == 0,
                   "controller initialization does not detect, ask permission or capture")
        model.mayStart = { "Another Workbench recording is active." }
        await model.start()
        try expect(!model.isBusy && factories == 0 && permissions == 0, "shared admission guard prevents capture")
        model.mayStart = nil; model.refreshApps(); model.selectedAppID = 789; model.includeMicrophone = false
        model.saveTranscript = { transcript, purpose in
            guard purpose == "meeting" else { throw MeetingError.message("Purpose changed") }
            history = TranscriptHistory.adding(transcript, to: history)
        }
        await model.start()
        try expect(model.isRecording && model.isBusy && factories == 1 && permissions == 0 && recognition == 0,
                   "explicit app-only Start records without microphone access or concurrent recognition")
        let activeID = UUID(uuidString: MeetingStore.sessions(in: root.appendingPathComponent("model"))[0].lastPathComponent)!
        var removalCommits = 0
        do {
            _ = try model.removeCompletedRecording(for: activeID) { removalCommits += 1 }
            throw MeetingError.message("An active recording allowed removal")
        } catch {
            try expect(removalCommits == 0 && model.isRecording && model.hasRecording(for: activeID),
                       "removing a completed transcript cannot remove an active recording")
        }
        var oldMeeting = manifest(state: .committed)
        oldMeeting.seconds = 1
        oldMeeting.segments = [.init(index: 0, file: "segments/segment-0000.wav", startSeconds: 0,
                                      seconds: 1, bytes: 32_000, text: "An earlier completed meeting")]
        _ = try MeetingStore.create(root: root.appendingPathComponent("model"), manifest: oldMeeting)
        _ = try model.removeCompletedRecording(for: oldMeeting.id) { removalCommits += 1 }
        try expect(removalCommits == 1 && model.isRecording && model.hasRecording(for: activeID)
                   && !model.hasRecording(for: oldMeeting.id), "an unrelated active recording does not prevent an old completed recording's removal")
        await model.stop()
        try expect(!model.isBusy && capture.finished == 1 && history.count == 1 && recognition == 1,
                   "Stop closes capture then saves through the shared history callback")
        try expect(!model.hasRecovery, "committed controller session is not offered as unfinished")
        await model.prepareForShutdown()

        let permissionGate = Gate<Bool>()
        var lateFactories = 0
        let lateModel = MeetingModel(directory: root.appendingPathComponent("late-permission"), defaults: defaults,
                                     processSource: ProcessFixture(), transcribe: { _ in "unused" },
                                     microphonePermission: { await permissionGate.wait() },
                                     captureFactory: { lateFactories += 1; return CaptureFixture() })
        let lateStart = Task { await lateModel.start() }
        await waitUntil { permissionGate.isWaiting }
        await lateModel.cancel()
        try expect(!lateModel.isBusy, "cancelled permission request releases a gate with no capture resources")
        permissionGate.resume(true); await lateStart.value
        try expect(lateFactories == 0 && !lateModel.isRecording, "late microphone grant cannot start stale capture")
        await lateModel.prepareForShutdown()

        let startGate = Gate<Bool>(), delayedCapture = CaptureFixture()
        delayedCapture.startGate = startGate
        let delayedModel = MeetingModel(directory: root.appendingPathComponent("late-capture"), defaults: defaults,
                                        processSource: source, transcribe: { _ in "unused" },
                                        microphonePermission: { true }, captureFactory: { delayedCapture },
                                        startupNoticeDelayNanoseconds: 1_000_000)
        delayedModel.selectedAppID = 789; delayedModel.includeMicrophone = false
        let delayedStart = Task { await delayedModel.start() }
        await waitUntil { startGate.isWaiting }
        await waitUntil { delayedModel.notice.contains("has not finished") }
        try expect(delayedModel.isStarting && !delayedModel.isRecording && delayedModel.notice.contains("Audio Recording permission"),
                   "slow app startup explains the permission wait without claiming recording or releasing ownership")
        let delayedCancel = Task { await delayedModel.cancel() }
        await waitUntil { delayedCapture.stopping }
        try expect(delayedModel.isBusy, "late system-access cancellation reserves ownership until capture teardown")
        try expect(delayedModel.notice.hasPrefix("Cancelling start."), "cancel explains the pending macOS return without claiming teardown finished")
        startGate.resume(true); await delayedStart.value; await delayedCancel.value
        try expect(!delayedModel.isBusy && delayedCapture.finished == 1 && !delayedCapture.recorded,
                   "late system access never begins samples after cancellation")
        await delayedModel.prepareForShutdown()

        let recognitionGate = Gate<String>(), processingCapture = CaptureFixture()
        var processingHistory: [Transcript] = []
        let processingModel = MeetingModel(directory: root.appendingPathComponent("cancel-processing"), defaults: defaults,
                                           processSource: ProcessFixture(), transcribe: { _ in await recognitionGate.wait() },
                                           microphonePermission: { true }, captureFactory: { processingCapture })
        processingModel.saveTranscript = { transcript, _ in processingHistory.append(transcript) }
        await processingModel.start()
        let processingStop = Task { await processingModel.stop() }
        await waitUntil { recognitionGate.isWaiting }
        let processingCancel = Task { await processingModel.cancel() }
        await Task.yield()
        try expect(processingModel.isBusy, "processing cancellation retains the shared engine gate until unwind")
        recognitionGate.resume("late text")
        await processingStop.value; await processingCancel.value
        try expect(processingHistory.isEmpty && processingModel.hasRecovery && !processingModel.isBusy,
                   "cancelled recognition cannot commit late text and preserves explicit recovery")
        await processingModel.prepareForShutdown()

        let failedCapture = CaptureFixture(), failedRoot = root.appendingPathComponent("changed-manifest")
        let failedModel = MeetingModel(directory: failedRoot, defaults: defaults, processSource: ProcessFixture(),
                                       transcribe: { _ in "unused" }, microphonePermission: { true }, captureFactory: { failedCapture })
        await failedModel.start()
        let changedSession = MeetingStore.sessions(in: failedRoot)[0]
        let changedURL = changedSession.appendingPathComponent(MeetingStore.manifestName)
        let changed = try Data(contentsOf: changedURL) + Data(" ".utf8)
        try MeetingStore.writePrivate(changed, to: changedURL)
        await failedModel.stop()
        try expect(failedModel.error != nil && !failedModel.isBusy && failedModel.hasRecovery,
                   "failed final metadata commit is visible and leaves recoverable audio")
        try expect(try Data(contentsOf: changedURL) == changed, "controller never overwrites an outside metadata edit")
        await failedModel.prepareForShutdown()

        let quitCapture = CaptureFixture(), quitRoot = root.appendingPathComponent("quit")
        let quitModel = MeetingModel(directory: quitRoot, defaults: defaults, processSource: ProcessFixture(),
                                    transcribe: { _ in "unused" }, microphonePermission: { true }, captureFactory: { quitCapture })
        await quitModel.start(); await quitModel.prepareForShutdown()
        try expect(quitCapture.finished == 1 && !quitModel.isBusy && quitModel.hasRecovery,
                   "normal shutdown awaits audio flush and leaves recovery without recognition")
        try expect(MeetingRecovery.scan(root: quitRoot).first?.manifest?.state == .stopped,
                   "shutdown leaves a durable stopped session")
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<5_000 { if condition() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private static func manifest(state: MeetingState = .stopped) -> MeetingManifest {
        MeetingManifest(id: UUID(), createdAt: Date(), updatedAt: Date(), purpose: "meeting",
                        includesMicrophone: true, includesRemote: true, state: state, seconds: 0)
    }

    fileprivate static func audio(source: MeetingTrackSource, seconds: Double, rate: Double, value: Float,
                                  offset: Double, session: URL) throws -> MeetingTrack {
        let relative = "tracks/\(source.rawValue).caf"
        let url = try MeetingStore.safeURL(session: session, relative: relative)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)!
            var remaining = Int(seconds * rate)
            while remaining > 0 {
                let count = min(8_192, remaining); buffer.frameLength = AVAudioFrameCount(count)
                for index in 0..<count { buffer.floatChannelData![0][index] = value }
                try file.write(from: buffer); remaining -= count
            }
        }
        let timing = MeetingTrackTiming(source: source, startSeconds: offset, sampleRate: rate)
        try MeetingStore.writePrivate(JSONEncoder().encode(timing), to: url.deletingPathExtension().appendingPathExtension("json"))
        return MeetingTrack(source: source, file: relative, startSeconds: offset, seconds: seconds, sampleRate: rate,
                            peak: Double(abs(value)), droppedSeconds: 0)
    }

    private static func sample(_ url: URL, at seconds: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        file.framePosition = Int64(seconds * file.processingFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1)!
        try file.read(into: buffer, frameCount: 1)
        return buffer.floatChannelData![0][0]
    }

    private final class ProcessFixture: MeetingProcessSource {
        var isAvailable = true
        var unavailableReason = "Synthetic unavailable metadata"
        var values: [MeetingProcessSnapshot] = []
        var calls = 0
        var failure = false
        func snapshot() throws -> [MeetingProcessSnapshot] {
            calls += 1
            if failure { throw MeetingError.message("Synthetic metadata failure") }
            return values
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; let old = value; value = false; return old }
    }

    @MainActor fileprivate final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async -> Value { await withCheckedContinuation { continuation = $0 } }
        func resume(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
    }

    private final class CaptureFixture: MeetingCapture {
        var startGate: Gate<Bool>?
        var stopping = false
        var recorded = false
        var finished = 0
        var elapsedSeconds = 1.0
        var stopReason: String?
        private var report = MeetingCaptureReport()
        func start(_ request: MeetingCaptureRequest) async throws {
            if let startGate { _ = await startGate.wait() }
            guard !stopping else { throw CancellationError() }
            let session = request.tracksDirectory.deletingLastPathComponent()
            let source: MeetingTrackSource = request.includeMicrophone ? .local : .remote
            let track = try await MeetingChecks.audio(source: source, seconds: 1, rate: 16_000, value: 0.2, offset: 0, session: session)
            report = MeetingCaptureReport(tracks: [track], seconds: 1)
            recorded = true
        }
        func requestStop() { stopping = true }
        func finish() async -> MeetingCaptureReport { finished += 1; stopping = true; return report }
    }
}
