import simd
import XCTest
@testable import ShotFinder

final class GeometryTests: XCTestCase {
    private let optics = CameraOptics(tanHorizontal: 0.75, tanVertical: 1)
    private let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    private func result(x: Double, y: Double, size: Double) -> ScanResult {
        let json = #"{"label":"a","tip":"b","center_x":\#(x),"center_y":\#(y),"size":\#(size)}"#
        return try! JSONDecoder().decode(ScanResult.self, from: Data(json.utf8))
    }

    private func target(x: Double = 0.7, y: Double = 0.3, size: Double = 0.25, ratio: CaptureRatio = .threeFour) -> ScanTarget {
        ScanTarget(result: result(x: x, y: y, size: size), optics: optics, scanZoomFactor: 1, scanLens: 0.5, ratio: ratio)
    }

    func testShotAppearsWhereItWasScanned() throws {
        let projection = try XCTUnwrap(target().projection(rotation: identity, optics: optics, zoomFactor: 1, crop: CGSize(width: 1, height: 1)))
        XCTAssertEqual(projection.x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(projection.y, 0.3, accuracy: 0.0001)
        XCTAssertEqual(projection.width, 0.25, accuracy: 0.0001)
    }

    func testZoomGrowsTheShotAroundTheCentre() throws {
        let projection = try XCTUnwrap(target().projection(rotation: identity, optics: optics, zoomFactor: 4, crop: CGSize(width: 1, height: 1)))
        XCTAssertEqual(projection.x, 0.5 + 0.2 * 4, accuracy: 0.0001)
        XCTAssertEqual(projection.y, 0.5 - 0.2 * 4, accuracy: 0.0001)
        XCTAssertEqual(projection.fill, 1, accuracy: 0.0001)
        XCTAssertTrue(projection.isZoomed)
    }

    func testLensIsTheZoomThatFillsTheFrame() {
        XCTAssertEqual(target(size: 0.25).lens, 2, accuracy: 0.0001)
        XCTAssertEqual(target(size: 0.25, ratio: .nineSixteen).lens, 0.5 / (0.25 / 0.75), accuracy: 0.0001)
    }

    func testTurningThePhoneLeftMovesTheShotRight() throws {
        let centred = target(x: 0.5, y: 0.5)
        let turnLeft = simd_quatd(angle: 0.2, axis: SIMD3(0, 1, 0)).inverse
        let projection = try XCTUnwrap(centred.projection(rotation: turnLeft, optics: optics, zoomFactor: 1, crop: CGSize(width: 1, height: 1)))
        XCTAssertGreaterThan(projection.x, 0.55)
        XCTAssertEqual(projection.y, 0.5, accuracy: 0.0001)
    }

    func testAutoZoomWaitsUntilTheShotWouldStayInView() {
        let nearMiddle = GuideProjection(x: 0.51, y: 0.51, width: 0.2, height: 0.2, fill: 0.2)
        let offToTheSide = GuideProjection(x: 0.7, y: 0.5, width: 0.2, height: 0.2, fill: 0.2)
        XCTAssertTrue(nearMiddle.staysCentered(afterZooming: 4))
        XCTAssertFalse(offToTheSide.staysCentered(afterZooming: 4))
        XCTAssertFalse(nearMiddle.staysCentered(afterZooming: 1))
    }

    func testShotBehindThePhoneHasNoPosition() {
        let halfTurn = simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0))
        XCTAssertNil(target(x: 0.5, y: 0.5).projection(rotation: halfTurn, optics: optics, zoomFactor: 1, crop: CGSize(width: 1, height: 1)))
    }

    func testBadScanValuesAreKeptInRange() {
        let scanned = target(x: 3, y: -2, size: 9)
        XCTAssertEqual(scanned.scale, 1)
        XCTAssertEqual(scanned.lens, 0.5, accuracy: 0.0001)
    }

    func testRatiosCropTheViewfinderCorrectly() {
        XCTAssertEqual(CaptureRatio.threeFour.cropInViewfinder, CGSize(width: 1, height: 1))
        XCTAssertEqual(CaptureRatio.square.cropInViewfinder.height, 0.75, accuracy: 0.0001)
        XCTAssertEqual(CaptureRatio.fourFive.cropInViewfinder.height, 0.9375, accuracy: 0.0001)
        XCTAssertEqual(CaptureRatio.nineSixteen.cropInViewfinder.width, 0.75, accuracy: 0.0001)
        XCTAssertEqual(CaptureRatio.nineSixteen.next, .threeFour)
    }
}
