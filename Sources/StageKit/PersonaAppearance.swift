import AppKit

/// How a persona looks: a Circle of its portrait, the labelled Card, or the
/// Original image exactly as imported. It is one choice, an Option of Persona,
/// and the values each look needs stay with the persona whichever is chosen, so
/// changing shape never loses a framing, label or colour.
struct PersonaAppearance: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case circle, card, original
        var id: Self { self }
        /// The same words in the workspace, the editor and the Persona Overlay menu.
        var title: String {
            switch self {
            case .circle: return "Circle"
            case .card: return "Card"
            case .original: return "Original"
            }
        }
        /// The visible edge this shape draws, which the voice outline and the
        /// handles follow. Original's is measured from its pixels instead.
        var outline: PersonaArtworkOutline? {
            switch self {
            case .circle: return PersonaCircleRenderer.outline
            case .card: return PersonaCardRenderer.outline
            case .original: return nil
            }
        }
    }

    var shape: Shape
    /// Where Circle sits on the portrait once someone has framed it; nil uses the automatic framing.
    var framing: PersonaFraming? = nil
    /// The automatic framing: curated for a bundled starter portrait, centred for anything else.
    var automaticFraming: PersonaFraming? = nil

    /// The framing Circle draws with.
    var currentFraming: PersonaFraming { framing ?? automaticFraming ?? .centred }

    func validated() throws -> PersonaAppearance {
        var copy = self
        copy.framing = try framing?.validated()
        copy.automaticFraming = try automaticFraming?.validated()
        return copy
    }

    /// The artwork this appearance draws from a portrait. Original returns the
    /// portrait itself; Card and Circle draw a new image and never change it.
    func image(portrait: NSImage, card: PersonaCardStyle?) throws -> NSImage {
        switch shape {
        case .original: return portrait
        case .card: return try PersonaCardRenderer.image(portrait: portrait, style: card ?? PersonaCardStyle())
        case .circle: return try PersonaCircleRenderer.image(portrait: portrait, framing: currentFraming)
        }
    }
}

/// One live copy, named exactly, so a live change never falls through to another:
/// the one floating card by its copy identity, or one copy of a prepared set by
/// its instance in that set.
enum PersonaLiveCopy: Equatable {
    case card(UUID)
    case overlay(UUID, group: UUID)
}

/// Where Circle crops the portrait: the circle's centre across and up the
/// portrait, from 0 to 1 with y rising as in AppKit, and how close it is. Zoom 1
/// fits the circle to the portrait's shorter side and 4 comes closest. The
/// circle always stays inside the portrait.
struct PersonaFraming: Codable, Equatable {
    var x = 0.5
    var y = 0.5
    var zoom = 1.0
    static let centred = PersonaFraming()
    static let zoomRange = 1.0...4.0

    func validated() throws -> PersonaFraming {
        guard [x, y, zoom].allSatisfy(\.isFinite), (0...1).contains(x), (0...1).contains(y),
              Self.zoomRange.contains(zoom) else { throw PersonaError.invalidSettings }
        return self
    }

    /// The circle's square on a portrait of `size`, in the same units, moved inside it where needed.
    func crop(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return .zero }
        let zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, self.zoom.isFinite ? self.zoom : 1))
        let side = min(size.width, size.height) / zoom
        let x = self.x.isFinite ? self.x : 0.5, y = self.y.isFinite ? self.y : 0.5
        let centre = CGPoint(x: min(size.width - side / 2, max(side / 2, size.width * x)),
                             y: min(size.height - side / 2, max(side / 2, size.height * y)))
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    /// This framing with its centre where the circle can actually be, so moving
    /// past an edge banks nothing that has to be undone before it moves back.
    func clamped(to size: CGSize) -> PersonaFraming {
        guard size.width > 0, size.height > 0 else { return self }
        let box = crop(in: size)
        return PersonaFraming(x: min(1, max(0, box.midX / size.width)), y: min(1, max(0, box.midY / size.height)),
                              zoom: min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom.isFinite ? zoom : 1)))
    }

    /// Dragging the picture by `translation` points in a preview `diameter`
    /// points across: the picture follows the pointer, so the circle moves the
    /// other way over it. The translation's y grows downward, as in SwiftUI.
    func dragged(by translation: CGSize, diameter: CGFloat, portrait size: CGSize) -> PersonaFraming {
        let box = crop(in: size)
        guard box.width > 0, diameter > 0, size.width > 0, size.height > 0 else { return self }
        let scale = box.width / diameter
        var next = self
        next.x = (box.midX - translation.width * scale) / size.width
        next.y = (box.midY + translation.height * scale) / size.height
        return next.clamped(to: size)
    }

    func zoomed(to value: Double, portrait size: CGSize) -> PersonaFraming {
        var next = self
        next.zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value.isFinite ? value : 1))
        return next.clamped(to: size)
    }
}

/// Circle: the original portrait cropped by its framing into a circle with
/// transparent corners. No generated label or background is drawn, and the
/// portrait itself is never changed.
enum PersonaCircleRenderer {
    /// The largest circle drawn, in pixels, so a large photo stays sharp on a
    /// Retina display without keeping its whole size decoded.
    static let maximumDiameter = 1024
    static let outline = PersonaArtworkOutline.circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5)

    /// The circle's diameter in pixels for a portrait `pixels` across and up.
    static func diameter(for pixels: CGSize, framing: PersonaFraming) -> Int {
        max(1, min(maximumDiameter, Int(framing.crop(in: pixels).width.rounded(.down))))
    }

    static func image(portrait: NSImage, framing: PersonaFraming) throws -> NSImage {
        let framing = try framing.validated()
        guard let source = portrait.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0, source.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw PersonaError.unreadableImage }
        let pixels = CGSize(width: source.width, height: source.height)
        let crop = framing.crop(in: pixels), side = diameter(for: pixels, framing: framing)
        guard crop.width > 0, let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PersonaError.unreadableImage }
        let scale = CGFloat(side) / crop.width
        context.interpolationQuality = .high
        context.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        context.clip()
        context.draw(source, in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                                        width: pixels.width * scale, height: pixels.height * scale))
        guard let circle = context.makeImage() else { throw PersonaError.unreadableImage }
        return NSImage(cgImage: circle, size: CGSize(width: side, height: side))
    }
}
