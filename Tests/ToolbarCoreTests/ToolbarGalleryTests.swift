import XCTest
@testable import ToolbarCore

/// The gallery is the review surface for the look. These checks keep it honest:
/// a visual state that is not in here has never been looked at in both themes.
final class ToolbarGalleryTests: XCTestCase {
    func testEveryFixtureHasAUniqueStableName() {
        let names = ToolbarGallery.states.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        // These become snapshot filenames, and the disk is case-insensitive.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(name.unicodeScalars.allSatisfy(safe.contains), name)
        }
    }

    func testSlugsStayUniqueOnACaseInsensitiveDisk() {
        XCTAssertEqual(Set(ToolbarMode.allCases.map(\.slug)).count, ToolbarMode.allCases.count)
        XCTAssertEqual(Set(ToolbarAnchor.allCases.map(\.slug)).count, ToolbarAnchor.allCases.count)
    }

    func testEveryTierDockAndModeIsRepresented() {
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.tier)), Set(ToolbarTier.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.anchor)), Set(ToolbarAnchor.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.mode)), Set(ToolbarMode.allCases))
        for mode in ToolbarMode.allCases {
            let tiers = ToolbarGallery.modes.filter { $0.mode == mode }.map(\.tier)
            XCTAssertEqual(Set(tiers), Set(ToolbarTier.allCases), mode.rawValue)
        }
    }

    func testBothTiersAppearAtEveryDock() {
        for anchor in ToolbarAnchor.allCases {
            let tiers = ToolbarGallery.placements.filter { $0.anchor == anchor }.map(\.tier)
            XCTAssertEqual(Set(tiers), Set(ToolbarTier.allCases), anchor.rawValue)
        }
    }

    func testUnusableBindingsNeverBecomeHoverText() {
        let kinds: [ToolbarShortcut] = [.off, .unavailable, .assigned("⌃⌥Space")]
        XCTAssertEqual(Set(kinds.map(\.label)).count, 3, "off, failed and assigned must not read the same")
        XCTAssertNil(ToolbarShortcut.off.hintKey)
        XCTAssertNil(ToolbarShortcut.unavailable.hintKey)
        XCTAssertEqual(ToolbarShortcut.assigned("⌃⌥Space").hintKey, "⌃⌥Space")
        for state in ToolbarGallery.states {
            XCTAssertNotEqual(state.actionHint, ToolbarShortcut.off.label, state.name)
            XCTAssertNotEqual(state.actionHint, ToolbarShortcut.unavailable.label, state.name)
        }
    }

    func testActiveWorkReplacesTheStartActionRatherThanAddingToIt() {
        let drawing = ToolbarGallery.activity.first { $0.name == "activity-drawing" }
        XCTAssertEqual(drawing?.actionTitle, "Stop drawing")
        XCTAssertNotEqual(drawing?.actionTitle, ToolbarMode.draw.title)
        XCTAssertEqual(ToolbarGallery.activity.first { $0.name == "activity-presenting" }?.actionTitle, "End presentation")
        XCTAssertEqual(ToolbarGallery.activity.first { $0.name == "activity-personas" }?.actionTitle, "Hide personas")
    }

    /// Work started from a key while another tool is chosen: the label follows the work, the
    /// chosen tool stays unlit and the chooser's row for that work lights instead (#134).
    func testWorkInAnotherToolLightsItsChooserRow() throws {
        let state = try XCTUnwrap(ToolbarGallery.activity.first { $0.name == "activity-drawing-in-dictate" })
        XCTAssertEqual(state.mode, .dictate)
        XCTAssertEqual(state.actionTitle, "Stop drawing")
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.choices.filter(\.isLive).map(\.mode), [.draw])
        XCTAssertEqual(state.choices.filter(\.isSelected).map(\.mode), [.dictate], "one chosen tool, checked in the chooser")
        XCTAssertTrue(state.hasLiveWork, "the launcher's one aggregate indicator shows other work")
        XCTAssertEqual(state.launcherDescription, "Dictate. Also running: Draw")
    }

    /// A mode's own ending claims the label only in that mode.
    func testAnotherModesEndingLightsItsChipAndKeepsTheStartVerb() throws {
        let state = try XCTUnwrap(ToolbarGallery.activity.first { $0.name == "activity-presenting-in-draw" })
        XCTAssertEqual(state.mode, .draw)
        XCTAssertEqual(state.actionTitle, "Draw")
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.choices.filter(\.isLive).map(\.mode), [.present])
    }

    func testTheCountLivesInTheLabelAndTheKeyInTheHint() {
        let between = ToolbarGallery.idle.first { $0.name == "idle-session-open" }
        XCTAssertEqual(between?.actionTitle, "Capture next · 3")
        XCTAssertEqual(between?.actionHint, "⌥C")
        XCTAssertEqual(between?.isBusy, false, "a saved session does not pretend to be recording")
        let saving = ToolbarGallery.activity.first { $0.name == "activity-transcribing" }
        XCTAssertEqual(saving?.actionHint, "saving · ⌥C")
        XCTAssertEqual(saving?.isBusy, true)
        XCTAssertEqual(ToolbarGallery.activity.first { $0.name == "activity-presenting" }?.accessoryTitle, "Prompts")
        XCTAssertNil(ToolbarGallery.modes.first { $0.mode == .dictate }?.accessoryTitle)
    }

    /// At rest every state is the compact mark, and running work shows on it without hovering:
    /// its indicator is never idle while something runs, in the chosen tool or another (#134).
    func testRunningWorkIsVisibleWithoutHovering() {
        let resting = ToolbarGallery.activity.filter { $0.tier == .resting }
        XCTAssertFalse(resting.isEmpty, "the compact rest must be reviewed with work running too")
        for state in resting { XCTAssertNotEqual(state.status.indicator, .idle, state.name) }
        let idle = ToolbarGallery.modes.filter { $0.tier == .resting }
        XCTAssertTrue(idle.allSatisfy { $0.status == .idle }, "an idle tool's rest shows nothing but the mark")
    }

    /// Every compact indicator is reviewed, in both themes and at both text sizes.
    func testEveryCompactIndicatorHasAFixture() {
        let shown = Set(ToolbarGallery.statuses.map { "\($0.status.indicator)" })
        for indicator in ["capture", "playback", "processing", "failure", "pendingDelivery", "unsavedCapture", "paused"] {
            XCTAssertTrue(shown.contains(indicator), indicator)
        }
        XCTAssertTrue(ToolbarGallery.statuses.contains { $0.status.attentionBadge }, "recording with a job that needs attention")
        XCTAssertTrue(ToolbarGallery.statuses.contains { $0.status.stopsSoonBadge }, "recording in its last seconds")
        XCTAssertTrue(ToolbarGallery.statuses.contains { if case .live = $0.status.indicator { return true }; return false })
        XCTAssertTrue(ToolbarGallery.statuses.allSatisfy { $0.tier == .resting })
    }

    /// A finished break timer rests as nothing running: it is neither live work nor paused (#205 review).
    func testAFinishedTimerRestsAsNothingRunning() throws {
        let finished = try XCTUnwrap(ToolbarGallery.states.first { $0.name == "idle-timer-finished-resting" })
        XCTAssertEqual(finished.status.indicator, .idle, finished.status.description)
        XCTAssertEqual(ToolbarGallery.activity(ToolbarLiveState(mode: .dictate, timer: .paused)).paused, true)
        XCTAssertEqual(ToolbarGallery.activity(ToolbarLiveState(mode: .dictate, timer: .running)).live, [.timer])
    }

    /// Dictation, narration and reading are the row's own work now (#134 T4): revealed, the row's
    /// next action stops, pauses or resumes them, and at rest they are the compact mark.
    func testRecordingAndReadingRenderInTheSameRow() {
        func state(_ name: String) -> ToolbarViewState? { ToolbarGallery.states.first { $0.name == name } }
        XCTAssertEqual(state("recording-dictation")?.actionTitle, "Finish dictation")
        XCTAssertEqual(state("recording-dictation")?.status.indicator, .capture)
        XCTAssertEqual(state("recording-dictation-in-present")?.actionTitle, "Finish dictation", "the recording claims the button in any tool")
        XCTAssertEqual(state("recording-processing")?.isActionEnabled, false)
        XCTAssertEqual(state("recording-narration")?.actionTitle, "Stop narration")
        XCTAssertEqual(state("reading-playing")?.actionTitle, "Stop reading")
        XCTAssertEqual(state("reading-paused")?.actionTitle, "Stop reading", "Resume reading stays in the chooser's Read row")
        XCTAssertEqual(state("recording-dictation-stops-soon")?.status.stopsSoonBadge, true)
        XCTAssertEqual(state("recording-dictation-stops-soon-attention")?.status.badges, [.stopsSoon, .attention], "both badges, in the launcher too")
        XCTAssertEqual(state("recording-waiting-for-drawing")?.actionTitle, "Stop drawing", "words waiting for drawing (#211 F5)")
        XCTAssertEqual(state("recording-waiting-for-drawing")?.status.indicator, .pendingDelivery)
        for resting in ToolbarGallery.recording.filter({ $0.tier == .resting }) {
            XCTAssertNotEqual(resting.status.indicator, .idle, "\(resting.name) rests with its status")
        }
    }

    /// A result waiting for the person is reviewed as keyboard entry shows it: the launcher row,
    /// revealed, carrying the result's status (#211 F1).
    func testAWaitingResultIsReviewedOnTheLauncherRow() {
        XCTAssertEqual(ToolbarGallery.waiting.map(\.tier), [.revealed, .revealed])
        XCTAssertEqual(ToolbarGallery.waiting.map(\.status.indicator), [.failure, .pendingDelivery])
    }

    /// Each tool's one accessory, when it applies (#134 part B): Snap & Talk's Review once a
    /// session is open, Draw's Tools, Present's Prompts, and Persona's Appearance for a selected
    /// live copy, shown or hidden. Dictate, Read and Snap have none, whatever else is live.
    func testEachToolOffersOnlyItsOwnAccessory() {
        func offered(_ live: ToolbarLiveState, copy: Bool = false) -> ToolbarAccessory? {
            ToolbarAccessory.offered(for: live, selectedPersonaCopy: copy)
        }
        XCTAssertNil(offered(ToolbarLiveState(mode: .snapAndTalk)), "no session, nothing to review")
        XCTAssertEqual(offered(ToolbarLiveState(mode: .snapAndTalk, captureCount: 0)), .review, "an open session, before its first capture")
        XCTAssertEqual(offered(ToolbarLiveState(mode: .snapAndTalk, narrating: true, captureCount: 3)), .review, "while narrating")
        XCTAssertEqual(offered(ToolbarLiveState(mode: .draw)), .tools)
        XCTAssertEqual(offered(ToolbarLiveState(mode: .draw, drawing: true)), .tools)
        XCTAssertEqual(offered(ToolbarLiveState(mode: .present, presenting: true)), .prompts)
        XCTAssertEqual(offered(ToolbarLiveState(mode: .persona)), .personaPicker, "nothing live: the cards and the camera are one click away")
        for camera in [ToolbarLiveState.Persona.cameraStarting, .cameraShown, .cameraHidden, .cameraFailed] {
            XCTAssertEqual(offered(ToolbarLiveState(mode: .persona, persona: camera)), .personaPicker, "the camera is one of Persona's choices: \(camera)")
        }
        XCTAssertNil(offered(ToolbarLiveState(mode: .persona, persona: .session)), "a live set with no copy selected")
        XCTAssertEqual(offered(ToolbarLiveState(mode: .persona, persona: .shown), copy: true), .personaPicker)
        XCTAssertNil(offered(ToolbarLiveState(mode: .persona, persona: .sessionHidden), copy: true), "show a hidden set before cycling")
        XCTAssertEqual(offered(ToolbarLiveState(mode: .persona), copy: true), .personaPicker, "a kept card is chosen again from the same picker")
        // Whatever is live elsewhere, a tool offers only its own accessory, and these three none.
        for mode in ToolbarMode.allCases {
            let states = [ToolbarLiveState(mode: mode), ToolbarLiveState(mode: mode, dictation: .recording),
                          ToolbarLiveState(mode: mode, reading: .playing, narrating: true, captureCount: 2),
                          ToolbarLiveState(mode: mode, drawing: true, presenting: true, persona: .shown, timer: .running)]
            for live in states {
                for copy in [false, true] {
                    let accessory = offered(live, copy: copy)
                    XCTAssertTrue(accessory == nil || accessory?.mode == mode, "\(mode): \(String(describing: accessory))")
                    if [.dictate, .read, .snap].contains(mode) { XCTAssertNil(accessory, "\(mode) has no accessory") }
                }
            }
        }
        XCTAssertEqual(ToolbarAccessory.allCases.map(\.title), ["Review", "Tools", "Prompts", "Choose Persona"])
        // Appearance carries the Persona menus' word, and VoiceOver hears whose it is (#169).
        XCTAssertEqual(ToolbarAccessory.appearanceDescription(copyHidden: false), "Appearance of the selected persona")
        XCTAssertEqual(ToolbarAccessory.appearanceDescription(copyHidden: true), "Appearance of the selected persona, hidden")
        XCTAssertEqual(Set(ToolbarAccessory.allCases.map(\.mode)).count, ToolbarAccessory.allCases.count, "at most one accessory per tool")
        XCTAssertEqual(ToolbarAccessory.allCases.filter { !$0.opensList }, [.review], "Review goes to the review; the rest open a list")
    }

    /// Every accessory is reviewed in the gallery, each only with its own tool, Appearance also
    /// hidden and at a right-hand dock.
    func testEveryAccessoryHasAFixture() {
        XCTAssertEqual(Set(ToolbarGallery.states.compactMap(\.accessory)), Set(ToolbarAccessory.allCases))
        for state in ToolbarGallery.states {
            if let accessory = state.accessory { XCTAssertEqual(accessory.mode, state.mode, state.name) }
        }
        let modes = Dictionary(uniqueKeysWithValues: ToolbarGallery.modes.filter { $0.tier == .revealed }.map { ($0.mode, $0.accessory) })
        XCTAssertEqual(modes, [.dictate: nil, .read: nil, .snap: nil, .snapAndTalk: nil, .draw: .tools, .present: .prompts, .persona: .personaPicker],
                       "idle, Draw and Present show theirs, Persona offers its cards and camera, and nothing else has one to show")
        let hidden = ToolbarGallery.states.first { $0.name == "accessory-persona-hidden" }
        XCTAssertEqual(hidden?.accessory, .personaPicker, "a kept card is chosen again from the picker")
        XCTAssertNil(hidden?.quickControl, "Next waits until the card shows")
        XCTAssertEqual(ToolbarGallery.states.first { $0.name == "accessory-persona-camera" }?.accessoryDescription, "Choose Persona · Camera")
        XCTAssertTrue(ToolbarGallery.accessories.contains { $0.accessory == .personaPicker && $0.anchor.growsLeftward })
    }

    /// The row is a glance, not a sentence. The label budget is the next action's.
    func testEveryLabelStaysAGlance() {
        for state in ToolbarGallery.states {
            XCTAssertFalse(state.actionTitle.isEmpty, state.name)
            XCTAssertLessThanOrEqual(state.actionTitle.count, ToolbarNextAction.titleBudget, state.name)
            XCTAssertEqual(state.choices.map(\.mode), ToolbarMode.allCases, "the chooser always lists all seven tools, in order: \(state.name)")
            XCTAssertEqual(state.choices.filter(\.isSelected).map(\.mode), [state.mode], state.name)
        }
    }

    func testARowGrowsInwardFromItsDockedEdge() {
        XCTAssertEqual(ToolbarAnchor.allCases.filter(\.growsLeftward), [.topRight, .right, .bottomRight])
    }

    func testEachModeKeepsOneSymbolAndOnePageAcrossEverySurface() {
        let symbols = ToolbarMode.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertEqual(ToolbarMode.draw.page, "annotate")
        XCTAssertEqual(ToolbarMode.read.page, "speak")
        XCTAssertEqual(ToolbarMode.snapAndTalk.page, "readback")
        XCTAssertEqual(ToolbarMode.persona.page, "personas")
    }
}
