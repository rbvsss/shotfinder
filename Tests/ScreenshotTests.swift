import SwiftUI
import XCTest
@testable import ShotFinder

/// Renders the scanning state, which passes too quickly for the flow tests to catch, to check by eye.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testScanMarks() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "jpg"))
        let photo = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack {
            ZStack {
                Image(uiImage: photo).resizable().scaledToFill()
                RatioMask(crop: CaptureRatio.fourFive.cropInViewfinder)
                ScanBrackets(crop: CaptureRatio.fourFive.cropInViewfinder)
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipped()
            Spacer()
        }
        .background(Color.black))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = URL(fileURLWithPath: "/tmp/shotfinder-screens")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("scanning.png"))
    }
}
