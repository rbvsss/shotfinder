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

/// Marks that lead to the shot and get out of the way. Corners show where it is, or a chevron points
/// the way if it is out of view. Once you are lined up, the viewfinder is left empty.
struct GuideOverlay: View {
    let roll: Double
    let projection: GuideProjection?
    let isAligned: Bool

    /// How far inside the viewfinder's edge the chevron sits.
    private static let chevronInset: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                if let projection {
                    if projection.isInView {
                        if !projection.isZoomed || !projection.isCentered {
                            // A dark outline drawn under the white, cheaper to redraw every frame than a shadow.
                            ZStack {
                                CornerMarks(arm: 18)
                                    .stroke(Theme.keyline, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                                CornerMarks(arm: 18)
                                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            }
                                .frame(width: projection.width * size.width, height: projection.height * size.height)
                                .position(x: projection.x * size.width, y: projection.y * size.height)
                        }
                    } else {
                        chevron(pointingTo: projection, in: size)
                    }
                }

                levelLine(width: size.width * 0.2)
                    .shadow(color: Theme.keyline, radius: 1)
                    .position(x: size.width / 2, y: size.height / 2)
            }
            .opacity(isAligned ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: isAligned)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func chevron(pointingTo projection: GuideProjection, in size: CGSize) -> some View {
        let dx = (projection.x - 0.5) * size.width
        let dy = (projection.y - 0.5) * size.height
        // Slides along the edge of the viewfinder, on the straight line towards the shot.
        let reachX = size.width / 2 - Self.chevronInset
        let reachY = size.height / 2 - Self.chevronInset
        let scale = min(reachX / max(abs(dx), 1), reachY / max(abs(dy), 1))
        return Image(systemName: "chevron.up")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: Theme.keyline, radius: 1)
            .rotationEffect(.radians(atan2(dx, -dy)))
            .position(x: size.width / 2 + dx * scale, y: size.height / 2 + dy * scale)
    }

    private func levelLine(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Capsule().frame(width: width * 0.14, height: 1.5)
            Capsule().frame(width: width * 0.62, height: 1.5)
                .rotationEffect(.radians(-roll))
            Capsule().frame(width: width * 0.14, height: 1.5)
        }
        .foregroundStyle(Color.white.opacity(0.85))
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
