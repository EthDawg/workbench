import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VoiceAppearance

/// One voice appearance (#134, #158): the toolbar's compact trace and the
/// Persona ring share a state model and one look, dots that a voice raises
/// into bars, with an input response for the speaker and a calmer one for the
/// audience. These checks feed both the same synthetic sequence, hold the
/// trace to its box, and keep the recorder's level to the 150 ms and 500 ms
/// targets; the optional gallery renders both at their native sizes, and
/// both in motion from spoken sentences.
final class VoiceAppearanceTests {
    /// Quiet, soft, usual, raised, then a pause: one second each, delivered
    /// ten times a second as a microphone does.
    static let sequence: [(name: String, from: Double, to: Double, sample: VoiceSample?)] = [
        ("quiet", 0, 0.6, nil),
        ("soft", 0.6, 1.6, VoiceSample(voiced: true, level: 0.1)),
        ("usual", 1.6, 2.6, VoiceSample(voiced: true, level: 0.5)),
        ("raised", 2.6, 3.6, VoiceSample(voiced: true, level: 1)),
        ("pause", 3.6, 4.6, VoiceSample.silent)
    ]
    static func sample(at time: Double) -> VoiceSample? {
        sequence.first { time >= $0.from && time < $0.to }?.sample
    }
    static let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!

    private func ring(_ outline: PersonaArtworkOutline, artwork: CGRect, canvas: CGSize, appearance: NSAppearance,
                      increaseContrast: Bool = false, reduceMotion: Bool = false) -> PersonaVoiceRingLayer {
        let ring = PersonaVoiceRingLayer()
        ring.increaseContrast = increaseContrast; ring.reduceMotion = reduceMotion
        ring.frame = CGRect(origin: .zero, size: canvas); ring.contentsScale = 2
        ring.colors = VoiceStyle.overlayColors(chosen: PersonaVoiceRingLayer.usualColor.nsColor.cgColor)
        ring.geometry = PersonaVoiceRingGeometry(outline: outline, artwork: artwork)
        ring.layoutIfNeeded()
        return ring
    }
    private func trace(appearance: NSAppearance, increaseContrast: Bool = false, reduceMotion: Bool = false) -> VoiceTraceView {
        let view = VoiceTraceView(frame: CGRect(x: 0, y: 0, width: 48, height: 28))
        view.appearance = appearance
        view.color = VoiceStyle.resolved(WorkbenchPalette.nativeAccent, in: appearance)
        view.increaseContrast = increaseContrast; view.reduceMotion = reduceMotion
        return view
    }

