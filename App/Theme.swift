import SwiftUI

enum Theme {
    /// Dims what falls outside the chosen ratio while keeping the scene readable.
    static let mask = Color.black.opacity(0.72)
    /// A tight dark edge that keeps white marks readable over a bright sky.
    static let keyline = Color.black.opacity(0.75)
    /// The background of controls and empty slots on the black area below the viewfinder.
    static let control = Color.white.opacity(0.14)
    /// The one colour in the app, for whatever is on or selected.
    static let accent = Color(red: 1, green: 0.839, blue: 0.039)
    /// The yellow, thinned to sit behind a lit button or lens.
    static let accentWash = accent.opacity(0.22)
    /// The background of the shot's name over the viewfinder.
    static let pill = Color.black.opacity(0.55)
    static let quick = Animation.easeOut(duration: 0.18)
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
