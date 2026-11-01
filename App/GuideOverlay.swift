import SwiftUI

/// The level line, crosshair and target box drawn over the viewfinder.
struct GuideOverlay: View {
    let roll: Double
    let projection: GuideProjection?
    let isAligned: Bool

    static let levelTolerance = 1.5 * Double.pi / 180

    private var isLevel: Bool {
        abs(roll) < Self.levelTolerance
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            ZStack {
                if let projection {
                    let target = CGPoint(x: projection.x * size.width, y: projection.y * size.height)

                    if !projection.isCentered {
                        Path { path in
                            path.move(to: center)
                            path.addLine(to: target)
                        }
                        .stroke(Theme.signal, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    }

                    // Once the frame matches the shot, the box has done its job.
                    if !(projection.isCentered && projection.isZoomed) {
                        Rectangle()
                            .stroke(Theme.signal, lineWidth: 2)
                            .frame(width: projection.width * size.width, height: projection.height * size.height)
                            .position(target)
                    }
                }

                levelLine(width: size.width * 0.36)
                    .position(center)

                if projection != nil {
                    crosshair
                        .position(center)
                }
            }
            .shadow(color: Theme.ink.opacity(0.7), radius: 1)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func levelLine(width: CGFloat) -> some View {
        let color = isLevel && projection != nil ? Theme.signal : Theme.paper.opacity(0.8)
        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: width * 0.18, height: 1.5)
            Rectangle().fill(color).frame(width: width * 0.64, height: 1.5)
                .rotationEffect(.radians(-roll))
            Rectangle().fill(color).frame(width: width * 0.18, height: 1.5)
        }
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().frame(width: 14, height: 1.5)
            Rectangle().frame(width: 1.5, height: 14)
        }
        .foregroundStyle(isAligned ? Theme.signal : Theme.paper)
    }
}

/// Dims what falls outside the chosen ratio, so the frame is honest but the scene stays visible.
struct RatioMask: View {
    let crop: CGSize

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let bandX = (1 - crop.width) * width / 2
            let bandY = (1 - crop.height) * height / 2

            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: width, height: bandY))
                path.addRect(CGRect(x: 0, y: height - bandY, width: width, height: bandY))
                path.addRect(CGRect(x: 0, y: bandY, width: bandX, height: height - 2 * bandY))
                path.addRect(CGRect(x: width - bandX, y: bandY, width: bandX, height: height - 2 * bandY))
            }
            .fill(Theme.ink.opacity(0.78))
        }
        .allowsHitTesting(false)
    }
}

/// Corner marks that breathe while a scan is running.
struct ScanBrackets: View {
    @State private var dimmed = false

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 16
            let arm: CGFloat = 26
            let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: inset, dy: inset)

            Path { path in
                for (corner, dx, dy) in [
                    (CGPoint(x: rect.minX, y: rect.minY), arm, arm),
                    (CGPoint(x: rect.maxX, y: rect.minY), -arm, arm),
                    (CGPoint(x: rect.minX, y: rect.maxY), arm, -arm),
                    (CGPoint(x: rect.maxX, y: rect.maxY), -arm, -arm)
                ] {
                    path.move(to: CGPoint(x: corner.x + dx, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
                }
            }
            .stroke(Theme.signal, lineWidth: 2)
            .shadow(color: Theme.ink.opacity(0.7), radius: 1)
            .opacity(dimmed ? 0.25 : 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}
