import CoreGraphics
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

    init(result: ScanResult, optics: CameraOptics, scanZoomFactor: Double, scanLens: Double, ratio: CaptureRatio) {
        let centerX = min(max(result.centerX, 0), 1)
        let centerY = min(max(result.centerY, 0), 1)
        let scale = min(max(result.size / Double(ratio.cropInViewfinder.width), 0.1), 1)
        label = result.label
        tip = result.tip
        self.scale = scale
        self.scanZoomFactor = scanZoomFactor
        lens = scanLens / scale
        ray = simd_normalize(SIMD3(
            (2 * centerX - 1) * optics.tanHorizontal / scanZoomFactor,
            (1 - 2 * centerY) * optics.tanVertical / scanZoomFactor,
            -1
        ))
    }

    var displayLabel: String {
        label.prefix(1).uppercased() + label.dropFirst()
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

    var isCentered: Bool {
        hypot(x - 0.5, y - 0.5) < 0.04
    }

    var isZoomed: Bool {
        fill > 0.85 && fill < 1.15
    }

    var staysAligned: Bool {
        hypot(x - 0.5, y - 0.5) < 0.055 && fill > 0.8 && fill < 1.2
    }

    /// Whether the shot would still be near the middle after zooming in by this much.
    func staysCentered(afterZooming growth: Double) -> Bool {
        growth > 1 && hypot(x - 0.5, y - 0.5) * growth < 0.2
    }
}
