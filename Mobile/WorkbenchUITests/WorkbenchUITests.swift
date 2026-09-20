import XCTest

@MainActor
final class WorkbenchUITests: XCTestCase {
    private let sentence = "Meet at 3pm. Bring the revised drawings."

    private func launchIsolatedApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Debug app code chooses a new temporary library for every launch.
        // This never resets, replaces or imports the installed user's library.
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["tool.dictate"].waitForExistence(timeout: 10))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            let identifier = element.identifier.isEmpty ? element.label : element.identifier
            let candidates = app.scrollViews.containing(element.elementType, identifier: identifier).allElementsBoundByIndex
            if let scroll = candidates.max(by: { $0.frame.height < $1.frame.height }) {
                // Scroll through the outside margin, away from PencilKit ink,
                // image crop gestures and editable text in the content area.
                let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8))
                let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2))
                start.press(forDuration: 0.01, thenDragTo: end)
            } else {
                XCTFail("No page contains \(identifier)", file: file, line: line)
                return
            }
        }
        XCTAssertTrue(element.isHittable, "The control must be reachable by scrolling", file: file, line: line)
    }

    private func beginEditing(_ editor: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Wait for speech availability checking to release the editor", file: file, line: line)
        reveal(editor, in: app, file: file, line: line)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Tapping the editor must open the native keyboard", file: file, line: line)
    }

    private func typeInitialDraft(_ text: String, into editor: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        beginEditing(editor, in: app, file: file, line: line)
        // Establish exact cleanup input through the native keyboard. Keep the
        // separate rapid later-typing regression as a single bulk insertion.
        var entered = ""
        for character in text {
            editor.typeText(String(character))
            entered.append(character)
            XCTAssertEqual(editor.value as? String, entered, "Verify every native input character before testing cleanup", file: file, line: line)
        }
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), file: file, line: line)
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(editor.value as? String, text, "Ending editing must preserve the exact cleanup input", file: file, line: line)
    }

    private func selectTab(_ label: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let exactLabel = NSPredicate(format: "label == %@", label)
        let matches = app.descendants(matching: .any).matching(exactLabel)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), "The \(label) tab must be available", file: file, line: line)
        // iPhone exposes tab buttons; the native iPad floating tab strip can
        // expose cells/other elements. Match the same exact accessible label.
        let queries = [app.buttons.matching(exactLabel), app.cells.matching(exactLabel), app.otherElements.matching(exactLabel)]
        for query in queries {
            if let target = query.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                target.tap()
                let title = label == "Tools" ? "Workbench" : "Saved"
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), file: file, line: line)
                return
            }
        }
        XCTFail("No actionable tab has the exact label \(label)", file: file, line: line)
    }

    private func attachScreenshot(_ name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTypedDraftCanBeSavedReopenedAndHandedToReading() {
        let app = launchIsolatedApp()
        app.buttons["tool.dictate"].tap()
        let draft = app.textViews["dictate.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        reveal(draft, in: app)
        draft.tap()
        draft.typeText(sentence)
        XCTAssertEqual(draft.value as? String, sentence)
        let done = app.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
        let save = app.buttons["dictate.save"]
        reveal(save, in: app)
        save.tap()
        let notice = app.staticTexts["dictate.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Saved on this device.")

        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Saved", in: app)
        let savedTitle = app.staticTexts[sentence].firstMatch
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 5))
        savedTitle.tap()
        let savedText = app.textViews["Saved text"]
        XCTAssertTrue(savedText.waitForExistence(timeout: 5))
        XCTAssertEqual(savedText.value as? String, sentence)
        let read = app.buttons["Read aloud"]
        reveal(read, in: app)
        read.tap()
        let readingText = app.textViews["reading.text"]
        XCTAssertTrue(readingText.waitForExistence(timeout: 5))
        XCTAssertEqual(readingText.value as? String, sentence)
        XCTAssertTrue(app.buttons["reading.play"].isEnabled)
        attachScreenshot("Saved text handed to reading", of: app)
        // Verify the saved-text handoff without depending on installed speech
        // voices, producing audio or starting a model/permission workflow.
    }

    func testCleaningTypedTextKeepsOriginalWhenSavedAndReopened() {
        let app = launchIsolatedApp()
        let original = "Um, meet at 2pm, actually 3pm."
        let cleaned = "Meet at 3pm."
        app.buttons["tool.dictate"].tap()
        let draft = app.textViews["dictate.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        typeInitialDraft(original, into: draft, in: app)
        let cleanup = app.buttons["Clean up"]
        reveal(cleanup, in: app); cleanup.tap()
        XCTAssertEqual(draft.value as? String, cleaned)
        let save = app.buttons["dictate.save"]
        reveal(save, in: app); save.tap()
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Saved", in: app)
        let title = app.staticTexts[cleaned].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap()
        XCTAssertEqual(app.textViews["Saved text"].value as? String, cleaned)
        let originalDisclosure = app.buttons["Original"]
        reveal(originalDisclosure, in: app); originalDisclosure.tap()
        XCTAssertTrue(app.staticTexts[original].waitForExistence(timeout: 5))
    }

    func testCleanupUndoKeepsLaterTypingAndSavedOriginal() {
        let app = launchIsolatedApp()
        let original = "Um, meet at 2pm, actually 3pm."
        let cleaned = "Meet at 3pm."
        app.buttons["tool.dictate"].tap()
        let draft = app.textViews["dictate.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        typeInitialDraft(original, into: draft, in: app)
        let done = app.buttons["Done"]
        let cleanup = app.buttons["Clean up"]
        reveal(cleanup, in: app); cleanup.tap()
        XCTAssertEqual(draft.value as? String, cleaned)
        let undo = app.buttons["Undo cleanup"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        reveal(undo, in: app); undo.tap()
        XCTAssertEqual(draft.value as? String, original, "Immediate Undo must restore the pre-cleanup draft")

        cleanup.tap()
        let addition = "Bring the drawings. "
        beginEditing(draft, in: app)
        draft.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .command)
        draft.typeText(addition)
        let edited = draft.value as? String ?? ""
        XCTAssertTrue(edited.contains(addition), "Native typing must insert the complete addition before testing Undo; actual draft: \(edited)")
        XCTAssertEqual(edited.replacingOccurrences(of: addition, with: ""), cleaned)
        if done.exists && done.isHittable { done.tap() }
        // Exercise the old destructive action if it remains available. The fixed
        // UI must retire this cleanup snapshot as soon as the user edits.
        if undo.exists { reveal(undo, in: app); undo.tap() }
        XCTAssertEqual(draft.value as? String, edited, "Cleanup Undo must never remove later typing")
        XCTAssertFalse(undo.exists)
        let save = app.buttons["dictate.save"]
        reveal(save, in: app); save.tap()
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Saved", in: app)
        let title = app.staticTexts[edited].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap()
        XCTAssertEqual(app.textViews["Saved text"].value as? String, edited)
        let originalDisclosure = app.buttons["Original"]
        reveal(originalDisclosure, in: app); originalDisclosure.tap()
        XCTAssertTrue(app.staticTexts[original].waitForExistence(timeout: 5))
    }

    func testCleanupUndoExpiresWhenTypingReturnsToTheSameText() {
        let app = launchIsolatedApp()
        app.buttons["tool.dictate"].tap()
        let draft = app.textViews["dictate.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        typeInitialDraft("Um, bring the drawings.", into: draft, in: app)
        let done = app.buttons["Done"]
        let cleanup = app.buttons["Clean up"]
        reveal(cleanup, in: app); cleanup.tap()
        let cleaned = "Bring the drawings."
        XCTAssertEqual(draft.value as? String, cleaned)
        XCTAssertTrue(app.buttons["Undo cleanup"].exists)
        beginEditing(draft, in: app); draft.typeText("X")
        let mutated = draft.value as? String ?? ""
        XCTAssertTrue(mutated.contains("X"))
        XCTAssertEqual(mutated.replacingOccurrences(of: "X", with: ""), cleaned)
        draft.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(draft.value as? String, cleaned)
        if done.exists && done.isHittable { done.tap() }
        XCTAssertFalse(app.buttons["Undo cleanup"].exists, "Returning to identical text must not revive a stale cleanup snapshot")
    }

    func testConsecutiveCharactersAfterCleanupPreserveInsertionPoint() {
        let app = launchIsolatedApp()
        app.buttons["tool.dictate"].tap()
        let draft = app.textViews["dictate.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        typeInitialDraft("Um, bring the drawings.", into: draft, in: app)
        let cleanup = app.buttons["Clean up"]
        reveal(cleanup, in: app); cleanup.tap()
        let cleaned = "Bring the drawings."
        XCTAssertEqual(draft.value as? String, cleaned)
        beginEditing(draft, in: app)
        // Keep the software keyboard active and observe the first insertion.
        // Hardware keyboard shortcuts are a separate input path.
        // Retiring Undo must preserve that native insertion point for the next.
        draft.typeText("1")
        let afterFirst = draft.value as? String ?? ""
        XCTAssertEqual(afterFirst.count, cleaned.count + 1)
        XCTAssertEqual(afterFirst.replacingOccurrences(of: "1", with: ""), cleaned)
        XCTAssertFalse(app.buttons["Undo cleanup"].exists)
        draft.typeText("2")
        XCTAssertEqual(draft.value as? String, afterFirst.replacingOccurrences(of: "1", with: "12"), "Retiring cleanup Undo must not move the native insertion point")
    }

    func testIndependentWallpaperEntryCanCreateAndReopenAStarter() {
        let app = launchIsolatedApp()
        attachScreenshot("Tools home", of: app)
        XCTAssertTrue(app.buttons["tool.read"].exists)
        XCTAssertTrue(app.buttons["tool.markup"].exists)
        let wallpaper = app.buttons["tool.wallpaper"]
        reveal(wallpaper, in: app)
        wallpaper.tap()
        let choose = app.buttons["wallpaper.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        reveal(choose, in: app)
        XCTAssertTrue(choose.isEnabled)
        // Use the bundled/generated starter to complete the job without Photos
        // permission or any personal images.
        let starter = app.buttons["Use Coast picture"]
        reveal(starter, in: app); starter.tap()
        XCTAssertTrue(app.navigationBars["Coast"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Saved", in: app)
        let saved = app.staticTexts["Coast"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.navigationBars["Coast"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["A calmer screen."].exists)
        attachScreenshot("Coast wallpaper editor", of: app)
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Tools", in: app)
        XCTAssertTrue(app.buttons["tool.dictate"].waitForExistence(timeout: 5))
    }

    func testFreshTestLaunchStartsWithEmptySavedCollection() {
        let app = launchIsolatedApp()
        selectTab("Saved", in: app)
        XCTAssertTrue(app.staticTexts["Your useful things, kept."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["Saved text"].exists)
        selectTab("Tools", in: app)
        XCTAssertTrue(app.buttons["tool.dictate"].waitForExistence(timeout: 5))
    }

    func testScenePreparedWithStarterStaysEditableInSaved() {
        let app = launchIsolatedApp()
        attachScreenshot("Tools home before scene preparation", of: app)
        let scenes = app.buttons["tool.scenes"]
        reveal(scenes, in: app); scenes.tap()
        let start = app.buttons["Start with a picture"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let coast = app.buttons["Coast"]
        XCTAssertTrue(coast.waitForExistence(timeout: 5)); coast.tap()
        let name = app.textFields["scene.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        reveal(name, in: app)
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Tapping the scene name must begin native text editing")
        name.typeText(" — Room preview")
        XCTAssertEqual(name.value as? String, "Coast — Room preview")
        // The toolbar Done explicitly flushes pending text before navigation.
        let done = app.navigationBars["Edit scene"].buttons["Done"]
        XCTAssertTrue(done.exists); done.tap()
        XCTAssertTrue(app.navigationBars["Scenes"].waitForExistence(timeout: 5))
        let saved = app.staticTexts["Coast — Room preview"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Coast — Room preview")
        attachScreenshot("Editable scene prepared for Mac", of: app)
        done.tap()
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Saved", in: app)
        XCTAssertTrue(app.staticTexts["Coast — Room preview"].firstMatch.waitForExistence(timeout: 5))
    }

    func testMarkupNameKeepsKeyboardFocusAcrossCanvasUpdatesAndReopens() {
        let app = launchIsolatedApp()
        let wallpaper = app.buttons["tool.wallpaper"]
        reveal(wallpaper, in: app); wallpaper.tap()
        let starter = app.buttons["wallpaper.starter.coast"]
        reveal(starter, in: app); starter.tap()
        XCTAssertTrue(app.navigationBars["Coast"].waitForExistence(timeout: 10))
        app.buttons["Image actions"].tap()
        let reuse = app.buttons["Mark up"]
        XCTAssertTrue(reuse.waitForExistence(timeout: 5)); reuse.tap()
        XCTAssertTrue(app.buttons["Undo drawing"].waitForExistence(timeout: 5))
        let name = app.textFields["Name this image"]
        reveal(name, in: app)
        name.tap()
        // Separate events allow a SwiftUI/canvas update between characters.
        // The drawing canvas must not reclaim focus from the name field.
        name.typeText(" A")
        XCTAssertEqual(name.value as? String, "Coast A")
        name.typeText(" B")
        XCTAssertEqual(name.value as? String, "Coast A B")
        attachScreenshot("Markup name retains editing focus", of: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Saved", in: app)
        let renamed = app.staticTexts["Coast A B"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5)); renamed.tap()
        let reopenedName = app.textFields["Name this image"]
        XCTAssertTrue(reopenedName.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedName.value as? String, "Coast A B")
    }
}
