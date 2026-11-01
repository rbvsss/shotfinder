import SwiftUI

@main
struct ShotFinderApp: App {
    @State private var camera = CameraController()
    @State private var motion = MotionTracker()

    var body: some Scene {
        WindowGroup {
            ContentView(camera: camera, motion: motion)
                .preferredColorScheme(.dark)
        }
    }
}
