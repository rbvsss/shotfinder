import CoreVideo
import UIKit
import XCTest
@testable import ShotFinder

/// Feeds the tracker video frames made from a photo that slides across the view, as the scene does when
/// the phone is moved without turning. The gyroscope sees nothing, so only the picture can move the guide.
final class SubjectTrackerTests: XCTestCase {
    private let optics = CameraOptics(tanHorizontal: 0.75, tanVertical: 1)
    private let size = CGSize(width: 600, height: 800)
    /// The church in the sample photo: a patch with plenty of detail to follow.
    private let subject = CGRect(x: 0.56, y: 0.58, width: 0.16, height: 0.16)

    private func photo() throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "jpg"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }

    /// One video frame with the photo moved right and down by these fractions of the view.
    private func frame(of image: CGImage, movedRight: CGFloat, movedDown: CGFloat) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attributes, &made)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        // Core Graphics measures up from the bottom, so moving down is a negative step.
        context.draw(image, in: CGRect(
            x: movedRight * size.width,
            y: -movedDown * size.height,
            width: size.width,
            height: size.height
        ))
        return buffer
    }

    /// Holds the scene still while the tracker settles, slides it by `right` and `down` over forty frames,
    /// then holds again, and returns how far the guide moved.
    private func guideMovement(right: CGFloat, down: CGFloat) throws -> (x: Double, y: Double) {
        let image = try photo()
        var result = ScanResult(label: "church", tip: "", centerX: Double(subject.midX), centerY: Double(subject.midY), size: 0.3)
        result.subject = subject
        let motion = MotionTracker()
        let target = ScanTarget(result: result, optics: optics, scanZoomFactor: 1, scanLens: 0.5, ratio: .threeFour)
        motion.setTarget(target, optics: optics, crop: CGSize(width: 1, height: 1))
        let tracker = SubjectTracker(motion: motion)
        let start = try XCTUnwrap(motion.snapshot().projection)

        for step in 0..<90 {
            let progress = min(max(CGFloat(step - 20) / 40, 0), 1)
            tracker.process(try frame(of: image, movedRight: right * progress, movedDown: down * progress))
        }
        let end = try XCTUnwrap(motion.snapshot().projection)
        return (end.x - start.x, end.y - start.y)
    }

    func testGuideFollowsTheSubjectSideways() throws {
        let moved = try guideMovement(right: 0.2, down: 0)
        XCTAssertEqual(moved.x, 0.2, accuracy: 0.04)
        XCTAssertEqual(moved.y, 0, accuracy: 0.04)
    }

    func testGuideFollowsTheSubjectUpwards() throws {
        let moved = try guideMovement(right: 0, down: -0.2)
        XCTAssertEqual(moved.x, 0, accuracy: 0.04)
        XCTAssertEqual(moved.y, -0.2, accuracy: 0.04)
    }

    func testGuideStaysPutWhenTheSceneDoes() throws {
        let moved = try guideMovement(right: 0, down: 0)
        XCTAssertEqual(moved.x, 0, accuracy: 0.01)
        XCTAssertEqual(moved.y, 0, accuracy: 0.01)
    }
}
