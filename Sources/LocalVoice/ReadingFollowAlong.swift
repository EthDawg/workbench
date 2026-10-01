import AppKit
import StageKit
import SwiftUI

/// The reading text while a Mac voice plays or is paused: read-only, with the
/// word being spoken marked. Editing returns when the reading stops. It keeps
/// the marked word in view, jumping instead of scrolling with Reduce Motion.
struct ReadingFollowAlongView: NSViewRepresentable {
    let text: String
    let highlight: NSRange?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let highlightColor = NSColor(name: nil) { appearance in
        var accent = WorkbenchPalette.nativeAccent
        appearance.performAsCurrentDrawingAppearance {
            accent = WorkbenchPalette.nativeAccent.usingColorSpace(.sRGB) ?? accent
        }
        return accent.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.34 : 0.24)
    }

    final class Coordinator {
        var text: String?
        var highlight: NSRange?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Text being read")
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        if coordinator.text != text {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 6
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ]))
            coordinator.text = text
            coordinator.highlight = nil
        }
        guard coordinator.highlight != highlight else { return }
        let length = storage.length
        if let previous = coordinator.highlight, NSMaxRange(previous) <= length {
            storage.removeAttribute(.backgroundColor, range: previous)
        }
        coordinator.highlight = nil
        guard let highlight, highlight.location != NSNotFound, highlight.length > 0, NSMaxRange(highlight) <= length else { return }
        storage.addAttribute(.backgroundColor, value: Self.highlightColor, range: highlight)
        coordinator.highlight = highlight
        reveal(highlight, in: textView, scrollView: scrollView)
    }

    /// Scrolls only when the word leaves the view, placing it a third of the way
    /// down so the view moves in occasional steps rather than line by line.
    private func reveal(_ range: NSRange, in textView: NSTextView, scrollView: NSScrollView) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var word = layout.boundingRect(forGlyphRange: glyphs, in: container)
        word.origin.y += textView.textContainerOrigin.y
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        guard visible.height > 0, word.minY < visible.minY || word.maxY > visible.maxY else { return }
        let limit = max(0, textView.frame.height - visible.height)
        let origin = NSPoint(x: visible.minX, y: min(max(0, word.minY - visible.height / 3), limit))
        if reduceMotion {
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }
}

/// A hint under the voice picker while every voice for the person's language
/// is compact. The button only opens the settings pane.
struct MacVoiceHintRow: View {
    let hint: MacVoiceHint
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform.badge.plus").foregroundStyle(Workbench.accent).accessibilityHidden(true)
            Text(hint.message).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(hint.buttonTitle, action: open).controlSize(.small).help(hint.help)
                .fixedSize()
                .accessibilityHint(hint.help)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
    }
}
