import Foundation
import simd

/// A shot found by a scan, fixed to a direction in the scene so it can be followed as the phone moves.
struct ScanTarget {
    let label: String
    let tip: String
    /// Direction of the shot in the phone's coordinates at the moment of the scan.
    let ray: SIMD3<Double>
    let size: Double
    let scanZoomFactor: Double
    let suggestedLens: Double

    init(result: ScanResult, optics: CameraOptics, scanZoomFactor: Double, scanLens: Double, lenses: [Double]) {
        let centerX = min(max(result.centerX, 0), 1)
        let centerY = min(max(result.centerY, 0), 1)
        size = min(max(result.size, 0.15), 1)
        label = result.label
        tip = result.tip
        self.scanZoomFactor = scanZoomFactor
        ray = simd_normalize(SIMD3(
            (2 * centerX - 1) * optics.tanHorizontal / scanZoomFactor,
            (1 - 2 * centerY) * optics.tanVertical / scanZoomFactor,
            -1
        ))
        // The longest lens that still fits the whole shot in the frame.
        let idealLens = scanLens / size
        suggestedLens = lenses.last(where: { $0 <= idealLens + 0.01 }) ?? scanLens
    }

    /// Where the shot currently appears, as fractions of the viewfinder. Nil when it is behind the phone.
    func projection(rotation: simd_quatd, optics: CameraOptics, zoomFactor: Double) -> GuideProjection? {
        let current = rotation.act(ray)
        guard current.z < -0.01 else { return nil }
        let x = current.x / -current.z / (optics.tanHorizontal / zoomFactor)
        let y = current.y / -current.z / (optics.tanVertical / zoomFactor)
        return GuideProjection(x: (x + 1) / 2, y: (1 - y) / 2, size: size * zoomFactor / scanZoomFactor)
    }
}

struct GuideProjection {
    let x: Double
    let y: Double
    let size: Double

    var isCentered: Bool {
        hypot(x - 0.5, y - 0.5) < 0.05
    }
}
