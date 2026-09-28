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

    /// Writes the images and the library record directly, so large fixtures skip import processing.
    private func fixture(_ cards: [Card], group: [Int]? = nil, selected: Int = 0, budget: Int? = nil) throws -> Fixture {
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
        let library = PersonaLibrary(root: root, sessionHUDEnabled: false)
        library.usesSharedControls = true
        if let budget { library.cardImageBudget = budget }
        return Fixture(root: root, library: library, items: items)
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

        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id, "A card that cannot load leaves the shown card up")
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertEqual(f.library.notice, PersonaCardUnavailable(label: "Persona 2", reason: .unreadable, keepsShownCard: true).localizedDescription,
                       "The failure names the card by its public label")
        XCTAssertFalse(f.library.notice?.contains("Private") == true, "No private library name or file appears")
        XCTAssertEqual(try selected(f), f.items[0].id, "A failed request saves no selection")

        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[2].id, "The next Next moves past the unavailable card")
        XCTAssertEqual(f.library.shownCard?.source.id, f.items[2].id)
        XCTAssertEqual(f.library.shownCard?.copyID, copy, "Cycling keeps the shown copy's identity")
        XCTAssertEqual(try selected(f), f.items[2].id)
        f.library.stepLivePersona(-1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[2].id, "Previous fails on the same card without moving the shown one")
        f.library.stepLivePersona(-1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id, "Previous is not trapped either")

        // An image that changes after showing is reported instead of showing different pixels.
        try png(side: 48, red: 0.1).write(to: f.url(3))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.url(3).path)
        f.library.stepLivePersona(-1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[0].id)
        XCTAssertEqual(f.library.notice, PersonaCardUnavailable(label: "Persona 4", reason: .changed, keepsShownCard: true).localizedDescription)
        f.library.stepLivePersona(-1)
        XCTAssertEqual(f.library.liveSelection?.currentID, f.items[2].id)
        XCTAssertEqual(shows, 1, "Cycling is not a new show")
        XCTAssertTrue(f.library.overlayVisible)

        // Requesting the missing card first fails before anything replaces the shown card.
        f.library.hideOverlay()
        f.library.selectedID = f.items[1].id
        let launch = f.library.showOverlay()
        XCTAssertThrowsError(try launch.get())
        if case .failure(let error) = launch {
            XCTAssertEqual(error as? PersonaCardUnavailable, PersonaCardUnavailable(label: "Persona 2", reason: .unreadable, keepsShownCard: false))
        }
        XCTAssertFalse(f.library.overlayVisible)
        XCTAssertTrue(f.library.shownCard == nil && f.library.cardDeck == nil)
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
        let f = try fixture(Array(repeating: Card(), count: 33) + Array(repeating: Card(side: 4096), count: 5))
        defer { cleanup(f) }
        let tooManyGroups = (0..<9).map { _ in UUID() }
        XCTAssertThrowsError(try f.library.startOverlaySession(groupIDs: tooManyGroups, initialGroupID: tooManyGroups[0]))
        let wide = try f.library.createGroup(name: "Private wide group", members: Array(f.items.prefix(33).map(\.id)))
        // Nine copies in one group are refused.
        XCTAssertThrowsError(try f.library.saveGroupLayout(wide, overlays: (0..<9).map { _ in PersonaOverlayItem(personaID: f.items[0].id) }, publicLabel: nil))
        try f.library.saveGroupLayout(wide, overlays: [PersonaOverlayItem(personaID: f.items[0].id)], publicLabel: nil)
        do {
            try f.library.startOverlaySession(groupIDs: [wide], initialGroupID: wide)
            XCTAssertTrue(false, "33 different personas exceed a prepared session's 32")
        } catch {
            XCTAssertEqual(error.localizedDescription, PersonaSessionError.tooManyCandidates.localizedDescription)
        }
        let heavy = try f.library.createGroup(name: "Private heavy group", members: f.items.suffix(5).map(\.id))
        try f.library.saveGroupLayout(heavy, overlays: [PersonaOverlayItem(personaID: f.items[33].id)], publicLabel: nil)
        do {
            try f.library.startOverlaySession(groupIDs: [heavy], initialGroupID: heavy)
            XCTAssertTrue(false, "Five 64 MB images exceed the prepared session's 256 MB preflight")
        } catch {
            XCTAssertEqual(error.localizedDescription, PersonaSessionError.tooManyCandidates.localizedDescription)
        }
        XCTAssertEqual(f.library.sessionState.phase, .idle)
        XCTAssertFalse(f.library.overlayVisible)
    }
}
