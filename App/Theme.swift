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

/// The scan button's mark, drawn so it stays crisp and is only used in this one place.
struct ScanMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let waist = min(rect.width, rect.height) * 0.1
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: center.x - waist, y: center.y - waist))
        path.closeSubpath()
        return path
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
