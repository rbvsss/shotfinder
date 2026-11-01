import ImageIO
import XCTest
@testable import ShotFinder

final class PhotoDeveloperTests: XCTestCase {
    /// A 2:1 photo with a coloured gradient, stored sideways with an orientation tag.
    private func sidewaysPhoto() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            for x in stride(from: 0, to: 1200, by: 20) {
                UIColor(red: CGFloat(x) / 1200, green: 0.5, blue: 1 - CGFloat(x) / 1200, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: 0, width: 20, height: 600))
            }
        }
        let tagged = UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: .right)
        return try XCTUnwrap(tagged.jpegData(compressionQuality: 0.9))
    }

    private func developer(ratio: CaptureRatio = .threeFour) throws -> PhotoDeveloper {
        try PhotoDeveloper(data: sidewaysPhoto(), ratio: ratio)
    }

    private func averageColor(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(pixel.prefix(3))
    }

    func testOrientationIsAppliedBeforeCropping() throws {
        let preview = try XCTUnwrap(developer().renderPreview(DevelopSettings()))
        XCTAssertEqual(preview.size.width / preview.size.height, 0.75, accuracy: 0.01)
    }

    func testEachRatioGivesItsShape() throws {
        for ratio in CaptureRatio.allCases {
            let preview = try XCTUnwrap(developer(ratio: ratio).renderPreview(DevelopSettings()))
            XCTAssertEqual(preview.size.width / preview.size.height, ratio.widthOverHeight, accuracy: 0.01, ratio.rawValue)
        }
    }

    func testEveryLookIsBundledAndChangesTheImage() throws {
        let ready = try developer()
        let natural = try averageColor(XCTUnwrap(ready.renderPreview(DevelopSettings())))
        for look in Look.allCases where look != .natural {
            var settings = DevelopSettings()
            settings.look = look
            let toned = try averageColor(XCTUnwrap(ready.renderPreview(settings)))
            XCTAssertNotEqual(toned, natural, look.rawValue)
            XCTAssertNotNil(ready.renderThumbnails()[look], look.rawValue)
        }
    }

    func testGraphiteIsNeutral() throws {
        var settings = DevelopSettings()
        settings.look = .graphite
        let color = try averageColor(XCTUnwrap(developer().renderPreview(settings)))
        XCTAssertLessThan(abs(Int(color[0]) - Int(color[2])), 8)
    }

    func testGrainKeepsSizeAndBrightness() throws {
        let ready = try developer()
        let clean = try XCTUnwrap(ready.renderPreview(DevelopSettings()))
        var settings = DevelopSettings()
        settings.grain = .heavy
        let grainy = try XCTUnwrap(ready.renderPreview(settings))
        XCTAssertEqual(grainy.size, clean.size)
        let before = try averageColor(clean)
        let after = try averageColor(grainy)
        for channel in 0..<3 {
            XCTAssertLessThan(abs(Int(before[channel]) - Int(after[channel])), 12)
        }
    }

    func testFramesAddTheirMargins() throws {
        let ready = try developer()
        let plain = try XCTUnwrap(ready.renderPreview(DevelopSettings()))
        var settings = DevelopSettings()
        settings.frame = .mat
        let framed = try XCTUnwrap(ready.renderPreview(settings))
        XCTAssertEqual(framed.size.width, plain.size.width * 1.12, accuracy: 2)
        XCTAssertEqual(framed.size.height, plain.size.height + plain.size.width * 0.24, accuracy: 2)
    }

    func testUnreadablePhotoFailsCleanly() {
        XCTAssertThrowsError(try PhotoDeveloper(data: Data([0, 1, 2]), ratio: .square))
    }
}
