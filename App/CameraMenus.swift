import AVFoundation
import SwiftUI

/// A small rectangle in the shape of a ratio.
struct RatioIcon: View {
    let ratio: CaptureRatio

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .stroke(lineWidth: 1.5)
            .frame(width: 18 * ratio.widthOverHeight, height: 18)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

struct RatioMenu: View {
    @Binding var ratio: CaptureRatio
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Aspect ratio")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            ForEach(CaptureRatio.allCases, id: \.self) { option in
                Button {
                    withAnimation(Theme.quick) { ratio = option }
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        RatioIcon(ratio: option)
                        Text(option.rawValue)
                            .monospacedDigit()
                        Spacer()
                        if option == ratio {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(option == ratio ? Theme.control : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(option == ratio ? .isSelected : [])
            }
        }
        .padding(8)
        .frame(width: 200)
        .presentationCompactAdaptation(.popover)
    }
}

/// Night, the timer and exposure, behind the aperture button.
struct CameraMenu: View {
    let camera: CameraController
    @Binding var timer: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: Binding(get: { camera.isNightOn }, set: { camera.setNight($0) })) {
                Label("Night", systemImage: "moon")
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Timer", systemImage: "timer")
                Picker("Timer", selection: $timer) {
                    Text("Off").tag(0)
                    Text("3s").tag(3)
                    Text("10s").tag(10)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Exposure", systemImage: "plusminus")
                    Spacer()
                    Text(String(format: "%+.1f", camera.exposureCompensation))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(camera.exposureCompensation) },
                        set: { camera.setExposureCompensation(Float(($0 * 10).rounded() / 10)) }
                    ),
                    in: -2...2
                )
                .accessibilityLabel("Exposure")
            }
        }
        .font(.subheadline)
        .padding(16)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
        .sensoryFeedback(.selection, trigger: timer)
    }
}

extension AVCaptureDevice.FlashMode {
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        default: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "bolt.badge.automatic.fill"
        case .on: return "bolt.fill"
        default: return "bolt.slash"
        }
    }
}
