import CoreGraphics
import CoreMotion
import simd

/// Follows how far the phone has turned since the scan, and how level it is.
final class MotionTracker: ObservableObject {
    @Published private(set) var roll: Double = 0
    @Published private(set) var rotationSinceMark = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    private let manager = CMMotionManager()
    private var lastTimestamp: TimeInterval?
    private var isFlat = false

    /// Longest gap between readings to integrate, so a pause in updates can't cause a jump.
    private static let maxStep: TimeInterval = 0.2

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.update(with: motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lastTimestamp = nil
    }

    /// Starts measuring rotation from the phone's current position.
    func mark() {
        rotationSinceMark = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    }

    /// Rotation for a photo so it comes out upright however the phone is held.
    var captureRotationAngle: CGFloat {
        guard !isFlat else { return 90 }
        let quarterTurns = (roll / (.pi / 2)).rounded()
        let angle = (90 + quarterTurns * 90 + 360).truncatingRemainder(dividingBy: 360)
        return CGFloat(angle)
    }

    private func update(with motion: CMDeviceMotion) {
        let gravity = motion.gravity
        roll = atan2(gravity.x, -gravity.y)
        isFlat = abs(gravity.z) > 0.8

        defer { lastTimestamp = motion.timestamp }
        guard let last = lastTimestamp else { return }
        let step = motion.timestamp - last
        guard step > 0, step < Self.maxStep else { return }

        let rate = SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
        let speed = simd_length(rate)
        guard speed > 0 else { return }
        // The phone turned by this much, so a fixed point in the scene turned the opposite way.
        let turn = simd_quatd(angle: speed * step, axis: rate / speed)
        rotationSinceMark = simd_normalize(turn.inverse * rotationSinceMark)
    }
}
