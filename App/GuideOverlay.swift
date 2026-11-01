import SwiftUI

/// The only view that updates every frame while the phone moves.
struct LiveGuide: View {
    let motion: MotionTracker
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { _ in
            let snapshot = motion.snapshot()
            GuideOverlay(roll: snapshot.roll, projection: snapshot.projection, isAligned: motion.guide.isAligned)
        }
    }
}

/// An arrow pointing towards a shot that isn't centred yet.
struct LiveDirection: View {
    let motion: MotionTracker
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { _ in
            if let projection = motion.snapshot().projection, !projection.isCentered {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.radians(atan2(projection.x - 0.5, 0.5 - projection.y)))
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The level line and shot marks drawn over the viewfinder. They stay white, because blue
/// vanishes against a blue sky. Being lined up is shown by a heavier line, the shutter and the text.
struct GuideOverlay: View {
    let roll: Double
    let projection: GuideProjection?
    let isAligned: Bool

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
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 6]))
                    }

                    // Once the frame matches the shot, the marks have done their job.
                    if !(projection.isCentered && projection.isZoomed) {
                        CornerMarks(arm: 18)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .frame(width: projection.width * size.width, height: projection.height * size.height)
                            .position(target)
                    }
                }

                levelLine(width: size.width * 0.2)
                    .position(center)

                Capsule()
                    .fill(Color.white)
                    .frame(width: 1.5, height: 12)
                    .position(center)
            }
            .compositingGroup()
            .shadow(color: Theme.keyline, radius: 1)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func levelLine(width: CGFloat) -> some View {
        let weight: CGFloat = isAligned ? 2.5 : 1.5
        return HStack(spacing: 6) {
            Capsule().frame(width: width * 0.14, height: weight)
            Capsule().frame(width: width * 0.62, height: weight)
                .rotationEffect(.radians(-roll))
            Capsule().frame(width: width * 0.14, height: weight)
        }
        .foregroundStyle(Color.white.opacity(isAligned ? 1 : 0.85))
    }
}

/// Four corner marks that frame a shot without covering it.
struct CornerMarks: Shape {
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        let reach = min(arm, min(rect.width, rect.height) / 3)
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), reach, reach),
            (CGPoint(x: rect.maxX, y: rect.minY), -reach, reach),
            (CGPoint(x: rect.minX, y: rect.maxY), reach, -reach),
            (CGPoint(x: rect.maxX, y: rect.maxY), -reach, -reach)
        ] {
            path.move(to: CGPoint(x: corner.x + dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
        }
        return path
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

/// Corner marks around the chosen frame that breathe while a scan is running.
struct ScanBrackets: View {
    let crop: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        GeometryReader { geometry in
            CornerMarks(arm: 28)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .padding(18)
                .frame(width: geometry.size.width * crop.width, height: geometry.size.height * crop.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .shadow(color: Theme.keyline, radius: 1)
        .opacity(reduceMotion ? 0.7 : (dimmed ? 0.45 : 1))
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}
