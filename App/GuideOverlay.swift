import SwiftUI

/// The level line, crosshair and target box drawn over the viewfinder.
struct GuideOverlay: View {
    let roll: Double
    let projection: GuideProjection?
    let isAligned: Bool

    private var isLevel: Bool {
        abs(roll) < 1.5 * .pi / 180
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            ZStack {
                if let projection {
                    let target = CGPoint(x: projection.x * size.width, y: projection.y * size.height)

                    Path { path in
                        path.move(to: center)
                        path.addLine(to: target)
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))

                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.yellow, lineWidth: 4)
                        .frame(width: projection.size * size.width, height: projection.size * size.height)
                        .position(target)
                }

                levelLine(width: size.width * 0.4)
                    .position(center)

                crosshair
                    .position(center)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func levelLine(width: CGFloat) -> some View {
        let color = isLevel ? Color.yellow : Color.white
        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: width * 0.2, height: 3)
            Rectangle().fill(color).frame(width: width * 0.6, height: 3)
                .rotationEffect(.radians(-roll))
            Rectangle().fill(color).frame(width: width * 0.2, height: 3)
        }
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().frame(width: 24, height: 2)
            Rectangle().frame(width: 2, height: 24)
        }
        .foregroundStyle(isAligned ? Color.green : Color.yellow)
    }
}
