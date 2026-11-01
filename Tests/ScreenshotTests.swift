import SwiftUI
import XCTest
@testable import ShotFinder

/// Renders the real screens on a simulator and writes them out, so the design can be checked by eye.
final class ScreenshotTests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/shotfinder-screens")

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
    }

    private func samplePhoto() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "jpg"))
        return try Data(contentsOf: url)
    }

    @MainActor
    private func capture<Content: View>(_ name: String, delay: TimeInterval = 1.5, @ViewBuilder content: () -> Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content().preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        self.window = window

        RunLoop.main.run(until: Date().addingTimeInterval(delay))

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testCameraScreen() throws {
        let camera = CameraController()
        camera.stageForScreenshots(lenses: [0.5, 1, 2, 5], supportsRAW: true)
        try capture("camera") {
            ContentView(camera: camera)
        }
    }

    @MainActor
    func testGuideOnPhoto() throws {
        let photo = try XCTUnwrap(UIImage(data: samplePhoto()))
        let projection = GuideProjection(x: 0.62, y: 0.42, width: 0.3, height: 0.3, fill: 0.3)
        try capture("guide") {
            VStack {
                ZStack {
                    Image(uiImage: photo).resizable().scaledToFill()
                    RatioMask(crop: CaptureRatio.fourFive.cropInViewfinder)
                    GuideOverlay(roll: 0.07, projection: projection, isAligned: false)
                    ScanBrackets()
                }
                .aspectRatio(0.75, contentMode: .fit)
                .clipped()
                Spacer()
            }
            .background(Theme.ink)
        }
    }

    @MainActor
    func testDevelopScreen() throws {
        let photo = CapturedPhoto(data: try samplePhoto(), rawData: nil)
        UserDefaults.standard.set(Look.kiln.rawValue, forKey: "develop.look")
        UserDefaults.standard.set(0.35, forKey: "develop.grain")
        UserDefaults.standard.set(PhotoFrame.mat.rawValue, forKey: "develop.frame")
        defer {
            for key in ["develop.look", "develop.grain", "develop.frame"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try capture("develop", delay: 4) {
            DevelopView(photo: photo, ratio: .fourFive, onSaved: { _ in }, onDiscard: {})
        }
    }

    @MainActor
    func testKeyScreen() throws {
        try capture("key") {
            SettingsView()
        }
    }

    @MainActor
    func testIconAndContactSheet() throws {
        let photo = try samplePhoto()
        let developer = try PhotoDeveloper(photo: CapturedPhoto(data: photo, rawData: nil), ratio: .threeFour)
        var settings = DevelopSettings()
        settings.grain = 0.5
        settings.look = .cinder
        let image = try XCTUnwrap(developer.renderPreview(settings))
        try capture("grain") {
            Image(uiImage: image).resizable().scaledToFit().background(Theme.ink)
        }
    }
}
