import Foundation

enum ReadbackPackChecks {
    @MainActor
    static func run() throws {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw ReadbackError.message("READBACK_PACK_CHECK_FAILED: \(message)") }
            passed += 1
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-skill-pack-check-\(UUID().uuidString)")
        let domain = "Workbench.SkillPackChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? fm.removeItem(at: fixture) }
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let store = ReadbackSkillPackStore(root: fixture.appendingPathComponent("Installed packs"))
        let engine = RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults))
        let model = ReadbackModel(engine: engine, defaults: defaults, skillPacks: store)
        defer { model.shutdown() }
        try check(model.newSessionStyle == .neutral && model.installedServiceNow == nil, "new preferences default to neutral without installing ServiceNow")
        let neutral = fixture.appendingPathComponent("Neutral session")
        let neutralManifest = try model.createSession(at: neutral, title: "Neutral synthetic")
        let neutralSkill = try String(contentsOf: neutral.appendingPathComponent("SKILL.md"), encoding: .utf8)
        try check(neutralManifest.skillPack == .neutral && neutralSkill.contains("template.pptx"), "neutral sessions snapshot their identity and keep the template route")
        try check(!fm.fileExists(atPath: neutral.appendingPathComponent("brand").path), "neutral sessions have no optional branding or helpers")

        model.installServiceNowPack()
        try check(model.newSessionStyle == .serviceNow && model.installedServiceNow == .serviceNow && model.newSessionStyleProblem == nil, "one install action enables ServiceNow for future sessions")
        let expected = try ReadbackResources.bundledSnapshot(.serviceNow)
        let branded = fixture.appendingPathComponent("ServiceNow session")
        var brandedManifest = try model.createSession(at: branded, title: "ServiceNow synthetic")
        try check(brandedManifest.skillPack == .serviceNow, "ServiceNow sessions freeze pack id and version")
        let currentJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: branded.appendingPathComponent("session.json"))) as! [String: Any]
        try check(currentJSON["skillPack"] == nil, "session.json does not create a competing pack metadata record")
        for (path, bytes) in expected.files {
            let copied = try Data(contentsOf: branded.appendingPathComponent(path))
            let mode = try fm.attributesOfItem(atPath: branded.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber
            try check(copied == bytes && mode?.intValue == 0o600, "private full-payload snapshot matches \(path)")
        }
        // Keep ready captures and edited notes in their existing manifest order.
        for words in [" First edited narration.\n", "Second edited narration, exactly."] {
            let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
            try ReadbackStore.createPrivateDirectory(branded.appendingPathComponent(directory), includingParents: false)
            try ReadbackStore.writePrivate(Data("Synthetic whole-display screenshot".utf8), to: branded.appendingPathComponent(directory + "/screen.png"))
            try ReadbackStore.writePrivate(Data(words.utf8), to: branded.appendingPathComponent(directory + "/narration.txt"))
            brandedManifest.sections.append(ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: 10), displayName: "Synthetic display", directory: directory,
                screenshot: directory + "/screen.png", audio: nil, originalTranscript: nil, transcript: directory + "/narration.txt",
                status: .ready, failure: nil, deletedAt: nil))
        }
        try ReadbackStore.save(brandedManifest, at: branded)
        try ReadbackStore.writePrivate(Data("User customised session skill".utf8), to: branded.appendingPathComponent("SKILL.md"))
        func filesInSession() throws -> [String: Data] {
            var files: [String: Data] = [:]
            let enumerator = fm.enumerator(at: branded, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.path] = try Data(contentsOf: url)
            }
            return files
        }
        let originalFiles = try filesInSession()
        let reopened = ReadbackModel(engine: engine, defaults: defaults, skillPacks: store)
        defer { reopened.shutdown() }
        try check(reopened.newSessionStyle == .serviceNow && reopened.manifest?.skillPack == .serviceNow, "style selection and session identity survive reopening")
        try check(reopened.manifest?.sections.map(\.id) == brandedManifest.sections.map(\.id), "reopening preserves captured section order")
        try check(reopened.transcriptDrafts[brandedManifest.sections[0].id] == " First edited narration.\n", "reopening preserves exact edited narration")

        model.installServiceNowPack()
        model.selectNewSessionStyle(.neutral)
        let afterReinstall = try filesInSession()
        try check(afterReinstall == originalFiles, "reinstalling a pack and changing future style never rewrite an existing session or custom skill")
        model.selectNewSessionStyle(.serviceNow)
        model.uninstallServiceNowPack()
        try check(model.newSessionStyle == .serviceNow && model.newSessionStyleProblem != nil, "uninstalling an explicitly selected pack does not silently select neutral")
        let refused = fixture.appendingPathComponent("Refused session")
        do {
            _ = try model.createSession(at: refused, title: "Must not exist")
            throw ReadbackError.message("READBACK_PACK_CHECK_FAILED: unavailable explicit pack was accepted")
        } catch {
            try check(error.localizedDescription.contains("unavailable") && !fm.fileExists(atPath: refused.path), "missing selected pack explains recovery before creating any session")
        }
        let afterRemoval = try filesInSession()
        try check(afterRemoval == originalFiles, "uninstalling preserves existing screenshots, helpers, order, edited notes and customised skill byte for byte")
        model.selectNewSessionStyle(.neutral)
        let laterNeutral = try model.createSession(at: fixture.appendingPathComponent("Later neutral"), title: "Neutral still works")
        try check(laterNeutral.skillPack == .neutral && model.newSessionStyleProblem == nil, "ordinary neutral sessions work with no optional pack installed")

        model.installServiceNowPack()
        let installedSkill = store.root.appendingPathComponent(ReadbackSkillPackReference.serviceNow.id + "/SKILL.md")
        try Data("Incomplete changed installed pack".utf8).write(to: installedSkill)
        model.refreshSkillPacks()
        try check(model.newSessionStyleProblem != nil && model.installedServiceNow == nil, "changed installed payload is rejected instead of claiming the original version")
        model.installServiceNowPack()
        try check(model.installedServiceNow == .serviceNow && model.newSessionStyleProblem == nil, "an explicit reinstall repairs the optional pack")

        // This is the Codable shape shipped before skill packs. Older-app edits
        // preserve the companion without needing to understand pack metadata.
        let olderAppSession = fixture.appendingPathComponent("Older app save")
        try fm.copyItem(at: branded, to: olderAppSession)
        let receiptBefore = try Data(contentsOf: olderAppSession.appendingPathComponent(ReadbackStore.skillPackReceiptName))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var older = try decoder.decode(LegacyManifest.self, from: Data(contentsOf: olderAppSession.appendingPathComponent("session.json")))
        older.title = "Edited by an older app"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(older).write(to: olderAppSession.appendingPathComponent("session.json"))
        let olderJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: olderAppSession.appendingPathComponent("session.json"))) as! [String: Any]
        try check(olderJSON["skillPack"] == nil, "the older Codable writer needs no pack fields or format upgrade")
        let compatible = try ReadbackStore.load(from: olderAppSession)
        let receiptAfter = try Data(contentsOf: olderAppSession.appendingPathComponent(ReadbackStore.skillPackReceiptName))
        try check(compatible.skillPack == .serviceNow && compatible.title == older.title && receiptBefore == receiptAfter, "immutable companion preserves pack identity/version across an older-app edit")
        try check(compatible.sections == brandedManifest.sections, "older-app round trip preserves capture order and section metadata")
        let olderSkill = try String(contentsOf: olderAppSession.appendingPathComponent("SKILL.md"), encoding: .utf8)
        try check(olderSkill == "User customised session skill"
            && ReadbackStore.readText(root: olderAppSession, relative: compatible.sections[0].transcript) == " First edited narration.\n", "older-app round trip preserves the customized skill and exact notes")

        // Version-one legacy manifests remain readable without a pack marker.
        let legacy = fixture.appendingPathComponent("Legacy session")
        _ = try ReadbackStore.create(at: legacy, title: "Legacy fixture")
        try fm.removeItem(at: legacy.appendingPathComponent(ReadbackStore.skillPackReceiptName))
        let legacyLoaded = try ReadbackStore.load(from: legacy)
        try check(legacyLoaded.skillPack == nil, "legacy sessions open without invented style metadata or migration")
        print("READBACK_PACK_CHECKS_OK: \(passed) checks")
    }

    private struct LegacyManifest: Codable {
        var formatVersion: Int
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var sections: [ReadbackSection]
    }
}
