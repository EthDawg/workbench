import AppKit

struct ReadingSelectionImport: Identifiable, Equatable {
    static let maximumCharacters = 1_000_000

    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.message("Select some text, then choose Read Selection in Workbench again.")
        }
        guard text.count <= Self.maximumCharacters else {
            throw VoiceError.message("The selection is too large to review safely. Select a smaller passage and try again.")
        }
        self.id = id
        self.text = text
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
