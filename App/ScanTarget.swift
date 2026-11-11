import Foundation
import simd

/// A shot found by a scan, fixed to a direction in the scene so it can be followed as the phone moves.
struct ScanTarget {
    let label: String
    let tip: String
    /// Direction of the shot in the phone's coordinates at the moment of the scan.
    let ray: SIMD3<Double>
    /// The shot's size relative to the whole crop at the zoom it was scanned at.
    let scale: Double
    let scanZoomFactor: Double
    /// The zoom, as shown on the lens buttons, at which the shot fills the frame.
    let lens: Double
    /// Direction and size of the subject itself, which the camera follows in the live picture.
    let subjectRay: SIMD3<Double>
    let subjectSize: CGSize

    init(result: ScanResult, optics: CameraOptics, scanZoomFactor: Double, scanLens: Double, ratio: CaptureRatio) {
        let centerX = min(max(result.centerX, 0), 1)
        let centerY = min(max(result.centerY, 0), 1)
        let scale = min(max(result.size / Double(ratio.cropInViewfinder.width), 0.1), 1)
        label = result.label.lowercased()
        tip = result.tip
        self.scale = scale
        self.scanZoomFactor = scanZoomFactor
        lens = scanLens / scale
        ray = Self.direction(x: centerX, y: centerY, optics: optics, zoomFactor: scanZoomFactor)
        if let subject = result.subject {
            subjectRay = Self.direction(x: Double(subject.midX), y: Double(subject.midY), optics: optics, zoomFactor: scanZoomFactor)
            subjectSize = subject.size
        } else {
            subjectRay = ray
            subjectSize = CGSize(width: result.size, height: result.size)
        }
    }

    /// The direction of a point given as fractions of the viewfinder at a zoom.
    static func direction(x: Double, y: Double, optics: CameraOptics, zoomFactor: Double) -> SIMD3<Double> {
        simd_normalize(SIMD3(
            (2 * x - 1) * optics.tanHorizontal / zoomFactor,
            (1 - 2 * y) * optics.tanVertical / zoomFactor,
            -1
        ))
    }

    /// Where the subject itself should be now, as fractions of the viewfinder. Nil when it is behind the phone.
    func subjectBox(rotation: simd_quatd, optics: CameraOptics, zoomFactor: Double) -> CGRect? {
        let current = rotation.act(subjectRay)
        guard current.z < -0.01 else { return nil }
        let x = (current.x / -current.z / (optics.tanHorizontal / zoomFactor) + 1) / 2
        let y = (1 - current.y / -current.z / (optics.tanVertical / zoomFactor)) / 2
        let growth = zoomFactor / scanZoomFactor
        let width = Double(subjectSize.width) * growth
        let height = Double(subjectSize.height) * growth
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// Where the shot currently appears, as fractions of the viewfinder. Nil when it is behind the phone.
    func projection(rotation: simd_quatd, optics: CameraOptics, zoomFactor: Double, crop: CGSize) -> GuideProjection? {
        let current = rotation.act(ray)
        guard current.z < -0.01 else { return nil }
        let x = current.x / -current.z / (optics.tanHorizontal / zoomFactor)
        let y = current.y / -current.z / (optics.tanVertical / zoomFactor)
        let fill = scale * zoomFactor / scanZoomFactor
        return GuideProjection(
            x: (x + 1) / 2,
            y: (1 - y) / 2,
            width: fill * Double(crop.width),
            height: fill * Double(crop.height),
            fill: fill
        )
    }
}

struct GuideProjection {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    /// How much of the crop the shot covers. 1 means it fills the frame exactly.
    let fill: Double

    /// Close enough that the subject is in the frame, so roughly pointing at it counts.
    var isCentered: Bool {
        hypot(x - 0.5, y - 0.5) < 0.13
    }

    /// Any zoom from a little wide to just past the shot. Further in would cut the subject.
    var isZoomed: Bool {
        fill > 0.7 && fill < 1.15
    }

    var staysAligned: Bool {
        hypot(x - 0.5, y - 0.5) < 0.2 && fill > 0.6 && fill < 1.25
    }

    /// Whether the shot would still be near the middle after zooming in by this much.
    func staysCentered(afterZooming growth: Double) -> Bool {
        growth > 1 && hypot(x - 0.5, y - 0.5) * growth < 0.2
    }
}
