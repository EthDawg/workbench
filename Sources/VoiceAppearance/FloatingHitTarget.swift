import AppKit

/// One 8-bit alpha step keeps otherwise clear floating controls hittable in
/// WindowServer without adding a visible rectangular backing.
public enum FloatingHitTarget {
    public static let backingAlpha: CGFloat = 1.0 / 255.0
}
