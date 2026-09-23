import AppKit
import SwiftUI

/// One Mac palette for Voice, StageKit and native toolbar/gallery rendering.
public enum WorkbenchPalette {
    public static let nativeAccent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.43, green: 0.89, blue: 0.73, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.43, blue: 0.32, alpha: 1)
    }
    public static let accent = Color(nsColor: nativeAccent)
}
