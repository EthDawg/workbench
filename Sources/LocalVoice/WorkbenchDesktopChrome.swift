import SwiftUI

/// Sidebar rows and Home's large actions use the same restrained pointer response.
struct WorkbenchNavigationStyle: ButtonStyle {
    var selected = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Workbench.accent.opacity(scheme == .dark ? 0.19 : 0.12) : Color.clear)
            }
            .overlay(RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : hovered ? (scheme == .dark ? 0.08 : 0.045) : 0) : 0))
                .allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Workbench.accent.opacity(0.22) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovered = $0 }
    }
}

/// A finite sequence rather than a repeating timer. Home's shell remembers that it played,
/// so changing pages never restarts it. The accessible label is stable throughout.
enum HomeGreetingSequence {
    static let welcome = "Welcome back!"
    static let settled = "Let’s make something. ✨"
    struct Frame: Equatable { let text: String; let milliseconds: UInt64 }
    static var frames: [Frame] {
        let hello = Array(welcome), finish = Array(settled)
        return (1...hello.count).map { Frame(text: String(hello.prefix($0)), milliseconds: 45) }
            + [Frame(text: welcome, milliseconds: 650)]
            + (0..<hello.count).reversed().map { Frame(text: String(hello.prefix($0)), milliseconds: 22) }
            + (1...finish.count).map { Frame(text: String(finish.prefix($0)), milliseconds: 36) }
    }
}

struct HomeGreeting: View {
    @Binding var hasPlayed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = HomeGreetingSequence.settled
    var body: some View {
        // Reserve the finished line's space, including while text is being erased.
        Text(HomeGreetingSequence.settled).hidden().overlay(alignment: .leading) { Text(text) }
            .font(.system(size: 29, weight: .semibold, design: .rounded))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HomeGreetingSequence.settled).accessibilityAddTraits(.isHeader)
            .task(id: reduceMotion) {
                guard !reduceMotion, !hasPlayed, !ProcessInfo.processInfo.arguments.contains(SurfaceGallery.passFlag) else {
                    hasPlayed = true; text = HomeGreetingSequence.settled; return
                }
                hasPlayed = true
                for frame in HomeGreetingSequence.frames {
                    guard !Task.isCancelled else { return }
                    text = frame.text
                    do { try await Task.sleep(nanoseconds: frame.milliseconds * 1_000_000) } catch { return }
                }
            }
    }
}
