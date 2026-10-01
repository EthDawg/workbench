import AVFoundation
import FluidAudio
import Foundation

/// Parakeet reads audio longer than 15 seconds in windows, and a short last window can drop,
/// cut or invent the final words. A second reading of only the ending, as one window that
/// stops where the speech does, is stitched onto the transcript at the last words both share.
/// Measured on 411 recordings of 15 to 35 seconds (docs/model-providers.md): where speech
/// runs to the end, wrong endings fell from 63 to 33, about the level of spelling
/// differences, and word errors from 3.11% to 2.54%.
enum TranscriptEnding {
    static let sampleRate = 16_000.0
    /// Up to this length the audio is one window already and needs no second reading.
    static let singleWindowSeconds = 15.0
    static let windowSeconds = 11.5
    /// Quiet kept after the last speech. Half a second read endings best in every condition
    /// measured (speech to the end, then 1.5 s of silence, of faint noise, 3 s of room noise);
    /// 0.3 s and 1.2 s were both worse.
    static let marginSeconds = 0.5
    /// How far back from the end to look for where the speech stops.
    static let searchSeconds = 20.0
    /// Fewer shared words than this is no anchor: the transcript is left as it is.
    static let minimumSharedWords = 4
    /// The ending can only replace words this close to the transcript's end.
    static let comparedWords = 45

    /// The ending of a recording longer than one window, as 16 kHz mono samples. Nil for
    /// shorter audio, or when its last stretch holds no speech.
    static func window(of url: URL) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0, Double(file.length) / rate > singleWindowSeconds else { return nil }
        let frames = min(file.length, AVAudioFramePosition((windowSeconds + searchSeconds) * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        file.framePosition = file.length - frames
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        return window(ofEnding: try AudioConverter().resampleBuffer(buffer))
    }

    /// The last `windowSeconds` that end `marginSeconds` after the speech does. A recording
    /// that stops sooner than that is given silence for the rest of the margin.
    static func window(ofEnding samples: [Float]) -> [Float]? {
        guard let speechEnd = speechEnd(in: samples) else { return nil }
        let end = speechEnd + Int(marginSeconds * sampleRate), length = Int(windowSeconds * sampleRate)
        let window = Array(samples[max(0, min(end, samples.count) - length)..<min(end, samples.count)])
            + [Float](repeating: 0, count: max(0, end - samples.count))
        // Under a second of audio is too little to anchor on.
        return window.count >= Int(sampleRate) ? Array(window.suffix(length)) : nil
    }

    /// The sample after the last 80 ms frame that is loud enough to be speech: a tenth of the
    /// recording's loud level, kept between room tone and quiet speech. Nil when no frame is.
    static func speechEnd(in samples: [Float]) -> Int? {
        let frame = 1_280
        guard samples.count >= frame else { return nil }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for index in start..<(start + frame) { sum += samples[index] * samples[index] }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        let loud = levels.sorted()[min(levels.count - 1, levels.count * 9 / 10)]
        let threshold = min(max(loud * 0.1, 0.0005), 0.008)
        guard let last = levels.lastIndex(where: { $0 >= threshold }) else { return nil }
        return (last + 1) * frame
    }

    /// The transcript up to the last run of words it shares with the ending, then the ending
    /// from there on. With no run of `minimumSharedWords`, or when both end on the same
    /// words, the transcript is returned unchanged.
    static func stitch(_ transcript: String, ending: String) -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let endingWords = ending.split(whereSeparator: \.isWhitespace).map(String.init)
        let plain = words.map(comparable), endingPlain = endingWords.map(comparable)
        let floor = max(0, plain.count - comparedWords)
        var best: (end: Int, endingEnd: Int, length: Int)?
        var end = plain.count
        while end > floor {
            var endingEnd = endingPlain.count
            while endingEnd > 0 {
                var length = 0
                while end - length > floor, endingEnd - length > 0,
                      !plain[end - length - 1].isEmpty, plain[end - length - 1] == endingPlain[endingEnd - length - 1] { length += 1 }
                if length >= minimumSharedWords, length > (best?.length ?? 0) { best = (end, endingEnd, length) }
                endingEnd -= 1
            }
            // The run that reaches furthest into the transcript wins; earlier ends are not tried.
            if let best, best.end == end { break }
            end -= 1
        }
        guard let best, !(best.end == plain.count && best.endingEnd == endingPlain.count) else { return transcript }
        // The run's last word is written as the ending has it: it knows what follows.
        return (words[..<(best.end - 1)] + endingWords[(best.endingEnd - 1)...]).joined(separator: " ")
    }

    private static func comparable(_ word: String) -> String {
        String(word.lowercased().replacingOccurrences(of: "’", with: "'").filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }
}
