import CoreVideo
import Vision

/// Follows the subject in the live picture, so the guide stays on it when the phone is moved and not only turned.
/// The gyroscope can't see a step to the side, which matters most for things close by.
final class SubjectTracker {
    private let motion: MotionTracker
    private var handler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?
    /// From the middle of the part being followed to the middle of the subject, when it started partly out of view.
    private var offset = CGVector.zero
    private var frames = 0

    /// Every other frame is plenty, and leaves the camera's queue free.
    private static let frameStride = 2
    private static let minimumConfidence: Float = 0.45
    /// How much of the subject must be in view to start following it.
    private static let minimumVisible: CGFloat = 0.7
    private static let smallestSide: CGFloat = 0.04
    /// A sighting this far from where the subject should be is a mistake, not a movement.
    private static let largestJump: CGFloat = 0.25
    /// Closer to the edge than this, the subject is leaving the view and can't be followed.
    private static let edge: CGFloat = 0.04
    private static let view = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(motion: MotionTracker) {
        self.motion = motion
    }

    /// Takes each video frame, upright and covering the whole viewfinder. Runs on the camera's queue.
    func process(_ pixels: CVPixelBuffer) {
        frames += 1
        guard frames % Self.frameStride == 0 else { return }
        guard let expected = motion.expectedSubject() else {
            stop()
            return
        }

        let isStarting = observation == nil
        if isStarting {
            let box = expected.box
            let visible = box.intersection(Self.view)
            guard expected.isSteady, !visible.isNull,
                  visible.width > Self.smallestSide, visible.height > Self.smallestSide,
                  visible.width * visible.height > Self.minimumVisible * box.width * box.height else { return }
            offset = CGVector(dx: box.midX - visible.midX, dy: box.midY - visible.midY)
            // Vision measures from the bottom left.
            observation = VNDetectedObjectObservation(boundingBox: CGRect(
                x: visible.minX,
                y: 1 - visible.maxY,
                width: visible.width,
                height: visible.height
            ))
        }
        guard let last = observation else { return }

        let request = VNTrackObjectRequest(detectedObjectObservation: last)
        request.trackingLevel = .accurate
        guard (try? handler.perform([request], on: pixels)) != nil,
              let found = request.results?.first as? VNDetectedObjectObservation,
              found.confidence >= Self.minimumConfidence else {
            stop()
            return
        }
        observation = found
        // The first frame only teaches the tracker what to follow.
        guard !isStarting else { return }

        let followed = CGPoint(x: found.boundingBox.midX, y: 1 - found.boundingBox.midY)
        let seen = CGPoint(x: followed.x + offset.dx, y: followed.y + offset.dy)
        guard followed.x > Self.edge, followed.x < 1 - Self.edge,
              followed.y > Self.edge, followed.y < 1 - Self.edge,
              hypot(seen.x - expected.box.midX, seen.y - expected.box.midY) < Self.largestJump else {
            stop()
            return
        }
        motion.follow(subjectAt: seen)
    }

    private func stop() {
        guard observation != nil else { return }
        observation = nil
        // A new handler lets go of the old tracker.
        handler = VNSequenceRequestHandler()
    }
}
