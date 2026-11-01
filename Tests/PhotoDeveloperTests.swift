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

    func testBlackAndWhiteIsNeutral() throws {
        var settings = DevelopSettings()
        settings.look = .soot
        let color = try averageColor(XCTUnwrap(developer().renderPreview(settings)))
        XCTAssertLessThan(abs(Int(color[0]) - Int(color[2])), 8)
    }

    func testGrainKeepsSizeAndBrightness() throws {
        let ready = try developer()
        let clean = try XCTUnwrap(ready.renderPreview(DevelopSettings()))
        var settings = DevelopSettings()
        settings[.grain] = 70
        let grainy = try XCTUnwrap(ready.renderPreview(settings))
        XCTAssertEqual(grainy.size, clean.size)
        let before = try averageColor(clean)
        let after = try averageColor(grainy)
        for channel in 0..<3 {
            XCTAssertLessThan(abs(Int(before[channel]) - Int(after[channel])), 12)
        }
    }

    /// Spread of brightness values, in 8-bit levels, across a square patch from the middle.
    private func noise(in image: UIImage) throws -> Double {
        let side = 400
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draws at the preview's scale, so a full-size render is averaged down as a viewer would see it.
        let scale = CGFloat(1500) / CGFloat(max(cgImage.width, cgImage.height))
        let width = CGFloat(cgImage.width) * scale
        let height = CGFloat(cgImage.height) * scale
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        let values = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0 + 1]) }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    func testSavedPhotoHasAboutAsMuchGrainAsThePreview() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3024, height: 4032), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return format
        }())
        let grey = renderer.image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3024, height: 4032))
        }
        let ready = try PhotoDeveloper(data: XCTUnwrap(grey.jpegData(compressionQuality: 1)), ratio: .threeFour)
        for level in [30.0, 70.0] {
            var settings = DevelopSettings()
            settings[.grain] = level
            let preview = try noise(in: XCTUnwrap(ready.renderPreview(settings)))
            let saved = try noise(in: XCTUnwrap(ready.renderFullSize(settings)))
            XCTAssertGreaterThan(preview, 1, "\(level)")
            XCTAssertGreaterThan(saved / preview, 0.6, "\(level): preview \(preview), saved \(saved)")
            XCTAssertLessThan(saved / preview, 1.6, "\(level): preview \(preview), saved \(saved)")
        }
    }

    func testFramesAddTheirMargins() throws {
        let ready = try developer()
        let plain = try XCTUnwrap(ready.renderPreview(DevelopSettings()))
        var settings = DevelopSettings()
        settings.frame = .paper
        let framed = try XCTUnwrap(ready.renderPreview(settings))
        XCTAssertEqual(framed.size.width, plain.size.width * 1.12, accuracy: 2)
        XCTAssertEqual(framed.size.height, plain.size.height + plain.size.width * 0.24, accuracy: 2)
    }

    /// The colour of the pixel just inside an image's top left corner.
    private func cornerColor(_ image: UIImage) throws -> [Int] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: -2, y: 1 - CGFloat(cgImage.height) + 2, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return pixel.map(Int.init)
    }

    func testPrintFrameIsWhiteOutsideAndRoughInside() throws {
        var settings = DevelopSettings()
        settings.frame = .print
        let image = try XCTUnwrap(developer().renderPreview(settings)?.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)

        // Rows across the left edge: the border is white, and how deep it goes varies along the edge.
        var depths = Set<Int>()
        for row in stride(from: image.height / 10, to: image.height * 9 / 10, by: 8) {
            let line = pixels + row * image.width
            XCTAssertGreaterThan(line[1], 240)
            var depth = 0
            while depth < image.width / 8, line[depth] > 240 {
                depth += 1
            }
            depths.insert(depth)
        }
        XCTAssertGreaterThan(depths.count, 3, "The edge should wander, not run straight")
    }

    func testPaperStaysLightWhateverIsApplied() throws {
        let ready = try developer()
        let look = try XCTUnwrap(Look.allCases.first { $0 != .natural })
        let changes: [(String, (inout DevelopSettings) -> Void)] = [
            ("frame only", { _ in }),
            ("look", { $0.look = look }),
            ("glow", { $0[.glow] = 25 }),
            ("grain", { $0[.grain] = 25 }),
            ("date", { $0.showsDate = true }),
            ("fade", { $0[.fade] = 100 }),
            ("vignette", { $0[.vignette] = 100 }),
            ("look and grain", { $0.look = look; $0[.grain] = 25 }),
            ("look and glow", { $0.look = look; $0[.glow] = 25 })
        ]
        for (name, change) in changes {
            var settings = DevelopSettings()
            settings.frame = .paper
            change(&settings)
            let corner = try cornerColor(XCTUnwrap(ready.renderPreview(settings)))
            XCTAssertGreaterThan(corner[0], 220, "\(name): \(corner)")
            XCTAssertEqual(corner[3], 255, "\(name): \(corner)")
        }
    }

    func testEveryFrameAndDateStampRender() throws {
        let ready = try developer()
        for frame in PhotoFrame.allCases {
            var settings = DevelopSettings()
            settings.frame = frame
            settings.showsDate = true
            XCTAssertNotNil(ready.renderPreview(settings), frame.rawValue)
        }
    }

    private func color(with change: (inout DevelopSettings) -> Void) throws -> [Int] {
        var settings = DevelopSettings()
        change(&settings)
        return try averageColor(XCTUnwrap(developer().renderPreview(settings))).map(Int.init)
    }

    func testExposureAndHighlightsAndShadowsMoveBrightness() throws {
        let plain = try color { _ in }
        XCTAssertGreaterThan(try color { $0[.exposure] = 50 }[1], plain[1] + 10)
        XCTAssertLessThan(try color { $0[.exposure] = -50 }[1], plain[1] - 10)
        XCTAssertGreaterThan(try color { $0[.shadows] = 100 }[1], plain[1])
        XCTAssertLessThan(try color { $0[.highlights] = -100 }[1], plain[1])
    }

    func testWarmthMovesRedAgainstBlue() throws {
        let plain = try color { _ in }
        let warm = try color { $0[.warmth] = 100 }
        let cool = try color { $0[.warmth] = -100 }
        XCTAssertGreaterThan(warm[0] - warm[2], plain[0] - plain[2])
        XCTAssertLessThan(cool[0] - cool[2], plain[0] - plain[2])
    }

    func testSaturationZeroAtMinimum() throws {
        let grey = try color { $0[.saturation] = -100 }
        XCTAssertLessThan(abs(grey[0] - grey[2]), 3)
    }

    func testEffectsChangeThePhotoAndKeepItsSize() throws {
        let ready = try developer()
        let plain = try XCTUnwrap(ready.renderPreview(DevelopSettings()))
        let plainColor = try averageColor(plain)
        for dial in [Dial.fade, .glow, .vignette] {
            var settings = DevelopSettings()
            settings[dial] = 100
            let changed = try XCTUnwrap(ready.renderPreview(settings))
            XCTAssertEqual(changed.size, plain.size, dial.rawValue)
            XCTAssertNotEqual(try averageColor(changed), plainColor, dial.rawValue)
        }
    }

    func testLookStrengthBlendsTowardsThePhoto() throws {
        let look = try XCTUnwrap(Look.allCases.first { $0 != .natural })
        let plain = try color { _ in }
        let none = try color {
            $0.look = look
            $0.lookStrength = 0
        }
        XCTAssertEqual(none, plain)
    }

    func testStyleKeepsTheLookAndDropsCorrections() throws {
        var settings = DevelopSettings()
        settings.look = try XCTUnwrap(Look.allCases.first { $0 != .natural })
        settings[.exposure] = 40
        settings[.grain] = 30
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(settings.style))
        XCTAssertEqual(decoded.look, settings.look)
        XCTAssertEqual(decoded[.exposure], 0)
        XCTAssertEqual(decoded[.grain], 30)
    }

    func testCaptionReadsTheCameraSettings() {
        let caption = PhotoCaption(properties: [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "iPhone 18 Pro"],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 24,
                kCGImagePropertyExifFNumber as String: 1.8,
                kCGImagePropertyExifExposureTime as String: 0.02,
                kCGImagePropertyExifISOSpeedRatings as String: [200],
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:01 17:58:00"
            ]
        ])
        XCTAssertEqual(caption.specs, "iPhone 18 Pro   24mm   f/1.8   1/50s   ISO 200")
        XCTAssertEqual(caption.dateStamp, "'26 11 01")
    }

    func testUnreadablePhotoFailsCleanly() {
        XCTAssertThrowsError(try PhotoDeveloper(data: Data([0, 1, 2]), ratio: .square))
    }
}