    /// One sequence through both renderers holds each response within its
    /// bounds and checks quiet, normal and loud states without requiring the
    /// speaker's input meter and the audience's outline to move identically.
    func testSurfacesShareVoiceStatesWithDistinctResponse() {
        let outline = ring(.circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5), artwork: CGRect(x: 20, y: 20, width: 96, height: 96),
                           canvas: CGSize(width: 136, height: 136), appearance: Self.dark)
        let pill = trace(appearance: Self.dark)
        guard let geometry = outline.geometry else { XCTAssertTrue(false, "The outline has geometry"); return }
        var tick = 0.0, delivered = -1.0, frames = 0, mismatches = 0
        var rows: [String] = []
        var reached: [String: Set<VoiceEnvelope.Visible>] = [:]
        var traceReached: [String: Set<VoiceEnvelope.Visible>] = [:]
        while tick < 4.6 {
            let due = (tick * 10).rounded(.down) / 10
            if due > delivered, let sample = Self.sample(at: due) {
                outline.receive([sample], at: due); pill.receive([sample], at: due)
                delivered = due
            } else if due > delivered { delivered = due }
            tick += 1.0 / 60
            outline.advance(to: tick); pill.advance(to: tick)
            frames += 1
            let a = outline.state, b = pill.envelope
            if !(0...1).contains(a.intensity) || !(0...1).contains(b.intensity) { mismatches += 1 }
            if outline.stroke.opacity < 0.34 || pill.stroke.opacity < 0.45 { mismatches += 1 }
            let segment = Self.sequence.first { tick >= $0.from && tick < $0.to }?.name ?? "pause"
            reached[segment, default: []].insert(a.visible)
            traceReached[segment, default: []].insert(b.visible)
            // Every bar stays within its own room: the ring's reach and the trace's tapered box.
            let ringBars = outline.heights, pillBars = pill.heights
            if !ringBars.allSatisfy({ (0...geometry.barReach).contains($0) }) { mismatches += 1 }
            if !zip(pillBars, VoiceTraceGeometry.taper).allSatisfy({ $0 >= VoiceTraceGeometry.barWidth && $0 <= max(VoiceTraceGeometry.barWidth, VoiceTraceGeometry.trace.height * $1) + 0.0001 }) { mismatches += 1 }
            if frames % 12 == 0 {
                rows.append(String(format: "%.2f s %@ intensity %.3f %@ opacity %.2f · ring's tallest bar %.1f pt · trace's tallest bar %.1f pt", tick, segment,
                                   a.intensity, a.visible.rawValue, outline.stroke.opacity, ringBars.max() ?? 0, pillBars.max() ?? 0))
            }
        }
        XCTAssertEqual(mismatches, 0, "Both responses stay within their visible and geometric limits")
        XCTAssertEqual(reached["quiet"], [.quiet], "Nothing shows before a voice")
        XCTAssertFalse(reached["soft"]?.contains(.loud) ?? true, "A soft voice lights without reading as raised")
        XCTAssertTrue(reached["soft"]?.contains(.normal) ?? false)
        XCTAssertTrue(reached["raised"]?.contains(.loud) ?? false, "A raised voice reads as loud on both")
        XCTAssertEqual(traceReached["quiet"], [.quiet])
        XCTAssertFalse(traceReached["soft"]?.contains(.loud) ?? true)
        XCTAssertTrue(traceReached["soft"]?.contains(.normal) ?? false)
        XCTAssertTrue(traceReached["raised"]?.contains(.loud) ?? false)
        XCTAssertEqual(pill.envelope.visible, .quiet)
        XCTAssertEqual(outline.state.visible, .quiet, "The pause returns both to rest")
        XCTAssertFalse(outline.isMoving || pill.isMoving, "At rest, nothing moves")
        print("Voice appearance, audience ring and responsive input trace (\(frames) display frames, 0 out-of-range values):\n  " + rows.joined(separator: "\n  "))
    }

    /// The trace fits its 28 × 12 box, beside a 4-point dot and 4-point gap,
    /// inside the compact mark's 48 × 28 target and 12-point active height.
    /// Its bars are tallest in the middle and thin out to each side, a
    /// syllable swells from the middle outward, and silence is a row of dots.
    func testTraceFitsTheCompactMarkAndPeaksInTheMiddle() {
        XCTAssertEqual(VoiceTraceGeometry.size, CGSize(width: 36, height: 12))
        XCTAssertTrue(VoiceTraceGeometry.size.width <= 48 && VoiceTraceGeometry.size.height <= 12, "Fits the compact mark's target and active height")
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 28)
        let layout = VoiceTraceGeometry.layout(in: bounds)
        XCTAssertEqual(layout.dot.width, 4); XCTAssertEqual(layout.dot.height, 4)
        XCTAssertEqual(layout.trace.minX - layout.dot.maxX, 4, "A 4-point gap")
        XCTAssertEqual(Double(layout.dot.midY), Double(layout.trace.midY), accuracy: 0.001)
        XCTAssertEqual(VoiceTraceGeometry.taper.count, VoiceTraceGeometry.bars)
        let middle = VoiceTraceGeometry.bars / 2
        XCTAssertEqual(VoiceTraceGeometry.taper[middle], 1, "The middle bar may take the whole height")
        XCTAssertTrue((0..<middle).allSatisfy { VoiceTraceGeometry.taper[$0] < VoiceTraceGeometry.taper[$0 + 1] }, "Bars thin out to the left")
        XCTAssertEqual(VoiceTraceGeometry.taper, Array(VoiceTraceGeometry.taper.reversed()), "And to the right alike")
        // The tallest waveform stays inside its box, and the box inside the mark.
        let tallest = VoiceTraceGeometry.path(in: layout.trace, heights: VoiceTraceGeometry.taper.map { $0 * 100 }).boundingBoxOfPath
        XCTAssertTrue(layout.trace.insetBy(dx: -0.01, dy: -0.01).contains(tallest), "The tallest bars stay inside the box (\(tallest))")
        XCTAssertTrue(bounds.contains(tallest.union(layout.dot)))
        // Silence is a row of dots: every bar as tall as it is wide.
        var wave = VoiceWave(starvation: nil, response: .input)
        XCTAssertTrue(VoiceTraceGeometry.heights(wave, reduceMotion: false).allSatisfy { $0 == VoiceTraceGeometry.barWidth }, "Silence is a row of dots")
        let dots = VoiceTraceGeometry.path(in: layout.trace, heights: VoiceTraceGeometry.heights(wave, reduceMotion: false)).boundingBoxOfPath
        XCTAssertEqual(Double(dots.height), Double(VoiceTraceGeometry.barWidth), accuracy: 0.0001)
        XCTAssertEqual(Double(dots.width), Double(layout.trace.width), accuracy: 0.0001)
        // A syllable swells from the middle and reaches the ends a moment later.
        wave.receive(1, at: 0)
        wave.advance(to: 0.05)
        let early = VoiceTraceGeometry.heights(wave, reduceMotion: false)
        XCTAssertTrue(early[middle] > VoiceTraceGeometry.barWidth * 2 && early[0] == VoiceTraceGeometry.barWidth, "The middle rises first (\(early))")
        for step in 4...36 { wave.advance(to: Double(step) / 60) }
        let full = VoiceTraceGeometry.heights(wave, reduceMotion: false)
        XCTAssertTrue(full[middle] > full[0] && full[middle] > full[VoiceTraceGeometry.bars - 1] && full[0] > VoiceTraceGeometry.barWidth, "Then the whole row stands, tallest in the middle (\(full))")
        XCTAssertTrue(Set(full.map { ($0 * 4).rounded() }).count >= 4, "Bars differ: never one bar repeated")
        // The voice ends: the row sinks back to dots and the wave rests.
        wave.receive(0, at: 0.6)
        for step in 37...100 { wave.advance(to: Double(step) / 60) }
        XCTAssertFalse(wave.isMoving, "Without a voice nothing moves")
        XCTAssertTrue(VoiceTraceGeometry.heights(wave, reduceMotion: false).allSatisfy { $0 == VoiceTraceGeometry.barWidth })
        // Energies that arrive together play in turn, and a stalled source never builds a backlog.
        var batched = VoiceWave(starvation: 0.35, response: .speaker)
        batched.receive([1, 0, 1, 0, 1], spacing: 0.02, at: 10)
        var seen: [Double] = []
        for step in 1...8 { batched.advance(to: 10 + Double(step) * 0.0125); seen.append(batched.level()) }
        XCTAssertTrue(zip(seen, seen.dropFirst()).contains { $1 < $0 } && zip(seen, seen.dropFirst()).contains { $1 > $0 }, "Each energy of a buffer shows in its turn (\(seen))")
        for step in 0..<80 { batched.advance(to: 10.1 + Double(step) / 60) }
        XCTAssertFalse(batched.isMoving, "A source that stops sending settles")
    }

    /// The same syllables give prompt input feedback and a calmer audience outline.
    func testInputTraceFollowsSyllablesWhileTheOutlineStaysCalm() {
        let pill = trace(appearance: Self.dark)
        let outline = ring(.circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5),
                           artwork: CGRect(x: 20, y: 20, width: 96, height: 96),
                           canvas: CGSize(width: 136, height: 136), appearance: Self.dark)
        XCTAssertTrue(outline.stroke.opacity < pill.stroke.opacity, "The audience outline recedes at rest")
        var time = 0.0
        func feed(_ level: Double, for seconds: Double) {
            let end = time + seconds
            while time < end {
                let sample = VoiceSample(voiced: true, level: level)
                pill.receive([sample], at: time); outline.receive([sample], at: time)
                time += 1.0 / 60
                pill.advance(to: time); outline.advance(to: time)
            }
        }
        feed(0.3, for: 0.8)
        feed(1, for: 0.1)
        XCTAssertTrue(pill.envelope.loudness > outline.state.loudness + 0.2,
                      "A syllable shows promptly to the person recording")
        feed(0.1, for: 0.1)
        XCTAssertTrue(pill.envelope.loudness < outline.state.loudness - 0.1,
                      "Input drops promptly while the audience outline eases")
    }

    func testTraceShowsSoftInputTheRecorderCanKeep() {
        let view = trace(appearance: Self.dark)
        // A soft -50 dBFS input is inside the recorder's accepted range. The
        // input meter should show it even when a speaker detector would not.
        let level = Double(-50 + 55) / 55
        view.receive(level: level, at: 1)
        for step in 1...6 { view.advance(to: 1 + Double(step) / 60) }
        XCTAssertTrue((view.heights.max() ?? 0) > VoiceTraceGeometry.barWidth + 0.3, "Soft microphone input visibly raises the trace (\(view.heights))")
        XCTAssertTrue(view.envelope.visible != .quiet, "Input appears within 100 ms")
        view.receive(level: 0, at: 1.1)
        for step in 1...30 { view.advance(to: 1.1 + Double(step) / 60) }
        XCTAssertTrue(view.heights.allSatisfy { $0 == VoiceTraceGeometry.barWidth }, "Silence settles the input trace to dots")
        view.receive(level: nil, at: 1.7)
        XCTAssertFalse(view.envelope.isMoving, "Missing input never creates motion")
    }

    /// Silence and missing input rest; Reduce Motion fixes the shape.
    func testTraceRestsWhenStillAndHoldsItsShapeWithReduceMotion() {
        let view = trace(appearance: Self.light)
        XCTAssertTrue(view.hitTest(CGPoint(x: 24, y: 14)) == nil, "The trace never takes the pointer")
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertEqual(view.intrinsicContentSize, VoiceTraceGeometry.size)
        var clock = 10.0
        func run(_ seconds: Double, level: Double?) {
            let end = clock + seconds
            var next = clock
            while clock < end {
                if clock >= next { view.receive(level: level, at: clock); next += 0.08 }
                clock += 1.0 / 60
                view.advance(to: clock)
            }
        }
        run(1, level: 0.05)
        XCTAssertFalse(view.envelope.isMoving, "A quiet room never moves the trace")
        XCTAssertTrue(view.heights.allSatisfy { $0 == VoiceTraceGeometry.barWidth }, "A row of dots")
        run(1, level: nil)
        XCTAssertFalse(view.envelope.isMoving, "No level, no motion")
        run(0.6, level: 0.55)
        XCTAssertTrue(view.envelope.isMoving && (view.heights.max() ?? 0) > VoiceTraceGeometry.trace.height * 0.4, "A voice raises the bars (\(view.heights))")
        // The level stops changing but stays loud: the voice is still shown.
        view.receive(level: 0.55, at: clock)
        for _ in 0..<60 { clock += 1.0 / 60; view.advance(to: clock) }
        XCTAssertTrue(view.envelope.visible != .quiet, "A steady level stays lit without new readings")
        // It goes quiet and stops, even with no new reading after the last.
        view.receive(level: 0.02, at: clock)
        var stoppedAt: Double?
        for _ in 0..<60 where stoppedAt == nil { clock += 1.0 / 60; if !view.advance(to: clock) { stoppedAt = clock } }
        XCTAssertTrue(stoppedAt != nil, "After a voice it settles and display updates stop")
        XCTAssertTrue(view.heights.allSatisfy { $0 == VoiceTraceGeometry.barWidth })
        // Reduce Motion: the bars hold one still waveform; brightness alone says a voice is heard.
        view.reduceMotion = true
        let still = view.heights
        XCTAssertTrue(still[VoiceTraceGeometry.bars / 2] > still[0], "A still waveform, tallest in the middle")
        run(0.6, level: 0.7)
        XCTAssertEqual(view.heights, still, "Reduce Motion keeps the trace's shape")
        XCTAssertTrue(view.stroke.opacity > 0.9, "A voice brightens it")
        run(1, level: 0)
        XCTAssertEqual(view.heights, still)
        XCTAssertEqual(view.stroke.opacity, VoiceStyle.restOpacity(increaseContrast: false), accuracy: 0.0001)
    }

    /// The recorder's own level, read every 80 ms as Dictate publishes it,
    /// reaches the same targets: lit within 150 ms of the first voiced reading
    /// it receives, back to rest within 500 ms of the last, and steady through
    /// the dips between syllables. A quiet room never lights it.
    func testRecorderLevelMeetsTheTargets() {
        var random: UInt64 = 0x2545_F491_4F6C_DD1D
        func noise() -> Double { random ^= random << 13; random ^= random >> 7; random ^= random << 17; return Double(random % 1_000) / 1_000 }
        var readings: [(time: Double, level: Double)] = []
        var phrases: [(first: Double, last: Double)] = []
        var time = 0.0
        func room(_ seconds: Double) { let end = time + seconds; while time < end { readings.append((time, 0.01 + 0.03 * noise())); time += 0.08 } }
        func phrase(_ seconds: Double, level: Double) {
            let end = time + seconds
            var first: Double?, last = time
            while time < end {
                // Syllables with short dips between them.
                let dip = Int((time * 12.5).rounded()) % 4 == 3
                let value = dip ? 0.01 + 0.03 * noise() : level + 0.12 * (noise() - 0.5)
                readings.append((time, value))
                if value >= VoiceMeter.voiceAt { if first == nil { first = time }; last = time }
                time += 0.08
            }
            phrases.append((first ?? time, last))
        }
        room(1.2)
        for level in [0.32, 0.5, 0.72, 0.5] { phrase(1.6, level: level); room(0.9) }
        let view = trace(appearance: Self.dark)
        var clock = 0.0, index = 0
        var ticks: [(time: Double, visible: VoiceEnvelope.Visible)] = []
        while clock < time + 1 {
            while index < readings.count, readings[index].time <= clock { view.receive(level: readings[index].level, at: readings[index].time); index += 1 }
            clock += 1.0 / 60
            view.advance(to: clock)
            ticks.append((clock, view.envelope.visible))
        }
        var worstOnset = 0.0, worstRelease = 0.0
        for phrase in phrases {
            let lit = ticks.first { $0.time >= phrase.first && $0.visible != .quiet }?.time
            let rest = ticks.first { $0.time >= phrase.last && $0.visible == .quiet }?.time
            let onset = lit.map { $0 - phrase.first } ?? .infinity, release = rest.map { $0 - phrase.last } ?? .infinity
            worstOnset = max(worstOnset, onset); worstRelease = max(worstRelease, release)
            XCTAssertTrue(onset <= 0.15, "Lit within 150 ms of the first voiced reading (\(Int(onset * 1_000)) ms)")
            XCTAssertTrue(release <= 0.5, "At rest within 500 ms of the last (\(Int(release * 1_000)) ms)")
            let during = ticks.filter { $0.time >= (lit ?? phrase.last) && $0.time <= phrase.last }
            XCTAssertTrue(during.allSatisfy { $0.visible != .quiet }, "Steady through the dips between syllables")
        }
        let roomTicks = ticks.filter { tick in !phrases.contains { tick.time >= $0.first - 0.1 && tick.time <= $0.last + 0.6 } }
        XCTAssertTrue(roomTicks.allSatisfy { $0.visible == .quiet }, "A quiet room never lights it")
        print(String(format: "Voice trace from the recorder's level: onset ≤ %.0f ms from the first voiced reading, back to rest ≤ %.0f ms from the last (%d phrases, 80 ms readings)",
                     worstOnset * 1_000, worstRelease * 1_000, phrases.count))
    }

    /// The SwiftUI trace drops into a toolbar row: its fixed size, the accent
    /// resolved for the row's appearance, and Reduce Motion and Increase
    /// Contrast from the environment. It draws through the same capture the
    /// toolbar's galleries use.
    func testSwiftUITraceDropsIntoAToolbarRow() throws {
        try MainActor.assumeIsolated {
            func host<V: View>(_ view: V) throws -> (NSHostingView<V>, VoiceTraceView, NSWindow) {
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 120, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting
                hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                func find(_ view: NSView) -> VoiceTraceView? { (view as? VoiceTraceView) ?? view.subviews.lazy.compactMap(find).first }
                guard let trace = find(hosting) else { throw PersonaError.unreadableImage }
                return (hosting, trace, window)
            }
            let accent = Color(nsColor: WorkbenchPalette.nativeAccent)
            for (scheme, appearance) in [(ColorScheme.light, Self.light), (.dark, Self.dark)] {
                let (hosting, trace, window) = try host(VoiceTrace(level: 0.6, accent: accent).environment(\.colorScheme, scheme))
                defer { window.close() }
                XCTAssertEqual(hosting.fittingSize, VoiceTraceGeometry.size, "It keeps its own size")
                let expected = VoiceStyle.resolved(WorkbenchPalette.nativeAccent, in: appearance)
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let got = trace.color.converted(to: space, intent: .defaultIntent, options: nil)?.components ?? []
                let want = expected.converted(to: space, intent: .defaultIntent, options: nil)?.components ?? []
                XCTAssertTrue(zip(got, want).allSatisfy { abs($0 - $1) < 0.01 } && got.count == want.count, "The \(scheme) accent (\(got) against \(want))")
                XCTAssertTrue(trace.envelope.isMoving, "A level reached the trace")
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PersonaError.unreadableImage }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                var inked = 0
                for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { inked += 1 } }
                XCTAssertTrue(inked > 20, "The dot and trace draw in the toolbar's capture (\(inked) pixels)")
            }
            let (_, still, stillWindow) = try host(VoiceTrace(level: 0.6, accent: accent).environment(\._accessibilityReduceMotion, true).environment(\._colorSchemeContrast, .increased))
            defer { stillWindow.close() }
            XCTAssertTrue(still.reduceMotion && still.increaseContrast, "Reduce Motion and Increase Contrast come from the environment")
        }
    }

    // MARK: Gallery

    /// A synthetic portrait photo: a person against a soft backdrop.
    static func portrait() -> NSImage {
        NSImage(size: CGSize(width: 300, height: 360), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.78, green: 0.84, blue: 0.9, alpha: 1), ending: NSColor(srgbRed: 0.55, green: 0.62, blue: 0.75, alpha: 1))!.draw(in: rect, angle: 90)
            NSColor(srgbRed: 0.24, green: 0.28, blue: 0.36, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 50, y: -70, width: 200, height: 190)).fill()
            NSColor(srgbRed: 0.87, green: 0.72, blue: 0.6, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 100, y: 110, width: 100, height: 120)).fill()
            NSColor(srgbRed: 0.3, green: 0.22, blue: 0.18, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 92, y: 186, width: 116, height: 62)).fill()
            return true
        }
    }
    /// A slide full of colour and text, for a busy background.
    static func busy(_ size: CGSize) -> CGImage? {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.93, blue: 0.84, alpha: 1), NSColor(srgbRed: 0.72, green: 0.84, blue: 0.95, alpha: 1),
                                NSColor(srgbRed: 0.18, green: 0.24, blue: 0.4, alpha: 1)])!.draw(in: rect, angle: -30)
            let colours: [NSColor] = [.systemOrange, .systemTeal, .systemPink, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for index in 0..<18 {
                colours[index % colours.count].withAlphaComponent(0.85).setFill()
                let height = CGFloat((index * 37) % 90 + 30)
                NSBezierPath(roundedRect: CGRect(x: 12 + CGFloat(index) * rect.width / 18, y: 16, width: rect.width / 30, height: height), xRadius: 3, yRadius: 3).fill()
            }
            for line in 0..<Int(rect.height / 18) {
                (line % 3 == 0 ? NSColor.black : NSColor.white).withAlphaComponent(0.55).setFill()
                let width = rect.width * (0.3 + 0.5 * CGFloat((line * 53) % 10) / 10)
                NSBezierPath(roundedRect: CGRect(x: CGFloat((line * 71) % 60), y: rect.height - 20 - CGFloat(line) * 18, width: width, height: 6), xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Both surfaces at their native sizes, in one state, over one background:
    /// the trace inside a compact mark, a small Circle and a large Card.
    final class Scene {
        enum Background: String { case light, dark, busy }
        let background: Background
        let appearance: NSAppearance
        let pill: VoiceTraceView
        let pillZoom: VoiceTraceView
        let circle: PersonaVoiceRingLayer, card: PersonaVoiceRingLayer
        let circleImage: CGImage, cardImage: CGImage
        let circleRect: CGRect, cardRect: CGRect, markRect: CGRect, zoomRect: CGRect
        let circleCanvas: CGRect, cardCanvas: CGRect
        static let size = CGSize(width: 720, height: 540)
        let busyImage: CGImage?
        var clock = 100.0

        init(background: Background, appearance: NSAppearance, increaseContrast: Bool = false, reduceMotion: Bool = false) throws {
            self.background = background; self.appearance = appearance
            let tests = VoiceAppearanceTests()
            pill = tests.trace(appearance: appearance, increaseContrast: increaseContrast, reduceMotion: reduceMotion)
            pillZoom = tests.trace(appearance: appearance, increaseContrast: increaseContrast, reduceMotion: reduceMotion)
            // The Circle and Card looks as Persona draws them, with the edges they supply.
            let portrait = VoiceAppearanceTests.portrait()
            guard let circleImage = try PersonaCircleRenderer.image(portrait: portrait, framing: .centred).cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let cardImage = try PersonaCardRenderer.image(portrait: portrait, style: PersonaCardStyle(label: "Care lead"))
                    .cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let circleOutline = PersonaAppearance.Shape.circle.outline, let cardOutline = PersonaAppearance.Shape.card.outline
            else { throw PersonaError.unreadableImage }
            self.circleImage = circleImage; self.cardImage = cardImage
            // A small Circle (96 points) and a large Card (300 points wide), placed with their outline's room.
            let circleInsets = PersonaVoiceRingGeometry(outline: circleOutline, artwork: CGRect(x: 0, y: 0, width: 96, height: 96)).outsets
            let cardSize = CGSize(width: 300, height: 375)
            let cardInsets = PersonaVoiceRingGeometry(outline: cardOutline, artwork: CGRect(origin: .zero, size: cardSize)).outsets
            circleCanvas = CGRect(x: 30, y: 250, width: 96 + circleInsets.left + circleInsets.right, height: 96 + circleInsets.top + circleInsets.bottom)
            circleRect = CGRect(x: circleInsets.left, y: circleInsets.bottom, width: 96, height: 96)
            cardCanvas = CGRect(x: 310, y: 30, width: cardSize.width + cardInsets.left + cardInsets.right, height: cardSize.height + cardInsets.top + cardInsets.bottom)
            cardRect = CGRect(x: cardInsets.left, y: cardInsets.bottom, width: cardSize.width, height: cardSize.height)
            markRect = CGRect(x: 64, y: 460, width: 48, height: 28)
            zoomRect = CGRect(x: 40, y: 80, width: 48 * 4, height: 28 * 4)
            circle = tests.ring(circleOutline, artwork: circleRect, canvas: circleCanvas.size, appearance: appearance, increaseContrast: increaseContrast, reduceMotion: reduceMotion)
            card = tests.ring(cardOutline, artwork: cardRect, canvas: cardCanvas.size, appearance: appearance, increaseContrast: increaseContrast, reduceMotion: reduceMotion)
            busyImage = background == .busy ? VoiceAppearanceTests.busy(Self.size) : nil
        }
        /// Settles every surface on `sample` (nil stays at rest).
        func settle(_ sample: VoiceSample?) {
            guard let sample else { return }
            for step in 0..<40 {
                if step % 6 == 0 { deliver([sample]) }
                advance(1.0 / 60)
            }
        }
        func deliver(_ samples: [VoiceSample]) {
            circle.receive(samples, at: clock); card.receive(samples, at: clock)
            pill.receive(samples, at: clock); pillZoom.receive(samples, at: clock)
        }
        func advance(_ seconds: Double) {
            clock += seconds
            circle.advance(to: clock); card.advance(to: clock); pill.advance(to: clock); pillZoom.advance(to: clock)
        }
        func snapshot(scale: CGFloat = 2) throws -> CGImage {
            let size = Self.size
            guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw PersonaError.unreadableImage }
            context.scaleBy(x: scale, y: scale)
            switch background {
            case .light: context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: size))
            case .dark: context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); context.fill(CGRect(origin: .zero, size: size))
            case .busy: if let busyImage { context.draw(busyImage, in: CGRect(origin: .zero, size: size)) }
            }
            // The compact mark: a 48 × 12 capsule in its 48 × 28 target, as the toolbar rests while capturing.
            func mark(in rect: CGRect, zoom: CGFloat, view: VoiceTraceView) {
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: zoom, y: zoom)
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let capsule = CGPath(roundedRect: CGRect(x: 0, y: 8, width: 48, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil)
                context.addPath(capsule); context.setFillColor(NSColor(white: isDark ? 0.17 : 0.97, alpha: 0.94).cgColor); context.fillPath()
                context.addPath(capsule); context.setStrokeColor(NSColor(white: isDark ? 1 : 0, alpha: 0.3).cgColor); context.setLineWidth(1); context.strokePath()
                view.render(in: context)
                context.restoreGState()
            }
            mark(in: markRect, zoom: 1, view: pill)
            mark(in: zoomRect, zoom: 4, view: pillZoom)
            for (layer, canvas, rect, image) in [(circle, circleCanvas, circleRect, circleImage), (card, cardCanvas, cardRect, cardImage)] {
                context.saveGState()
                context.translateBy(x: canvas.minX, y: canvas.minY)
                layer.render(in: context)
                context.draw(image, in: rect)
                context.restoreGState()
            }
            guard let image = context.makeImage() else { throw PersonaError.unreadableImage }
            return image
        }
    }

    private func png(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
        try data.write(to: url)
    }
    private static func grid(_ images: [CGImage], columns: Int) throws -> CGImage {
        guard let first = images.first else { throw PersonaError.unreadableImage }
        let rows = (images.count + columns - 1) / columns
        guard let context = CGContext(data: nil, width: first.width * columns, height: first.height * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PersonaError.unreadableImage }
        for (index, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: (index % columns) * first.width, y: (rows - 1 - index / columns) * first.height, width: first.width, height: first.height))
        }
        guard let result = context.makeImage() else { throw PersonaError.unreadableImage }
        return result
    }

    /// Set WORKBENCH_LAYOUT_EVIDENCE to write the gallery: each state at native
    /// size over light, dark and busy backgrounds, the cross cases where the
    /// appearance and the content differ, Reduce Motion and Increase Contrast,
    /// and a motion recording of the shared sequence, both surfaces together.
    func testOffscreenVoiceAppearanceGallery() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, VoiceSample?)] = [("quiet", nil), ("soft", VoiceSample(voiced: true, level: 0.1)),
                                                 ("usual", VoiceSample(voiced: true, level: 0.5)), ("raised", VoiceSample(voiced: true, level: 1))]
        let cases: [(String, Scene.Background, NSAppearance, Bool, Bool)] = [
            ("light", .light, Self.light, false, false), ("dark", .dark, Self.dark, false, false),
            ("busy-dark", .busy, Self.dark, false, false), ("busy-light", .busy, Self.light, false, false),
            ("light-appearance-over-dark", .dark, Self.light, false, false), ("dark-appearance-over-light", .light, Self.dark, false, false),
            ("reduce-motion-dark", .dark, Self.dark, false, true), ("increase-contrast-light", .light, Self.light, true, false),
            ("increase-contrast-dark", .dark, Self.dark, true, false)
        ]
        for (name, background, appearance, contrast, reduceMotion) in cases {
            var sheet: [CGImage] = []
            for (label, sample) in states {
                let scene = try Scene(background: background, appearance: appearance, increaseContrast: contrast, reduceMotion: reduceMotion)
                scene.settle(sample)
                let image = try scene.snapshot()
                sheet.append(image)
                try png(image, to: directory.appendingPathComponent("voice-appearance-\(name)-\(label).png"))
            }
            let url = directory.appendingPathComponent("sheet-\(name).png")
            try png(Self.grid(sheet, columns: 2), to: url)
            print("Voice appearance gallery: " + url.path)
        }
        try recordMotion(to: directory.appendingPathComponent("voice-appearance-motion.gif"))
        try recordSpeech(to: directory)
    }

    /// Sentences spoken by the Mac's own voice (written with `say -o`, never
    /// played) through both surfaces as each really hears a voice: the Persona
    /// analyser from 100 ms microphone buffers, and the trace from a recorder's
    /// level read every 80 ms. Writes the motion at 30 frames a second, each
    /// frame as a still, and a sheet of moments a quarter of a second apart.
    private func recordSpeech(to directory: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceWaveSay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("speech.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "--file-format=WAVE", "--data-format=LEF32@48000", "-o", file.path,
                             "So, here is the plan. First, open the settings. Then look at the numbers: seven of them are ready."]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { return }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return }
        var fixture = PersonaVoiceLatencyTests.Fixture("speech")
        fixture.room(0.7, -62)
        fixture.recorded(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), -28, room: -62)
        fixture.room(1.2, -62)
        let samples = fixture.samples, rate = fixture.rate
        let analyzer = PersonaVoiceAnalyzer(sampleRate: rate)
        let microphone = Int(rate * 0.1), meter = Int(rate * 0.08)
        let top = try Scene(background: .dark, appearance: Self.dark), bottom = try Scene(background: .busy, appearance: Self.light)
        let frames = Int(Double(samples.count) / rate * 60)
        let url = directory.appendingPathComponent("voice-appearance-speech.gif")
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, (frames + 1) / 2, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let stills = directory.appendingPathComponent("speech-frames")
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        var heard = 0, metered = 0, strip: [CGImage] = []
        for frame in 0..<frames {
            let sample = Int(Double(frame) / 60 * rate)
            // A microphone buffer arrives once its last sample has been heard.
            while heard + microphone <= sample {
                let voice = samples[heard..<heard + microphone].withUnsafeBufferPointer { analyzer.process($0) }
                for scene in [top, bottom] { scene.circle.receive(voice, at: scene.clock); scene.card.receive(voice, at: scene.clock) }
                heard += microphone
            }
            // The recorder's meter: the average power of the last 80 ms, over 55 dB.
            while metered + meter <= sample {
                let power = samples[metered..<metered + meter].reduce(Float(0)) { $0 + $1 * $1 } / Float(meter)
                let level = Double(max(0, min(1, (10 * log10(max(1e-12, power)) + 55) / 55)))
                for scene in [top, bottom] { scene.pill.receive(level: level, at: scene.clock); scene.pillZoom.receive(level: level, at: scene.clock) }
                metered += meter
            }
            top.advance(1.0 / 60); bottom.advance(1.0 / 60)
            guard frame % 2 == 0 else { continue }
            let image = try Self.grid([try top.snapshot(scale: 1), try bottom.snapshot(scale: 1)], columns: 1)
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
            try png(try top.snapshot(scale: 2), to: stills.appendingPathComponent(String(format: "frame-%04d.png", frame / 2)))
            // Eight moments from inside the sentences, a quarter of a second apart.
            if frame >= 66 && (frame - 66) % 16 == 0 && strip.count < 8 { strip.append(try top.snapshot(scale: 1)) }
        }
        guard CGImageDestinationFinalize(gif) else { throw PersonaError.unreadableImage }
        try png(Self.grid(strip, columns: 4), to: directory.appendingPathComponent("voice-appearance-speech-strip.png"))
        print("Voice appearance, spoken sentences: " + url.path)
    }

    /// The shared sequence through both surfaces at 30 frames a second, dark
    /// above and light below, at native size (the trace also magnified).
    private func recordMotion(to url: URL) throws {
        let top = try Scene(background: .dark, appearance: Self.dark), bottom = try Scene(background: .light, appearance: Self.light)
        let frames = Int(4.6 * 30)
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var delivered = -1.0
        for frame in 0..<frames {
            let time = Double(frame) / 30
            let due = (time * 10).rounded(.down) / 10
            if due > delivered { delivered = due; if let sample = Self.sample(at: due) { top.deliver([sample]); bottom.deliver([sample]) } }
            for _ in 0..<2 { top.advance(1.0 / 60); bottom.advance(1.0 / 60) }
            let stacked = try Self.grid([try top.snapshot(scale: 1), try bottom.snapshot(scale: 1)], columns: 1)
            CGImageDestinationAddImage(gif, stacked, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw PersonaError.unreadableImage }
        print("Voice appearance motion: " + url.path)
    }
}
