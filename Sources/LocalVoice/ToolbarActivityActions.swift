import AppKit
import ToolbarCore

/// A command is rendered from the same owner that will admit it on release.
struct ToolbarActivityCommand {
    var value: ToolbarChooserAction
    var mode: ToolbarMode?
    var run: () -> Void
}

extension FloatingToolbar {
    var chooserCommands: [ToolbarActivityCommand] {
        var commands: [ToolbarActivityCommand] = []
        func command(_ title: String, id: String, _ mode: ToolbarMode?, identity: String = "", run: @escaping () -> Void) {
            let owner = mode == .dictate ? model.toolbarCaptureIdentity : mode == .read ? model.toolbarReadingIdentity : ""
            commands.append(.init(value: .init(id, title, identity: owner + ":" + identity), mode: mode, run: run))
        }
        let phase = String(describing: model.phase)
        if model.phase == .recording { command("Stop dictating", id: "dictate.stop", .dictate, identity: phase) { model.stopRecording() } }
        if model.waitingForDrawing { command("Copy now", id: "dictate.copy-now", .dictate) { model.copyWaitingDelivery() } }
        if model.phase != .idle, model.canCancelCurrentCapture {
            command("Cancel", id: "dictate.cancel", .dictate, identity: phase) { model.cancelCurrentCapture() }
        }
        if model.phase == .idle, model.captureFailure != nil {
            if model.canRetry { command(model.retryCaptureLabel, id: "dictate.retry", .dictate, identity: model.retryCaptureLabel) { model.retryTranscription() } }
            if model.canRecordAgain { command("Record again", id: "dictate.record-again", .dictate) { model.recordAgain() } }
            command("Dismiss message", id: "dictate.dismiss", .dictate) { model.dismissCaptureFailure() }
        }
        if model.hasCaptureRecovery { command("Review recordings", id: "dictate.review", .dictate) { model.onShowEditor?("dictate") } }
        if let unresolved = model.unresolvedDelivery {
            let identity = String(describing: unresolved.id)
            command("Review delivery", id: "dictate.review-delivery", .dictate, identity: identity) { model.onShowEditor?("dictate") }
            if unresolved.offersCopy { command("Copy again", id: "dictate.copy-again", .dictate, identity: identity) { model.copyUnresolvedDelivery() } }
            command("Dismiss delivery", id: "dictate.dismiss-delivery", .dictate, identity: identity) { model.dismissUnresolvedDelivery() }
        }
        switch live.reading {
        case .preparing: command("Cancel", id: "read.cancel", .read) { model.cancelReading() }
        case .playing:
            command("Pause reading", id: "read.pause", .read) { model.listen() }
            command("Stop reading", id: "read.stop", .read, identity: "playing") { model.stopPlayback() }
        case .paused:
            command("Resume reading", id: "read.resume", .read) { model.listen() }
            command("Stop reading", id: "read.stop", .read, identity: "paused") { model.stopPlayback() }
        case .idle:
            if model.readingFailure != nil {
                if model.canRetryReading { command("Retry", id: "read.retry", .read) { model.retryReading() } }
                command("Dismiss message", id: "read.dismiss", .read) { model.dismissReadingFailure() }
            }
        }
        if let draft = snapModel.draft {
            command("Review unsaved Snap", id: "snap.review", .snap, identity: draft.id.uuidString) { model.onShowEditor?("snap") }
        }
        if readback.isRecording {
            let identity = readback.narrationIdentity ?? ""
            command("Finish narration", id: "snap-talk.stop", .snapAndTalk, identity: identity) { readback.stopNarration() }
            command("Cancel narration", id: "snap-talk.cancel", .snapAndTalk, identity: identity) { readback.cancelNarration() }
        }
        if readback.sessionURL != nil { command("Review captures", id: "snap-talk.review", .snapAndTalk) { model.onShowEditor?("readback") } }
        if stage.isDrawing { command("Stop drawing", id: "draw.stop", .draw, identity: stage.drawingIdentity?.uuidString ?? "") { stage.finishDrawing() } }
        if stage.isPresenting { command("End presentation", id: "present.end", .present, identity: stage.presentationIdentity?.uuidString ?? "") { stage.endDeviceScene() } }
        if promptInsertion.running { command("Stop inserting", id: "present.stop-inserting", .present, identity: promptInsertion.operationIdentity.uuidString) { promptInsertion.cancel() } }
        // Persona's live commands name the source that is actually live: a
        // prepared set, the one floating card or the camera bubble, which is also
        // cancellable while it starts. Each title is part of the command's
        // identity, so a stale row cannot perform a different operation.
        if stage.hasLivePersonaSource {
            let visibility = stage.personaVisibilityTitle, end = stage.personaEndTitle
            if stage.personaCameraPhase == .off || WorkbenchControlContext(model: model, readback: readback, stage: stage, snap: snapModel).state.enabled(.persona) {
                command(visibility, id: "persona.visibility", .persona,
                    identity: stage.personaSessionIdentity.uuidString + visibility + stage.personaStatus + String(describing: stage.selectedPersonaCopy)) { stage.togglePersona() }
            }
            command(end, id: "persona.end", .persona, identity: stage.personaSessionIdentity.uuidString + end + String(describing: stage.selectedPersonaCopy)) { stage.endPersona() }
        }
        if let identity = meetings.recordingIdentity {
            command("Stop & transcribe", id: "meeting.stop", nil, identity: identity.uuidString) {
                Task { await meetings.stop(expected: identity) }
            }
        }
        if meetings.isBusy || meetings.hasRecovery {
            command("Open Meetings…", id: "meeting.review", nil) { model.onShowEditor?("meeting") }
        }
        if stage.hasTimerSession {
            let step = stage.timerStep
            command(step.transport.title + " timer", id: "timer.transport", nil, identity: String(describing: step)) { stage.performTimerTransport(expected: step) }
            command("End timer", id: "timer.end", nil, identity: String(describing: step)) { stage.stopTimer() }
        }
        return commands
    }

