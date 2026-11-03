import CoreGraphics
import Foundation

/// The Edge display's rotation as reported by `CGDisplayRotation` (degrees,
/// clockwise). Only the four quarter turns are supported.
public enum DisplayRotation: Int, Equatable, CaseIterable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    /// Normalizes a `CGDisplayRotation` value. Equivalent angles (e.g. -90, 450)
    /// fold onto their quarter turn. Returns `nil` for any other angle; callers
    /// treat that as `.degrees0` and log it.
    public init?(degrees: Double) {
        guard degrees.isFinite else { return nil }
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        switch normalized {
        case 0: self = .degrees0
        case 90: self = .degrees90
        case 180: self = .degrees180
        case 270: self = .degrees270
        default: return nil
        }
    }

    /// Rotation to apply for a raw `CGDisplayRotation` value: the matching
    /// quarter turn, or `.degrees0` (with `isSupported == false`) for any other
    /// angle.
    public static func resolve(degrees: Double) -> (rotation: DisplayRotation, isSupported: Bool) {
        if let rotation = DisplayRotation(degrees: degrees) {
            return (rotation, true)
        }
        return (.degrees0, false)
    }

    // MARK: - Panel-to-display convention

    /// THE 90°/270° CONVENTION SWITCH. Flip this one line if the live 4-corner
    /// tap test shows taps landing on the mirrored corner at 90°/270°.
    ///
    /// `true` assumes `CGDisplayRotation` 90° means the framebuffer is rotated
    /// 90° CLOCKWISE onto the panel (IOKit's convention). The HID digitizer is
    /// fixed to the panel's native landscape axes: raw X runs along the long
    /// (2560) edge left to right, raw Y along the short (720) edge top to
    /// bottom, raw (0, 0) = native top-left (proven by the 0° mapping in use).
    /// A clockwise turn puts the image's top edge on the panel's native right
    /// edge and the image's left edge on the panel's native top edge, so the
    /// image point under panel point (nx, ny) is (ny, 1 - nx).
    static let quarterTurnIsClockwise = true

    /// Maps a normalized panel-native point (nx, ny in 0...1, origin at the
    /// panel's native top-left) to a normalized point in the rotated display's
    /// own frame (u, v in 0...1, origin at the display's top-left, which is
    /// where `CGDisplayBounds` puts its origin).
    ///
    /// 0° is the identity and does no arithmetic, so its output is bit-for-bit
    /// what the pre-rotation mapper produced.
    func displayUnitPoint(nx: CGFloat, ny: CGFloat) -> (u: CGFloat, v: CGFloat) {
        switch self {
        case .degrees0:
            return (nx, ny)
        case .degrees90:
            return Self.quarterTurnIsClockwise ? (ny, 1 - nx) : (1 - ny, nx)
        case .degrees180:
            return (1 - nx, 1 - ny)
        case .degrees270:
            return Self.quarterTurnIsClockwise ? (1 - ny, nx) : (ny, 1 - nx)
        }
    }
}
