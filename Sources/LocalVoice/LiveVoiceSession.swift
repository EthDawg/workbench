import Foundation

/// Shared presentation contract for Meetings and Dictate. Capture owns these
/// facts; a view never infers recording health from recognizer progress.
enum LiveVoicePhase: String, Codable, Sendable {
    case idle, preparing, listening, paused, reconnecting, finishing, completed, recoverableFailure
}

enum LiveVoiceSource: String, Codable, CaseIterable, Sendable {
    case microphone, app
    var label: String { self == .microphone ? "You" : "Others" }
}

struct LiveVoiceSourceStatus: Equatable, Sendable {
    enum Health: String, Sendable { case waiting, receiving, quiet, paused, reconnecting, unavailable }
    var source: LiveVoiceSource
    var name: String
    var health: Health = .waiting
    var level: Double = 0
    var message: String?
}

struct LiveVoiceSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var source: LiveVoiceSource
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
}

struct LiveVoiceSnapshot: Equatable, Sendable {
    var sessionID: UUID?
    var phase: LiveVoicePhase = .idle
    var elapsed: Double = 0
    var sources: [LiveVoiceSourceStatus] = []
    var segments: [LiveVoiceSegment] = []
    var recognitionDelayed = false
    var message: String?

    var text: String { segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    var hasProvisionalText: Bool { segments.contains { !$0.isFinal && !$0.text.isEmpty } }
    var isActive: Bool { [.preparing, .listening, .paused, .reconnecting, .finishing].contains(phase) }
}

/// A checkpoint records confirmed words, never a provisional UI hypothesis.
/// It lives beside owned audio and is not another History store.
struct LiveVoiceCheckpoint: Codable, Equatable, Sendable {
    var formatVersion = 1
    var sessionID: UUID
    var segments: [LiveVoiceSegment] = []
    var completedThrough: [String: Double] = [:]
    var complete = false
    var notes: [String] = []

    var text: String { orderedSegments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    var orderedSegments: [LiveVoiceSegment] {
        segments.sorted { ($0.start, $0.source.rawValue) < ($1.start, $1.source.rawValue) }
    }
    var conversation: String {
        LiveVoiceTurns.group(orderedSegments).map { "\($0.source.label): \($0.text)" }.joined(separator: "\n\n")
    }
}

enum LiveVoiceTurns {
    /// Store word timing, project adjacent same-source words into readable turns. Different
    /// sources remain present even when they overlap or independently say the same words.
    static func group(_ words: [LiveVoiceSegment]) -> [LiveVoiceSegment] {
        var turns: [LiveVoiceSegment] = []
        for word in words.sorted(by: { ($0.start, $0.source.rawValue) < ($1.start, $1.source.rawValue) }) where !word.text.isEmpty {
            if let last = turns.last, last.source == word.source, last.isFinal == word.isFinal, word.start - last.end <= 0.8 {
                turns[turns.count - 1].text += " " + word.text
                turns[turns.count - 1].end = max(last.end, word.end)
            } else { turns.append(word) }
        }
        return turns
    }
}
