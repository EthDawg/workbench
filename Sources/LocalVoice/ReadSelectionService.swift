import AppKit

/// Text arriving in Read from elsewhere. Every import goes through the same
/// decision in AppModel; the origin only names the text in what Read says.
struct ReadingSelectionImport: Identifiable, Equatable {
    static let maximumCharacters = 1_000_000

    enum Origin: Equatable {
        /// The macOS Service's selected text.
        case selection
        /// Read aloud on a History transcript.
        case transcript
        /// Read aloud on a Library item.
        case savedText

        var name: String {
            switch self {
            case .selection: return "Selected text"
            case .transcript: return "The transcript"
            case .savedText: return "The saved text"
            }
        }
        /// What Keep current leaves behind, said on the review and after it.
        var keepNote: String {
            switch self {
            case .selection: return "Keep current discards only this imported selection."
            case .transcript: return "Keep current leaves it in History."
            case .savedText: return "Keep current leaves it in Library."
            }
        }
        var keptNote: String {
            switch self {
            case .selection: return "The imported selection was not saved or sent."
            case .transcript: return "The transcript is still in History."
            case .savedText: return "The saved text is still in Library."
            }
        }
        fileprivate var emptyMessage: String {
            switch self {
            case .selection: return "Select some text, then choose Read Selection in Workbench again."
            case .transcript: return "This transcript has no words to read."
            case .savedText: return "This saved item has no text to read."
            }
        }
    }

    let id: UUID
    let text: String
    let origin: Origin

    init(id: UUID = UUID(), text: String, origin: Origin = .selection) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.message(origin.emptyMessage)
        }
        guard text.count <= Self.maximumCharacters else {
            throw VoiceError.message(origin == .selection ? "The selection is too large to review safely. Select a smaller passage and try again."
                                                          : "This text is too large to review safely.")
        }
        self.id = id
        self.text = text
        self.origin = origin
    }

    static func read(from pasteboard: NSPasteboard) throws -> Self {
        guard pasteboard.availableType(from: [.string]) != nil,
              let text = pasteboard.string(forType: .string) else {
            throw VoiceError.message("Workbench received no text selection. Select text in the other app and try again.")
        }
        return try Self(text: text)
    }

    static func needsReview(current: String, incoming: String) -> Bool {
        !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && current != incoming
    }
}

/// The only data source is the request pasteboard supplied by macOS Services.
/// This provider never consults the general clipboard, Accessibility, a window,
/// or the screen when the requesting app has no usable selection.
@MainActor
final class ReadSelectionService: NSObject {
    typealias Handler = (ReadingSelectionImport) -> Void
    typealias Reader = (NSPasteboard) throws -> ReadingSelectionImport
    private let reader: Reader
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.reader = { try ReadingSelectionImport.read(from: $0) }
        self.handler = handler
        super.init()
    }

    init(reader: @escaping Reader, handler: @escaping Handler) {
        self.reader = reader
        self.handler = handler
        super.init()
    }

    @objc(readSelection:userData:error:)
    func readSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        do { handler(try reader(pasteboard)) }
        catch { errorPointer.pointee = error.localizedDescription as NSString }
    }
}
