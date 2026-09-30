import AppKit
import ImageIO
import CoreText

enum SnapRendering {
    static func dimensions(_ bytes: Data) throws -> (width: Int, height: Int) {
        guard !bytes.isEmpty, bytes.count <= SnapStore.maximumImageBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              Int64(width) * Int64(height) <= 100_000_000 else {
            throw SnapError.message("Choose a supported image under 100 MB and 100 megapixels.")
        }
        return (width, height)
    }

    static func image(_ bytes: Data) throws -> CGImage {
        _ = try dimensions(bytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SnapError.message("This image could not be read. Its source file was kept.")
        }
        return image
    }

    static func png(_ bytes: Data) throws -> Data {
        let size = try dimensions(bytes)
        // Imported photos can encode orientation in metadata. Flatten that
        // orientation once before crop/ink coordinates are attached to pixels.
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
              ] as CFDictionary),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapError.message("This image could not be prepared for Snap.")
        }
        return png
    }

    static func render(_ bytes: Data, edit: SnapEdit) throws -> Data {
        guard edit.isValid else { throw SnapError.message("The crop or annotation is outside the original image.") }
        if edit == SnapEdit() { _ = try image(bytes); return bytes }
        let image = try image(bytes), originalWidth = Double(image.width), originalHeight = Double(image.height)
        let size = outputSize(image: CGSize(width: originalWidth, height: originalHeight), edit: edit)
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SnapError.message("There is not enough memory to edit this image.")
        }
        draw(image, edit: edit, in: context, size: size)
        guard let result = context.makeImage(), let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
            throw SnapError.message("The edited image could not be rendered. Your original remains unchanged.")
        }
        return png
    }

    static func outputSize(image: CGSize, edit: SnapEdit) -> CGSize {
        let w = max(1, (image.width * edit.crop.width).rounded())
        let h = max(1, (image.height * edit.crop.height).rounded())
        return edit.quarterTurns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }

    /// The editor and PNG export use this exact compositor. Coordinates stay
    /// attached to the original; rotation never rewrites or resamples it.
    static func draw(_ image: CGImage, edit: SnapEdit, in context: CGContext, size: CGSize) {
        let original = CGSize(width: image.width, height: image.height)
        let output = outputSize(image: original, edit: edit)
        let w = max(1, (original.width * edit.crop.width).rounded())
        let h = max(1, (original.height * edit.crop.height).rounded())
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        context.scaleBy(x: size.width / output.width, y: size.height / output.height)
        switch edit.quarterTurns {
        case 1: context.translateBy(x: 0, y: w); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: w, y: h); context.rotate(by: .pi)
        case 3: context.translateBy(x: h, y: 0); context.rotate(by: .pi / 2)
        default: break
        }
        context.translateBy(x: -edit.crop.x * original.width, y: -edit.crop.y * original.height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: original))
        draw(edit.marks, in: context, size: original)
        context.restoreGState()
    }

    static func colour(_ name: String) -> NSColor {
        switch name {
        case "yellow": .systemYellow
        case "blue": .systemBlue
        case "white": .white
        case "black": .black
        default: .systemRed
        }
    }

    static func draw(_ marks: [SnapMark], in context: CGContext, size: CGSize) {
        for mark in marks where mark.isValid {
            context.saveGState()
            defer { context.restoreGState() }
            let points = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first, let last = points.last else { continue }
            let width = max(1, mark.width * min(size.width, size.height))
            context.setStrokeColor(colour(mark.colour).cgColor)
            context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
            context.beginPath()
            switch mark.kind {
            case .pen:
                context.addLines(between: points)
            case .rectangle:
                context.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y)))
            case .arrow:
                context.move(to: first); context.addLine(to: last)
                let angle = atan2(last.y - first.y, last.x - first.x), length = max(width * 4, min(size.width, size.height) * 0.025)
                for offset in [-Double.pi / 6, Double.pi / 6] {
                    context.move(to: last)
                    context.addLine(to: CGPoint(x: last.x - cos(angle + offset) * length, y: last.y - sin(angle + offset) * length))
                }
            case .text:
                let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                  width: abs(first.x - last.x), height: abs(first.y - last.y))
                let fontSize = (mark.fontSize ?? 0.035) * min(size.width, size.height)
                let padding = fontSize * 0.3
                if let background = mark.background, background != "none" {
                    context.setFillColor(colour(background).cgColor)
                    context.fill(rect)
                }
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
                let string = NSAttributedString(string: mark.text ?? "", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: colour(mark.colour), .paragraphStyle: paragraph
                ])
                context.clip(to: rect)
                context.translateBy(x: rect.minX, y: rect.minY)
                switch mark.textRotation ?? 0 {
                case 1: context.translateBy(x: 0, y: rect.height); context.rotate(by: -.pi / 2)
                case 2: context.translateBy(x: rect.width, y: rect.height); context.rotate(by: .pi)
                case 3: context.translateBy(x: rect.width, y: 0); context.rotate(by: .pi / 2)
                default: break
                }
                let sideways = (mark.textRotation ?? 0) % 2 != 0
                let textRect = CGRect(x: 0, y: 0, width: sideways ? rect.height : rect.width, height: sideways ? rect.width : rect.height)
                context.textMatrix = .identity
                let path = CGPath(rect: textRect.insetBy(dx: padding, dy: padding), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(), path, nil), context)
            }
            context.strokePath()
        }
    }
}