    var chooserChoices: [ToolbarToolChoice] {
        let commands = chooserCommands
        return ToolbarNextAction.choices(for: live, key: key).map { choice in
            var choice = choice
            choice.actions = commands.filter { $0.mode == choice.mode }.map(\.value)
            switch choice.mode {
            case .dictate:
                if model.waitingForDrawing { choice.detail = "Words ready · waiting for Draw" }
                else if model.captureFailure != nil { choice.detail = "Dictation needs attention" }
                else if model.hasCaptureRecovery { choice.detail = "Recording kept for recovery" }
                else if model.unresolvedDelivery != nil { choice.detail = "Delivery needs attention" }
            case .read: if model.readingFailure != nil { choice.detail = "Reading stopped · text kept" }
            case .snap: if snapModel.draft != nil { choice.detail = "Unsaved capture" }
            case .snapAndTalk:
                if readback.sessionURL != nil { choice.detail = "\(readback.activeSections.count) captures" }
            case .persona:
                if !choice.actions.isEmpty { choice.detail = stage.personaCycleNotice ?? stage.personaStatus }
            default: break
            }
            return choice
        }
    }

    var chooserActivities: ToolbarChooserActivities {
        let actions = chooserCommands.filter { $0.mode == nil }.map(\.value)
        var rows: [ToolbarChooserActivity] = []
        let meeting = actions.filter { $0.id.hasPrefix("meeting.") }
        if !meeting.isEmpty {
            rows.append(.init(id: "meeting", title: "Meetings", symbol: "person.2.wave.2",
                detail: meetings.isRecording ? "Recording" : meetings.isBusy ? "Processing" : "Recording kept for recovery", actions: meeting))
        }
        let timer = actions.filter { $0.id.hasPrefix("timer.") }
        if !timer.isEmpty { rows.append(.init(id: "timer", title: "Timer", symbol: "timer", detail: stage.timerText, actions: timer)) }
        return .init(rows)
    }

    func performChooserAction(_ shown: ToolbarChooserAction) {
        // A fresh read prevents an already-completed Stop becoming a new Start, or a
        // stale recovery command consuming a replacement recording.
        chooserCommands.first(where: { $0.value == shown })?.run()
    }
}
