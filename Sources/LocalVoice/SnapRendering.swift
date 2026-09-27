import AppKit
import ImageIO

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
        let crop = edit.crop
        let width = max(1, Int((crop.width * originalWidth).rounded())), height = max(1, Int((crop.height * originalHeight).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SnapError.message("There is not enough memory to edit this image.")
        }
        context.translateBy(x: -crop.x * originalWidth, y: -crop.y * originalHeight)
        context.draw(image, in: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
        draw(edit.marks, in: context, size: CGSize(width: originalWidth, height: originalHeight))
        guard let result = context.makeImage(), let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
            throw SnapError.message("The edited image could not be rendered. Your original remains unchanged.")
        }
        return png
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
            }
            context.strokePath()
        }
    }
}
