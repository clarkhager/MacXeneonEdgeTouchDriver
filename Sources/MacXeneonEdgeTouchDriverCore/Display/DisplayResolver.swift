import CoreGraphics
import Foundation

/// Result of enumerating the active display list.
///
/// The distinction matters: a `CGGetActiveDisplayList` error and a genuine
/// empty list are both otherwise reported as `[]`, which the mapping coordinator
/// must NOT treat the same — a transient enumeration failure must never tear
/// down a working coordinate frame, whereas a successful empty (or Edge-absent)
/// list is a real display loss.
public enum DisplayEnumeration: Equatable {
    /// The active display list was read successfully (may be empty).
    case ok([DisplaySnapshot])
    /// `CGGetActiveDisplayList` reported an error; the list is unknown.
    case failed
}

/// Snapshot of a connected display needed for Xeneon matching.
public struct DisplaySnapshot: Equatable {
    /// CoreGraphics display identifier.
    public let displayID: CGDirectDisplayID

    /// EDID vendor number.
    public let vendorNumber: UInt32

    /// EDID model number.
    public let modelNumber: UInt32

    /// EDID serial number.
    public let serialNumber: UInt32

    /// Current display bounds in Quartz coordinates.
    public let bounds: CGRect

    /// Physical pixel width.
    public let pixelsWide: Int

    /// Physical pixel height.
    public let pixelsHigh: Int

    /// Creates a display snapshot for matching or tests.
    public init(
        displayID: CGDirectDisplayID,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        bounds: CGRect,
        pixelsWide: Int,
        pixelsHigh: Int
    ) {
        self.displayID = displayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.bounds = bounds
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
    }
}

/// Resolves the Xeneon Edge display by EDID and physical size.
///
/// This type is now stateless: it enumerates the active displays and matches
/// the Edge. All tracking of "what is currently applied" lives in
/// `DisplayMappingCoordinator`, which owns the single serial domain.
public final class DisplayResolver {
    private let configuration: DriverConfiguration.Display
    private let activeDisplayProvider: () -> DisplayEnumeration

    /// Creates a display resolver using the effective configuration.
    public convenience init(configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display) {
        self.init(configuration: configuration, activeDisplayProvider: Self.enumerateActiveDisplays)
    }

    init(
        configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display,
        activeDisplayProvider: @escaping () -> DisplayEnumeration
    ) {
        self.configuration = configuration
        self.activeDisplayProvider = activeDisplayProvider
    }

    /// Enumerates the active display list (or reports failure).
    public func enumerate() -> DisplayEnumeration {
        activeDisplayProvider()
    }

    /// Convenience: enumerate and match in one call. Returns `nil` on either an
    /// enumeration failure or the Edge being absent (callers that must tell the
    /// two apart should use `enumerate()` + `resolve(from:)`).
    public func resolve() -> DisplaySnapshot? {
        switch enumerate() {
        case .failed:
            return nil
        case .ok(let displays):
            return resolve(from: displays)
        }
    }

    /// Returns the best Xeneon display match from supplied snapshots.
    public func resolve(from displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let vendorModelMatches = displays.filter { display in
            display.vendorNumber == configuration.vendorNumber &&
            display.modelNumber == configuration.modelNumber
        }

        let serialMatches: [DisplaySnapshot]
        if let serialNumber = configuration.serialNumber {
            serialMatches = vendorModelMatches.filter { $0.serialNumber == serialNumber }
        } else {
            serialMatches = vendorModelMatches
        }

        let sizeMatches = serialMatches.filter { display in
            display.pixelsWide == configuration.expectedWidth &&
            display.pixelsHigh == configuration.expectedHeight
        }

        return sizeMatches.first ?? serialMatches.first ?? vendorModelMatches.first
    }

    private static func enumerateActiveDisplays() -> DisplayEnumeration {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success else {
            // Debug level: an automatic poll every ~2s must not spam the log on a
            // transient enumeration failure. The coordinator leaves the mapping
            // untouched on `.failed`.
            DriverLoggers.log(.debug, category: .display, "CGGetActiveDisplayList count failed: \(countResult.rawValue)")
            return .failed
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        guard listResult == .success else {
            DriverLoggers.log(.debug, category: .display, "CGGetActiveDisplayList values failed: \(listResult.rawValue)")
            return .failed
        }

        return .ok(displayIDs.prefix(Int(displayCount)).map(makeSnapshot))
    }

    private static func makeSnapshot(displayID: CGDirectDisplayID) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: displayID,
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            bounds: CGDisplayBounds(displayID),
            pixelsWide: CGDisplayPixelsWide(displayID),
            pixelsHigh: CGDisplayPixelsHigh(displayID)
        )
    }
}
