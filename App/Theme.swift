import SwiftUI

enum Theme {
    /// Dims what falls outside the chosen ratio while keeping the scene readable.
    static let mask = Color.black.opacity(0.72)
    /// A tight dark edge that keeps white marks readable over a bright sky.
    static let keyline = Color.black.opacity(0.75)
    /// The background of controls and empty slots on the black area below the viewfinder.
    static let control = Color.white.opacity(0.14)
    static let quick = Animation.easeOut(duration: 0.18)
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
