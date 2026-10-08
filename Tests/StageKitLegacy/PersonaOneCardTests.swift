import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Show one card from a disposable library. Only the requested card is decoded and
/// checked, so unrelated missing, large or numerous saved items never block it, and
/// cycling passes over a card that cannot show while the shown card stays up.
final class PersonaOneCardTests {
    private struct Card {
        var side = 48
        var red: CGFloat = 0.2
        var label: String? = nil
        var missing = false
    }
    private struct Fixture {
        let root: URL
        let library: PersonaLibrary
        let items: [SavedPersona]
        func url(_ index: Int) -> URL { root.appendingPathComponent(items[index].image) }
    }
    /// Prepared sessions draw into these instead of windows over the desktop.
    private final class Panel: PersonaSessionDisplaying {
        func setVoiceRing(_ on: Bool) {}
        func setVoiceColor(_ color: InkColor) {}
        func showVoice(_ frames: [PersonaVoiceFrame]) {}
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 120)
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState { state }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) {}
        func hide() {}
        func shutdown() {}
    }

    private func fixture(_ cards: [Card], group: [Int]? = nil, selected: Int = 0, budget: Int? = nil, panels: Bool = false) throws -> Fixture {
        let (root, items) = try write(cards, group: group, selected: selected)
        let library = PersonaLibrary(root: root, sessionPanelFactory: panels ? { Panel() } : nil, sessionHUDEnabled: false)
        library.usesSharedControls = true
        if let budget { library.cardImageBudget = budget }
        return Fixture(root: root, library: library, items: items)
    }
    /// Writes the images and the library record directly, so large fixtures skip import processing.
    private func write(_ cards: [Card], group: [Int]? = nil, selected: Int = 0) throws -> (URL, [SavedPersona]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaOneCard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var encoded: [String: Data] = [:]
        let items = try cards.enumerated().map { index, card -> SavedPersona in
            let item = SavedPersona(name: "Private library name \(index)", image: "persona-\(UUID().uuidString).png",
                                    card: card.label.map { PersonaCardStyle(label: $0) })
            if !card.missing {
                let key = "\(card.side)-\(card.red)"
                let data = try encoded[key] ?? png(side: card.side, red: card.red)
                encoded[key] = data
                try data.write(to: root.appendingPathComponent(item.image))
            }
            return item
        }
        var archive = PersonaArchive(items: items, selectedID: items[selected].id)
        if let group {
            let members = PersonaGroup(name: "Private customer group", personaIDs: group.map { items[$0].id })
            archive.groups = [members]; archive.activeGroupID = members.id
        }
        try JSONEncoder().encode(archive).write(to: root.appendingPathComponent("persona-library.json"))
        return (root, items)
    }
    private func cleanup(_ fixture: Fixture) { fixture.library.shutdown(); try? FileManager.default.removeItem(at: fixture.root) }
    private func png(side: Int, red: CGFloat) throws -> Data {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PersonaError.unreadableImage }
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PersonaError.unreadableImage }
        return data as Data
    }
    private func image(side: Int) -> NSImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: side, height: side)) }
    }
    private func failure(_ menu: NSMenu) -> String? { menu.items.first.flatMap { $0.isEnabled || $0.hasSubmenu ? nil : $0.title } }
    private func selected(_ fixture: Fixture) throws -> UUID? {
        try JSONDecoder().decode(PersonaArchive.self, from: Data(contentsOf: fixture.root.appendingPathComponent("persona-library.json"))).selectedID
    }

    func testOneCardShowsDespiteManyMissingOrLargeUnrelatedItems() throws {
        let many = try fixture(Array(repeating: Card(), count: 33), selected: 7)
        defer { cleanup(many) }
        try many.library.showOverlay().get()
        XCTAssertTrue(many.library.overlayVisible, "33 saved cards no longer block one card")
        XCTAssertEqual(many.library.liveSelection?.currentID, many.items[7].id)
        XCTAssertEqual(many.library.liveSelection?.candidateIDs, many.items.map(\.id), "Every saved card stays available to cycle")
        XCTAssertTrue(many.library.cardDeck?.images.keys.map { $0 } == [many.items[7].id], "Only the requested card is decoded")
        guard let cycle = many.library.toolbarCycle else { XCTAssertTrue(false, "Shown artwork needs its cycle identity"); return }
        XCTAssertTrue(cycle.canAdvance)
        XCTAssertFalse(cycle.isSet)
        many.library.stepToolbarPersona(expected: cycle, offset: 1)
        let advanced = many.library.liveSelection?.currentID
        many.library.stepQuickPersona(-1)
        many.library.stepToolbarPersona(expected: cycle, offset: 1)
        XCTAssertEqual(many.library.liveSelection?.currentID, many.items[7].id, "Returning to a card does not revive a held Next")
        many.library.stepQuickPersona(1)
        XCTAssertEqual(advanced, many.items[8].id)
        many.library.stepToolbarPersona(expected: cycle, offset: 1)
        XCTAssertEqual(many.library.liveSelection?.currentID, advanced, "a stale Next cannot advance another card")
        try many.library.togglePersonaVisibility().get()
        XCTAssertTrue(many.library.toolbarCycle == nil, "hidden artwork has Show again, not Next")
        try many.library.togglePersonaVisibility().get()
        XCTAssertEqual(many.library.liveSelection?.currentID, advanced, "Show again preserves the frozen card")

        let single = try fixture([Card()])
        defer { cleanup(single) }
        try single.library.showOverlay().get()
        XCTAssertFalse(single.library.toolbarCycle?.canAdvance ?? true, "one candidate has no cycle action")

        let missing = try fixture([Card(), Card(missing: true), Card()], group: [0, 1, 2])
        defer { cleanup(missing) }
        try missing.library.showOverlay().get()
        XCTAssertTrue(missing.library.overlayVisible, "An unrelated missing image no longer blocks the chosen card")
        XCTAssertEqual(missing.library.liveSelection?.currentID, missing.items[0].id)

        // Five 4096-pixel images decode to 64 MB each: 320 MB together, over the 256 MB budget.
        let large = try fixture([Card()] + Array(repeating: Card(side: 4096), count: 5), group: Array(0...5))
        defer { cleanup(large) }
        let combined = (1...5).compactMap { PersonaCardDeck.decodedBytes(ofImageAt: large.url($0), card: false) }.reduce(0, +)
        XCTAssertGreaterThan(combined, PersonaSessionController.maximumImageBytes, "The group's decoded size is over the budget")
        try large.library.showOverlay().get()
        XCTAssertTrue(large.library.overlayVisible, "A small card shows although the whole group would not fit")
        XCTAssertTrue((large.library.cardDeck?.retainedBytes ?? .max) < 1_000_000, "Only the small requested card is decoded")
    }

    func testUnavailableRequestedCardKeepsTheShownCardAndCyclingContinues() throws {
        let f = try fixture([Card(label: "Site manager"), Card(missing: true), Card(red: 0.7), Card(red: 0.9)], group: [0, 1, 2, 3])
        defer { cleanup(f) }
        var shows = 0
        f.library.onShow = { shows += 1 }
        try f.library.showOverlay().get()
        let copy = f.library.shownCard?.copyID
        XCTAssertNotNil(copy)
        XCTAssertEqual(f.library.shownCard?.source.id, f.items[0].id)
        XCTAssertTrue(failure(f.library.makeControlsMenu()) == nil)

        let missing = PersonaCardUnavailable(label: "Persona 2", reason: .unreadable, keepsShownCard: true).localizedDescription
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id, "A card that cannot load leaves the shown card up")
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertEqual(f.library.notice, missing, "The failure names the card by its public label")
        XCTAssertFalse(f.library.notice?.contains("Private") == true, "No private library name or file appears")
        XCTAssertFalse(missing.contains("Next moves on"), "The notice promises no one direction")
        XCTAssertEqual(failure(f.library.makeControlsMenu()), missing, "The live menu says why nothing changed")
        XCTAssertEqual(try selected(f), f.items[0].id, "A failed request saves no selection")

        // Previous straight after it counts from the shown card, so the press visibly moves.
        f.library.stepLivePersona(-1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[3].id, "Previous shows the card before the shown one")
        XCTAssertTrue(f.library.notice == nil && failure(f.library.makeControlsMenu()) == nil, "Showing a card clears the failure")
        XCTAssertEqual(f.library.shownCard?.copyID, copy, "Cycling keeps the shown copy's identity")
        XCTAssertEqual(try selected(f), f.items[3].id)

        // Once another card has shown, the missing card is tried again, and the next press passes over it.
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id)
        XCTAssertEqual(f.library.notice, missing)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[2].id, "Next is never trapped at the unavailable card")
        XCTAssertEqual(f.library.shownCard?.source.id, f.items[2].id)

        // An image that changes after showing is reported instead of showing different
        // pixels. D was decoded before the change, so it keeps its frozen pixels.
        try png(side: 48, red: 0.1).write(to: f.url(0))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.url(0).path)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[3].id)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[3].id, "The changed card leaves the shown card up")
        let changed = PersonaCardUnavailable(label: "Site manager", reason: .changed, keepsShownCard: true).localizedDescription
        XCTAssertEqual(f.library.notice, changed)
        XCTAssertEqual(failure(f.library.makeControlsMenu()), changed)
        XCTAssertEqual(shows, 1, "Cycling is not a new show")

        // Hiding the card takes its failure with it.
        f.library.hideOverlay()
        XCTAssertTrue(f.library.notice == nil && f.library.cardFailure == nil, "Hide clears the failure")

        // A failed first Show is cleared by a later successful Show.
        f.library.selectedID = f.items[1].id
        let launch = f.library.showOverlay()
        XCTAssertThrowsError(try launch.get())
        if case .failure(let error) = launch {
            XCTAssertEqual(error as? PersonaCardUnavailable, PersonaCardUnavailable(label: "Persona 2", reason: .unreadable, keepsShownCard: false))
            XCTAssertEqual(f.library.notice, error.localizedDescription)
            XCTAssertEqual(f.library.cardFeedback, error.localizedDescription)
        }
        XCTAssertFalse(f.library.overlayVisible)
        XCTAssertTrue(f.library.shownCard == nil && f.library.cardDeck == nil)
        f.library.selectedID = f.items[0].id
        try f.library.showOverlay().get()
        XCTAssertTrue(f.library.notice == nil && f.library.cardFailure == nil, "A later Show clears the earlier failure")
        XCTAssertEqual(shows, 2)
        // Hide and Show start fresh: an earlier informational notice leaves the panel too.
        f.library.notice = "An unrelated notice"
        f.library.hideOverlay()
        XCTAssertTrue(f.library.notice == nil, "Hide clears an earlier informational notice")
        f.library.notice = "Another earlier notice"
        try f.library.showOverlay().get()
        XCTAssertTrue(f.library.notice == nil, "Show clears it as well")
        f.library.hideOverlay()
    }

    /// When every other card has failed while the shown card is up, Next and
    /// Previous say so instead of doing nothing, and the shown card stays.
    func testNextWithNoOtherCardSaysSo() throws {
        let f = try fixture([Card(label: "Site manager"), Card(missing: true), Card(missing: true)], group: [0, 1, 2])
        defer { cleanup(f) }
        try f.library.showOverlay().get()
        f.library.stepLivePersona(1); f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.shownCard?.source.id, f.items[0].id)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.cardFeedback, "No other card can show right now.")
        XCTAssertEqual(failure(f.library.makeControlsMenu()), "No other card can show right now.", "The live menu leads with it")
        f.library.stepLivePersona(-1)
        XCTAssertEqual(f.library.cardFeedback, "No other card can show right now.", "Previous says the same")
        XCTAssertEqual(f.library.shownCard?.source.id, f.items[0].id)
        // A read-only library keeps saying so through Hide and Show.
        let blocked = PersonaLibrary(root: f.root, readOnlyReason: "Synthetic read-only library", sessionHUDEnabled: false)
        defer { blocked.shutdown() }
        blocked.usesSharedControls = true
        try blocked.showOverlay().get(); blocked.hideOverlay()
        XCTAssertEqual(blocked.notice, "Synthetic read-only library")
    }

    func testReplacingTheShownCardWithABadOneKeepsIt() throws {
        // A and C each fit the lowered budget alone, but not both at once.
        let f = try fixture([Card(side: 900), Card(missing: true), Card(side: 900, red: 0.6), Card()], group: [0, 1, 2, 3],
                            budget: 4 * 1_048_576)
        defer { cleanup(f) }
        var shows = 0
        f.library.onShow = { shows += 1 }
        try f.library.showOverlay().get()
        let shown = f.library.shownCard

        // Show one card again for a missing card, as a delayed launch can: the shown card stays.
        f.library.selectedID = f.items[1].id
        XCTAssertEqual(f.library.shownCard, shown, "Browsing never changes the shown card")
        XCTAssertThrowsError(try f.library.showOverlay().get())
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertEqual(f.library.shownCard, shown, "A failed replacement keeps the shown card and its copy")
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id)
        XCTAssertEqual(failure(f.library.makeControlsMenu()), f.library.notice)
        XCTAssertEqual(shows, 1)

        // Choose Persona on the missing card does the same.
        f.library.selectLivePersona(f.items[1].id)
        XCTAssertEqual(f.library.shownCard, shown)
        XCTAssertEqual(f.library.notice, PersonaCardUnavailable(label: "Persona 2", reason: .unreadable, keepsShownCard: true).localizedDescription)

        // A replacement counts the shown card, which stays decoded until it is ready.
        f.library.selectedID = f.items[2].id
        let launch = f.library.showOverlay()
        XCTAssertThrowsError(try launch.get())
        if case .failure(let error) = launch {
            XCTAssertEqual(error as? PersonaCardUnavailable, PersonaCardUnavailable(label: "Persona 3", reason: .tooLarge, keepsShownCard: false))
        }
        XCTAssertEqual(f.library.shownCard, shown)
        f.library.selectLivePersona(f.items[2].id)
        XCTAssertEqual(f.library.shownCard, shown)
        XCTAssertEqual(f.library.notice, PersonaCardUnavailable(label: "Persona 3", reason: .tooLarge, keepsShownCard: true).localizedDescription)
        XCTAssertTrue((f.library.cardDeck?.retainedBytes ?? .max) <= f.library.cardImageBudget)
        XCTAssertEqual(shows, 1)

        // Alone, the same card shows.
        f.library.hideOverlay()
        try f.library.showOverlay().get()
        XCTAssertEqual(f.library.shownCard?.source.id, f.items[2].id)
        XCTAssertTrue(f.library.notice == nil)
    }

    func testOversizedRequestedCardKeepsTheShownCardWithinTheBudget() throws {
        // A lowered budget stands in for 256 MB: the library decodes at most 4096 pixels
        // on a side, so no single production image can exceed the real one.
        let budget = 4 * 1_048_576
        let f = try fixture([Card(side: 64), Card(side: 2048), Card(side: 256)], group: [0, 1, 2], budget: budget)
        defer { cleanup(f) }
        try f.library.showOverlay().get()
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id, "An oversized card leaves the shown card up")
        XCTAssertEqual(f.library.notice, PersonaCardUnavailable(label: "Persona 2", reason: .tooLarge, keepsShownCard: true).localizedDescription)
        XCTAssertTrue(f.library.cardDeck?.images[f.items[1].id] == nil, "The oversized card is refused before it is decoded")
        XCTAssertTrue((f.library.cardDeck?.retainedBytes ?? .max) <= budget)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[2].id, "Cycling continues past the oversized card")
        XCTAssertTrue((f.library.cardDeck?.retainedBytes ?? .max) <= budget)

        // Each of these fits alone, but not beside the other: the shown card stays
        // decoded until its replacement is ready, so both count.
        let pair = try fixture([Card(side: 900), Card(side: 900, red: 0.6), Card(side: 64)], group: [0, 1, 2], budget: budget)
        defer { cleanup(pair) }
        try pair.library.showOverlay().get()
        pair.library.stepLivePersona(1)
        XCTAssertEqual(pair.library.liveSelection?.currentID, pair.items[0].id)
        XCTAssertEqual(pair.library.notice, PersonaCardUnavailable(label: "Persona 2", reason: .tooLarge, keepsShownCard: true).localizedDescription)
        pair.library.stepLivePersona(1)
        XCTAssertEqual(pair.library.liveSelection?.currentID, pair.items[2].id)
        pair.library.stepLivePersona(-1)
        XCTAssertEqual(pair.library.liveSelection?.currentID, pair.items[1].id, "Beside a small shown card the same card fits")
        XCTAssertTrue((pair.library.cardDeck?.retainedBytes ?? .max) <= budget)
    }

    func testDecodingDropsNeighboursOnceMoreBeforeRefusing() throws {
        let f = try fixture([Card(side: 64), Card(side: 64, red: 0.5), Card(side: 64, red: 0.8)], group: [0, 1, 2])
        defer { cleanup(f) }
        let (a, b, c) = (f.items[0].id, f.items[1].id, f.items[2].id)
        // B's file estimates as small, but it decodes larger, as padded rows can.
        guard let large = image(side: 256), let bitmap = large.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTAssertTrue(false, "The stand-in image renders"); return
        }
        let largeBytes = bitmap.bytesPerRow * bitmap.height
        let render: (SavedPersona) -> NSImage? = { $0.id == b ? large : f.library.renderedImage(for: $0) }
        func deck(budget: Int) throws -> (PersonaCardDeck, Int) {
            let deck = PersonaCardDeck(candidates: f.items, root: f.root, budget: budget, label: { _ in "Floating persona" })
            _ = try deck.image(for: a, shown: nil, render: render); deck.didShow(a)
            let shownBytes = deck.retainedBytes
            _ = try deck.image(for: c, shown: a, render: render)
            XCTAssertTrue(deck.images[a] != nil && deck.images[c] != nil, "A and its decoded neighbour C are kept")
            return (deck, shownBytes)
        }
        let (probe, small) = try deck(budget: .max)
        XCTAssertTrue(small > 0 && largeBytes > 2 * small && (PersonaCardDeck.decodedBytes(ofImageAt: f.url(1), card: false) ?? 0) < largeBytes)
        _ = probe

        // A, C and the decoded B do not fit; A and B do, once C is dropped.
        let (fits, _) = try deck(budget: small + largeBytes + small / 2)
        _ = try fits.image(for: b, shown: a, render: render)
        XCTAssertTrue(fits.images[b] != nil && fits.images[a] != nil && fits.images[c] == nil, "The neighbour goes before refusing")
        XCTAssertTrue(fits.retainedBytes <= fits.budget)

        // Without room even then, B is refused and A stays.
        let (tight, _) = try deck(budget: small + largeBytes - 1)
        XCTAssertThrowsError(try tight.image(for: b, shown: a, render: render))
        XCTAssertTrue(tight.images[a] != nil && tight.images[b] == nil && tight.retainedBytes <= tight.budget)
        XCTAssertEqual(tight.step(from: a, by: 1), c, "Next passes over the refused card")
        XCTAssertEqual(tight.step(from: a, by: -1), c, "Previous from A reaches C, before it")
    }

    func testFrozenSourcesKeepAppearanceAndDecodingStaysBounded() throws {
        let cards = [Card(label: "Site manager"), Card(label: "Account lead")] + (2..<8).map { Card(red: CGFloat($0) / 10) }
        let f = try fixture(cards, group: Array(0..<8))
        defer { cleanup(f) }
        try f.library.showOverlay().get()
        guard let original = f.library.renderedImage(for: f.items[1]) else { XCTAssertTrue(false, "The fixture card renders"); return }
        let frozen = try PersonaCardRenderer.png(original)
        XCTAssertTrue(f.library.updateCard(f.items[1].id, style: PersonaCardStyle(label: "LATER PRIVATE CONTENT", background: InkColor(1, 1, 0))))
        let extra = try f.library.addImage(f.url(2), name: "Later private item")
        XCTAssertEqual(f.library.liveSelection?.candidateIDs, f.items.map(\.id), "A later library item does not join the shown set")
        XCTAssertFalse(f.library.cardDeck?.sources[extra.id] != nil)

        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[1].id)
        guard let shown = f.library.cardDeck?.images[f.items[1].id] else { XCTAssertTrue(false, "The next card is decoded"); return }
        XCTAssertEqual(try PersonaCardRenderer.png(shown), frozen, "Next shows the appearance frozen when the card was shown")
        XCTAssertEqual(f.library.shownCard?.source.persona.card?.label, "Account lead")
        XCTAssertEqual(f.library.cardDeck?.labels[f.items[1].id], "Account lead", "The public label stays frozen too")

        // A full cycle keeps at most the shown card and its two neighbours decoded.
        let budget = f.library.cardImageBudget
        for step in 0..<(2 * f.items.count) {
            f.library.stepLivePersona(step < f.items.count ? 1 : -1)
            guard let deck = f.library.cardDeck, let current = f.library.liveSelection?.currentID else { XCTAssertTrue(false, "The card stays up"); return }
            XCTAssertTrue(deck.images[current] != nil && deck.images.count <= 3 && deck.retainedBytes <= budget,
                          "Only the shown card and nearby cards stay decoded")
        }

        // Removing a saved card takes it out of the set; it never substitutes another.
        f.library.remove(f.items[5].id)
        XCTAssertEqual(f.library.liveSelection?.candidateIDs.contains(f.items[5].id), false)
        XCTAssertTrue(f.library.cardDeck?.sources[f.items[5].id] == nil && f.library.cardDeck?.images[f.items[5].id] == nil)
    }

    func testPreparedSessionsKeepTheirLimitsAndPreflight() throws {
        let f = try fixture(Array(repeating: Card(), count: 33) + Array(repeating: Card(side: 4096), count: 5), panels: true)
        defer { cleanup(f) }
        func group(_ name: String, _ members: [Int], copies: Int = 1) throws -> UUID {
            let id = try f.library.createGroup(name: name, members: members.map { f.items[$0].id })
            try f.library.saveGroupLayout(id, overlays: (0..<copies).map { _ in PersonaOverlayItem(personaID: f.items[members[0]].id) }, publicLabel: nil)
            return id
        }
        func refuses(_ groups: [UUID], _ expected: PersonaSessionError, _ name: String) {
            do {
                try f.library.startOverlaySession(groupIDs: groups, initialGroupID: groups[0])
                XCTAssertTrue(false, name); f.library.endOverlaySession()
            } catch { XCTAssertEqual(error.localizedDescription, expected.localizedDescription, name) }
            XCTAssertEqual(f.library.sessionState.phase, .idle)
        }
        // Eight real prepared groups start; a ninth is refused for its number alone.
        let sets = try (0..<9).map { try group("Private set \($0)", [$0]) }
        try f.library.startOverlaySession(groupIDs: Array(sets.prefix(8)), initialGroupID: sets[0])
        XCTAssertEqual(f.library.sessionState.groups.count, 8)
        f.library.endOverlaySession()
        refuses(sets, .tooManyOverlays, "Nine prepared groups are refused")

        // Eight copies start; a ninth cannot be saved.
        let copies = try group("Private copies", [0], copies: 8)
        try f.library.startOverlaySession(groupIDs: [copies], initialGroupID: copies)
        XCTAssertEqual(f.library.sessionState.instances.count, 8)
        f.library.endOverlaySession()
        XCTAssertThrowsError(try f.library.saveGroupLayout(copies, overlays: (0..<9).map { _ in PersonaOverlayItem(personaID: f.items[0].id) }, publicLabel: nil))

        // 32 different personas start; 33 are refused.
        let wide = try group("Private 32", Array(0..<32))
        try f.library.startOverlaySession(groupIDs: [wide], initialGroupID: wide)
        XCTAssertEqual(f.library.sessionState.candidates.count, 32)
        f.library.endOverlaySession()
        let tooWide = try group("Private 33", Array(0..<33))
        refuses([tooWide], .tooManyCandidates, "33 different personas are refused")

        // Five 64 MB images exceed the prepared session's 256 MB preflight, before any window.
        let heavy = try group("Private heavy", Array(33..<38))
        refuses([heavy], .tooManyCandidates, "Five 64 MB images exceed the image budget")
        XCTAssertFalse(f.library.overlayVisible)
    }

    func testFailedNextIsReportedInTheLiveMenuAndThePanelNotice() throws {
        let (root, items) = try write([Card(label: "Site manager"), Card(missing: true), Card()], group: [0, 1, 2])
        defer { try? FileManager.default.removeItem(at: root) }
        // A suite named by a path keeps its plist in this folder, not in ~/Library/Preferences.
        let settings = SettingsStore(defaults: UserDefaults(suiteName: root.appendingPathComponent("settings").path)!)
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        let scenes = DemoScenes(root: root, systemIntegrationEnabled: false)
        app.demoScenes = scenes
        defer { scenes.shutdown() }
        MainActor.assumeIsolated {
            let stage = StageKitController(coordinator: app)
            stage.useSharedActivityControls()
            stage.togglePersona()
            XCTAssertTrue(scenes.personas.overlayVisible)
            XCTAssertEqual(scenes.personas.shownCard?.source.id, items[0].id)
            scenes.notice = "An older scene message"
            XCTAssertEqual(stage.notice, "An older scene message")

            // The Next shortcut reaches the missing card.
            app.handleHotkey(.personaNext, down: true)
            let missing = PersonaCardUnavailable(label: "Persona 2", reason: .unreadable, keepsShownCard: true).localizedDescription
            XCTAssertEqual(scenes.personas.shownCard?.source.id, items[0].id, "The shown card stays up")
            XCTAssertEqual(failure(stage.makePersonaMenu()), missing, "The floating toolbar's Persona menu says why")
            XCTAssertEqual(stage.notice, missing, "The menu panel shows it ahead of an older scene message")
            XCTAssertFalse(stage.makePersonaPanelMenu().items.contains { $0.title == missing }, "The panel shows it once, in its feedback line")

            // The next press passes over it and clears the failure.
            app.handleHotkey(.personaNext, down: true)
            XCTAssertEqual(scenes.personas.shownCard?.source.id, items[2].id)
            XCTAssertTrue(failure(stage.makePersonaMenu()) == nil)
            XCTAssertEqual(stage.notice, "An older scene message")

            // Hiding the card clears a failure too.
            app.handleHotkey(.personaNext, down: true)
            app.handleHotkey(.personaNext, down: true)
            XCTAssertEqual(stage.notice, missing)
            stage.togglePersona()
            XCTAssertFalse(scenes.personas.overlayVisible)
            XCTAssertEqual(stage.notice, "An older scene message", "Hide clears the failure from the panel")
            XCTAssertTrue(scenes.personas.notice == nil)
        }
    }
}
