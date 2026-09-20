import XCTest
import UIKit
import PencilKit
import SwiftUI
@testable import WorkbenchMobile

@MainActor
private final class SpeechAssetFixture: MobileSpeechAssetProviding {
    var isAvailable = true
    var installCalls: [String] = []
    var cancelCount = 0
    var failure: Error?
    var suspendInstallation = false
    var onInstall: (() -> Void)?
    var onCancel: (() -> Void)?
    var statusSequence: [MobileSpeechAssetStatus] = []
    var installedLocaleOverride: Bool?
    var installsImmediately = true
    var outcome = MobileSpeechInstallationOutcome.downloadAttemptFinished
    var snapshotCalls = 0
    private var installed = Set<String>()
    private var continuation: CheckedContinuation<Void, Never>?
    private var progress: (@MainActor (Double) -> Void)?

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en_AU"), Locale(identifier: "fr_FR")] }
    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await supportedLocales().first { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
    func snapshot(for locale: Locale) async -> MobileSpeechAssetSnapshot {
        snapshotCalls += 1
        let identifier = locale.identifier(.bcp47)
        let status = statusSequence.isEmpty ? (installed.contains(identifier) ? MobileSpeechAssetStatus.installed : .supported) : statusSequence.removeFirst()
        return MobileSpeechAssetSnapshot(status: status, localeIdentifier: identifier,
            localeIsInstalled: installedLocaleOverride ?? installed.contains(identifier),
            reservedLocaleIdentifiers: installed.contains(identifier) ? [identifier] : [])
    }
    func install(for locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws -> MobileSpeechInstallationOutcome {
        let identifier = locale.identifier(.bcp47)
        installCalls.append(identifier)
        self.progress = progress
        if let failure { throw failure }
        if suspendInstallation {
            await withCheckedContinuation { continuation in self.continuation = continuation; onInstall?() }
        } else { onInstall?() }
        // Deliberately noncooperative after cancellation: the service must reject
        // this late completion using its invocation generation.
        if installsImmediately { installed.insert(identifier) }
        return outcome
    }
    func cancelInstallation() { cancelCount += 1; onCancel?() }
    func publishProgress(_ value: Double) { progress?(value) }
    func finishSuspendedInstallation() { continuation?.resume(); continuation = nil }
}

final class MobileDocumentTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileDocumentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testSharedCleanupAndDictionaryKeepOriginalThroughDocumentRoundTrip() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        let original = "Um, meet at 2pm, actually 3pm. Bring git hub notes."
        let rule = Replacement(heard: "git hub", written: "GitHub")
        let cleaned = TextRules.apply(DictationCleanup.light(original), replacements: [rule])
        XCTAssertEqual(cleaned, "Meet at 3pm. Bring GitHub notes.")
        let record = MobileText(title: "Meeting", original: original, text: cleaned, modified: Date(timeIntervalSinceReferenceDate: 42))
        var document = MobileDocument()
        document.texts = [record]
        document.draft = cleaned
        document.draftOriginal = original
        document.replacements = [rule]
        document.readText = cleaned
        try disk.save(document)

        let restored = try disk.load()
        XCTAssertEqual(restored, document)
        XCTAssertEqual(restored.texts.first?.original, original)
        XCTAssertEqual(restored.replacements.first?.id, rule.id)
        XCTAssertEqual(TextRules.apply("Next GIT HUB capture", replacements: restored.replacements), "Next GitHub capture")
    }

