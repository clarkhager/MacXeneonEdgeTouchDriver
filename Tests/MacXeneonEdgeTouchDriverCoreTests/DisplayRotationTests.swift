import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DisplayRotationTests: XCTestCase {
    // Live M1 values, 2026-11-02: Edge at CGDisplayRotation 90,
    // CGDisplayBounds (3008, 354, 720, 2560).
    private let portraitBounds = CGRect(x: 3_008, y: 354, width: 720, height: 2_560)
    private let landscapeBounds = CGRect(x: 248, y: 1_692, width: 2_560, height: 720)
    private let maxX = XeneonEdgeDevice.rawXRange.upperBound
    private let maxY = XeneonEdgeDevice.rawYRange.upperBound

    // MARK: - 0 degrees is unchanged

    /// The pre-JAD-824 formula, verbatim. 0 degrees must match it exactly.
    private func legacyMap(rawX: Int, rawY: Int, bounds: CGRect) -> CGPoint {
        let minX = XeneonEdgeDevice.rawXRange.lowerBound
        let minY = XeneonEdgeDevice.rawYRange.lowerBound
        let cx = min(max(rawX, minX), maxX)
        let cy = min(max(rawY, minY), maxY)
        let nx = CGFloat(cx - minX) / CGFloat(maxX - minX)
        let ny = CGFloat(cy - minY) / CGFloat(maxY - minY)
        return CGPoint(x: bounds.origin.x + nx * bounds.width, y: bounds.origin.y + ny * bounds.height)
    }

    func testZeroDegreesIsBitIdenticalToLegacyMapping() {
        let boundsList = [
            landscapeBounds,
            CGRect(x: -1_280, y: 1_890, width: 2_560, height: 720),
            CGRect(x: 10, y: 20, width: 2_560, height: 720),
            portraitBounds,
        ]
        let xs = [-500, 0, 1, 1_234, 8_191, 16_382, maxX, 99_999]
        let ys = [-500, 0, 1, 777, 4_799, 9_598, maxY, 99_999]
        for bounds in boundsList {
            let explicitZero = CoordinateMapper(displayBounds: bounds, rotation: .degrees0)
            let defaulted = CoordinateMapper(displayBounds: bounds)
            for x in xs {
                for y in ys {
                    let expected = legacyMap(rawX: x, rawY: y, bounds: bounds)
                    XCTAssertEqual(explicitZero.map(rawX: x, rawY: y), expected, "raw (\(x), \(y)) in \(bounds)")
                    XCTAssertEqual(defaulted.map(rawX: x, rawY: y), expected, "raw (\(x), \(y)) in \(bounds)")
                }
            }
        }
    }

    func testDefaultRotationIsZero() {
        XCTAssertEqual(CoordinateMapper(displayBounds: landscapeBounds).rotation, .degrees0)
    }

    // MARK: - Corners per rotation
    //
    // Panel-native raw corners: (0,0) = native top-left, (maxX,0) = native
    // top-right, (0,maxY) = native bottom-left, (maxX,maxY) = native bottom-right.

    private func corners(_ mapper: CoordinateMapper) -> [CGPoint] {
        [
            mapper.map(rawX: 0, rawY: 0),
            mapper.map(rawX: maxX, rawY: 0),
            mapper.map(rawX: 0, rawY: maxY),
            mapper.map(rawX: maxX, rawY: maxY),
        ]
    }

    func testCornersAt0() {
        let b = landscapeBounds
        XCTAssertEqual(corners(CoordinateMapper(displayBounds: b, rotation: .degrees0)), [
            CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
            CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY),
        ])
    }

    /// Pins the LIVE-OBSERVED 90-degree convention (M1 2026-11-02 corner test):
    /// (u, v) = (1 - ny, nx).
    func testCornersAt90() {
        let b = portraitBounds
        XCTAssertEqual(corners(CoordinateMapper(displayBounds: b, rotation: .degrees90)), [
            CGPoint(x: b.maxX, y: b.minY), // native top-left     -> display top-right
            CGPoint(x: b.maxX, y: b.maxY), // native top-right    -> display bottom-right
            CGPoint(x: b.minX, y: b.minY), // native bottom-left  -> display top-left
            CGPoint(x: b.minX, y: b.maxY), // native bottom-right -> display bottom-left
        ])
    }

    /// The live receipts: under the first build's convention, (ny, 1 - nx),
    /// every corner tap landed diagonally opposite. The settled convention must
    /// be exactly that point turned 180 degrees about the display centre.
    func testSettledNinetyIsFirstBuildTurned180() {
        let mapper = CoordinateMapper(displayBounds: portraitBounds, rotation: .degrees90)
        let b = portraitBounds
        for (x, y) in [(0, 0), (maxX, 0), (0, maxY), (maxX, maxY), (3_000, 7_000), (12_345, 2_222)] {
            let nx = CGFloat(x) / CGFloat(maxX)
            let ny = CGFloat(y) / CGFloat(maxY)
            let firstBuild = CGPoint(x: b.minX + ny * b.width, y: b.minY + (1 - nx) * b.height)
            let p = mapper.map(rawX: x, rawY: y)
            XCTAssertEqual(p.x, b.minX + b.maxX - firstBuild.x, accuracy: 1e-9, "raw (\(x), \(y))")
            XCTAssertEqual(p.y, b.minY + b.maxY - firstBuild.y, accuracy: 1e-9, "raw (\(x), \(y))")
        }
    }

    func testCornersAt180() {
        let b = landscapeBounds
        XCTAssertEqual(corners(CoordinateMapper(displayBounds: b, rotation: .degrees180)), [
            CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY),
            CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.minY),
        ])
    }

    /// 270 is the inverse of the settled 90: (u, v) = (ny, 1 - nx).
    func testCornersAt270() {
        let b = portraitBounds
        XCTAssertEqual(corners(CoordinateMapper(displayBounds: b, rotation: .degrees270)), [
            CGPoint(x: b.minX, y: b.maxY), // native top-left     -> display bottom-left
            CGPoint(x: b.minX, y: b.minY), // native top-right    -> display top-left
            CGPoint(x: b.maxX, y: b.maxY), // native bottom-left  -> display bottom-right
            CGPoint(x: b.maxX, y: b.minY), // native bottom-right -> display top-right
        ])
    }

    func testMidpointAt90SwapsAxes() {
        // Native centre stays the display centre; a native step right (along the
        // long axis) moves DOWN the portrait display (settled convention).
        let mapper = CoordinateMapper(displayBounds: portraitBounds, rotation: .degrees90)
        let centre = mapper.map(rawX: 8_192, rawY: 4_800)
        XCTAssertEqual(centre.x, portraitBounds.midX, accuracy: 0.1)
        XCTAssertEqual(centre.y, portraitBounds.midY, accuracy: 0.2)
        let right = mapper.map(rawX: 12_000, rawY: 4_800)
        XCTAssertGreaterThan(right.y, centre.y)
        XCTAssertEqual(right.x, centre.x, accuracy: 0.1)
    }

    // MARK: - Clamping per rotation

    func testClampsOutOfRangeRawInEveryRotation() {
        for rotation in DisplayRotation.allCases {
            let b = (rotation == .degrees90 || rotation == .degrees270) ? portraitBounds : landscapeBounds
            let mapper = CoordinateMapper(displayBounds: b, rotation: rotation)
            XCTAssertEqual(mapper.map(rawX: -500, rawY: -500), mapper.map(rawX: 0, rawY: 0), "\(rotation)")
            XCTAssertEqual(mapper.map(rawX: 99_999, rawY: 99_999), mapper.map(rawX: maxX, rawY: maxY), "\(rotation)")
            XCTAssertEqual(mapper.map(rawX: 99_999, rawY: -1), mapper.map(rawX: maxX, rawY: 0), "\(rotation)")
            for (x, y) in [(-500, 99_999), (99_999, -500), (8_000, 4_000), (99_999, 99_999)] {
                let p = mapper.map(rawX: x, rawY: y)
                XCTAssertTrue((b.minX...b.maxX).contains(p.x), "\(rotation) x \(p.x)")
                XCTAssertTrue((b.minY...b.maxY).contains(p.y), "\(rotation) y \(p.y)")
            }
        }
    }

    // MARK: - Unit-space algebra

    func testNinetyAndTwoSeventyAreInverses() {
        for (nx, ny) in [(0.0, 0.0), (1.0, 0.0), (0.25, 0.75), (0.5, 0.5), (0.1, 0.9)] as [(CGFloat, CGFloat)] {
            let a = DisplayRotation.degrees90.displayUnitPoint(nx: nx, ny: ny)
            let back = DisplayRotation.degrees270.displayUnitPoint(nx: a.u, ny: a.v)
            XCTAssertEqual(back.u, nx, accuracy: 1e-12)
            XCTAssertEqual(back.v, ny, accuracy: 1e-12)
            let twice = DisplayRotation.degrees90.displayUnitPoint(nx: a.u, ny: a.v)
            let oneEighty = DisplayRotation.degrees180.displayUnitPoint(nx: nx, ny: ny)
            XCTAssertEqual(twice.u, oneEighty.u, accuracy: 1e-12)
            XCTAssertEqual(twice.v, oneEighty.v, accuracy: 1e-12)
        }
    }

    // MARK: - Degree normalization

    func testDegreeNormalization() {
        XCTAssertEqual(DisplayRotation(degrees: 0), .degrees0)
        XCTAssertEqual(DisplayRotation(degrees: 90), .degrees90)
        XCTAssertEqual(DisplayRotation(degrees: 180), .degrees180)
        XCTAssertEqual(DisplayRotation(degrees: 270), .degrees270)
        XCTAssertEqual(DisplayRotation(degrees: 360), .degrees0)
        XCTAssertEqual(DisplayRotation(degrees: -90), .degrees270)
        XCTAssertEqual(DisplayRotation(degrees: 450), .degrees90)
        XCTAssertEqual(DisplayRotation(degrees: -0.0), .degrees0)
        XCTAssertNil(DisplayRotation(degrees: 45))
        XCTAssertNil(DisplayRotation(degrees: 89.5))
        XCTAssertNil(DisplayRotation(degrees: .nan))
        XCTAssertNil(DisplayRotation(degrees: .infinity))
    }

    func testUnsupportedAngleResolvesToZeroAndIsFlagged() {
        let odd = DisplayRotation.resolve(degrees: 45)
        XCTAssertEqual(odd.rotation, .degrees0)
        XCTAssertFalse(odd.isSupported)
        let ok = DisplayRotation.resolve(degrees: 90)
        XCTAssertEqual(ok.rotation, .degrees90)
        XCTAssertTrue(ok.isSupported)
    }
}
