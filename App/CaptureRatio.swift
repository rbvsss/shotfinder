import CoreGraphics

enum CaptureRatio: String, CaseIterable {
    case threeFour = "3:4"
    case fourFive = "4:5"
    case square = "1:1"
    case nineSixteen = "9:16"

    var next: CaptureRatio {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    /// Width over height when the phone is held upright.
    var widthOverHeight: CGFloat {
        switch self {
        case .threeFour: return 3.0 / 4.0
        case .fourFive: return 4.0 / 5.0
        case .square: return 1
        case .nineSixteen: return 9.0 / 16.0
        }
    }

    /// The part of the camera's 3:4 view this ratio keeps, as fractions of its width and height.
    var cropInViewfinder: CGSize {
        let sensor: CGFloat = 3.0 / 4.0
        if widthOverHeight >= sensor {
            return CGSize(width: 1, height: sensor / widthOverHeight)
        }
        return CGSize(width: widthOverHeight / sensor, height: 1)
    }
}
