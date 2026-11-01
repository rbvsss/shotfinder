import SwiftUI
import XCTest
@testable import ShotFinder

/// Renders the real screens on a simulator and writes them out, so the design can be checked by eye.
final class ScreenshotTests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/shotfinder-screens")
    private let optics = CameraOptics(tanHorizontal: 0.75, tanVertical: 1)

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
    private func stagedCamera() throws -> CameraController {
        let camera = CameraController()
        camera.stageForScreenshots(lenses: [0.5, 1, 2, 4, 8], backdrop: UIImage(data: try samplePhoto()))
        return camera
    }

    private func target(x: Double, y: Double, size: Double) -> ScanTarget {
        ScanTarget(
            result: ScanResult(label: "distant church spires", tip: "Keep the horizon low", centerX: x, centerY: y, size: size),
            optics: optics,
            scanZoomFactor: 1,
            scanLens: 0.5,
            ratio: .threeFour
        )
    }

    @MainActor
    func testCameraScreen() throws {
        let camera = try stagedCamera()
        try capture("camera") {
            ContentView(camera: camera, motion: MotionTracker())
        }
    }

    @MainActor
    func testGuiding() throws {
        let camera = try stagedCamera()
        let motion = MotionTracker()
        motion.setTarget(target(x: 0.66, y: 0.64, size: 0.34), optics: optics, crop: CaptureRatio.threeFour.cropInViewfinder)
        motion.noteZoomTaken()
        try capture("guiding") {
            ContentView(camera: camera, motion: motion)
        }
    }

    @MainActor
    func testReady() throws {
        let camera = try stagedCamera()
        let motion = MotionTracker()
        motion.setTarget(target(x: 0.5, y: 0.5, size: 0.5), optics: optics, crop: CaptureRatio.threeFour.cropInViewfinder)
        motion.noteZoomTaken()
        motion.setZoomFactor(2)
        try capture("ready") {
            ContentView(camera: camera, motion: motion)
        }
    }

    @MainActor
    func testScanMarks() throws {
        let photo = try XCTUnwrap(UIImage(data: samplePhoto()))
        try capture("scanning") {
            VStack {
                ZStack {
                    Image(uiImage: photo).resizable().scaledToFill()
                    RatioMask(crop: CaptureRatio.fourFive.cropInViewfinder)
                    ScanBrackets(crop: CaptureRatio.fourFive.cropInViewfinder)
                }
                .aspectRatio(0.75, contentMode: .fit)
                .clipped()
                Spacer()
            }
            .background(Color.black)
        }
    }

    @MainActor
    func testDevelopScreen() throws {
        let photo = CapturedPhoto(data: try samplePhoto())
        UserDefaults.standard.set(Look.kiln.rawValue, forKey: "develop.look")
        UserDefaults.standard.set(GrainLevel.fine.rawValue, forKey: "develop.grain")
        UserDefaults.standard.set(PhotoFrame.mat.rawValue, forKey: "develop.frame")
        defer {
            for key in ["develop.look", "develop.grain", "develop.frame"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try capture("develop", delay: 10) {
            DevelopView(photo: photo, ratio: .fourFive, onSaved: { _ in }, onDiscard: {})
        }
    }

    @MainActor
    func testKeyScreen() throws {
        try capture("settings") {
            SettingsView()
        }
    }

    @MainActor
    func testGrainAtFullSize() throws {
        let developer = try PhotoDeveloper(data: samplePhoto(), ratio: .threeFour)
        var settings = DevelopSettings()
        settings.grain = .heavy
        settings.look = .cinder
        let image = try XCTUnwrap(developer.renderPreview(settings))
        try capture("grain") {
            Image(uiImage: image).resizable().scaledToFit().background(Color.black)
        }
    }
}
