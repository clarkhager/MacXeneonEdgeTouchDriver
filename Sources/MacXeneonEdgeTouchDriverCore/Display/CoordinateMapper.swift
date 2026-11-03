import CoreGraphics
import Foundation

/// Maps raw HID coordinates into Quartz display coordinates.
public struct CoordinateMapper: Equatable {
    /// Minimum raw X coordinate emitted by the touchscreen.
    public let rawMinX: Int

    /// Maximum raw X coordinate emitted by the touchscreen.
    public let rawMaxX: Int

    /// Minimum raw Y coordinate emitted by the touchscreen.
    public let rawMinY: Int

    /// Maximum raw Y coordinate emitted by the touchscreen.
    public let rawMaxY: Int

    /// Target display bounds in Quartz coordinates.
    public let displayBounds: CGRect

    /// Display rotation. The touch digitizer is fixed to the panel's native
    /// landscape axes, so a rotated display needs the normalized touch point
    /// rotated into the display's own frame before scaling to `displayBounds`.
    public let rotation: DisplayRotation

    /// Creates a mapper for a raw coordinate range and target display bounds.
    public init(
        rawMinX: Int = XeneonEdgeDevice.rawXRange.lowerBound,
        rawMaxX: Int = XeneonEdgeDevice.rawXRange.upperBound,
        rawMinY: Int = XeneonEdgeDevice.rawYRange.lowerBound,
        rawMaxY: Int = XeneonEdgeDevice.rawYRange.upperBound,
        displayBounds: CGRect,
        rotation: DisplayRotation = .degrees0
    ) {
        precondition(rawMaxX > rawMinX, "rawMaxX must be greater than rawMinX")
        precondition(rawMaxY > rawMinY, "rawMaxY must be greater than rawMinY")

        self.rawMinX = rawMinX
        self.rawMaxX = rawMaxX
        self.rawMinY = rawMinY
        self.rawMaxY = rawMaxY
        self.displayBounds = displayBounds
        self.rotation = rotation
    }

    /// Maps a raw touchscreen coordinate to the target display.
    public func map(rawX: Int, rawY: Int) -> CGPoint {
        let clampedX = clamp(rawX, lowerBound: rawMinX, upperBound: rawMaxX)
        let clampedY = clamp(rawY, lowerBound: rawMinY, upperBound: rawMaxY)

        let normalizedX = CGFloat(clampedX - rawMinX) / CGFloat(rawMaxX - rawMinX)
        let normalizedY = CGFloat(clampedY - rawMinY) / CGFloat(rawMaxY - rawMinY)

        // Rotate BEFORE scaling: `displayBounds` is already in the rotated frame
        // (e.g. 720x2560 at 90 degrees).
        let unit = rotation.displayUnitPoint(nx: normalizedX, ny: normalizedY)

        return CGPoint(
            x: displayBounds.origin.x + unit.u * displayBounds.width,
            y: displayBounds.origin.y + unit.v * displayBounds.height
        )
    }

    private func clamp(_ value: Int, lowerBound: Int, upperBound: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }
}
