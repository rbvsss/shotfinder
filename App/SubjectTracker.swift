import CoreVideo
import Vision

/// Follows the subject in the live picture, so the guide stays on it when the phone is moved and not only turned.
/// The gyroscope can't see a step to the side, which matters most for things close by.
final class SubjectTracker {
    private let motion: MotionTracker
    private var handler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?
    /// From the middle of the tracker's box to the middle of the subject. The tracker hands back its
    /// starting box untouched, then settles a little off it on the next frame. Measuring from where it
    /// settled keeps that from shifting the guide. Nil until then.
    private var offset: CGVector?
    private var frames = 0
    private var lastFrame: TimeInterval = 0

    /// Every other frame is plenty, and leaves the camera's queue free.
    private static let frameStride = 2
    private static let minimumConfidence: Float = 0.45
    private static let smallestSide: CGFloat = 0.04
    /// A sighting this far from where the subject should be is a mistake, not a movement.
    private static let largestJump: CGFloat = 0.25
    /// Followed only while all of it is this far inside the view. At the edge the tracker holds on to
    /// whatever is left in view, and would drag the guide with it.
    private static let inside = CGRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94)
    /// After a gap this long the picture has moved on, and the last sighting can't be matched to it.
    private static let longestGap: TimeInterval = 0.3

    init(motion: MotionTracker) {
        self.motion = motion
    }

    /// Takes each video frame, upright and covering the whole viewfinder. Runs on the camera's queue.
    func process(_ pixels: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrame > Self.longestGap {
            stop()
        }
        lastFrame = now

        frames += 1
        guard frames % Self.frameStride == 0 else { return }
        guard let expected = motion.expectedSubject(), Self.inside.contains(expected.box) else {
            stop()
            return
        }

        let isStarting = observation == nil
        if isStarting {
            let box = expected.box
            guard expected.canStart, box.width > Self.smallestSide, box.height > Self.smallestSide else { return }
            // Vision measures from the bottom left.
            observation = VNDetectedObjectObservation(boundingBox: CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
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
        let box = CGRect(
            x: found.boundingBox.minX,
            y: 1 - found.boundingBox.maxY,
            width: found.boundingBox.width,
            height: found.boundingBox.height
        )
        // The first frame only teaches the tracker what to follow, and the second shows where it settled.
        guard !isStarting else { return }
        guard let offset else {
            if expected.canStart {
                offset = CGVector(dx: expected.box.midX - box.midX, dy: expected.box.midY - box.midY)
            }
            return
        }

        let seen = CGPoint(x: box.midX + offset.dx, y: box.midY + offset.dy)
        guard Self.inside.contains(box),
              hypot(seen.x - expected.box.midX, seen.y - expected.box.midY) < Self.largestJump else {
            stop()
            return
        }
        if expected.canFollow {
            motion.follow(subjectAt: seen)
        }
    }

    private func stop() {
        guard observation != nil else { return }
        observation = nil
        offset = nil
        // A new handler lets go of the old tracker.
        handler = VNSequenceRequestHandler()
    }
}
