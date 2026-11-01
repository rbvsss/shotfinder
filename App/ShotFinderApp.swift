import SwiftUI

@main
struct ShotFinderApp: App {
    @State private var camera = CameraController()
    @State private var motion = MotionTracker()

    init() {
        #if DEBUG
        if let path = Staging.photoPath {
            URLProtocol.registerClass(FakeClaude.self)
            camera.stageForTesting(lenses: [0.5, 1, 2, 4, 8], backdrop: UIImage(contentsOfFile: path))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(camera: camera, motion: motion)
        }
    }
}
