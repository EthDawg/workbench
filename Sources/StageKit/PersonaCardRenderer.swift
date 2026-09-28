import AppKit

/// Optional authoring values. A missing style means the imported finished image
/// must be shown unchanged, including its own text, colour and transparency.
struct PersonaCardStyle: Codable, Equatable {
    var label = ""
    var background = InkColor(0.08, 0.38, 0.31)

    func validated() throws -> PersonaCardStyle {
        guard label.count <= 80,
              label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              [background.r, background.g, background.b].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw PersonaError.invalidSettings }
        var value = self; value.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}

enum PersonaCardRenderer {
    static let size = CGSize(width: 480, height: 600)
    static let cornerRadius: CGFloat = 28
    /// The card's visible edge, which the voice outline and the handles follow.
    static let outline = PersonaArtworkOutline.roundedRect(CGRect(x: 0, y: 0, width: 1, height: size.height / size.width),
                                                           radius: cornerRadius / size.width)

    static func image(portrait: NSImage, style: PersonaCardStyle) throws -> NSImage {
        let style = try style.validated()
        guard portrait.size.width.isFinite, portrait.size.height.isFinite,
              portrait.size.width > 0, portrait.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw PersonaError.unreadableImage }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.clear.setFill(); CGRect(origin: .zero, size: size).fill(using: .copy)
        let outline = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: cornerRadius, yRadius: cornerRadius)
        outline.addClip(); style.background.nsColor.setFill(); outline.fill()
        let footer: CGFloat = style.label.isEmpty ? 0 : 100
        let available = CGRect(x: 18, y: footer, width: size.width - 36, height: size.height - footer - 18)
        let scale = min(available.width / portrait.size.width, available.height / portrait.size.height)
        let fitted = CGSize(width: portrait.size.width * scale, height: portrait.size.height * scale)
        portrait.draw(in: CGRect(x: available.midX - fitted.width / 2, y: available.minY,
            width: fitted.width, height: fitted.height), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        if !style.label.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 29, weight: .semibold),
                .foregroundColor: labelColor(on: style.background), .paragraphStyle: paragraph]
            let text = NSAttributedString(string: style.label, attributes: attributes)
            text.draw(with: CGRect(x: 20, y: 12, width: size.width - 40, height: 76),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        graphics.flushGraphics()
        let result = NSImage(size: size); result.addRepresentation(bitmap); return result
    }

    /// Deterministic sRGB contrast choice; a brand colour never dictates unreadable text.
    static func labelColor(on background: InkColor) -> NSColor {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(background.r) + 0.7152 * linear(background.g) + 0.0722 * linear(background.b)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
    }

    static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
        return data
    }
}