    func testExplicitNoActuallyTimeCorrectionKeepsOriginalAndNegation() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        let original = "Um, meet at 3pm, no actually 4pm. Don't bring the old notes."
        let cleaned = DictationCleanup.light(original)
        XCTAssertEqual(cleaned, "Meet at 4pm. Don't bring the old notes.")
        var document = MobileDocument()
        document.texts = [MobileText(title: "Meeting", original: original, text: cleaned)]
        try disk.save(document)
        XCTAssertEqual(try disk.load().texts.first?.original, original)
        XCTAssertEqual(try disk.load().texts.first?.text, cleaned)
        XCTAssertEqual(DictationCleanup.light("Meet at 3:30 p.m., no, actually 4:15 p.m."), "Meet at 4:15pm.")
        XCTAssertEqual(DictationCleanup.light("Meet at 3pm. No, actually I leave at 4pm."), "Meet at 3pm. No, actually I leave at 4pm.")
        XCTAssertEqual(DictationCleanup.light("Meet at 3pm.\n\nActually 4pm is when I leave."), "Meet at 3pm.\n\nActually 4pm is when I leave.")
    }

    @MainActor
    func testSpeechPreparationUsesResolvedLocaleAndNeverDownloadsDuringCheck() async throws {
        let assets = SpeechAssetFixture()
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets, recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false)
        await service.refreshAvailability()
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(service.readiness, .needsDownload)
        XCTAssertEqual(assets.installCalls, [])
        XCTAssertEqual(service.selectedLanguageID, "en-AU")
        await service.prepare()
        XCTAssertEqual(assets.installCalls, ["en-AU"])
        XCTAssertTrue(service.isReady)
        XCTAssertFalse(service.isWorking)
        XCTAssertNil(service.error)
        await service.prepare()
        XCTAssertEqual(assets.installCalls, ["en-AU"], "Already-installed assets must not request another download")
    }

    @MainActor
    func testUnavailableSpeechOffersSupportedLanguageWithoutSilentFallback() async throws {
        let assets = SpeechAssetFixture()
        let service = SpeechService(locale: Locale(identifier: "zz_ZZ"), assets: assets, recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false)
        await service.refreshAvailability()
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(service.readiness, .unavailable)
        XCTAssertFalse(service.canPrepare)
        XCTAssertEqual(assets.installCalls, [])
        XCTAssertTrue(service.languages.contains(where: { $0.id == "en-AU" }))
        await service.selectLanguage("en-AU")
        XCTAssertEqual(service.readiness, .needsDownload)
        XCTAssertNil(service.error)
        XCTAssertEqual(assets.installCalls, [], "Changing language must not download")
        assets.isAvailable = false
        await service.refreshAvailability()
        XCTAssertEqual(service.readiness, .unavailable)
        XCTAssertFalse(service.canPrepare)
    }

    @MainActor
    func testSpeechDownloadFailureIsActionableAndKeepsRecoveryMarker() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("recovery.json")
        let originalMarker = Data("{ unreadable recovery".utf8)
        try originalMarker.write(to: marker)
        let assets = SpeechAssetFixture()
        assets.failure = NSError(domain: "SpeechAssetFixture", code: 42, userInfo: [NSLocalizedDescriptionKey: "The speech asset could not be downloaded."])
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets, recoveryDirectory: directory, preferences: nil, observesInterruptions: false)
        await service.prepare()
        XCTAssertFalse(service.isReady)
        XCTAssertFalse(service.isWorking)
        XCTAssertTrue(service.canPrepare)
        XCTAssertEqual(service.readiness, .failed)
        XCTAssertTrue(service.error?.contains("could not be downloaded") == true)
        XCTAssertTrue(service.diagnosticDetail?.contains("SpeechAssetFixture (42)") == true)
        XCTAssertTrue(service.diagnosticDetail?.contains("Language: en-AU") == true)
        XCTAssertFalse(service.diagnosticDetail?.contains(directory.path) == true)
        XCTAssertTrue(service.hasRecovery)
        XCTAssertEqual(try Data(contentsOf: marker), originalMarker)
    }

    @MainActor
    func testCancelledSpeechInstallationCannotPublishLateReadinessOrProgress() async throws {
        let assets = SpeechAssetFixture()
        assets.suspendInstallation = true
        let started = expectation(description: "Installation began")
        assets.onInstall = { started.fulfill() }
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets, recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false)
        let preparation = Task { await service.prepare() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(service.isWorking)
        await service.selectLanguage("fr-FR")
        XCTAssertEqual(service.selectedLanguageID, "en-AU", "A busy invocation freezes its language")
        service.cancel()
        XCTAssertFalse(service.isWorking)
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(assets.cancelCount, 1)
        await service.selectLanguage("fr-FR")
        let phase = service.phase
        assets.publishProgress(0.9)
        assets.finishSuspendedInstallation()
        await preparation.value
        XCTAssertEqual(service.selectedLanguageID, "fr-FR")
        XCTAssertEqual(service.phase, phase)
        XCTAssertFalse(service.isReady)
        XCTAssertNil(service.downloadProgress)
        XCTAssertNil(service.error)
    }

    @MainActor
    func testInstalledLocaleCannotOverrideUnsupportedOrUnreadyConfiguredModule() async throws {
        let assets = SpeechAssetFixture()
        assets.installedLocaleOverride = true
        var waits = 0
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets,
            recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false,
            assetRecheckDelay: { waits += 1 })
        await service.refreshAvailability()
        XCTAssertFalse(service.isReady, "The locale list does not establish readiness for this exact preset")
        XCTAssertEqual(waits, 4)
        XCTAssertEqual(assets.snapshotCalls, 5)
        XCTAssertTrue(service.error?.contains("speech module is not ready") == true)
        XCTAssertTrue(service.diagnosticDetail?.contains("status=supported; installedLocales contains exact locale=true") == true)
        XCTAssertEqual(assets.installCalls, [], "Corroboration never silently requests a download")

        assets.statusSequence = [.unsupported]
        await service.refreshAvailability()
        XCTAssertEqual(service.readiness, .unavailable)
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(waits, 4, "Unsupported modules do not enter a readiness retry loop")
        XCTAssertNil(service.error)
    }

    @MainActor
    func testNilInstallationOutcomeWaitsForConfiguredModuleConvergence() async throws {
        let assets = SpeechAssetFixture()
        assets.outcome = .alreadyInstalled
        assets.installsImmediately = false
        assets.installedLocaleOverride = true
        assets.statusSequence = [.supported, .supported, .installed]
        var waits = 0
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets,
            recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false,
            assetRecheckDelay: { waits += 1 })
        await service.prepare()
        XCTAssertEqual(assets.installCalls, ["en-AU"])
        XCTAssertEqual(waits, 1)
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(service.readiness, .ready)
        XCTAssertNil(service.error)
        XCTAssertFalse(service.isRecording)
    }

    @MainActor
    func testReturnedInstallationAttemptWithUnreadyModuleStopsAfterBoundedChecks() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("recovery.json")
        let original = Data("{ unreadable recovery".utf8)
        try original.write(to: marker)
        let assets = SpeechAssetFixture()
        assets.installsImmediately = false
        var waits = 0
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets,
            recoveryDirectory: directory, preferences: nil, observesInterruptions: false,
            assetRecheckDelay: { waits += 1 })
        await service.prepare()
        XCTAssertEqual(waits, 4)
        XCTAssertEqual(assets.snapshotCalls, 6, "One initial and five post-completion snapshots")
        XCTAssertEqual(assets.installCalls, ["en-AU"], "Rechecks never repeat the installation request")
        XCTAssertFalse(service.isReady)
        XCTAssertFalse(service.isWorking)
        XCTAssertTrue(service.error?.contains("finished the first installation attempt") == true)
        XCTAssertFalse(service.error?.contains("internet connection") == true)
        XCTAssertTrue(service.diagnosticDetail?.contains("Installation outcome: downloadAttemptFinished") == true)
        XCTAssertTrue(service.diagnosticDetail?.contains("status=supported; installedLocales contains exact locale=false") == true)
        XCTAssertEqual(try Data(contentsOf: marker), original)
    }

    @MainActor
    func testNilInstallationWithoutConvergenceDoesNotPretendReady() async throws {
        let assets = SpeechAssetFixture()
        assets.outcome = .alreadyInstalled
        assets.installsImmediately = false
        assets.installedLocaleOverride = true
        var waits = 0
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets,
            recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false,
            assetRecheckDelay: { waits += 1 })
        await service.prepare()
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(waits, 4)
        XCTAssertTrue(service.diagnosticDetail?.contains("Installation outcome: alreadyInstalled") == true)
        XCTAssertTrue(service.error?.contains("reported the language already installed") == true)
        XCTAssertTrue(service.diagnosticDetail?.contains("Module: SpeechTranscriber.transcription; locale=en-AU") == true)
        XCTAssertEqual(assets.installCalls.count, 1)
    }

    @MainActor
    func testBackgroundDuringAssetRecheckRejectsLateReadinessThenRefreshes() async throws {
        let assets = SpeechAssetFixture()
        assets.outcome = .alreadyInstalled
        assets.installsImmediately = false
        assets.statusSequence = [.supported, .supported]
        let waiting = expectation(description: "Waiting for inventory convergence")
        let cancelled = expectation(description: "Background cancels preparation")
        var continuation: CheckedContinuation<Void, Never>?
        assets.onCancel = { cancelled.fulfill() }
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets,
            recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: true,
            assetRecheckDelay: {
                // Deliberately ignore cancellation until released, to verify the
                // service's generation guard rather than the fake clock's behavior.
                await withCheckedContinuation { continuation = $0; waiting.fulfill() }
            })
        let task = Task { await service.prepare() }
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertTrue(service.isWorking)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertFalse(service.isWorking)
        XCTAssertFalse(service.isReady)
        let snapshotCount = assets.snapshotCalls
        assets.statusSequence = [.installed]
        continuation?.resume(); continuation = nil
        await task.value
        XCTAssertEqual(assets.snapshotCalls, snapshotCount, "No late inventory read or readiness commit")
        XCTAssertFalse(service.isReady)
        XCTAssertNil(service.error)
        XCTAssertNil(service.diagnosticDetail)
        await service.refreshAvailability()
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(assets.installCalls, ["en-AU"], "Later foreground checks do not download")
        assets.onCancel = nil
    }

    @MainActor
    func testPreviouslyReadyReentryRechecksWithoutPersistingReadiness() async throws {
        let assets = SpeechAssetFixture()
        assets.statusSequence = [.installed, .supported, .installed]
        var waits = 0
        let service = SpeechService(locale: Locale(identifier: "en_AU"), assets: assets,
            recoveryDirectory: try temporaryDirectory(), preferences: nil, observesInterruptions: false,
            assetRecheckDelay: { waits += 1 })
        await service.refreshAvailability()
        XCTAssertTrue(service.isReady)
        await service.refreshAvailability()
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(waits, 1)
        await service.refreshAvailability()
        XCTAssertFalse(service.isReady, "Genuinely absent assets cannot inherit cached ready state")
        XCTAssertEqual(service.readiness, .needsDownload)
        XCTAssertEqual(waits, 5)
        XCTAssertEqual(assets.installCalls, [])
        XCTAssertNil(service.error)
    }

    func testSharedCorrectionPreviewPreservesWhitespaceAndLiteralPhraseBoundaries() throws {
        let source = " \nGit hub, concatenate, cat.\t "
        let proposal = try CorrectionRule.propose(heard: "git hub", written: "GitHub", draft: source, replacements: [])
        XCTAssertEqual(proposal.previewText, " \nGitHub, concatenate, cat.\t ")
        XCTAssertEqual(proposal.sourceDraft, source)
        XCTAssertEqual(proposal.matchCount, 1)
        XCTAssertEqual(TextRules.apply("cat concatenate", replacements: [Replacement(heard: "cat", written: "kitten")]), "kitten concatenate")
        XCTAssertFalse(DictationCleanup.isFaithful("Meet at 4pm.", to: "Meet at 3pm."))
        XCTAssertFalse(DictationCleanup.isFaithful("I want that.", to: "I don't want that."))
    }

    func testFirstLoadDoesNotCreateOrPopulateAUserLibrary() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        XCTAssertEqual(try disk.load(), MobileDocument())
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.manifest.path))
    }

    func testCorruptAndUnsupportedDocumentsRemainByteForByteUntouched() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        var future = MobileDocument(); future.version = 2
        var otherFormat = MobileDocument(); otherFormat.format = "unrelated-document"
        let inputs = [Data("{ unfinished".utf8), try JSONEncoder().encode(future), try JSONEncoder().encode(otherFormat)]
        for bytes in inputs {
            try bytes.write(to: disk.manifest)
            XCTAssertThrowsError(try disk.load())
            XCTAssertEqual(try Data(contentsOf: disk.manifest), bytes)
        }
    }

    func testRejectedSaveKeepsExistingManifestAndOriginals() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        var original = MobileDocument()
        original.texts = [MobileText(title: "Keep", original: "Original words", text: "Reviewed words")]
        try disk.save(original)
        let bytes = try Data(contentsOf: disk.manifest)
        var invalid = original
        invalid.draft = String(repeating: "x", count: 50_001)
        XCTAssertThrowsError(try disk.save(invalid))
        XCTAssertEqual(try Data(contentsOf: disk.manifest), bytes)
        XCTAssertEqual(try disk.load(), original)
    }

    func testDuplicateRecordIdentitiesAreRejected() throws {
        let text = MobileText(title: "Same identity", original: "First", text: "First")
        var document = MobileDocument(); document.texts = [text, text]
        XCTAssertThrowsError(try document.validated())
        document.texts = []
        let image = MobileImageProject(title: "Same identity", kind: .markup, asset: "original.png")
        document.images = [image, image]
        XCTAssertThrowsError(try document.validated())
    }

    func testAssetNamesCannotEscapeTheAssetDirectory() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        for name in ["", ".", "..", "../original.png", "/tmp/original.png", "nested/original.png", "nested\\original.png", "a\nb.png", "%2e%2e.png", String(repeating: "x", count: 100)] {
            XCTAssertFalse(MobileDocument.safeAsset(name), name)
            XCTAssertNil(disk.assetURL(name), name)
            var document = MobileDocument()
            document.images = [MobileImageProject(title: "Imported", kind: .wallpaper, asset: name)]
            XCTAssertThrowsError(try document.validated(), name)
        }
        for name in ["original.png", UUID().uuidString + ".m4a", "café-1.png"] {
            XCTAssertTrue(MobileDocument.safeAsset(name), name)
            XCTAssertEqual(disk.assetURL(name)?.deletingLastPathComponent(), disk.assets)
        }
        for suffix in ["../png", "png/../../other", "exe"] {
            XCTAssertThrowsError(try disk.importAsset(Data([1, 2, 3]), suffix: suffix))
        }
        XCTAssertThrowsError(try disk.importAsset(Data(), suffix: "png"))
    }

    func testImportedAssetsHaveIndependentNamesAndKeepExactOriginalBytes() throws {
        let disk = MobileDocumentStore(directory: try temporaryDirectory())
        let firstBytes = Data([0, 1, 2, 3, 255])
        let secondBytes = Data([9, 8, 7])
        let first = try disk.importAsset(firstBytes, suffix: "audio")
        let second = try disk.importAsset(secondBytes, suffix: "audio")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(disk.assetURL(first))), firstBytes)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(disk.assetURL(second))), secondBytes)
    }

    func testSavedCropValidationRejectsNonfiniteAndOutOfRangeValues() throws {
        let valid = MobileImageProject(title: "Crop", kind: .wallpaper, asset: "original.png")
        let invalidEdits: [(inout MobileImageProject) -> Void] = [
            { $0.zoom = 0.9 }, { $0.zoom = 5.1 }, { $0.zoom = .nan },
            { $0.centerX = -0.01 }, { $0.centerX = .infinity },
            { $0.centerY = 1.01 }, { $0.centerY = .nan },
            { $0.wallpaperAspect = 0.39 }, { $0.wallpaperAspect = 1.51 }
        ]
        for edit in invalidEdits {
            var image = valid; edit(&image)
            var document = MobileDocument(); document.images = [image]
            XCTAssertThrowsError(try document.validated())
        }
        var document = MobileDocument(); document.images = [valid]
        XCTAssertNoThrow(try document.validated())
    }

    @MainActor
    func testCropAlwaysCoversCanvasWithoutStretchingAtEdgesAndCorners() {
        let images = [CGSize(width: 4000, height: 1000), CGSize(width: 1000, height: 4000), CGSize(width: 1000, height: 1000)]
        let canvases = [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)]
        let centers: [(Double, Double)] = [(0, 0), (0.5, 0.5), (1, 1), (0, 1), (1, 0)]
        for image in images {
            for canvas in canvases {
                for zoom in [1.0, 2.5, 5.0] {
                    for (x, y) in centers {
                        let frame = MobileImageRenderer.cropRect(image: image, canvas: canvas, zoom: zoom, centerX: x, centerY: y)
                        XCTAssertLessThanOrEqual(frame.minX, 0.0001)
                        XCTAssertLessThanOrEqual(frame.minY, 0.0001)
                        XCTAssertGreaterThanOrEqual(frame.maxX, canvas.width - 0.0001)
                        XCTAssertGreaterThanOrEqual(frame.maxY, canvas.height - 0.0001)
                        XCTAssertEqual(frame.width / frame.height, image.width / image.height, accuracy: 0.0001)
                    }
                }
            }
        }
        XCTAssertEqual(MobileImageRenderer.cropRect(image: .zero, canvas: canvases[0], zoom: 1, centerX: 0.5, centerY: 0.5), .zero)
    }

    @MainActor
    func testRendererExportsEachJobsAspectAtBoundedPixelDimensions() throws {
        let background = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }
        let expected: [(MobileImageKind, CGSize)] = [
            (.markup, CGSize(width: 320, height: 200)),
            (.backdrop, CGSize(width: 320, height: 180)),
            (.wallpaper, CGSize(width: 160, height: 320))
        ]
        for (kind, size) in expected {
            var project = MobileImageProject(title: "Synthetic", kind: kind, asset: "fixture.png")
            project.wallpaperAspect = 0.5
            let rendered = try MobileImageRenderer.render(project: project, background: background, maxDimension: 320)
            let pixels = try XCTUnwrap(rendered.cgImage)
            XCTAssertEqual(pixels.width, Int(size.width))
            XCTAssertEqual(pixels.height, Int(size.height))
            XCTAssertEqual(rendered.scale, 1)
        }
        XCTAssertEqual(background.size, CGSize(width: 640, height: 400))
    }

    @MainActor
    func testRendererRejectsMissingLayersAndUnreadableInkInsteadOfSilentlyDroppingThem() throws {
        let background = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        var backdrop = MobileImageProject(title: "Missing layer", kind: .backdrop, asset: "fixture.png")
        backdrop.foregroundAsset = "unavailable.png"
        XCTAssertThrowsError(try MobileImageRenderer.render(project: backdrop, background: background, maxDimension: 100))
        var markup = MobileImageProject(title: "Unreadable drawing", kind: .markup, asset: "fixture.png")
        markup.drawing = Data("not a PencilKit drawing".utf8)
        XCTAssertThrowsError(try MobileImageRenderer.render(project: markup, background: background, maxDimension: 100))
    }

    @MainActor
    func testUpdatingSavedTextPreservesItsIdentityOriginalAndAudio() throws {
        let directory = try temporaryDirectory()
        let store = MobileStore(directory: directory)
        let audio = directory.appendingPathComponent("fixture.m4a")
        let originalAudio = Data([0, 1, 5, 9])
        try originalAudio.write(to: audio)
        let id = try XCTUnwrap(store.saveText("Reviewed words", original: "Um, original words", audioURL: audio))
        let audioAsset = try XCTUnwrap(store.document.texts.first?.audioAsset)
        XCTAssertEqual(store.saveText("Later manual edit", original: "Do not replace the original", id: id), id)
        XCTAssertEqual(store.document.texts.count, 1)
        XCTAssertEqual(store.document.texts.first?.original, "Um, original words")
        XCTAssertEqual(store.document.texts.first?.text, "Later manual edit")
        XCTAssertEqual(store.document.texts.first?.audioAsset, audioAsset)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.disk.assetURL(audioAsset))), originalAudio)
        XCTAssertEqual(try store.disk.load(), store.document)
    }

    @MainActor
    func testPasteKeepsPreviousDraftAndOriginalInOneCommit() throws {
        let directory = try temporaryDirectory()
        let store = MobileStore(directory: directory)
        XCTAssertTrue(store.change { $0.draft = "Earlier edited words"; $0.draftOriginal = "Earlier original" })
        XCTAssertTrue(store.replaceDraftWithPaste("New pasted words", preserving: "Earlier edited words", original: "Earlier original", savedID: nil))
        XCTAssertEqual(store.document.draft, "New pasted words")
        XCTAssertEqual(store.document.draftOriginal, "New pasted words")
        XCTAssertEqual(store.document.texts.count, 1)
        let saved = try XCTUnwrap(store.document.texts.first)
        XCTAssertEqual(saved.text, "Earlier edited words")
        XCTAssertEqual(saved.original, "Earlier original")
        XCTAssertEqual(try store.disk.load(), store.document)
        // Updating an existing saved capture must retain identity and original.
        XCTAssertTrue(store.replaceDraftWithPaste("Second paste", preserving: "Latest manual edit", original: "Should not replace original", savedID: saved.id))
        XCTAssertEqual(store.document.texts.count, 1)
        XCTAssertEqual(store.document.texts.first?.id, saved.id)
        XCTAssertEqual(store.document.texts.first?.original, "Earlier original")
        XCTAssertEqual(store.document.texts.first?.text, "Latest manual edit")
        XCTAssertEqual(MobileStore(directory: directory).document, store.document)
    }

    @MainActor
    func testPasteFailureOrEmptyPayloadKeepsDraftAndLibraryUntouched() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("PasteLibrary")
        let store = MobileStore(directory: directory)
        XCTAssertTrue(store.change { $0.draft = "Keep me"; $0.draftOriginal = "Original words" })
        let before = store.document
        XCTAssertFalse(store.replaceDraftWithPaste("  ", preserving: "Keep me", original: "Original words", savedID: nil))
        XCTAssertFalse(store.replaceDraftWithPaste(String(repeating: "x", count: 50_001), preserving: "Keep me", original: "Original words", savedID: nil))
        XCTAssertEqual(store.document, before)
        let bytes = try Data(contentsOf: store.disk.manifest)
        let retained = root.appendingPathComponent("PasteRetained")
        try FileManager.default.moveItem(at: directory, to: retained)
        try Data("blocked directory".utf8).write(to: directory)
        XCTAssertFalse(store.replaceDraftWithPaste("Replacement", preserving: "Keep me", original: "Original words", savedID: nil))
        XCTAssertEqual(store.document, before)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("library.json")), bytes)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: retained, to: directory)
        XCTAssertTrue(store.replaceDraftWithPaste("Replacement", preserving: "Keep me", original: "Original words", savedID: nil))
        XCTAssertEqual(store.document.texts.count, 1)
        XCTAssertEqual(try store.disk.load().texts.first?.text, "Keep me")
    }

    @MainActor
    func testFailedDiskCommitDoesNotPublishNewState() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("Library")
        let store = MobileStore(directory: directory)
        XCTAssertNotNil(store.saveText("Keep this draft", original: "Keep this original"))
        let before = store.document
        let bytes = try Data(contentsOf: store.disk.manifest)
        let retained = root.appendingPathComponent("Retained")
        try FileManager.default.moveItem(at: directory, to: retained)
        // A regular file at the directory path causes a deterministic filesystem
        // failure without changing permissions or touching any existing app data.
        try Data("blocked directory".utf8).write(to: directory)
        XCTAssertFalse(store.change { $0.draft = "Must not be published" })
        XCTAssertEqual(store.document, before)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("library.json")), bytes)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: retained, to: directory)
        XCTAssertTrue(store.change { $0.draft = "Retry succeeds" })
        XCTAssertEqual(try store.disk.load().draft, "Retry succeeds")
        XCTAssertEqual(store.document.texts, before.texts)
    }

    @MainActor
    func testUnreadableLibraryPausesWritesInsteadOfReplacingItWithDefaults() throws {
        let directory = try temporaryDirectory()
        let disk = MobileDocumentStore(directory: directory)
        var future = MobileDocument(); future.version = 99
        for bytes in [Data("invalid json".utf8), try JSONEncoder().encode(future)] {
            try bytes.write(to: disk.manifest)
            let store = MobileStore(directory: directory)
            XCTAssertTrue(store.writesDisabled)
            XCTAssertNotNil(store.error)
            XCTAssertFalse(store.change { $0.draft = "Do not overwrite" })
            XCTAssertNil(store.saveText("Do not overwrite", original: "Do not overwrite"))
            XCTAssertEqual(try Data(contentsOf: disk.manifest), bytes)
        }
    }

    @MainActor
    func testReplacingOrRepairingBackgroundPreservesInkLayersAndProjectIdentityAfterReload() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let ink = PKDrawing(strokes: [stroke]).dataRepresentation()

        for kind in MobileImageKind.allCases {
            for isRepair in [false, true] {
                let store = MobileStore(directory: try temporaryDirectory())
                let originalAsset = try store.disk.importAsset(bytes, suffix: "png")
                let originalURL = try XCTUnwrap(store.disk.assetURL(originalAsset))
                var project = MobileImageProject(title: "Keep this project", kind: kind, asset: originalAsset)
                project.drawing = ink
                project.foregroundAsset = try store.disk.importAsset(bytes, suffix: "png")
                project.logoAsset = try store.disk.importAsset(bytes, suffix: "png")
                project.personaAsset = try store.disk.importAsset(bytes, suffix: "png")
                project.caption = "Keep this caption"
                project.wallpaperAspect = 0.75
                project.zoom = 3; project.centerX = 0.2; project.centerY = 0.8
                XCTAssertTrue(store.updateImage(project))
                let original = try XCTUnwrap(store.document.images.first)
                if isRepair { try FileManager.default.removeItem(at: originalURL) }
                let replacement = try store.disk.importAsset(bytes, suffix: "png")

                project.replaceBackground(with: replacement)
                XCTAssertTrue(store.updateImage(project))

                let restored = try store.disk.load()
                XCTAssertEqual(restored.images.count, 1)
                let repaired = try XCTUnwrap(restored.images.first)
                XCTAssertEqual(repaired.id, original.id)
                XCTAssertEqual(repaired.kind, original.kind)
                XCTAssertEqual(repaired.title, original.title)
                XCTAssertEqual(repaired.asset, replacement)
                XCTAssertEqual(repaired.drawing, ink)
                XCTAssertEqual(try PKDrawing(data: XCTUnwrap(repaired.drawing)).strokes.count, 1)
                XCTAssertEqual(repaired.foregroundAsset, original.foregroundAsset)
                XCTAssertEqual(repaired.logoAsset, original.logoAsset)
                XCTAssertEqual(repaired.personaAsset, original.personaAsset)
                XCTAssertEqual(repaired.caption, original.caption)
                XCTAssertEqual(repaired.wallpaperAspect, original.wallpaperAspect)
                XCTAssertEqual(repaired.zoom, 1)
                XCTAssertEqual(repaired.centerX, 0.5)
                XCTAssertEqual(repaired.centerY, 0.5)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.disk.assetURL(replacement))), bytes)
                if !isRepair { XCTAssertEqual(try Data(contentsOf: originalURL), bytes) }
            }
        }
    }

    @MainActor
    func testDrawingToolsRequestFocusOnlyWhenActivated() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let canvas = FocusRecordingCanvas()
        window.addSubview(canvas)
        let controls = MobileDrawingControls()
        func drawingView(toolsVisible: Bool, isEnabled: Bool = true) -> MobileDrawingCanvas {
            MobileDrawingCanvas(image: UIImage(), data: .constant(nil), toolsVisible: toolsVisible,
                                isEnabled: isEnabled, controls: controls, onError: { _ in })
        }
        let coordinator = drawingView(toolsVisible: true).makeCoordinator()
        coordinator.canvas = canvas
        coordinator.updateTools()
        XCTAssertEqual(canvas.focusRequests, 1)

        // SwiftUI updates the representable while the user types a project name.
        for _ in 0..<3 {
            coordinator.parent = drawingView(toolsVisible: true)
            coordinator.updateTools()
        }
        XCTAssertEqual(canvas.focusRequests, 1)
        coordinator.parent = drawingView(toolsVisible: false)
        coordinator.updateTools()
        coordinator.updateTools()
        XCTAssertEqual(canvas.releaseRequests, 1)
        coordinator.parent = drawingView(toolsVisible: true)
        coordinator.updateTools()
        XCTAssertEqual(canvas.focusRequests, 2)
        coordinator.parent = drawingView(toolsVisible: true, isEnabled: false)
        coordinator.updateTools()
        XCTAssertEqual(canvas.releaseRequests, 2)
        canvas.removeFromSuperview()
    }

    @MainActor
    private final class FocusRecordingCanvas: PKCanvasView {
        var focusRequests = 0
        var releaseRequests = 0
        override func becomeFirstResponder() -> Bool { focusRequests += 1; return true }
        override func resignFirstResponder() -> Bool { releaseRequests += 1; return true }
    }

    @MainActor
    func testReusingImageSharesOriginalAssetButKeepsEachProjectsEditsIndependent() throws {
        let store = MobileStore(directory: try temporaryDirectory())
        let originalBytes = Data([1, 4, 9, 16])
        let asset = try store.disk.importAsset(originalBytes, suffix: "image")
        var original = MobileImageProject(title: "Shared original", kind: .backdrop, asset: asset)
        original.zoom = 2; original.centerX = 0.2; original.caption = "Presentation only"
        XCTAssertTrue(store.updateImage(original))
        let savedOriginal = try XCTUnwrap(store.document.images.first { $0.id == original.id })
        var wallpaper = try XCTUnwrap(store.reuse(savedOriginal, as: .wallpaper))
        XCTAssertNotEqual(wallpaper.id, savedOriginal.id)
        XCTAssertEqual(wallpaper.asset, savedOriginal.asset)
        XCTAssertEqual(wallpaper.zoom, 1)
        XCTAssertEqual(wallpaper.centerX, 0.5)
        XCTAssertEqual(wallpaper.caption, "")
        wallpaper.zoom = 3; wallpaper.centerY = 0.8
        XCTAssertTrue(store.updateImage(wallpaper))
        XCTAssertEqual(store.document.images.first { $0.id == savedOriginal.id }, savedOriginal)
        store.deleteImage(wallpaper.id)
        XCTAssertEqual(store.document.images, [savedOriginal])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.disk.assetURL(asset))), originalBytes)
    }
}
