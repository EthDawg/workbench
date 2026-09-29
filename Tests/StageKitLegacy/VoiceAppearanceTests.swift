import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VoiceAppearance

/// One voice appearance (#134, #158): the toolbar's compact trace and the
/// Persona outline share a colour and state model, with an input response for
/// the speaker and a calmer outline for the audience. These checks feed both
/// the same synthetic sequence, hold the
/// trace to its box, and keep the recorder's level to the 150 ms and 500 ms
/// targets; the optional gallery renders both at their native sizes.
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
        ring.colors = VoiceStyle.overlayColors(WorkbenchPalette.nativeAccent, in: appearance)
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
            if outline.stroke.opacity < 0.18 || pill.stroke.opacity < 0.45 { mismatches += 1 }
            let segment = Self.sequence.first { tick >= $0.from && tick < $0.to }?.name ?? "pause"
            reached[segment, default: []].insert(a.visible)
            traceReached[segment, default: []].insert(b.visible)
            // Both strokes remain within their own allowed weight range.
            let ringShare = (geometry.width(outline.stroke) - geometry.lineWidth) / (geometry.maximumWidth - geometry.lineWidth)
            let pillShare = (pill.lineWidth - VoiceTraceGeometry.stroke) / (VoiceTraceGeometry.heaviest - VoiceTraceGeometry.stroke)
            if !(-0.0001...1.0001).contains(ringShare) || !(-0.0001...1.0001).contains(pillShare) { mismatches += 1 }
            // The lobes follow the shared intensity directly: no smoothing of their own.
            if abs(pill.amplitude - VoiceTraceGeometry.reach * CGFloat(b.intensity)) > 0.000001 { mismatches += 1 }
            if frames % 12 == 0 {
                rows.append(String(format: "%.2f s %@ intensity %.3f %@ opacity %.2f · outline %.2f pt · trace %.2f pt, lobes %.2f pt", tick, segment,
                                   a.intensity, a.visible.rawValue, outline.stroke.opacity, geometry.width(outline.stroke), pill.lineWidth, pill.amplitude))
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
        XCTAssertFalse(outline.isMoving || pill.envelope.isMoving, "At rest, nothing moves")
        print("Voice appearance, audience outline and responsive input trace (\(frames) display frames, 0 out-of-range values):\n  " + rows.joined(separator: "\n  "))
    }

    /// The trace fits its 24 × 10 box with the heaviest stroke and tallest
    /// lobes, beside a 4-point dot and 4-point gap, inside the compact mark's
    /// 48 × 28 target and 12-point active height. Its three lobes stay where
    /// they are as the voice changes, and silence is a straight line.
    func testTraceFitsTheCompactMarkAndNeverTravels() {
        XCTAssertEqual(VoiceTraceGeometry.size, CGSize(width: 32, height: 10))
        XCTAssertTrue(VoiceTraceGeometry.size.width <= 48 && VoiceTraceGeometry.size.height <= 12, "Fits the compact mark's target and active height")
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 28)
        let layout = VoiceTraceGeometry.layout(in: bounds)
        XCTAssertEqual(layout.dot.width, 4); XCTAssertEqual(layout.dot.height, 4)
        XCTAssertEqual(layout.trace.minX - layout.dot.maxX, 4, "A 4-point gap")
        XCTAssertEqual(Double(layout.dot.midY), Double(layout.trace.midY), accuracy: 0.001)
        let tallest = VoiceTraceGeometry.path(in: layout.trace, amplitude: VoiceTraceGeometry.reach)
        let inked = tallest.copy(strokingWithWidth: VoiceTraceGeometry.heaviest, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
        XCTAssertTrue(layout.trace.insetBy(dx: -0.01, dy: -0.01).contains(inked), "The tallest, heaviest trace stays inside its box (\(inked))")
        XCTAssertTrue(bounds.contains(inked.union(layout.dot)))
        let flat = VoiceTraceGeometry.path(in: layout.trace, amplitude: 0).boundingBoxOfPath
        XCTAssertTrue(flat.height < 0.0001, "Silence is a straight line (\(flat.height))")
        // Three lobes, in place: the same crossings and peaks at every reach.
        func extremes(_ amplitude: CGFloat) -> [CGFloat] {
            let values: [CGFloat] = (0...240).map { step in VoiceTraceGeometry.shape(CGFloat(step) / 240) * amplitude }
            var found: [CGFloat] = []
            for index in 1..<240 {
                let before: CGFloat = values[index] - values[index - 1], after: CGFloat = values[index + 1] - values[index]
                if before * after < 0 { found.append(CGFloat(index) / 240) }
            }
            return found
        }
        let peaks = extremes(VoiceTraceGeometry.reach)
        XCTAssertEqual(peaks.count, 3, "Three lobes (\(peaks))")
        XCTAssertEqual(extremes(1), peaks, "A quieter voice keeps the lobes where they are")
        XCTAssertEqual(Double(VoiceTraceGeometry.shape(0.5)), 1, accuracy: 0.0001)
        XCTAssertTrue(VoiceTraceGeometry.shape(peaks[0]) < 0 && VoiceTraceGeometry.shape(peaks[2]) < 0, "Shallow outer lobes either side of a taller middle")
        XCTAssertTrue(abs(VoiceTraceGeometry.shape(peaks[0])) < 0.8)
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
        XCTAssertTrue(view.amplitude > 0.8, "Soft microphone input visibly moves the trace")
        XCTAssertTrue(view.envelope.visible != .quiet, "Input appears within 100 ms")
        view.receive(level: 0, at: 1.1)
        for step in 1...30 { view.advance(to: 1.1 + Double(step) / 60) }
        XCTAssertEqual(view.amplitude, 0, "Silence settles the input trace")
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
        XCTAssertEqual(view.amplitude, 0); XCTAssertEqual(view.lineWidth, VoiceTraceGeometry.stroke)
        run(1, level: nil)
        XCTAssertFalse(view.envelope.isMoving, "No level, no motion")
        run(0.6, level: 0.55)
        XCTAssertTrue(view.envelope.isMoving && view.amplitude > VoiceTraceGeometry.reach * 0.6, "A voice raises the lobes")
        // The level stops changing but stays loud: the voice is still shown.
        view.receive(level: 0.55, at: clock)
        for _ in 0..<60 { clock += 1.0 / 60; view.advance(to: clock) }
        XCTAssertTrue(view.envelope.visible != .quiet, "A steady level stays lit without new readings")
        // It goes quiet and stops, even with no new reading after the last.
        view.receive(level: 0.02, at: clock)
        var stoppedAt: Double?
        for _ in 0..<60 where stoppedAt == nil { clock += 1.0 / 60; if !view.advance(to: clock) { stoppedAt = clock } }
        XCTAssertTrue(stoppedAt != nil, "After a voice it settles and display updates stop")
        XCTAssertEqual(view.amplitude, 0)
        // Reduce Motion: the lobes hold one shape; brightness alone says a voice is heard.
        view.reduceMotion = true
        let still = view.amplitude
        run(0.6, level: 0.7)
        XCTAssertEqual(view.amplitude, still, "Reduce Motion keeps the trace's shape")
        XCTAssertEqual(view.lineWidth, VoiceTraceGeometry.stroke)
        XCTAssertTrue(view.stroke.opacity > 0.9, "A voice brightens it")
        run(1, level: 0)
        XCTAssertEqual(view.amplitude, still)
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
        static let size = CGSize(width: 660, height: 480)
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
            circleCanvas = CGRect(x: 40, y: 240, width: 96 + circleInsets.left + circleInsets.right, height: 96 + circleInsets.top + circleInsets.bottom)
            circleRect = CGRect(x: circleInsets.left, y: circleInsets.bottom, width: 96, height: 96)
            cardCanvas = CGRect(x: 300, y: 40, width: cardSize.width + cardInsets.left + cardInsets.right, height: cardSize.height + cardInsets.top + cardInsets.bottom)
            cardRect = CGRect(x: cardInsets.left, y: cardInsets.bottom, width: cardSize.width, height: cardSize.height)
            markRect = CGRect(x: 64, y: 400, width: 48, height: 28)
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
