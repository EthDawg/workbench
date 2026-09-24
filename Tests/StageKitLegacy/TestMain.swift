import AppKit

@main
struct TestRunner {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--annotation-menu-only"] {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let suite = AnnotationMenuTests()
            let tests: [(String, () throws -> Void)] = [
                ("annotation menu live shortcuts and single key owner", suite.testMenuUsesLiveShortcutsWithoutAddingAKeyRoute),
                ("annotation menu native actions and live state", suite.testNativeActionsRefreshSelectionAndHistory),
                ("annotation menu preserves ink and boards", suite.testBoardsAndControlsPreserveInkUntilExplicitClear),
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
            print("Usage: StageMarkTests [--ci | --scenes-only | --scene-list-only | --persona-quick-only | --board-presentation-only | --board-presentation-fixture | --backdrop-only | --backdrop-fixture | --persona-session-fixture | --phone-guide-fixture]")

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
        let desktopMotion = DesktopMotionTests()
        let gentleMotion = GentleMotionTests()
        let ambientScenes = AmbientSceneTests()
        let viewportFit = ViewportFitTests()
        let logoImport = LogoImportTests()
        let sceneMedia = SceneMediaTests()
        let personas = PersonaTests()
        let personaSessions = PersonaSessionTests()
        let personaControls = PersonaControlsTests()
        let personaControlTests: [(String, () throws -> Void)] = [
            ("persona controls: single size slider", personaControls.testSingleSizeControlIsVisibleAndRoutesAbsoluteWidth),
            ("persona controls: selected copy and empty recovery", personaControls.testSessionControlsTargetSelectedCopyAndRecoverFromEmptySet)
        ]
        let personaStarters = PersonaStarterTests()
        let floating = FloatingControlGeometryTests()
        let timerPlacement = BreakTimerPlacementTests()
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
        var tests: [(String, () throws -> Void)] = [
            ("board export pixels orientation text and Retina", boardExport.testBoardPixelsOrientationTextAndRetinaScale),
            ("board snapshot file bounds and invalid input", boardExport.testSnapshotPersistenceBoundsAndInvalidInput),
            ("board private clipboard image and failure preservation", boardExport.testPrivateClipboardPNGAndFailurePreservation),
            ("presentation window and fullscreen lifecycle", presentationLifecycle.testModeChangesKeepPresentationAndEndClosesOnce),
            ("presentation transition interruption and failure recovery", presentationLifecycle.testEndDuringNativeTransitionsAndFailureRecovery),
            ("phone: restricted versus denied video access", phonePresentation.testRestrictedCameraGuidanceDoesNotOfferUserPermissionToggle),
            ("phone: explicit first source selection", phonePresentation.testFirstCaptureRequiresExplicitSelectionEvenForMuxedHint),
            ("phone: handoff waits for capture and window", phonePresentation.testNativeHandoffWaitsForBothCaptureAndWindowInEitherOrder),
            ("phone: handoff launch and ordinary close ownership", phonePresentation.testHandoffKeepsFirstRequestAndDoesNotRetryFailedLaunchOrOrdinaryClose),
            ("phone: handoff native transition failure", phonePresentation.testHandoffWaitsThroughFailedNativeTransitionAndRepeatedEnd),
            ("phone: capture release retains pending handoff", phonePresentation.testCaptureStopCompletionRetainsHandoffAfterPresenterRelease),
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
            ("full-height frame persistence and edges", viewportFit.testFullHeightSurvivesSavingAndReachesBothEdges),
            ("maximum frame size across displays", viewportFit.testMaximumSizeFitsDisplayAndPreservesScreenShape),
            ("full-height export and live geometry", viewportFit.testExportAndLiveScreenUseFullHeightBorder),
            ("logo native WebP decoding and alpha", logoImport.testWebPAndTransparentPadding),
            ("logo image orientation and rejection", logoImport.testOrientationAndInvalidImages),
            ("logo paste image and file persistence", logoImport.testPasteImageAndFilePersistence),
            ("logo browser addresses and inline validation", sceneMedia.testSearchAndImageAddressesStayBounded),
            ("logo browser bounded download validation", sceneMedia.testDownloadsRejectOversizeHTMLAndInvalidBytes),
            ("logo browser request cancellation", sceneMedia.testDownloadCancellationStopsTheOwnedRequest),
            ("logo browser explicit captured-scene save", sceneMedia.testWebLogoPreviewAndExplicitSavePreserveOtherScenes),
            ("editor motion suppression and drag pause", sceneMedia.testMotionPolicyReportsSuppressionAndCanvasPausesForEditing),
            ("persona starter: CatalogHasStableUniqueBundleNamesAndEditableLabels", personaStarters.testCatalogHasStableUniqueBundleNamesAndEditableLabels),
            ("persona starter: MissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas", personaStarters.testMissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas),
            ("persona starter: ChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies", personaStarters.testChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies),
            ("persona starter: BundledPortraitsHaveReadableArtworkAndRealTransparency", personaStarters.testBundledPortraitsHaveReadableArtworkAndRealTransparency),
            ("persona geometry and strict validation", personas.testGeometryBoundsAndValidation),
            ("persona durable image and separate desktop placement", personas.testDurableImportSeparatePlacementAndRemoval),
            ("persona corrupt future and concurrent archive preservation", personas.testCorruptFutureAndConcurrentArchivesStayUntouched),
            ("persona scene attachment transparency and missing-file recovery", personas.testSceneAttachmentTransparencyAndMissingFile),
            ("persona native window focus lock drag and visibility", personas.testNativeOverlayWindowAndDragLifecycle),
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
            ("settings persistence and bounds", suite.testPreferencesPersistAndClamp),
            ("settings recovery", suite.testCorruptPreferencesArePreservedForRecovery),
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
            ("motion transparent photo keeps still base", gentleMotion.testTransparentPhotographKeepsStillBase),
            ("desktop ownership and spaces", desktopMotion.testDesktopOwnershipLossCannotResumeOrFollowAnotherSpace),
            ("desktop sleep and pause independence", desktopMotion.testDesktopSleepReasonsAndPauseRemainIndependent),
            ("desktop removal and fresh session", desktopMotion.testDesktopRemovalStopsEvenDuringSleepAndRestartNeedsNewSession)
        ], at: 5)
        tests.insert(contentsOf: backdropTests, at: 5)
        tests.insert(contentsOf: sceneListTests, at: 5)
        tests.insert(contentsOf: personaControlTests, at: 5)
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
                ("annotation menu rechecks admission", annotationMenu.testStaleMenuCannotBypassChangedAdmission)
            ])
        }
        for (name, test) in tests {
            let before = assertionFailures
            do { try test() } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }
            if assertionFailures == before { print("PASS \(name)") }
        }
        print("\(tests.count) tests · \(assertionCount) assertions · \(assertionFailures) failures")
        exit(assertionFailures == 0 ? 0 : 1)
    }
}
