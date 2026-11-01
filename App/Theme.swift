import SwiftUI

/// The app's one visual style: a darkroom. Near-black, warm paper, and a single safelight colour.
enum Theme {
    static let ink = Color(red: 0.047, green: 0.047, blue: 0.043)
    static let paper = Color(red: 0.949, green: 0.933, blue: 0.898)
    static let muted = paper.opacity(0.5)
    static let raised = paper.opacity(0.09)
    static let signal = Color(red: 1, green: 0.365, blue: 0.18)

    static func label(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static let text = Font.system(size: 15, weight: .regular)
    static let quick = Animation.easeOut(duration: 0.18)
}

/// The scan button's mark: the app icon in miniature, a viewfinder with the shot marked inside.
struct ScanMark: View {
    private static let size = CGSize(width: 21, height: 28)
    private static let arm: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                let rect = CGRect(origin: .zero, size: Self.size).insetBy(dx: 0.875, dy: 0.875)
                for (corner, dx, dy) in [
                    (CGPoint(x: rect.minX, y: rect.minY), Self.arm, Self.arm),
                    (CGPoint(x: rect.maxX, y: rect.minY), -Self.arm, Self.arm),
                    (CGPoint(x: rect.minX, y: rect.maxY), Self.arm, -Self.arm),
                    (CGPoint(x: rect.maxX, y: rect.maxY), -Self.arm, -Self.arm)
                ] {
                    path.move(to: CGPoint(x: corner.x + dx, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
                }
            }
            .stroke(Theme.paper, lineWidth: 1.75)

            Rectangle()
                .fill(Theme.signal)
                .frame(width: 7, height: 10)
                .offset(x: 10, y: 5.5)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
