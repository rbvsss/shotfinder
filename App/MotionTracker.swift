import CoreMotion
import Foundation
import Observation
import simd

/// The parts of the guide that the screen reacts to. These change rarely, unlike the box itself.
struct GuideState: Equatable {
    var isBehind = false
    var isAligned = false
    var wantsAutoZoom = false
}

/// Follows how far the phone has turned since a scan, away from the main thread.
/// Only `LiveGuide` reads the position every frame, so nothing else redraws while it moves.
@Observable
final class MotionTracker {
    private(set) var guide = GuideState()
    private(set) var target: ScanTarget?
    /// Quarter turns clockwise from upright. Icons counter-rotate so they stay readable.
    private(set) var quarterTurns = 0

    private struct Live {
        var roll = 0.0
        var isFlat = false
        var quarterTurns = 0
        var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        var lastTimestamp: TimeInterval?
        var target: ScanTarget?
        var optics: CameraOptics?
        var crop = CGSize(width: 1, height: 1)
        var zoomFactor = 1.0
        var zoomIsManual = false
        var guide = GuideState()
    }

    @ObservationIgnored private var live = Live()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private static let manager = CMMotionManager()
    /// Longest gap between readings to integrate, so a pause in updates can't cause a jump.
    private static let maxStep: TimeInterval = 0.2
    /// How far past a quarter turn the phone must go before icons and photos follow, to stop flicker.
    private static let turnThreshold = 55.0 * Double.pi / 180
    private static let levelTolerance = 1.5 * Double.pi / 180
    private static let alignedLevelTolerance = 2.5 * Double.pi / 180

    func start() {
        guard Self.manager.isDeviceMotionAvailable, !Self.manager.isDeviceMotionActive else { return }
        Self.manager.deviceMotionUpdateInterval = 1.0 / 60.0
        Self.manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            if let motion {
                self?.update(with: motion)
            }
        }
    }

    func stop() {
        Self.manager.stopDeviceMotionUpdates()
        lock.withLock { live.lastTimestamp = nil }
    }

    /// Starts measuring rotation from the phone's current position. Safe to call from any thread.
    func mark() {
        lock.withLock { live.rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
    }

    func setTarget(_ target: ScanTarget?, optics: CameraOptics?, crop: CGSize) {
        self.target = target
        refreshGuide { live in
            live.target = target
            live.optics = optics
            live.crop = crop
            live.zoomIsManual = false
            live.guide.isAligned = false
        }
    }

    func setZoomFactor(_ factor: Double) {
        refreshGuide { $0.zoomFactor = factor }
    }

    /// Stops auto-zoom from fighting the user, or from running twice.
    func noteZoomTaken() {
        refreshGuide { $0.zoomIsManual = true }
    }

    /// The latest position for drawing. Cheap enough to call every frame.
    func snapshot() -> (roll: Double, projection: GuideProjection?) {
        // Pointing straight up or down there is no horizon, and the reading is only noise.
        lock.withLock { (live.isFlat ? 0 : live.roll, Self.projection(in: live)) }
    }

    /// Rotation for a photo so it comes out upright however the phone is held.
    var captureRotationAngle: CGFloat {
        let turns = lock.withLock { live.quarterTurns }
        return CGFloat((90 + turns * 90 + 360) % 360)
    }

    /// Scans are judged as portrait images, so a sideways phone would mislead them.
    var isHeldForScan: Bool {
        lock.withLock { live.isFlat || abs(live.roll) < .pi / 4 }
    }

    private func update(with motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let rate = SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
        let timestamp = motion.timestamp

        var turnsChanged: Int?
        refreshGuide { live in
            live.roll = atan2(gravity.x, -gravity.y)
            live.isFlat = abs(gravity.z) > 0.8
            if !live.isFlat {
                let turns = Self.quarterTurns(roll: live.roll, current: live.quarterTurns)
                if turns != live.quarterTurns {
                    live.quarterTurns = turns
                    turnsChanged = turns
                }
            }

            defer { live.lastTimestamp = timestamp }
            guard let last = live.lastTimestamp else { return }
            let step = timestamp - last
            let speed = simd_length(rate)
            guard step > 0, step < Self.maxStep, speed > 0 else { return }
            // The phone turned by this much, so a fixed point in the scene turned the opposite way.
            let turn = simd_quatd(angle: speed * step, axis: rate / speed)
            live.rotation = simd_normalize(turn.inverse * live.rotation)
        }
        if let turnsChanged {
            DispatchQueue.main.async { self.quarterTurns = turnsChanged }
        }
    }

    static func quarterTurns(roll: Double, current: Int) -> Int {
        var difference = roll - Double(current) * .pi / 2
        difference = atan2(sin(difference), cos(difference))
        guard abs(difference) > turnThreshold else { return current }
        var turns = Int((roll / (.pi / 2)).rounded())
        if turns == -2 { turns = 2 }
        return turns
    }

    /// Applies a change, then tells the screen only if something it shows has changed.
    private func refreshGuide(_ change: (inout Live) -> Void) {
        let changed: Bool = lock.withLock {
            let previous = live.guide
            change(&live)
            live.guide = Self.derive(from: live)
            return live.guide != previous
        }
        if changed {
            // Reads the newest value on arrival, so a late update can't overwrite a newer one.
            DispatchQueue.main.async {
                self.guide = self.lock.withLock { self.live.guide }
            }
        }
    }

    private static func projection(in live: Live) -> GuideProjection? {
        guard let target = live.target, let optics = live.optics else { return nil }
        return target.projection(
            rotation: live.rotation,
            optics: optics,
            zoomFactor: live.zoomFactor,
            crop: live.crop
        )
    }

    private static func derive(from live: Live) -> GuideState {
        guard live.target != nil else { return GuideState() }
        guard let projection = projection(in: live) else { return GuideState(isBehind: true) }

        // Harder to enter than to leave, so the buzz and the colour don't chatter at the edge.
        let isLevel = live.isFlat || abs(live.roll) < (live.guide.isAligned ? alignedLevelTolerance : levelTolerance)
        let isAligned = live.guide.isAligned
            ? projection.staysAligned && isLevel
            : projection.isCentered && projection.isZoomed && isLevel

        let wantsAutoZoom = !live.zoomIsManual
            && projection.fill < 0.95
            && projection.staysCentered(afterZooming: 1 / projection.fill)

        return GuideState(isBehind: false, isAligned: isAligned, wantsAutoZoom: wantsAutoZoom)
    }
}
