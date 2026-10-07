import AppKit

@main
struct TestRunner {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--library-image-reuse-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let suite = LibraryImageReuseTests()
            let tests: [(String, () throws -> Void)] = [
                ("Library scene preparation cancel create and replace", suite.testScenePreparationCancelCreateAndReplace),
                ("Library Persona preparation preserves live copies", suite.testPersonaPreparationCancelAndAddPreserveLiveCopies),
                ("Library preparation offscreen renders", { try MainActor.assumeIsolated { try suite.renderPreparationViews() } })
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--profile-camera-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let camera = ProfileCameraTests(), creation = PersonaCreationTests()
            let tests: [(String, () throws -> Void)] = [
                ("camera permission cancellation and late approval", camera.testPermissionIsExplicitAndLateApprovalCannotReopen),
                ("camera denied and restricted access", camera.testDeniedAndRestrictedAccessKeepAnExitWithoutOpeningHardware),
                ("camera timeout retry and stale events", camera.testStartupTimeoutRetryAndLateEvents),
                ("camera fresh frames and deadline ownership", camera.testOnlyFreshFramesEnableTheShutterAndOldDeadlinesCannotFailNewFrames),
                ("camera photo handoff and late cancellation", camera.testPhotoHandsOffOnceAfterStoppingAndCancelDropsLatePhoto),
                ("camera source switch and interruption", camera.testSwitchCameraRejectsOldPhotoAndDisconnectionRequiresExplicitRetry),
                ("camera photo failure and timeout", camera.testPhotoFailureAndTimeoutLeaveTheProfileUnchanged),
                ("camera stays in profile host and Cancel preserves library", camera.testProfileKeepsCameraInTheSameHostAndCancelReturnsWithoutSaving),
                ("camera frame conversion preserves pixels", camera.testFrameConversionKeepsItsSizeAndOrientation),
                ("camera synthetic layouts", camera.testCameraLayouts),
                ("profile replacement preserves originals", creation.testProfileReferenceAndPhotoReplacementPreserveIdentityAndOriginals),
                ("profile save failure preserves draft", creation.testFailedProfileReplacementKeepsDraftAndFiles)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-camera-only"] {
            // A fake camera, window, permission, clock and camera list on a
            // disposable library: no hardware, prompt or saved work is involved.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let suite = PersonaCameraTests()
            let tests: [(String, () throws -> Void)] = [
                ("camera is off until an explicit start", suite.testCameraIsOffUntilAnExplicitStartAndShowsNothingBeforeAFrame),
                ("camera sleep cancels permission and startup", suite.testSleepCancelsPermissionAndStartup),
                ("camera failures before readiness keep the shown artwork", suite.testFailuresBeforeReadinessLeaveTheShownArtworkAndNeedAnExplicitRetry),
                ("camera stall and disconnection need explicit retry", suite.testStalledAndDisconnectedFeedsRecoverOnlyOnExplicitRetry),
                ("camera in use is reported, not taken", suite.testABusyCameraIsReportedInsteadOfTaken),
                ("camera choice starts only the chosen camera", suite.testChoosingAnotherCameraStartsOnlyThatOneAndDropsTheOldFeed),
                ("camera is a choice in the pill's Persona picker", suite.testThePillPickerOffersTheCameraBesideTheCards),
                ("camera gone while hidden is named, never replaced", suite.testShowAgainAfterTheChosenCameraHasGoneNamesItAndOpensNoOther),
                ("camera End overlays shortcut ends the live source", suite.testEndOverlaysShortcutEndsTheLiveCameraAndKeepsTheReplacedCard),
                ("camera keeps saved and prepared artwork", suite.testTheCameraTakesTheSlotWithoutLosingSavedOrPreparedArtwork),
                ("camera Hide releases it and keeps its place", suite.testHideReleasesTheCameraAndKeepsItsPlaceForShowAgain),
                ("camera live doors and cycling", suite.testLiveDoorsFollowTheCameraAndCyclingNeverReplacesIt),
                ("camera and prepared sets never share the slot", suite.testPreparedSetsAndTheCameraNeverShareTheSlot),
                ("camera and photo carry the voice ring and write nothing", suite.testTheRingFramesLiveCameraAndThePhotoAndWritesNothing),
                ("My Profile and Live Camera are one click apart in the same place", suite.testMyProfileAndLiveCameraAreOneClickApartInTheSamePlace),
                ("live menu offers the same sources in the same words", suite.testTheLiveMenuOffersTheSameSourcesInTheSameWords),
                ("Centre Stage follows the camera and the Video menu", suite.testCenterStageFollowsTheCameraAndTheVideoMenu),
                ("switching keeps the outgoing picture whole until covered", suite.testTheOutgoingPictureStaysWholeUntilTheIncomingOneCoversIt),
                ("a card stepping aside stays whole and comes back whole", suite.testACardSteppingAsideStaysWholeAndComesBackWhole),
                ("the real bubble window carries the ring", suite.testTheRealBubbleWindowCarriesTheRing),
                ("only the switch asks for the microphone", suite.testOnlyTheSwitchAsksForTheMicrophone),
                ("a fault stops the ring without saving it off", suite.testAFaultStopsTheRingWithoutSavingItOff),
                ("My Profile is always first and Live Camera checked only while it shows", suite.testMyProfileIsAlwaysTheFirstRowAndLiveCameraIsCheckedOnlyWhileItShows),
                ("the Live Camera menu is grouped in title case", suite.testTheLiveCameraMenuIsGroupedInTitleCase),
                ("camera bubble window moves, resizes and crops", suite.testTheBubbleWindowMovesResizesAndCropsLikeArtwork),
                ("optional offscreen camera panel renders", suite.testOffscreenCameraPanelRenders),
                ("optional offscreen picker listings", suite.testOffscreenPickerListings)
            ]
            var skipped = 0
            for (name, test) in tests {
                if name.hasPrefix("optional"), ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] == nil {
                    skipped += 1; print("SKIP \(name): set WORKBENCH_LAYOUT_EVIDENCE to render"); continue
                }
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            if skipped > 0 { print("\(skipped) skipped") }
            print("\(tests.count - skipped) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-layout-only"] {
            guard ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] != nil else { exit(2) }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            NSApp.finishLaunching()
            do { try PersonaWorkspaceTests().testOffscreenWorkspaceLayouts() }
            catch { assertionFailures += 1; print("FAIL offscreen Persona/Present layouts: \(error)") }
            print("1 tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-workspace-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let suite = PersonaWorkspaceTests()
            let tests: [(String, () throws -> Void)] = [
                ("persona workspace immediate start and pause preservation", suite.testWorkspaceStartsWithoutDismissalAndPreservesPausedArrangement),
                ("persona workspace single card immediate show and stop", suite.testWorkspaceSingleCardShowsAndStopsWithoutDismissal),
                ("persona sheet launch only after dismissal", suite.testSheetLaunchWaitsForDismissalAndIsConsumedOnce),
                ("persona workspace failure preserves active session", suite.testWorkspaceFailureIsImmediateAndDoesNotReplaceSession),
                ("Present compact preview policy", suite.testPresentPreviewReservesControlsAndFitsNarrowEditors),
                ("optional offscreen workspace layouts", suite.testOffscreenWorkspaceLayouts)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--notice-owners-only"] {
            // Disposable folders only; nothing is started, registered or shown.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let suite = NoticeOwnerTests()
            let tests: [(String, () throws -> Void)] = [
                ("shortcut recording notices belong to Keyboard", suite.testShortcutRecordingNoticesBelongToKeyboard),
                ("login notices belong to General", suite.testLoginNoticesBelongToGeneral),
                ("saved settings notices belong to General", suite.testSavedSettingsNoticesBelongToGeneral)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-handles-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let suite = PersonaHandleTests()
            let tests: [(String, () throws -> Void)] = [
                ("persona handles sit on the visible artwork", suite.testHandlesSitOnTheVisibleArtworkNotItsTransparentRoom),
                ("persona resize keeps shape and limits", suite.testResizeFollowsThePointerKeepsTheShapeAndStaysWithinLimits),
                ("persona locked artwork moves and resizes from handles", suite.testLockedArtworkMovesAndResizesFromItsHandlesAndStaysLocked),
                ("persona handles appear after a brief pause", suite.testHandlesAppearAfterABriefPauseNearTheArtwork),
                ("persona unlocked artwork takes clicks only on its body", suite.testUnlockedArtworkTakesClicksOnlyOnItsBody),
                ("persona handles change only their own copy", suite.testHandlesChangeOnlyTheirOwnCopy),
                ("persona released controller stops following the pointer", suite.testReleasedControllerStopsFollowingThePointer),
                ("persona card moved under a still pointer", suite.testCardMovedUnderAStillPointerTakesClicksByWhereItIs),
                ("persona tall artwork keeps its size through a resize", suite.testTallArtworkKeepsItsSizeThroughAResize),
                ("persona native window focus lock drag and visibility", PersonaTests().testNativeOverlayWindowAndDragLifecycle),
                ("optional offscreen persona handle renders", suite.testOffscreenHandleRenders)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-one-card-only"] {
            // Disposable libraries only; no shortcut, preference or microphone.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let oneCard = PersonaOneCardTests(), sessions = PersonaSessionTests(), personas = PersonaTests(), workspace = PersonaWorkspaceTests()
            let tests: [(String, () throws -> Void)] = [
                ("one card despite many, missing or large saved items", oneCard.testOneCardShowsDespiteManyMissingOrLargeUnrelatedItems),
                ("one card unavailable request keeps the shown card", oneCard.testUnavailableRequestedCardKeepsTheShownCardAndCyclingContinues),
                ("one card bad replacement keeps the shown card", oneCard.testReplacingTheShownCardWithABadOneKeepsIt),
                ("one card oversized request stays within the budget", oneCard.testOversizedRequestedCardKeepsTheShownCardWithinTheBudget),
                ("one card decoding drops neighbours before refusing", oneCard.testDecodingDropsNeighboursOnceMoreBeforeRefusing),
                ("one card frozen sources and bounded decoding", oneCard.testFrozenSourcesKeepAppearanceAndDecodingStaysBounded),
                ("one card failed Next in live menu and panel notice", oneCard.testFailedNextIsReportedInTheLiveMenuAndThePanelNotice),
                ("one card Next with no other card says so", oneCard.testNextWithNoOtherCardSaysSo),
                ("prepared sessions keep their limits and preflight", oneCard.testPreparedSessionsKeepTheirLimitsAndPreflight),
                ("persona sessions: bounded replacement preflight", sessions.testBoundedPreflightAlsoProtectsLegacyShowAndCurrentSession),
                ("persona: visible single-card launch failure", sessions.testSingleCardLaunchFailureReturnsErrorAndPreservesExistingOutput),
                ("persona sessions: frozen artwork and failed start", sessions.testFrozenArtworkSurvivesLibraryEditsAndFailedReplacementStart),
                ("shared persona menu frozen target and session generation", sessions.testSharedMenuTargetsFrozenCopiesAndRejectsPreviousSessionActions),
                ("persona sessions: read-only and busy state", sessions.testReadOnlySessionsAndInteractionGuardsNeverWriteOrTrapOverlays),
                ("personas: LiveCandidatesRemainScopedAndHUDLabelsExcludePrivateNames", personas.testLiveCandidatesRemainScopedAndHUDLabelsExcludePrivateNames),
                ("persona ungrouped HUD scope and native controls", personas.testUngroupedHUDStaysScopedToDisplayedPersonaAndControlsItsLifecycle),
                ("persona read-only HUD browsing and placement", personas.testReadOnlyUngroupedHUDDoesNotPersistBrowsingOrPlacement),
                ("persona workspace single card immediate show and stop", workspace.testWorkspaceSingleCardShowsAndStopsWithoutDismissal),
                ("persona workspace failure preserves active session", workspace.testWorkspaceFailureIsImmediateAndDoesNotReplaceSession)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-voice-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let suite = PersonaVoiceTests(), latency = PersonaVoiceLatencyTests(), appearance = VoiceAppearanceTests()
            let tests: [(String, () throws -> Void)] = [
                ("persona voice ring listens only while on and showing", suite.testVoiceRingListensOnlyWhileOnAndItsPersonaShows),
                ("persona voice ring asks while preparing and stops when unavailable", suite.testVoiceRingAsksWhilePreparingAndStopsWhenTheMicrophoneIsUnavailable),
                ("persona voice ring single floating persona", suite.testSingleFloatingPersonaIsPlacedWithRoomForItsRing),
                ("persona voice ring placement keeps artwork and ring on screen", suite.testPlacementKeepsArtworkSizeAndTheRingOnScreen),
                ("persona voice analyzer quiet and loud microphones", suite.testAnalyzerHearsQuietAndLoudMicrophonesAlikeButNotTheRoom),
                ("persona voice analyzer room and startup silence", suite.testAnalyzerLearnsTheRoomAndIgnoresStartupSilence),
                ("persona voice analyzer recognises a voice by its pitch", suite.testAnalyzerRecognisesAVoiceByItsPitch),
                ("persona voice ring outline fitting", suite.testOutlineFollowsARoundBadgeACardAndAPhoto),
                ("persona voice ring is the chosen colour", suite.testRingIsTheChosenColourWhateverTheArtwork),
                ("persona voice ring geometry", suite.testRingGeometryHugsTheArtworkAndScalesWithIt),
                ("persona voice ring sleeps in silence and rises at once", suite.testRingSleepsInSilenceAndRisesOnTheFirstSyllable),
                ("persona voice outline latency: speech of every kind", latency.testOutlineRespondsWithinTargetsToSpeechOfEveryKind),
                ("persona voice outline latency: long speech never becomes the room", latency.testLongSpeechNeverBecomesTheRoom),
                ("persona voice outline: steady noise, typing and hum stay quiet", latency.testSteadyNoiseTypingAndHumNeverLightTheOutline),
                ("persona voice outline: raised voice reads as loud", latency.testRaisedVoiceShowsLoudAndUsualVoiceShowsNormal),
                ("persona voice outline state eases and settles", latency.testOutlineStateEasesAndSettlesWithoutFrames),
                ("persona voice outline lit through a held vowel", latency.testHeldVowelKeepsTheOutlineLit),
                ("persona voice outline: chimes, beeps and music settle", latency.testChimesBeepsAndMusicLightItOnlyWhileTheySound),
                ("optional Mac voices through the voice outline", latency.testSpokenSentencesFromSay),
                ("optional offscreen voice ring renders", suite.testOffscreenVoiceRingRenders),
                ("voice appearance: shared voice states with distinct responses", appearance.testSurfacesShareVoiceStatesWithDistinctResponse),
                ("voice appearance: trace fits the compact mark and peaks in the middle", appearance.testTraceFitsTheCompactMarkAndPeaksInTheMiddle),
                ("voice appearance: input follows syllables and outline stays calm", appearance.testInputTraceFollowsSyllablesWhileTheOutlineStaysCalm),
                ("voice appearance: soft usable input is visible", appearance.testTraceShowsSoftInputTheRecorderCanKeep),
                ("voice appearance: trace rests when still, fixed with Reduce Motion", appearance.testTraceRestsWhenStillAndHoldsItsShapeWithReduceMotion),
                ("voice appearance: recorder level meets the targets", appearance.testRecorderLevelMeetsTheTargets),
                ("voice appearance: SwiftUI trace drops into a toolbar row", appearance.testSwiftUITraceDropsIntoAToolbarRow),
                ("optional voice appearance gallery and motion", appearance.testOffscreenVoiceAppearanceGallery)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-shown-only"] {
            // Disposable libraries and synthetic artwork only; a fake microphone; no shortcut or preference.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let shown = PersonaShownTests(), oneCard = PersonaOneCardTests(), personas = PersonaTests(), workspace = PersonaWorkspaceTests()
            let tests: [(String, () throws -> Void)] = [
                ("shown: browsing never replaces or hides the shown card", shown.testBrowsingNeverReplacesOrHidesTheShownCard),
                ("shown: Replace shown keeps size, place and lock", shown.testReplaceShownWithSelectedKeepsSizePlaceAndLock),
                ("shown: Update shown card changes only that copy", shown.testUpdateShownCardChangesOnlyThatCopy),
                ("shown: a hidden card is kept with the microphone stopped", shown.testHiddenCardIsKeptUntilShowAgainWithTheMicrophoneStopped),
                ("shown: a prepared copy is identified and changed alone", shown.testPreparedCopyIsIdentifiedAndChangedAlone),
                ("shown: the End shortcut releases the card", shown.testEndShortcutReleasesTheCard),
                ("one card failed Next in live menu and panel notice", oneCard.testFailedNextIsReportedInTheLiveMenuAndThePanelNotice),
                ("one card bad replacement keeps the shown card", oneCard.testReplacingTheShownCardWithABadOneKeepsIt),
                ("persona ungrouped HUD scope and native controls", personas.testUngroupedHUDStaysScopedToDisplayedPersonaAndControlsItsLifecycle),
                ("persona workspace single card immediate show and stop", workspace.testWorkspaceSingleCardShowsAndStopsWithoutDismissal),
                ("optional offscreen selected and shown renders", shown.testOffscreenShownRenders)
            ]
            var skipped = 0
            for (name, test) in tests {
                // An optional render runs only when asked for; otherwise it is reported as skipped.
                if name.hasPrefix("optional"), ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] == nil {
                    skipped += 1; print("SKIP \(name): set WORKBENCH_LAYOUT_EVIDENCE to render"); continue
                }
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            if skipped > 0 { print("\(skipped) skipped") }
            print("\(tests.count - skipped) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-appearance-only"] {
            // Disposable libraries and synthetic artwork only; a fake microphone; no shortcut or preference.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let appearance = PersonaAppearanceTests(), creation = PersonaCreationTests(), personas = PersonaTests()
            let tests: [(String, () throws -> Void)] = [
                ("appearance: new portrait is a Circle and switching keeps everything", appearance.testNewPortraitStartsAsCircleAndSwitchingShapesKeepsEverything),
                ("appearance: existing personas keep their look", appearance.testExistingPersonasKeepTheirLookAfterUpgrade),
                ("appearance: shown copy reshapes keeping width, centre, lock and outline", appearance.testShownCopyReshapesKeepingWidthCentreLockAndOutline),
                ("appearance: live shape uses frozen ingredients for that copy only", appearance.testLiveShapeUsesFrozenIngredientsAndChangesOnlyThatCopy),
                ("appearance: prepared copy changes alone and saves only when asked", appearance.testPreparedCopyChangesShapeAloneAndSavesOnlyWhenAsked),
                ("appearance: one keyboard-reachable choice", appearance.testAppearanceChoiceIsOneKeyboardReachableSelection),
                ("appearance: the toolbar changes exactly the captured copy", appearance.testToolbarChangesExactlyTheCapturedCopy),
                ("appearance: the toolbar targets one prepared copy exactly", appearance.testToolbarTargetsOnePreparedCopyExactly),
                ("appearance: a paused copy reshapes around its centre", appearance.testPausedCopyReshapesAroundItsCentre),
                ("appearance: tall, wide, small and transparent artwork", appearance.testTallWideSmallAndTransparentArtworkAgreeWithTheirOutline),
                ("appearance: deck keeps the shown look until the new one is ready", appearance.testDeckKeepsTheShownLookUntilTheNewOneIsReady),
                ("appearance: scene placement uses the chosen look", appearance.testScenePlacementUsesTheChosenLook),
                ("new portrait Add saves once", creation.testAddSavesOneItemWithOneMembershipOnce),
                ("personas: EditableCardRenderingAndSaveFailurePreserveSources", personas.testEditableCardRenderingAndSaveFailurePreserveSources),
                ("persona scene attachment transparency and missing-file recovery", personas.testSceneAttachmentTransparencyAndMissingFile),
                ("optional offscreen appearance renders", appearance.testOffscreenAppearanceRenders)
            ]
            var skipped = 0
            for (name, test) in tests {
                // An optional render runs only when asked for; otherwise it is reported as skipped.
                if name.hasPrefix("optional"), ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] == nil {
                    skipped += 1; print("SKIP \(name): set WORKBENCH_LAYOUT_EVIDENCE to render"); continue
                }
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            if skipped > 0 { print("\(skipped) skipped") }
            print("\(tests.count - skipped) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-creation-only"] {
            // Disposable libraries and synthetic portraits only; no shortcut, preference or microphone.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let creation = PersonaCreationTests(), starters = PersonaStarterTests(), personas = PersonaTests()
            let tests: [(String, () throws -> Void)] = [
                ("new portrait cancel at any step leaves the library", creation.testCancellingANewPortraitAtAnyStepLeavesTheLibraryUnchanged),
                ("new portrait second draft never replaces an open one", creation.testASecondDraftNeverReplacesAnOpenOne),
                ("new portrait draft clears an earlier notice", creation.testANewDraftClearsAnEarlierNotice),
                ("new portrait repeated cancels leave nothing", creation.testRepeatedCancelsLeaveNoDuplicatesOrFiles),
                ("new portrait Add saves once", creation.testAddSavesOneItemWithOneMembershipOnce),
                ("new portrait failed Add keeps the draft", creation.testFailedAddKeepsTheDraftAndRetryAddsExactlyOne),
                ("profile reference and replacement keep identity and original artwork", creation.testProfileReferenceAndPhotoReplacementPreserveIdentityAndOriginals),
                ("profile failed replacement keeps draft and files", creation.testFailedProfileReplacementKeepsDraftAndFiles),
                ("saved card edit cancel and shown card", creation.testCancellingAnEditLeavesTheSavedCardAndTheShownCardAlone),
                ("read-only library makes no draft", creation.testReadOnlyLibraryMakesNoDraft),
                ("optional offscreen persona editor renders", creation.testOffscreenEditorRenders),
                ("persona starter: MissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas", starters.testMissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas),
                ("persona starter: ChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies", starters.testChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies),
                ("personas: EditableCardRenderingAndSaveFailurePreserveSources", personas.testEditableCardRenderingAndSaveFailurePreserveSources),
                ("persona corrupt future and concurrent archive preservation", personas.testCorruptFutureAndConcurrentArchivesStayUntouched)
            ]
            var skipped = 0
            for (name, test) in tests {
                // An optional render runs only when asked for; otherwise it is reported as skipped.
                if name.hasPrefix("optional"), ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] == nil {
                    skipped += 1; print("SKIP \(name): set WORKBENCH_LAYOUT_EVIDENCE to render"); continue
                }
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            if skipped > 0 { print("\(skipped) skipped") }
            print("\(tests.count - skipped) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--shortcut-settings-only"] {
            // Data-only: do not create NSApplication, monitors, windows or global registrations.
            let suite = CoreTests()
            let tests: [(String, () throws -> Void)] = [
                ("shortcut defaults", suite.testDefaultShortcutsAreUniqueAndComplete),
                ("untouched shortcut migration", suite.testUpdateMovesOnlyUntouchedShortcutsToPresenterDefaults),
                ("chosen shortcut preservation", suite.testNewDefaultNeverTakesAChosenCombination),
                ("app command migration", suite.testUpdateReturnsAppCommandsToOtherApps),
                ("later old-key choices", suite.testFreshInstallKeepsLaterChoicesOfOldKeys),
                ("settings persistence and validation", suite.testPreferencesPersistAndClamp),
                ("persona migration preserves existing assignments", suite.testPersonaShortcutMigrationPreservesExistingOverlayKeys),
                ("unreadable settings preservation", suite.testCorruptPreferencesArePreservedForRecovery),
                ("duplicate registration plan", suite.testDuplicateShortcutRegistrationPlanPausesBothWithoutChangingSettings)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--annotation-menu-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let suite = AnnotationMenuTests()
            let tests: [(String, () throws -> Void)] = [
                ("annotation menu live shortcuts and single key owner", suite.testMenuUsesLiveShortcutsWithoutAddingAKeyRoute),
                ("annotation menu native actions and live state", suite.testNativeActionsRefreshSelectionAndHistory),
                ("annotation menu preserves ink and boards", suite.testBoardsAndControlsPreserveInkUntilExplicitClear),
                ("stop drawing closes the board and keeps its ink", suite.testStopDrawingClosesTheBoardAndKeepsItsInk),
                ("pen key leaves the board and the hint matches draw", suite.testPenKeyLeavesTheBoardAndTheHintMatchesDraw),
                ("annotation menu rechecks admission", suite.testStaleMenuCannotBypassChangedAdmission)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--draw-page-only"] {
            // Views only: no start(), overlays, monitors or shortcut registration.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let drawPage = DrawPageTests()
            let tests: [(String, () throws -> Void)] = [
                ("embedded Draw page shows no inactive palette settings", drawPage.testEmbeddedDrawPageShowsNoInactivePaletteSettings)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--drawing-concurrency-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let workbench = WorkbenchModuleTests()
            let tests: [(String, () throws -> Void)] = [
                ("drawing admission preserves independent guards", workbench.testDrawingAdmissionIsSeparateFromGeneralInteraction),
                ("finish drawing preserves ink and settled input", workbench.testFinishDrawingPreservesBoardInkAndReportsSettledTransitions),
                ("shortcut replacement releases only held drawing", workbench.testShortcutReregistrationReleasesOnlyHeldDrawing)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--scene-media-only"] {
            _ = NSApplication.shared
            let media = SceneMediaTests()
            let tests: [(String, () throws -> Void)] = [
                ("logo browser addresses and inline validation", media.testSearchAndImageAddressesStayBounded),
                ("logo browser bounded download validation", media.testDownloadsRejectOversizeHTMLAndInvalidBytes),
                ("logo browser request cancellation", media.testDownloadCancellationStopsTheOwnedRequest),
                ("logo browser explicit captured-scene save", media.testWebLogoPreviewAndExplicitSavePreserveOtherScenes),
                ("editor motion suppression and drag pause", media.testMotionPolicyReportsSuppressionAndCanvasPausesForEditing),
                ("editor drag revision preservation", SceneSyncAdapterTests().testCanvasDragCommitsOnceAndRejectsInterveningRevision),
                ("ambient poster orientation and clipping", AmbientSceneTests().testMovingSceneViewMatchesPosterOrientationAndClipsCloudsToWindow),
                ("ambient missing artwork and ordinary-photo playback", AmbientSceneTests().testMissingRigAssetKeepsCompletePosterAndDoesNotBecomePhotoZoom),
                ("motion exports stay still", GentleMotionTests().testMotionDoesNotChangeStillExport),
                ("motion transparent photograph base", GentleMotionTests().testTransparentPhotographKeepsStillBase)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--persona-session-fixture"] || Bundle.main.bundleIdentifier == "app.workbench.overlay-review" {
            _ = NSApplication.shared
            PersonaSessionFixture().run()
            return
        }
        if args == ["--colour-accessibility-only"] {
            let suite = CoreTests(), before = assertionFailures
            suite.testInkColourAccessibilityDescriptions()
            if assertionFailures == before { print("PASS ink colour accessibility descriptions") }
            print("1 tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--backdrop-fixture"] {
            _ = NSApplication.shared
            BackdropReplacementFixture().run()
            return
        }
        if args == ["--board-presentation-fixture"] {
            _ = NSApplication.shared
            BoardPresentationFixture().run()
            return
        }
        if args == ["--timer-placement-only"] {
            let timerPlacement = BreakTimerPlacementTests()
            let tests: [(String, () throws -> Void)] = [
                ("timer free and named placement recovery", timerPlacement.testFreeAndNamedPositionsRecoverAcrossDisplayChanges),
                ("timer placement corrupt and concurrent preservation", timerPlacement.testStoragePreservesFutureCorruptAndConcurrentFiles)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--timer-transport-only"] {
            // Coordinator only: no global shortcut, chime or saved preference outside a temporary folder.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let timerTransport = TimerTransportTests()
            let tests: [(String, () throws -> Void)] = [
                ("timer idle and reset start without a hidden countdown", timerTransport.testIdleAndResetOfferStartAndNeverResumeAHiddenCountdown),
                ("timer finished restarts through the normal start path", timerTransport.testFinishedOffersRestartThroughTheNormalStartPath),
                ("timer paused resume and visibility-only shortcut", timerTransport.testPausedResumeKeepsItsTimeAndTheShortcutOnlyShowsOrHides),
                ("timer transport keeps marks and boards", timerTransport.testTransportLeavesMarksAndBoardsAlone),
                ("timer controls perform only the transport they showed", timerTransport.testAShownTransportIsTheOnlyOneItPerforms),
                ("timer one name and word set on every surface", timerTransport.testOneNameAndWordSetFollowTheTimerEverywhere),
                ("timer Position… sits by the window or the pointer", timerTransport.testPositionControlSitsByTheWindowOrThePointer)
            ]
            for (name, test) in tests {
                let before = assertionFailures
                do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
                if assertionFailures == before { print("PASS \(name)") }
            }
            print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--screenshot-native-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            do { try IntegrationTests().testScreenshotHandoffPreservesInkAndSuspendsInput() }
            catch { assertionFailures += 1; print("FAIL screenshot native handoff: \(error)") }
            print("1 tests · \(assertionCount) assertions · \(assertionFailures) failures")
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--timer-placement-native"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            do { try BreakTimerPlacementTests().testNativeTimerReopensAtItsSavedAnchor() }
            catch { assertionFailures += 1; fputs("FAIL timer native close and reopen placement: \(error)\n", stderr) }
            fputs("1 native timer placement test · \(assertionCount) assertions · \(assertionFailures) failures\n", stderr)
            exit(assertionFailures == 0 ? 0 : 1)
        }
        if args == ["--phone-guide-fixture"] || Bundle.main.bundleIdentifier == "app.workbench.phone-route-review" {
            _ = NSApplication.shared
            PhonePresentationFixture().run()
            return
        }
        let boardPresentationOnly = args == ["--board-presentation-only"]
        let backdropOnly = args == ["--backdrop-only"]
        let personaQuickOnly = args == ["--persona-quick-only"]
        let personaControlsOnly = args == ["--persona-controls-only"]
        let screenshotStateOnly = args == ["--screenshot-state-only"]
        let sceneListOnly = args == ["--scene-list-only"]
        guard args.isEmpty || args == ["--ci"] || args == ["--scenes-only"] || boardPresentationOnly || backdropOnly || personaQuickOnly || personaControlsOnly || screenshotStateOnly || sceneListOnly else {
            print("Usage: StageMarkTests [--ci | --scenes-only | --scene-list-only | --notice-owners-only | --persona-quick-only | --board-presentation-only | --board-presentation-fixture | --backdrop-only | --backdrop-fixture | --persona-session-fixture | --phone-guide-fixture]")

            exit(2)
        }
        let scenesOnly = args == ["--scenes-only"]
        let hostedCI = args == ["--ci"]
        if !screenshotStateOnly {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            if !scenesOnly && !boardPresentationOnly && !backdropOnly && !personaQuickOnly && !personaControlsOnly && !sceneListOnly { NSApp.finishLaunching() }
        }
        let suite = CoreTests()
        let integration = IntegrationTests()
        let scenes = SceneTests()
        let assets = SceneAssetTests()
        let demo = DemoModeTests()
        let phonePresentation = PhonePresentationTests()
        let phoneLink = PhoneLinkTests()
        let phoneEnd = PhoneEndTests()
        let phoneCapture = PhoneCaptureTests()
        let gentleMotion = GentleMotionTests()
        let ambientScenes = AmbientSceneTests()
        let viewportFit = ViewportFitTests()
        let logoImport = LogoImportTests()
        let sceneMedia = SceneMediaTests()
        let personas = PersonaTests()
        let personaSessions = PersonaSessionTests()
        let personaOneCard = PersonaOneCardTests()
        let personaControls = PersonaControlsTests()
        let personaHandles = PersonaHandleTests()
        let personaControlTests: [(String, () throws -> Void)] = [
            ("persona controls: single size slider", personaControls.testSingleSizeControlIsVisibleAndRoutesAbsoluteWidth),
            ("persona controls: selected copy and empty recovery", personaControls.testSessionControlsTargetSelectedCopyAndRecoverFromEmptySet)
        ]
        let personaWorkspace = PersonaWorkspaceTests()
        let personaVoice = PersonaVoiceTests()
        let personaVoiceLatency = PersonaVoiceLatencyTests()
        let voiceAppearance = VoiceAppearanceTests()
        let personaStarters = PersonaStarterTests()
        let personaCreation = PersonaCreationTests()
        let personaAppearance = PersonaAppearanceTests()
        let personaShown = PersonaShownTests()
        let personaCamera = PersonaCameraTests()
        let floating = FloatingControlGeometryTests()
        let timerPlacement = BreakTimerPlacementTests()
        let timerTransport = TimerTransportTests()
        let sceneSync = SceneSyncAdapterTests()
        let sceneList = SceneListTests()
        let sceneListTests: [(String, () throws -> Void)] = [
            ("scene list filtered selection", sceneList.testSelectionFiltersAndNeverTargetsHiddenScenes),
            ("scene list atomic confirmed deletion and preserved images", sceneList.testConfirmedBulkDeletionIsOneCommitAndPreservesEveryImage),
            ("scene list stale and failed deletion preservation", sceneList.testStaleOrFailedBulkDeletionKeepsWholeSelection),
            ("scene list rename search and stale snapshots", sceneList.testRenameReconcilesSearchAndRejectsStaleSnapshots),
            ("scene list drag selection and stale token rejection", sceneList.testDragReordersSelectionAndRejectsStaleOrForeignTokens),
            ("scene list keyboard focus ownership", sceneList.testDeleteAndReturnBelongOnlyToFocusedTable),
            ("scene list native inline rename commit and cancel", sceneList.testInlineRenameUsesFieldEditorAndCommitsOrCancels)
        ]
        let workbench = WorkbenchModuleTests()
        let boardExport = BoardExportTests()
        let presentationLifecycle = PresentationLifecycleTests()
        let backdrop = BackdropReplacementTests()
        let backdropTests: [(String, () throws -> Void)] = [
            ("photo handoff preview preserves scene and independent image", backdrop.testPhotoHandoffPreviewTargetsChosenSceneAndKeepsIndependentCopy),
            ("backdrop draft choice crop and cancellation", backdrop.testDraftCropChoiceAndCancelNeverWrite),
            ("backdrop commit preserves current foreground and originals", backdrop.testImportedCommitPreservesCurrentForegroundAndOriginals),
            ("backdrop saved reuse deduplication and missing-image repair", backdrop.testSavedReuseDeduplicationAndMissingBackdropRepair),
            ("backdrop stale deleted invalid and blocked preservation", backdrop.testStaleDeletedInvalidAndBlockedApplyPreserveBytes),
            ("backdrop failed save rollback and changed-image rejection", backdrop.testCommitFailureCleansOnlyNewCopyAndChangedSavedImageRejects),
            ("backdrop preview and saved composition pixels", backdrop.testPreviewAndSavedRenderingAtSameAspectKeepForeground)
        ]
        let drawPage = DrawPageTests()
        var tests: [(String, () throws -> Void)] = [
            ("embedded Draw page shows no inactive palette settings", drawPage.testEmbeddedDrawPageShowsNoInactivePaletteSettings),
            ("board export pixels orientation text and Retina", boardExport.testBoardPixelsOrientationTextAndRetinaScale),
            ("board snapshot file bounds and invalid input", boardExport.testSnapshotPersistenceBoundsAndInvalidInput),
            ("board private clipboard image and failure preservation", boardExport.testPrivateClipboardPNGAndFailurePreservation),
            ("presentation window and fullscreen lifecycle", presentationLifecycle.testModeChangesKeepPresentationAndEndClosesOnce),
            ("presentation transition interruption and failure recovery", presentationLifecycle.testEndDuringNativeTransitionsAndFailureRecovery),
            ("phone link: nothing on USB", phoneLink.testNothingAttachedNamesTheCableAndTheAccessoryPrompt),
            ("phone link: a cold start looks before it says anything is wrong", phoneLink.testAColdStartLooksBeforeItSaysAnythingIsWrong),
            ("phone link: phone on the bus without a screen", phoneLink.testPhoneOnTheBusWithoutAScreenAsksForUnlockAndTrust),
            ("phone link: one phone screen adopted, video device waits", phoneLink.testOnePhoneScreenIsAdoptedAndAPlainVideoDeviceWaitsForAClick),
            ("phone link: several screens and a remembered absent phone", phoneLink.testSeveralScreensAskForAChoiceAndARememberedAbsentPhoneWaits),
            ("phone link: remembered phone reads as connecting", phoneLink.testRememberedPhonePresentReadsAsConnectingUntilTheSessionSpeaks),
            ("phone link: monitor fixture and mirror", phoneLink.testMonitorFixtureAndMirrorAreIndependent),
            ("phone link: released for an Apple app", phoneLink.testReleasedForAnAppleAppSaysSoUntilReconnect),
            ("phone link: session phases outrank availability", phoneLink.testSessionPhasesOutrankAvailability),
            ("phone link: permission outranks availability", phoneLink.testPermissionOutranksAvailabilityAndRestrictedOffersNoToggle),
            ("phone link: nouns follow the device", phoneLink.testNounsFollowTheDeviceNotTheSerial),
            ("phone link: USB classification", phoneLink.testUSBClassificationKeepsPhonesAndDropsOtherAppleDevices),
            ("phone link: diagnostic without identifiers", phoneLink.testDiagnosticNamesFactsWithoutIdentifiers),
            ("phone: one screen adopted, lost device never switched", phonePresentation.testOnePhoneScreenIsAdoptedAndALostDeviceNeverSwitches),
            ("phone: handoff waits for capture and window", phonePresentation.testNativeHandoffWaitsForBothCaptureAndWindowInEitherOrder),
            ("phone: handoff launch and ordinary close ownership", phonePresentation.testHandoffKeepsFirstRequestAndDoesNotRetryFailedLaunchOrOrdinaryClose),
            ("phone: handoff native transition failure", phonePresentation.testHandoffWaitsThroughFailedNativeTransitionAndRepeatedEnd),
            ("phone: capture release retains pending handoff", phonePresentation.testCaptureStopCompletionRetainsHandoffAfterPresenterRelease),
            ("phone link: ended until a deliberate action", phoneLink.testEndedSaysSoAndOffersOnlyADeliberateWayBack),
            ("phone link: a failed USB check is not an empty bus", phoneLink.testAFailedUSBCheckIsNotAnEmptyBus),
            ("phone link: monitor keeps a failed look and drops a late one", phoneLink.testTheMonitorKeepsAFailedLookAndDropsALateOne),
            ("phone link: bounded capture faults and QuickTime only when busy", phoneLink.testCaptureFaultsStayBoundedAndOnlyABusyDeviceNamesQuickTime),
            ("phone link: reports carry kinds, never personal names", phoneLink.testReportsCarryKindsNeverPersonalNames),
            ("phone link: copy success depends on the pasteboard", phoneLink.testCopySuccessDependsOnThePasteboardsAnswer),
            ("phone End: a late permission answer stays ended", phoneEnd.testEndWithAPendingPermissionStaysEndedWhenTheAnswerArrivesLate),
            ("phone End: a late frame neither goes live nor reopens", phoneEnd.testALateFrameAfterEndNeitherGoesLiveNorReopens),
            ("phone End: stale stage steps cannot take the phone back", phoneEnd.testTheStagesStepsAfterEndCannotTakeThePhoneBack),
            ("phone End: a fresh visit or a re-plug resumes, End's own reopening does not", phoneEnd.testEndedResumesOnAFreshVisitOrWhenThePhoneIsPluggedInAgain),
            ("phone End: the host restores its window and End stays final", phoneEnd.testEndAsksTheHostToRestoreItsWindowAndStaysEnded),
            ("phone capture: the one phone screen is adopted beside a camera", phoneCapture.testTheOnePhoneScreenIsAdoptedBesideACamera),
            ("phone capture: Present and Reconnect after End try at once", phoneCapture.testPresentAfterEndTriesAtOnce),
            ("phone capture: a disconnect found by the health check is said", phoneCapture.testADisconnectFoundByTheHealthCheckIsSaid),
            ("phone capture: a stall keeps the last frame and says so beside it", phoneCapture.testAStallKeepsTheLastFrameAndSaysSoBesideIt),
            ("phone capture: another app's interruption is named and recovers", phoneCapture.testAnInterruptionByAnotherAppSaysSoAndRecovers),
            ("phone capture: the page's preview outlives a brief cover", phoneCapture.testThePagesPreviewOutlivesABriefCover),
            ("phone capture: an unchanged answer is not republished", phoneCapture.testAnUnchangedAnswerIsNotRepublished),
            ("phone capture: the stage is wired before the page", phoneCapture.testTheStageIsWiredBeforeThePagesPreview),
            ("phone capture: every frame is drawn on the page and the stage", phoneCapture.testEveryFrameOfTheSessionIsDrawnOnThePageAndTheStage),
            ("every SF Symbol StageKit names exists", SymbolTests().testEverySymbolStageKitNamesExists),
            ("persona sessions: empty return and visible feedback", personaSessions.testEmptySetCanBeRevisitedAndLiveFailuresStayVisible),
            ("persona sessions: opt-in archive migration", personaSessions.testOptInMigrationBacksUpExactArchiveAndPreservesLegacyPlacement),
            ("persona sessions: independent placed copies", personaSessions.testTwoInstancesOwnIndependentGeometryVisibilityLockAndOrder),
            ("persona sessions: paused switching and frozen scope", personaSessions.testPausedGroupSwitchKeepsLayoutsAndFrozenAllowedScope),
            ("persona sessions: frozen artwork and failed start", personaSessions.testFrozenArtworkSurvivesLibraryEditsAndFailedReplacementStart),
            ("persona sessions: explicit conflict-aware layout save", personaSessions.testSaveLayoutIsExplicitAtomicAndRejectsChangedPreparation),
            ("persona sessions: read-only and busy state", personaSessions.testReadOnlySessionsAndInteractionGuardsNeverWriteOrTrapOverlays),
            ("persona sessions: invalid and future archive preservation", personaSessions.testInvalidLayoutsAndFutureArchivePreserveOriginalBytes),
            ("persona sessions: bounded replacement preflight", personaSessions.testBoundedPreflightAlsoProtectsLegacyShowAndCurrentSession),
            ("persona: visible single-card launch failure", personaSessions.testSingleCardLaunchFailureReturnsErrorAndPreservesExistingOutput),
            ("one card despite many, missing or large saved items", personaOneCard.testOneCardShowsDespiteManyMissingOrLargeUnrelatedItems),
            ("one card unavailable request keeps the shown card", personaOneCard.testUnavailableRequestedCardKeepsTheShownCardAndCyclingContinues),
            ("one card bad replacement keeps the shown card", personaOneCard.testReplacingTheShownCardWithABadOneKeepsIt),
            ("one card oversized request stays within the budget", personaOneCard.testOversizedRequestedCardKeepsTheShownCardWithinTheBudget),
            ("one card decoding drops neighbours before refusing", personaOneCard.testDecodingDropsNeighboursOnceMoreBeforeRefusing),
            ("one card frozen sources and bounded decoding", personaOneCard.testFrozenSourcesKeepAppearanceAndDecodingStaysBounded),
            ("one card failed Next in live menu and panel notice", personaOneCard.testFailedNextIsReportedInTheLiveMenuAndThePanelNotice),
            ("one card Next with no other card says so", personaOneCard.testNextWithNoOtherCardSaysSo),
            ("prepared sessions keep their limits and preflight", personaOneCard.testPreparedSessionsKeepTheirLimitsAndPreflight),
            ("floating: AllTargetsAreDistinctFiniteAndBounded", floating.testAllTargetsAreDistinctFiniteAndBounded),
            ("floating: GuideLayoutPreservesTargetsAndFlipsDisplayCoordinates", floating.testGuideLayoutPreservesTargetsAndFlipsDisplayCoordinates),
            ("floating: GuideStateClearsWhenDragOrDisplayEnds", floating.testGuideStateClearsWhenDragOrDisplayEnds),
            ("personas: LegacyMigrationKeepsFinishedPixelsAndRequiresExplicitGroup", personas.testLegacyMigrationKeepsFinishedPixelsAndRequiresExplicitGroup),
            ("personas: OrderedGroupsAndDeletionNeverSelectAnotherCustomer", personas.testOrderedGroupsAndDeletionNeverSelectAnotherCustomer),
            ("personas: LiveCandidatesRemainScopedAndHUDLabelsExcludePrivateNames", personas.testLiveCandidatesRemainScopedAndHUDLabelsExcludePrivateNames),
            ("personas: EditableCardRenderingAndSaveFailurePreserveSources", personas.testEditableCardRenderingAndSaveFailurePreserveSources),
            ("sceneSync: Mac edit keeps original mobile attachments", sceneSync.testMacEditKeepsOriginalMobileAttachmentsInPortablePackage),
            ("sceneSync: MigrationRetainsEveryLayerAndNeverWritesLegacyAgain", sceneSync.testMigrationRetainsEveryLayerAndNeverWritesLegacyAgain),
            ("sceneSync: MissingLegacyAssetStaysVisibleAndRetryIsIdempotent", sceneSync.testMissingLegacyAssetStaysVisibleAndRetryIsIdempotent),
            ("sceneSync: MacEditsPreservePortableFieldsAndRejectStaleRevision", sceneSync.testMacEditsPreservePortableFieldsAndRejectStaleRevision),
            ("sceneSync: PersonaPlacementCopiesRenderedAndAuthoredValues", sceneSync.testPersonaPlacementCopiesRenderedAndAuthoredValues),
            ("sceneSync: BackdropUsesCurrentForegroundAndConcurrentStoreFailureKeepsOriginals", sceneSync.testBackdropUsesCurrentForegroundAndConcurrentStoreFailureKeepsOriginals),
            ("sceneSync: CanvasDragCommitsOnceAndRejectsInterveningRevision", sceneSync.testCanvasDragCommitsOnceAndRejectsInterveningRevision),
            ("floating controls anchors bounds and resize", floating.testAnchorsBoundsAndResize),
            ("floating controls snap and display recovery", floating.testSnapThresholdsAndDisplayRecovery),
            ("timer free and named placement recovery", timerPlacement.testFreeAndNamedPositionsRecoverAcrossDisplayChanges),
            ("timer placement corrupt and concurrent preservation", timerPlacement.testStoragePreservesFutureCorruptAndConcurrentFiles),
            ("timer native close and reopen placement", timerPlacement.testNativeTimerReopensAtItsSavedAnchor),
            ("timer idle and reset start without a hidden countdown", timerTransport.testIdleAndResetOfferStartAndNeverResumeAHiddenCountdown),
            ("timer finished restarts through the normal start path", timerTransport.testFinishedOffersRestartThroughTheNormalStartPath),
            ("timer paused resume and visibility-only shortcut", timerTransport.testPausedResumeKeepsItsTimeAndTheShortcutOnlyShowsOrHides),
            ("timer transport keeps marks and boards", timerTransport.testTransportLeavesMarksAndBoardsAlone),
            ("timer controls perform only the transport they showed", timerTransport.testAShownTransportIsTheOnlyOneItPerforms),
            ("timer one name and word set on every surface", timerTransport.testOneNameAndWordSetFollowTheTimerEverywhere),
            ("timer Position… sits by the window or the pointer", timerTransport.testPositionControlSitsByTheWindowOrThePointer),
            ("full-height frame persistence and edges", viewportFit.testFullHeightSurvivesSavingAndReachesBothEdges),
            ("maximum frame size across displays", viewportFit.testMaximumSizeFitsDisplayAndPreservesScreenShape),
            ("full-height export and live geometry", viewportFit.testExportAndLiveScreenUseFullHeightBorder),
            ("the phone's picture draws above the frame in a window", viewportFit.testThePhonesPictureDrawsAboveTheFrameInAWindow),
            ("logo native WebP decoding and alpha", logoImport.testWebPAndTransparentPadding),
            ("logo image orientation and rejection", logoImport.testOrientationAndInvalidImages),
            ("logo paste image and file persistence", logoImport.testPasteImageAndFilePersistence),
            ("logo browser addresses and inline validation", sceneMedia.testSearchAndImageAddressesStayBounded),
            ("logo browser bounded download validation", sceneMedia.testDownloadsRejectOversizeHTMLAndInvalidBytes),
            ("logo browser request cancellation", sceneMedia.testDownloadCancellationStopsTheOwnedRequest),
            ("logo browser explicit captured-scene save", sceneMedia.testWebLogoPreviewAndExplicitSavePreserveOtherScenes),
            ("editor motion policy and drag ownership", sceneMedia.testMotionPolicyReportsSuppressionAndCanvasPausesForEditing),
            ("persona starter: CatalogHasStableUniqueBundleNamesAndEditableLabels", personaStarters.testCatalogHasStableUniqueBundleNamesAndEditableLabels),
            ("persona starter: MissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas", personaStarters.testMissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas),
            ("persona starter: ChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies", personaStarters.testChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies),
            ("persona starter: BundledPortraitsHaveReadableArtworkAndRealTransparency", personaStarters.testBundledPortraitsHaveReadableArtworkAndRealTransparency),
            ("new portrait cancel at any step leaves the library", personaCreation.testCancellingANewPortraitAtAnyStepLeavesTheLibraryUnchanged),
            ("new portrait second draft never replaces an open one", personaCreation.testASecondDraftNeverReplacesAnOpenOne),
            ("new portrait draft clears an earlier notice", personaCreation.testANewDraftClearsAnEarlierNotice),
            ("new portrait repeated cancels leave nothing", personaCreation.testRepeatedCancelsLeaveNoDuplicatesOrFiles),
            ("new portrait Add saves once", personaCreation.testAddSavesOneItemWithOneMembershipOnce),
            ("new portrait failed Add keeps the draft", personaCreation.testFailedAddKeepsTheDraftAndRetryAddsExactlyOne),
                ("camera permission cancellation and late approval", ProfileCameraTests().testPermissionIsExplicitAndLateApprovalCannotReopen),
                ("camera denied and restricted access", ProfileCameraTests().testDeniedAndRestrictedAccessKeepAnExitWithoutOpeningHardware),
                ("camera timeout retry and stale events", ProfileCameraTests().testStartupTimeoutRetryAndLateEvents),
                ("camera fresh frames and deadline ownership", ProfileCameraTests().testOnlyFreshFramesEnableTheShutterAndOldDeadlinesCannotFailNewFrames),
                ("camera photo handoff and late cancellation", ProfileCameraTests().testPhotoHandsOffOnceAfterStoppingAndCancelDropsLatePhoto),
                ("camera source switch and interruption", ProfileCameraTests().testSwitchCameraRejectsOldPhotoAndDisconnectionRequiresExplicitRetry),
                ("camera photo failure and timeout", ProfileCameraTests().testPhotoFailureAndTimeoutLeaveTheProfileUnchanged),
                ("camera stays in profile host and Cancel preserves library", ProfileCameraTests().testProfileKeepsCameraInTheSameHostAndCancelReturnsWithoutSaving),
                ("camera frame conversion preserves pixels", ProfileCameraTests().testFrameConversionKeepsItsSizeAndOrientation),
                ("camera synthetic layouts", ProfileCameraTests().testCameraLayouts),
                ("persona camera is off until an explicit start", personaCamera.testCameraIsOffUntilAnExplicitStartAndShowsNothingBeforeAFrame),
                ("persona camera sleep cancels permission and startup", personaCamera.testSleepCancelsPermissionAndStartup),
                ("persona camera failures keep the shown artwork", personaCamera.testFailuresBeforeReadinessLeaveTheShownArtworkAndNeedAnExplicitRetry),
                ("persona camera stall and disconnection", personaCamera.testStalledAndDisconnectedFeedsRecoverOnlyOnExplicitRetry),
                ("persona camera in use is reported, not taken", personaCamera.testABusyCameraIsReportedInsteadOfTaken),
                ("persona camera choice starts only that camera", personaCamera.testChoosingAnotherCameraStartsOnlyThatOneAndDropsTheOldFeed),
                ("persona camera is a choice in the pill's Persona picker", personaCamera.testThePillPickerOffersTheCameraBesideTheCards),
                ("persona camera gone while hidden is named, never replaced", personaCamera.testShowAgainAfterTheChosenCameraHasGoneNamesItAndOpensNoOther),
                ("persona camera End overlays shortcut ends the live source", personaCamera.testEndOverlaysShortcutEndsTheLiveCameraAndKeepsTheReplacedCard),
                ("persona camera keeps saved and prepared artwork", personaCamera.testTheCameraTakesTheSlotWithoutLosingSavedOrPreparedArtwork),
                ("persona camera Hide releases it and keeps its place", personaCamera.testHideReleasesTheCameraAndKeepsItsPlaceForShowAgain),
                ("persona camera live doors and cycling", personaCamera.testLiveDoorsFollowTheCameraAndCyclingNeverReplacesIt),
                ("persona camera and prepared sets never share the slot", personaCamera.testPreparedSetsAndTheCameraNeverShareTheSlot),
                ("persona camera and photo carry the voice ring and write nothing", personaCamera.testTheRingFramesLiveCameraAndThePhotoAndWritesNothing),
                ("persona My Profile and Live Camera are one click apart in the same place", personaCamera.testMyProfileAndLiveCameraAreOneClickApartInTheSamePlace),
                ("persona live menu offers the same sources in the same words", personaCamera.testTheLiveMenuOffersTheSameSourcesInTheSameWords),
                ("persona Centre Stage follows the camera and the Video menu", personaCamera.testCenterStageFollowsTheCameraAndTheVideoMenu),
                ("persona switching keeps the outgoing picture whole until covered", personaCamera.testTheOutgoingPictureStaysWholeUntilTheIncomingOneCoversIt),
                ("persona a card stepping aside stays whole and comes back whole", personaCamera.testACardSteppingAsideStaysWholeAndComesBackWhole),
                ("persona the real bubble window carries the ring", personaCamera.testTheRealBubbleWindowCarriesTheRing),
                ("persona only the switch asks for the microphone", personaCamera.testOnlyTheSwitchAsksForTheMicrophone),
                ("persona a fault stops the ring without saving it off", personaCamera.testAFaultStopsTheRingWithoutSavingItOff),
                ("persona My Profile is always first and Live Camera checked only while it shows", personaCamera.testMyProfileIsAlwaysTheFirstRowAndLiveCameraIsCheckedOnlyWhileItShows),
                ("persona the Live Camera menu is grouped in title case", personaCamera.testTheLiveCameraMenuIsGroupedInTitleCase),
                ("persona camera bubble window moves, resizes and crops", personaCamera.testTheBubbleWindowMovesResizesAndCropsLikeArtwork),
            ("profile reference and replacement keep identity and original artwork", personaCreation.testProfileReferenceAndPhotoReplacementPreserveIdentityAndOriginals),
            ("profile failed replacement keeps draft and files", personaCreation.testFailedProfileReplacementKeepsDraftAndFiles),
            ("saved card edit cancel and shown card", personaCreation.testCancellingAnEditLeavesTheSavedCardAndTheShownCardAlone),
            ("read-only library makes no draft", personaCreation.testReadOnlyLibraryMakesNoDraft),
            ("appearance: new portrait is a Circle and switching keeps everything", personaAppearance.testNewPortraitStartsAsCircleAndSwitchingShapesKeepsEverything),
            ("appearance: existing personas keep their look", personaAppearance.testExistingPersonasKeepTheirLookAfterUpgrade),
            ("appearance: shown copy reshapes keeping width, centre, lock and outline", personaAppearance.testShownCopyReshapesKeepingWidthCentreLockAndOutline),
            ("appearance: live shape uses frozen ingredients for that copy only", personaAppearance.testLiveShapeUsesFrozenIngredientsAndChangesOnlyThatCopy),
            ("appearance: prepared copy changes alone and saves only when asked", personaAppearance.testPreparedCopyChangesShapeAloneAndSavesOnlyWhenAsked),
            ("appearance: one keyboard-reachable choice", personaAppearance.testAppearanceChoiceIsOneKeyboardReachableSelection),
            ("appearance: the toolbar changes exactly the captured copy", personaAppearance.testToolbarChangesExactlyTheCapturedCopy),
            ("appearance: the toolbar targets one prepared copy exactly", personaAppearance.testToolbarTargetsOnePreparedCopyExactly),
            ("appearance: a paused copy reshapes around its centre", personaAppearance.testPausedCopyReshapesAroundItsCentre),
            ("appearance: tall, wide, small and transparent artwork", personaAppearance.testTallWideSmallAndTransparentArtworkAgreeWithTheirOutline),
            ("appearance: deck keeps the shown look until the new one is ready", personaAppearance.testDeckKeepsTheShownLookUntilTheNewOneIsReady),
            ("appearance: scene placement uses the chosen look", personaAppearance.testScenePlacementUsesTheChosenLook),
            ("shown: browsing never replaces or hides the shown card", personaShown.testBrowsingNeverReplacesOrHidesTheShownCard),
            ("shown: Replace shown keeps size, place and lock", personaShown.testReplaceShownWithSelectedKeepsSizePlaceAndLock),
            ("shown: Update shown card changes only that copy", personaShown.testUpdateShownCardChangesOnlyThatCopy),
            ("shown: a hidden card is kept with the microphone stopped", personaShown.testHiddenCardIsKeptUntilShowAgainWithTheMicrophoneStopped),
            ("shown: a prepared copy is identified and changed alone", personaShown.testPreparedCopyIsIdentifiedAndChangedAlone),
            ("shown: the End shortcut releases the card", personaShown.testEndShortcutReleasesTheCard),
            ("persona geometry and strict validation", personas.testGeometryBoundsAndValidation),
            ("persona durable image and separate desktop placement", personas.testDurableImportSeparatePlacementAndRemoval),
            ("persona corrupt future and concurrent archive preservation", personas.testCorruptFutureAndConcurrentArchivesStayUntouched),
            ("persona scene attachment transparency and missing-file recovery", personas.testSceneAttachmentTransparencyAndMissingFile),
            ("persona native window focus lock drag and visibility", personas.testNativeOverlayWindowAndDragLifecycle),
            ("persona handles sit on the visible artwork", personaHandles.testHandlesSitOnTheVisibleArtworkNotItsTransparentRoom),
            ("persona resize keeps shape and limits", personaHandles.testResizeFollowsThePointerKeepsTheShapeAndStaysWithinLimits),
            ("persona locked artwork moves and resizes from handles", personaHandles.testLockedArtworkMovesAndResizesFromItsHandlesAndStaysLocked),
            ("persona handles appear after a brief pause", personaHandles.testHandlesAppearAfterABriefPauseNearTheArtwork),
            ("persona unlocked artwork takes clicks only on its body", personaHandles.testUnlockedArtworkTakesClicksOnlyOnItsBody),
            ("persona handles change only their own copy", personaHandles.testHandlesChangeOnlyTheirOwnCopy),
            ("persona released controller stops following the pointer", personaHandles.testReleasedControllerStopsFollowingThePointer),
            ("persona card moved under a still pointer", personaHandles.testCardMovedUnderAStillPointerTakesClicksByWhereItIs),
            ("persona tall artwork keeps its size through a resize", personaHandles.testTallArtworkKeepsItsSizeThroughAResize),
            ("persona ungrouped HUD scope and native controls", personas.testUngroupedHUDStaysScopedToDisplayedPersonaAndControlsItsLifecycle),
            ("persona read-only HUD browsing and placement", personas.testReadOnlyUngroupedHUDDoesNotPersistBrowsingOrPlacement),
            ("desktop verification waits for macOS and times out safely", scenes.testDesktopVerificationWaitsForMacOSAndStopsAtTimeout),
            ("scene search keeps customer selection consistent", scenes.testSceneSearchSelectsOnlyMatchingCustomers),
            ("desktop recovery across interrupted scene switch", scenes.testDesktopRecoverySurvivesInterruptedSwitch),
            ("scene persistence and bounds", scenes.testSceneRoundTripAndBounds),
            ("scene path and number validation", scenes.testUnsafeImagePathsAndNumbersRejected),
            ("scene corrupt and future archive safety", scenes.testCorruptAndFutureArchivesPreserved),
            ("scene duplicate ID validation", scenes.testDuplicateIDsRejected),
            ("phone geometry across display shapes", scenes.testPhoneStaysWithinWideAndTallDisplays),
            ("scene rendering and durable image import", scenes.testRenderAndImportedImageSurviveSourceRemoval),
            ("legacy scene decoding and logo validation", assets.testLegacyScenesAndLogoValidation),
            ("starter selection preserves saved customers", assets.testStartersNeverOverwriteSavedCustomers),
            ("logo import replacement and missing-file recovery", assets.testLogoImportReplacementAndRecovery),
            ("logo pixels and starter compositions", assets.testLogoPixelsCornersAndSceneCompositions),
            ("viewport geometry and saved device profiles", demo.testViewportGeometryAndProfiles),
            ("independent Space recovery and manual changes", demo.testIndependentSpaceRecoveryAndManualChanges),
            ("capture source identity and stale frames", demo.testCaptureSourceIdentityAndStaleFrames),
            ("presentation controls intentional reveal and retention", demo.testPresentationControlsRevealAndRetention),
            ("hand transparency persistence and no stretching", demo.testHandTransparencyPersistenceAndNoStretch),
            ("saved logo adoption reuse and removal", demo.testLogoLibraryMigrationReuseAndRemoval),
            ("library customization and corrupt file safety", demo.testLibraryCustomizationAndCorruptFileSafety),
            ("unified migration preserves malformed originals and preview edits", workbench.testMigrationCopiesPreviewOnceAndPreservesMalformedFiles),
            ("unified migration rejects symlinks and retries", workbench.testMigrationRejectsSymlinksAndRetriesCleanly),
            ("line hit testing", suite.testLineHitTestingUsesSegmentsNotBoundingBox),
            ("rectangle edge hit testing", suite.testRectangleOnlyErasesAtBorder),
            ("ellipse edge hit testing", suite.testEllipseOnlyErasesAtBorder),
            ("arrowhead hit testing", suite.testArrowHeadIsErasable),
            ("degenerate stroke", suite.testDegenerateStrokeDoesNotDivideByZero),
            ("constrained shapes", suite.testShiftConstrainedShapesAcrossQuadrants),
            ("undo redo divergent edit", suite.testUndoRedoAndDivergentEdit),
            ("eraser transaction", suite.testEraserDragIsOneUndoableAction),
            ("no-op eraser", suite.testNoOpEraserPreservesUndoHistory),
            ("undo clear", suite.testClearIsUndoableAndEmptyClearDoesNotAddHistory),
            ("bounded history", suite.testHistoryIsBounded),
            ("fade lifecycle", suite.testFadeTimingAndExpiredInkCannotResurrect),
            ("Screenshot handoff state and fade pause", suite.testScreenshotHandoffStateAndFadePause),
            ("countdown pause resume sleep", suite.testCountdownPauseResumeAndSleep),
            ("countdown formatting", suite.testCountdownRoundingAndHours),
            ("board persistence", suite.testBoardPersistenceRoundTripAndSeparateDisplays),
            ("corrupt board safety", suite.testCorruptBoardFailsWithoutOverwriting),
            ("missing and future board versions", suite.testMissingBoardStartsEmptyAndUnknownVersionFails),
            ("shortcut uniqueness", suite.testDefaultShortcutsAreUniqueAndComplete),
            ("flat shape drag draws a straight line", suite.testFlatShapeDragDrawsAStraightLine),
            ("presenter-first shortcut update", suite.testUpdateMovesOnlyUntouchedShortcutsToPresenterDefaults),
            ("new defaults never take a chosen key", suite.testNewDefaultNeverTakesAChosenCombination),
            ("update returns app commands to other apps", suite.testUpdateReturnsAppCommandsToOtherApps),
            ("fresh install keeps later key choices", suite.testFreshInstallKeepsLaterChoicesOfOldKeys),
            ("app commands never registered globally", suite.testAppCommandsAreNeverRegisteredGlobally),
            ("persona shortcut migration", suite.testPersonaShortcutMigrationPreservesExistingOverlayKeys),
            ("settings persistence and bounds", suite.testPreferencesPersistAndClamp),
            ("settings recovery", suite.testCorruptPreferencesArePreservedForRecovery),
            ("shortcut recording notices belong to Keyboard", NoticeOwnerTests().testShortcutRecordingNoticesBelongToKeyboard),
            ("login notices belong to General", NoticeOwnerTests().testLoginNoticesBelongToGeneral),
            ("saved settings notices belong to General", NoticeOwnerTests().testSavedSettingsNoticesBelongToGeneral),
            ("duplicate shortcut registration plan", suite.testDuplicateShortcutRegistrationPlanPausesBothWithoutChangingSettings),
            ("ink colour accessibility descriptions", suite.testInkColourAccessibilityDescriptions),
            ("actual rendering for every tool", suite.testAllToolsRenderToRealPixels),
            ("native mouse handlers and text commit", integration.testActualMouseHandlersAndTextCommit),
            ("first stroke after activation", integration.testFirstStrokeAfterActivationReachesInactiveCanvas),
            ("native drawing lifecycle and board isolation", integration.testDrawingLifecycleAndBoardIsolation),
            ("Screenshot handoff preserves ink and suspends input", integration.testScreenshotHandoffPreservesInkAndSuspendsInput),
            ("global shortcut registration and release", integration.testShortcutRegistrationAndRelease)
        ]
        tests.insert(contentsOf: [
            ("ambient starter exact assets duplicate and reopen", ambientScenes.testAllStartersKeepExactPortableAssetsThroughDuplicateAndReopen),
            ("ambient crop replacement and original preservation", ambientScenes.testCropKeepsRecipeAndReplacementClearsItWithoutRemovingOriginals),
            ("ambient stale recipe draft rejection", ambientScenes.testStaleCropAndSceneDraftRejectAnInterveningRecipeChange),
            ("ambient native scene poster orientation and window mask", ambientScenes.testMovingSceneViewMatchesPosterOrientationAndClipsCloudsToWindow),
            ("ambient missing detail poster fallback", ambientScenes.testMissingRigAssetKeepsCompletePosterAndDoesNotBecomePhotoZoom),
            ("motion legacy and portable settings", gentleMotion.testLegacyAndPortableSceneMotion),
            ("motion export pixels stay still", gentleMotion.testMotionDoesNotChangeStillExport),
            ("motion foreground remains transparent", gentleMotion.testForegroundExcludesPhotograph),
            ("motion transparent photo keeps still base", gentleMotion.testTransparentPhotographKeepsStillBase)
        ], at: 5)
        let libraryImageReuse = LibraryImageReuseTests()
        tests.append(contentsOf: [
            ("Library scene preparation cancel create and replace", libraryImageReuse.testScenePreparationCancelCreateAndReplace),
            ("Library Persona preparation preserves live copies", libraryImageReuse.testPersonaPreparationCancelAndAddPreserveLiveCopies)
        ])
        tests.insert(contentsOf: backdropTests, at: 5)
        tests.insert(contentsOf: sceneListTests, at: 5)
        tests.insert(contentsOf: personaControlTests, at: 5)
        tests.insert(contentsOf: [
            ("persona workspace immediate start and pause preservation", personaWorkspace.testWorkspaceStartsWithoutDismissalAndPreservesPausedArrangement),
            ("persona workspace single card immediate show and stop", personaWorkspace.testWorkspaceSingleCardShowsAndStopsWithoutDismissal),
            ("persona sheet launch only after dismissal", personaWorkspace.testSheetLaunchWaitsForDismissalAndIsConsumedOnce),
            ("persona workspace failure preserves active session", personaWorkspace.testWorkspaceFailureIsImmediateAndDoesNotReplaceSession),
            ("Present compact preview policy", personaWorkspace.testPresentPreviewReservesControlsAndFitsNarrowEditors),
            ("persona voice ring listens only while on and showing", personaVoice.testVoiceRingListensOnlyWhileOnAndItsPersonaShows),
            ("persona voice ring asks while preparing and stops when unavailable", personaVoice.testVoiceRingAsksWhilePreparingAndStopsWhenTheMicrophoneIsUnavailable),
            ("persona voice refusal offers Microphone Settings in the live menus", personaVoice.testRefusedMicrophoneOffersMicrophoneSettingsInTheLiveMenus),
            ("persona voice ring single floating persona", personaVoice.testSingleFloatingPersonaIsPlacedWithRoomForItsRing),
            ("persona voice ring placement keeps artwork and ring on screen", personaVoice.testPlacementKeepsArtworkSizeAndTheRingOnScreen),
            ("persona voice analyzer quiet and loud microphones", personaVoice.testAnalyzerHearsQuietAndLoudMicrophonesAlikeButNotTheRoom),
            ("persona voice analyzer room and startup silence", personaVoice.testAnalyzerLearnsTheRoomAndIgnoresStartupSilence),
            ("persona voice analyzer recognises a voice by its pitch", personaVoice.testAnalyzerRecognisesAVoiceByItsPitch),
            ("persona voice ring outline fitting", personaVoice.testOutlineFollowsARoundBadgeACardAndAPhoto),
            ("persona voice ring is the chosen colour", personaVoice.testRingIsTheChosenColourWhateverTheArtwork),
            ("persona voice ring geometry", personaVoice.testRingGeometryHugsTheArtworkAndScalesWithIt),
            ("persona voice ring sleeps in silence and rises at once", personaVoice.testRingSleepsInSilenceAndRisesOnTheFirstSyllable),
            ("persona voice outline latency: speech of every kind", personaVoiceLatency.testOutlineRespondsWithinTargetsToSpeechOfEveryKind),
            ("persona voice outline latency: long speech never becomes the room", personaVoiceLatency.testLongSpeechNeverBecomesTheRoom),
            ("persona voice outline: steady noise, typing and hum stay quiet", personaVoiceLatency.testSteadyNoiseTypingAndHumNeverLightTheOutline),
            ("persona voice outline: raised voice reads as loud", personaVoiceLatency.testRaisedVoiceShowsLoudAndUsualVoiceShowsNormal),
            ("persona voice outline state eases and settles", personaVoiceLatency.testOutlineStateEasesAndSettlesWithoutFrames),
            ("persona voice outline lit through a held vowel", personaVoiceLatency.testHeldVowelKeepsTheOutlineLit),
            ("persona voice outline: chimes, beeps and music settle", personaVoiceLatency.testChimesBeepsAndMusicLightItOnlyWhileTheySound),
            ("optional offscreen voice ring renders", personaVoice.testOffscreenVoiceRingRenders),
            ("voice appearance: shared voice states with distinct responses", voiceAppearance.testSurfacesShareVoiceStatesWithDistinctResponse),
            ("voice appearance: trace fits the compact mark and peaks in the middle", voiceAppearance.testTraceFitsTheCompactMarkAndPeaksInTheMiddle),
            ("voice appearance: input follows syllables and outline stays calm", voiceAppearance.testInputTraceFollowsSyllablesWhileTheOutlineStaysCalm),
            ("voice appearance: soft usable input is visible", voiceAppearance.testTraceShowsSoftInputTheRecorderCanKeep),
            ("voice appearance: trace rests when still, fixed with Reduce Motion", voiceAppearance.testTraceRestsWhenStillAndHoldsItsShapeWithReduceMotion),
            ("voice appearance: recorder level meets the targets", voiceAppearance.testRecorderLevelMeetsTheTargets),
            ("voice appearance: SwiftUI trace drops into a toolbar row", voiceAppearance.testSwiftUITraceDropsIntoAToolbarRow)
        ], at: 5)
        tests.append(("shared persona menu frozen target and session generation", personaSessions.testSharedMenuTargetsFrozenCopiesAndRejectsPreviousSessionActions))
        if personaControlsOnly {
            tests = personaControlTests + [
                ("persona independent copies and size", personaSessions.testTwoInstancesOwnIndependentGeometryVisibilityLockAndOrder),
                ("persona remove and re-add", personaSessions.testEmptySetCanBeRevisitedAndLiveFailuresStayVisible),
                ("shared persona menu generation", personaSessions.testSharedMenuTargetsFrozenCopiesAndRejectsPreviousSessionActions)
            ]
        } else if sceneListOnly {
            tests = sceneListTests
        } else if personaQuickOnly {
            tests = [
                ("persona quick shortcuts and default keys", suite.testDefaultShortcutsAreUniqueAndComplete),
                ("persona quick shortcut migration", suite.testPersonaShortcutMigrationPreservesExistingOverlayKeys),
                ("persona quick frozen selection", personas.testLiveCandidatesRemainScopedAndHUDLabelsExcludePrivateNames),
                ("persona quick overlay cycling and lifecycle", personas.testUngroupedHUDStaysScopedToDisplayedPersonaAndControlsItsLifecycle),
                ("persona quick read-only cycling", personas.testReadOnlyUngroupedHUDDoesNotPersistBrowsingOrPlacement)
            ]
        } else if backdropOnly {
            tests = backdropTests
        } else if boardPresentationOnly {
            tests = Array(tests.prefix(5))
        } else if screenshotStateOnly {
            tests = [("Screenshot handoff state and fade pause", suite.testScreenshotHandoffStateAndFadePause)]
        } else if scenesOnly {
            tests = Array(tests.prefix { $0.0 != "line hit testing" })
        } else if hostedCI {
            print("SKIP live menu-bar popover regression in --ci mode; run scripts/test.zsh on an interactive Mac for full coverage")
        } else {
            tests.append(("menu bar and non-destructive quick adjustments", integration.testMenuBarAccessAndQuickAdjustmentsPreserveBoard))
        }
        if !scenesOnly && !boardPresentationOnly && !backdropOnly && !personaQuickOnly && !personaControlsOnly && !screenshotStateOnly && !sceneListOnly {
            tests.append(contentsOf: [
                ("embedded navigation and recording suspension", workbench.testEmbeddedCallbacksAndSuspendedShortcutSettings),
                ("drawing admission preserves independent guards", workbench.testDrawingAdmissionIsSeparateFromGeneralInteraction),
                ("finish drawing preserves ink and settled input", workbench.testFinishDrawingPreservesBoardInkAndReportsSettledTransitions),
                ("shortcut replacement releases only held drawing", workbench.testShortcutReregistrationReleasesOnlyHeldDrawing)
            ])
            let annotationMenu = AnnotationMenuTests()
            tests.append(contentsOf: [
                ("annotation menu live shortcuts and single key owner", annotationMenu.testMenuUsesLiveShortcutsWithoutAddingAKeyRoute),
                ("annotation menu native actions and live state", annotationMenu.testNativeActionsRefreshSelectionAndHistory),
                ("annotation menu preserves ink and boards", annotationMenu.testBoardsAndControlsPreserveInkUntilExplicitClear),
                ("stop drawing closes the board and keeps its ink", annotationMenu.testStopDrawingClosesTheBoardAndKeepsItsInk),
                ("pen key leaves the board and the hint matches draw", annotationMenu.testPenKeyLeavesTheBoardAndTheHintMatchesDraw),
                ("annotation menu rechecks admission", annotationMenu.testStaleMenuCannotBypassChangedAdmission)
            ])
        }
        var skipped = 0
        for (name, test) in tests {
            let before = assertionFailures
            do { try test() }
            // A precondition this Mac cannot meet is reported, not failed; CI meets it.
            catch let skip as TestSkipped { skipped += 1; print("SKIP \(name): \(skip)"); continue }
            catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
            if assertionFailures == before { print("PASS \(name)") }
        }
        if skipped > 0 { print("\(skipped) skipped") }
        print("\(tests.count - skipped) tests · \(assertionCount) assertions · \(assertionFailures) failures")
        exit(assertionFailures == 0 ? 0 : 1)
    }
}
