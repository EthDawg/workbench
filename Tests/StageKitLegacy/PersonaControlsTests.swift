import AppKit

final class PersonaControlsTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private func control<T: NSView>(_ type: T.Type, _ id: String, in hud: PersonaHUDController) -> T {
        descendants(hud.window!.contentView!).first { $0.identifier?.rawValue == id || $0.accessibilityIdentifier() == id } as! T
    }
    private func fixture() throws -> (URL, PersonaHUDController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaControls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, PersonaHUDController(root: root, allowsSaving: false))
    }
    private func checkLayout(_ hud: PersonaHUDController, evidence: String) throws {
        let view = hud.window!.contentView!
        view.layoutSubtreeIfNeeded()
        for item in descendants(view) where item is NSControl && !item.isHidden {
            let rect = item.convert(item.bounds, to: view)
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Visible persona control fits the panel: \(item)")
        }
        if let path = ProcessInfo.processInfo.environment["WORKBENCH_PERSONA_EVIDENCE"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(evidence + ".png"))
            }
        }
    }

    func testSingleSizeControlIsVisibleAndRoutesAbsoluteWidth() throws {
        let (root, hud) = try fixture()
        defer { hud.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        var width = 0.0
        hud.onSetSize = { width = $0 }
        hud.show(items: [PersonaHUDItem(id: id, label: "Sample presenter", image: nil)], selectedID: id, locked: true, width: 0.12, near: nil)
        let slider = control(NSSlider.self, "persona.single.size", in: hud)
        XCTAssertEqual(slider.doubleValue, 0.12)
        XCTAssertEqual(slider.minValue, 0.06); XCTAssertEqual(slider.maxValue, 0.40)
        slider.doubleValue = 0.06
        NSApp.sendAction(slider.action!, to: slider.target, from: slider)
        XCTAssertEqual(width, 0.06, "Dragging left requests a smaller persona directly")
        hud.show(items: [PersonaHUDItem(id: id, label: "Sample presenter", image: nil)], selectedID: id, locked: true, width: width, near: nil)
        try checkLayout(hud, evidence: "persona-size-single")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("persona-controls.json").path))
    }

    func testSessionControlsTargetSelectedCopyAndRecoverFromEmptySet() throws {
        let (root, hud) = try fixture()
        defer { hud.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = UUID(), personaID = UUID(), image = NSImage(size: CGSize(width: 40, height: 60))
        let item = PersonaSessionInstance(id: id, personaID: personaID, label: "Sample presenter", image: image, visible: true, placement: PersonaOverlayState(width: 0.18))
        var state = PersonaSessionViewState()
        state.phase = .active; state.instances = [item]; state.selectedInstanceID = id
        state.candidates = [PersonaSessionCandidate(id: personaID, label: "Sample presenter", image: image)]
        var resized: UUID?, removed: UUID?, width = 0.0
        hud.showSession(viewModel: PersonaSessionHUDModel(state: state, perform: { action in
            if case .width(let target, let value) = action { resized = target; width = value }
            if case .remove(let target) = action { removed = target }
        }), near: nil)
        let slider = control(NSSlider.self, "persona.session.size", in: hud)
        let add = control(NSButton.self, "persona.session.add", in: hud)
        let remove = control(NSButton.self, "persona.session.remove", in: hud)
        XCTAssertTrue(add.isEnabled); XCTAssertTrue(remove.isEnabled); XCTAssertTrue(slider.isEnabled)
        slider.doubleValue = 0.08; NSApp.sendAction(slider.action!, to: slider.target, from: slider)
        XCTAssertEqual(resized, id); XCTAssertEqual(width, 0.08)
        remove.performClick(nil); XCTAssertEqual(removed, id)
        try checkLayout(hud, evidence: "persona-size-multiple")
        state.instances = []; state.selectedInstanceID = nil
        hud.showSession(viewModel: PersonaSessionHUDModel(state: state, perform: { _ in }), near: nil)
        XCTAssertTrue(add.isEnabled, "An empty set can still add a prepared persona")
        XCTAssertFalse(remove.isEnabled); XCTAssertFalse(slider.isEnabled)
        try checkLayout(hud, evidence: "persona-size-empty")
        state.instances = (0..<8).map { _ in PersonaSessionInstance(id: UUID(), personaID: personaID, label: "Card", image: image, visible: true, placement: PersonaOverlayState()) }
        state.selectedInstanceID = state.instances[0].id
        hud.showSession(viewModel: PersonaSessionHUDModel(state: state, perform: { _ in }), near: nil)
        XCTAssertFalse(add.isEnabled, "The existing eight-copy limit remains enforced")
        hud.show(items: [PersonaHUDItem(id: personaID, label: "Single again", image: nil)], selectedID: personaID, locked: true, near: nil)
        XCTAssertEqual(hud.window!.frame.height, 76)
        try checkLayout(hud, evidence: "persona-size-return-to-single")
    }
}
