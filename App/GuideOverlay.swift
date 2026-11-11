import SwiftUI

/// The only view that updates every frame while the phone moves.
struct LiveGuide: View {
    let motion: MotionTracker
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { _ in
            let snapshot = motion.snapshot()
            GuideOverlay(
                roll: snapshot.roll,
                showsLevel: !snapshot.isFlat,
                projection: snapshot.projection,
                label: motion.target?.label,
                isAligned: motion.guide.isAligned
            )
        }
    }
}

/// The box around the shot, a dashed line to it from a crosshair fixed mid-view, the level, and the shot's name.
struct GuideOverlay: View {
    let roll: Double
    let showsLevel: Bool
    let projection: GuideProjection?
    let label: String?
    let isAligned: Bool

    /// The level only appears near level, as on the iPhone camera, and joins up when it gets there.
    private static let levelRange = 15 * Double.pi / 180
    private static let levelTolerance = 3 * Double.pi / 180
    /// How far off the view the dashed line is drawn, so a shot far away can't make a huge path.
    private static let lineReach = 3.0
    /// The space the dashed line leaves around the crosshair.
    private static let lineGap: CGFloat = 28
    private static let lineWidth: CGFloat = 2.7
    /// Where the arrows sit along the line, from the box towards the crosshair.
    private static let arrowPositions: [CGFloat] = [0.38, 0.65]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                if let projection, !isAligned {
                    dashedLine(from: projection, in: size)

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 4)
                        .frame(width: projection.width * size.width, height: projection.height * size.height)
                        .position(x: projection.x * size.width, y: projection.y * size.height)
                }

                if showsLevel, abs(tilt) < Self.levelRange {
                    levelLine(width: size.width * 0.396)
                        .rotationEffect(.radians(-quarterTurn))
                        .position(x: size.width / 2, y: size.height / 2)
                }

                if label != nil {
                    crosshair
                        .position(x: size.width / 2, y: size.height / 2)
                }

                if let label {
                    pill(label)
                        .padding(.top, 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dashedLine(from projection: GuideProjection, in size: CGSize) -> some View {
        let reach = Self.lineReach
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let box = CGPoint(
            x: min(max(projection.x, -reach), reach) * size.width,
            y: min(max(projection.y, -reach), reach) * size.height
        )
        let distance = hypot(box.x - center.x, box.y - center.y)

        if distance > Self.lineGap {
            let length = distance - Self.lineGap
            let along = CGPoint(x: (center.x - box.x) / distance, y: (center.y - box.y) / distance)
            let end = CGPoint(x: box.x + along.x * length, y: box.y + along.y * length)
            let line = Path { path in
                path.move(to: box)
                path.addLine(to: end)
            }

            line.stroke(Theme.accent.opacity(0.12), lineWidth: Self.lineWidth)
            line.stroke(
                Theme.accent.opacity(0.8),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [3.3, 7.7])
            )
            arrows(from: box, along: along, length: length)
                .stroke(Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    /// Small arrows on the line, showing the way the shot moves as you turn towards it.
    private func arrows(from start: CGPoint, along: CGPoint, length: CGFloat) -> Path {
        Path { path in
            for position in Self.arrowPositions {
                let tip = CGPoint(x: start.x + along.x * length * position, y: start.y + along.y * length * position)
                let back = CGPoint(x: tip.x - along.x * 2.5, y: tip.y - along.y * 2.5)
                path.move(to: CGPoint(x: back.x - along.y * 3, y: back.y + along.x * 3))
                path.addLine(to: tip)
                path.addLine(to: CGPoint(x: back.x + along.y * 3, y: back.y - along.x * 3))
            }
        }
    }

    /// Stays in the middle of the view while guiding, and turns green when the shot is lined up.
    private var crosshair: some View {
        Path { path in
            path.move(to: CGPoint(x: 9, y: 0))
            path.addLine(to: CGPoint(x: 9, y: 18))
            path.move(to: CGPoint(x: 0, y: 9))
            path.addLine(to: CGPoint(x: 18, y: 9))
        }
        .stroke(isAligned ? Color.green : Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        .frame(width: 18, height: 18)
    }

    private func pill(_ label: String) -> some View {
        HStack(spacing: 11) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            if isAligned {
                pillDivider
                Text("Ready")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            } else if let projection {
                pillDivider
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .rotationEffect(.radians(atan2(projection.x - 0.5, 0.5 - projection.y)))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 30)
        .background(Theme.pill, in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.3))
            .frame(width: 1, height: 13)
    }

    /// The nearest upright or sideways position, so the level works however the phone is held.
    private var quarterTurn: Double {
        (roll / (.pi / 2)).rounded() * (.pi / 2)
    }

    private var tilt: Double {
        roll - quarterTurn
    }

    @ViewBuilder
    private func levelLine(width: CGFloat) -> some View {
        if abs(tilt) < Self.levelTolerance {
            Capsule()
                .fill(Theme.accent)
                .frame(width: width, height: 1.7)
        } else {
            HStack(spacing: 1) {
                Capsule().frame(width: width * 0.184, height: 1.7)
                Capsule().frame(width: width * 0.628, height: 1.7)
                    .rotationEffect(.radians(-tilt))
                Capsule().frame(width: width * 0.184, height: 1.7)
            }
            .foregroundStyle(Color.white.opacity(0.67))
        }
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
            .fill(Theme.mask)
        }
        .allowsHitTesting(false)
    }
}
