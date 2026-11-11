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
        var zoomChangedAt: TimeInterval = 0
        var zoomIsManual = false
        var turnSpeed = 0.0
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
    /// How long after a zoom the picture is still changing size, so the subject can't be followed in it.
    private static let zoomSettleTime: TimeInterval = 0.4
    /// Turning faster than this, in radians a second, the picture lags too far behind the gyroscope to compare.
    private static let steadyTurnSpeed = 0.6
    /// How far the guide moves towards each sighting of the subject, so it follows without jitter.
    private static let followStrength = 0.4

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
        refreshGuide { live in
            if factor != live.zoomFactor {
                live.zoomChangedAt = ProcessInfo.processInfo.systemUptime
            }
            live.zoomFactor = factor
        }
    }

    /// Where the subject should be in the live picture now, as fractions of the viewfinder.
    /// Nil with no shot, with the shot behind the phone, or while the zoom is changing.
    func expectedSubject() -> (box: CGRect, isSteady: Bool)? {
        lock.withLock { () -> (box: CGRect, isSteady: Bool)? in
            guard let target = live.target, let optics = live.optics,
                  ProcessInfo.processInfo.systemUptime - live.zoomChangedAt > Self.zoomSettleTime,
                  let box = target.subjectBox(rotation: live.rotation, optics: optics, zoomFactor: live.zoomFactor) else {
                return nil
            }
            return (box, live.turnSpeed < Self.steadyTurnSpeed)
        }
    }

    /// Moves the guide towards where the camera sees the subject, which also catches the phone being moved.
    func follow(subjectAt point: CGPoint) {
        refreshGuide { live in
            guard let target = live.target, let optics = live.optics, live.turnSpeed < Self.steadyTurnSpeed else { return }
            let expected = live.rotation.act(target.subjectRay)
            guard expected.z < -0.01 else { return }
            let seen = ScanTarget.direction(x: Double(point.x), y: Double(point.y), optics: optics, zoomFactor: live.zoomFactor)
            let whole = simd_quatd(from: simd_normalize(expected), to: seen)
            let part = simd_slerp(simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), whole, Self.followStrength)
            live.rotation = simd_normalize(part * live.rotation)
        }
    }

    /// Stops auto-zoom from fighting the user, or from running twice.
    func noteZoomTaken() {
        refreshGuide { $0.zoomIsManual = true }
    }

    /// The latest position for drawing. Cheap enough to call every frame.
    func snapshot() -> (roll: Double, isFlat: Bool, projection: GuideProjection?) {
        // Pointing straight up or down there is no horizon, and the reading is only noise.
        lock.withLock { (live.isFlat ? 0 : live.roll, live.isFlat, Self.projection(in: live)) }
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

            let speed = simd_length(rate)
            live.turnSpeed = speed
            defer { live.lastTimestamp = timestamp }
            guard let last = live.lastTimestamp else { return }
            let step = timestamp - last
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
        // A tilted phone still counts: the level line shows that on its own.
        let isAligned = live.guide.isAligned
            ? projection.staysAligned
            : projection.isCentered && projection.isZoomed

        let wantsAutoZoom = !live.zoomIsManual
            && projection.fill < 0.95
            && projection.staysCentered(afterZooming: 1 / projection.fill)

        return GuideState(isBehind: false, isAligned: isAligned, wantsAutoZoom: wantsAutoZoom)
    }
}
