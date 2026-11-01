import SwiftUI

/// The only view that updates every frame while the phone moves.
struct LiveGuide: View {
    let motion: MotionTracker
    let showsLevel: Bool
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { _ in
            let snapshot = motion.snapshot()
            GuideOverlay(
                roll: snapshot.roll,
                showsLevel: showsLevel && !snapshot.isFlat,
                projection: snapshot.projection,
                label: motion.target?.label,
                isAligned: motion.guide.isAligned
            )
        }
    }
}

/// The box around the shot, a dashed line from the middle of the view to it, the level, and the shot's name.
struct GuideOverlay: View {
    let roll: Double
    let showsLevel: Bool
    let projection: GuideProjection?
    let label: String?
    let isAligned: Bool

    /// The level only appears near level, as on the iPhone camera, and joins up when it gets there.
    private static let levelRange = 15 * Double.pi / 180
    private static let levelTolerance = 1.5 * Double.pi / 180
    /// How far off the view the dashed line is drawn, so a shot far away can't make a huge path.
    private static let lineReach = 3.0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                if let projection, !isAligned {
                    dashedLine(to: projection, in: size)

                    // A dark outline drawn under the colour, cheaper to redraw every frame than a shadow.
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.keyline, lineWidth: 4.5)
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.accent, lineWidth: 3)
                    }
                    .frame(width: projection.width * size.width, height: projection.height * size.height)
                    .position(x: projection.x * size.width, y: projection.y * size.height)

                    crossMark
                        .position(x: projection.x * size.width, y: projection.y * size.height)
                }

                if showsLevel, abs(tilt) < Self.levelRange {
                    levelLine(width: size.width * 0.32)
                        .rotationEffect(.radians(-quarterTurn))
                        .shadow(color: Theme.keyline, radius: 1)
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

    private func dashedLine(to projection: GuideProjection, in size: CGSize) -> some View {
        let reach = Self.lineReach
        let end = CGPoint(
            x: min(max(projection.x, -reach), reach) * size.width,
            y: min(max(projection.y, -reach), reach) * size.height
        )
        return Path { path in
            path.move(to: CGPoint(x: size.width / 2, y: size.height / 2))
            path.addLine(to: end)
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
    }

    private var crossMark: some View {
        Path { path in
            path.move(to: CGPoint(x: 6, y: 0))
            path.addLine(to: CGPoint(x: 6, y: 12))
            path.move(to: CGPoint(x: 0, y: 6))
            path.addLine(to: CGPoint(x: 12, y: 6))
        }
        .stroke(Theme.accent, lineWidth: 1.5)
        .frame(width: 12, height: 12)
    }

    private func pill(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.white)
                .lineLimit(1)

            if isAligned {
                pillDivider
                Text("Ready")
                    .foregroundStyle(Theme.accent)
            } else if let projection, !projection.isInView {
                pillDivider
                Image(systemName: "arrow.up")
                    .foregroundStyle(.white)
                    .rotationEffect(.radians(atan2(projection.x - 0.5, 0.5 - projection.y)))
                    .accessibilityHidden(true)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Theme.pill, in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.3))
            .frame(width: 1, height: 14)
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
            ZStack {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width, height: 1.5)
                if isAligned {
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 1.5, height: 10)
                }
            }
        } else {
            HStack(spacing: 6) {
                Capsule().frame(width: width * 0.14, height: 1.5)
                Capsule().frame(width: width * 0.62, height: 1.5)
                    .rotationEffect(.radians(-tilt))
                Capsule().frame(width: width * 0.14, height: 1.5)
            }
            .foregroundStyle(Color.white.opacity(0.85))
        }
    }
}

/// Rule-of-thirds lines across the chosen frame.
struct GridLines: View {
    let crop: CGSize

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * crop.width
            let height = geometry.size.height * crop.height
            let left = (geometry.size.width - width) / 2
            let top = (geometry.size.height - height) / 2

            Path { path in
                for third in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: left + width * third, y: top))
                    path.addLine(to: CGPoint(x: left + width * third, y: top + height))
                    path.move(to: CGPoint(x: left, y: top + height * third))
                    path.addLine(to: CGPoint(x: left + width, y: top + height * third))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// The focus square, with a sun beside it that moves with the brightness you drag to.
struct FocusMark: View {
    let exposure: Float

    /// How far the sun travels for the full range of the drag.
    private static let sunTravel: CGFloat = 44

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: 64, height: 64)
            Image(systemName: "sun.max.fill")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .offset(y: -CGFloat(exposure) / 2 * Self.sunTravel)
        }
        .shadow(color: Theme.keyline, radius: 1)
        .accessibilityHidden(true)
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
