import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Rebuildable facts about one Snap image: the text visible in it, for search,
/// and a Vision feature print, for spotting repeats. It is stored beside the
/// Snap and keyed to the image digest it came from, never inside the editable
/// record, so computing it cannot collide with an open editor's revision.
struct SnapDerivedData: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "derived.json"
    static let maximumTextCharacters = 20_000
    static let maximumBytes = 2 * 1_024 * 1_024

    var version = currentVersion
    var imageSHA256: String
    var text: String
    var featurePrint: Data?
}

/// Everything runs on this Mac with Apple's Vision framework. Nothing is sent
/// anywhere and no model is downloaded.
enum SnapAnalysis {
    /// Feature-print distance below which two captures are proposed as repeats.
    /// A synthetic window captured a minute apart (clock and pointer moved)
    /// measured 0.075; a different screen measured 0.637.
    static let repeatDistance: Float = 0.2

    static func analyze(png: Data, imageSHA256: String) throws -> SnapDerivedData {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SnapError.message("This Snap's image could not be read for search.")
        }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let print = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, print])
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let archived = try print.results?.first.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return SnapDerivedData(imageSHA256: imageSHA256,
                               text: String(lines.joined(separator: "\n").prefix(SnapDerivedData.maximumTextCharacters)),
                               featurePrint: archived)
    }

    static func observation(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Nil when the prints cannot be compared, for example after an OS update
    /// changed Vision's model revision.
    static func distance(_ first: VNFeaturePrintObservation, _ second: VNFeaturePrintObservation) -> Float? {
        var value: Float = 0
        guard (try? first.computeDistance(&value, to: second)) != nil, value.isFinite else { return nil }
        return value
    }
}
