import AppKit
import SwiftUI

/// Presentation reads capture and recognition separately. A quiet source is not
/// a finished call, and a delayed recognizer is not a stopped microphone.
extension LiveVoiceSnapshot {
    var recordingTitle: String {
        switch phase {
        case .idle: return "Ready to record"
        case .preparing: return "Starting recording"
        case .listening: return "Recording"
        case .paused: return "Paused"
        case .reconnecting: return "Reconnecting audio"
        case .finishing: return "Finishing transcript"
        case .completed: return "Transcript saved"
        case .recoverableFailure: return "Recording kept"
        }
    }

    var transcriptStatus: String {
        if recognitionDelayed { return "Words are catching up · audio is still being kept" }
        if let message, !message.isEmpty { return message }
        switch phase {
        case .preparing: return "Preparing live words…"
        case .paused: return "Resume to continue the same recording."
        case .reconnecting: return "Keeping this session open while audio reconnects."
        case .finishing: return "Saving your words and original recording…"
        case .completed: return "Saved in History with the original recording."
        case .recoverableFailure: return "Original audio is available for recovery."
        default: return hasProvisionalText ? "The latest words may settle as you speak." : "Words appear here as you speak."
        }
    }
}

struct LiveVoiceSourcesView: View {
    let sources: [LiveVoiceSourceStatus]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { rows }
            VStack(alignment: .leading, spacing: 8) { rows }
        }
    }
    private var rows: some View {
        ForEach(sources, id: \.source) { source in
            Label {
                Text(source.name + " · " + status(source.health))
                    .font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: source.source == .microphone ? "mic" : "speaker.wave.2")
                    .foregroundStyle(source.health == .unavailable ? Color.orange : Workbench.accent)
            }.help(source.message ?? source.name).accessibilityElement(children: .combine)
        }
    }
    private func status(_ health: LiveVoiceSourceStatus.Health) -> String {
        switch health {
        case .waiting: return "Waiting for audio"
        case .receiving: return "Receiving audio"
        case .quiet: return "Quiet"
        case .paused: return "Paused"
        case .reconnecting: return "Reconnecting"
        case .unavailable: return "Unavailable"
        }
    }
}

/// One selectable transcript surface in Meetings and Dictate. Native text keeps
/// selection and reading position while hypotheses change, including mouse-wheel
/// scrolling; new words never drag a reader away from earlier turns.
struct LiveVoiceTranscriptView: View {
    let snapshot: LiveVoiceSnapshot
    var conversation = false
    var completedText: String? = nil
    @State private var atLatest = true
    @State private var latestRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshot.phase == .completed ? "Transcript" : "Live transcript").font(Workbench.sectionTitle)
                Spacer()
                if !atLatest {
                    Button("Latest words") { latestRequest += 1 }.controlSize(.small)
                }
            }
            if snapshot.segments.isEmpty && (completedText ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(snapshot.phase == .paused ? "Your transcript will continue here." : "Listening for your words…")
                        .font(.body).foregroundStyle(.secondary)
                    Text(snapshot.transcriptStatus).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: LiveTranscriptText.minimumHeight, alignment: .topLeading).padding(.top, 8)
            } else {
                LiveTranscriptText(segments: snapshot.segments, conversation: conversation,
                                   completedText: completedText, latestRequest: latestRequest,
                                   atLatest: $atLatest)
                    .id(snapshot.sessionID)
                    .accessibilityIdentifier("voice.live-transcript")
                // A saved transcript's page already says so in its status title.
                if snapshot.phase != .completed {
                    Text(snapshot.transcriptStatus).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LiveTranscriptText: NSViewRepresentable {
    /// Short transcripts take only their own height; long ones scroll inside, keeping the
    /// newest words in view without pushing the page's controls away.
    static let minimumHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 360
    var segments: [LiveVoiceSegment]
    var conversation: Bool
    var completedText: String?
    var latestRequest: Int
    @Binding var atLatest: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.drawsBackground = false; text.textContainerInset = NSSize(width: 0, height: 4)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Transcript")
        scroll.documentView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll, weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let scroll, let coordinator else { return }
                coordinator.reportLatest?(Self.isAtLatest(scroll))
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.reportLatest = { value in
            DispatchQueue.main.async { if atLatest != value { atLatest = value } }
        }
        let follow = text.string.isEmpty || Self.isAtLatest(scroll)
        let selected = text.selectedRange(), position = scroll.contentView.bounds.origin
        let value = attributedText()
        if !text.attributedString().isEqual(to: value) {
            text.textStorage?.setAttributedString(value)
            text.setSelectedRange(NSRange(location: min(selected.location, value.length),
                                          length: min(selected.length, max(0, value.length - selected.location))))
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            if follow && selected.length == 0 { text.scrollToEndOfDocument(nil) }
            else { scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        if context.coordinator.latestRequest != latestRequest {
            context.coordinator.latestRequest = latestRequest
            text.setSelectedRange(NSRange(location: value.length, length: 0))
            text.scrollToEndOfDocument(nil)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let used = attributedText().boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return CGSize(width: width, height: min(Self.maximumHeight, max(Self.minimumHeight, ceil(used) + 8)))
    }
    private static func isAtLatest(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        return document.bounds.height - scroll.contentView.bounds.maxY < 30
    }
    private func attributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 12
        // Dictate's editor reads at the title 3 size (15 pt standard); both grow with larger text.
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .title3), .foregroundColor: NSColor.labelColor,
                                                   .paragraphStyle: paragraph]
        if let completedText { return NSAttributedString(string: completedText, attributes: body) }
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: conversation ? "\n\n" : " ", attributes: body)) }
            if conversation {
                let minutes = max(0, Int(segment.start)) / 60, seconds = max(0, Int(segment.start)) % 60
                result.append(NSAttributedString(string: "\(segment.source.label)  ·  \(minutes):\(String(format: "%02d", seconds))\n",
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
            }
            var style = body
            if !segment.isFinal { style[.foregroundColor] = NSColor.secondaryLabelColor }
            result.append(NSAttributedString(string: segment.text, attributes: style))
        }
        return result
    }
    final class Coordinator {
        var latestRequest = 0
        var reportLatest: ((Bool) -> Void)?
        var observation: NSObjectProtocol?
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
