import AVFoundation
import SwiftUI

/// The camera's controls in one place, laid out like the iPhone camera's own panel.
struct ControlsPanel: View {
    let camera: CameraController
    let canChangeRatio: Bool
    @Binding var ratio: CaptureRatio
    @Binding var timer: Int
    @Binding var showsGrid: Bool
    @Binding var showsLevel: Bool
    let onOpenSettings: () -> Void

    @State private var showingExposure = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: columns, spacing: 18) {
                if camera.hasFlash {
                    control("Flash", value: camera.flashMode.title, symbol: camera.flashMode.symbol, isOn: camera.flashMode != .off) {
                        camera.cycleFlash()
                    }
                }
                control("Night", value: camera.isNightOn ? "On" : "Off", symbol: camera.isNightOn ? "moon.fill" : "moon", isOn: camera.isNightOn) {
                    camera.setNight(!camera.isNightOn)
                }
                control("Aspect", value: ratio.rawValue, symbol: "aspectratio", isOn: false) {
                    ratio = ratio.next
                }
                .disabled(!canChangeRatio)
                .opacity(canChangeRatio ? 1 : 0.35)
                control("Timer", value: timer == 0 ? "Off" : "\(timer)s", symbol: "timer", isOn: timer != 0) {
                    timer = timer == 0 ? 3 : (timer == 3 ? 10 : 0)
                }
                control(
                    "Exposure",
                    value: String(format: "%+.1f", camera.exposureCompensation),
                    symbol: "plusminus",
                    isOn: camera.exposureCompensation != 0 || showingExposure
                ) {
                    withAnimation(Theme.quick) { showingExposure.toggle() }
                }
                control("Grid", value: showsGrid ? "On" : "Off", symbol: "grid", isOn: showsGrid) {
                    showsGrid.toggle()
                }
                control("Level", value: showsLevel ? "On" : "Off", symbol: "level", isOn: showsLevel) {
                    showsLevel.toggle()
                }
                control("API Key", value: KeyStore.load() == nil ? "Add" : "Set", symbol: "key", isOn: false, action: onOpenSettings)
            }

            if showingExposure {
                exposureSlider
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(showingExposure ? 410 : 350)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .sensoryFeedback(.selection, trigger: camera.flashMode)
        .sensoryFeedback(.selection, trigger: camera.isNightOn)
        .sensoryFeedback(.selection, trigger: timer)
    }

    private var exposureSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(camera.exposureCompensation) },
                    set: { camera.setExposureCompensation(Float(($0 * 10).rounded() / 10)) }
                ),
                in: -2...2
            )
            .accessibilityLabel("Exposure")
            Image(systemName: "sun.max.fill")
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }

    private func control(
        _ title: String,
        value: String,
        symbol: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isOn ? Color.black : Color.white)
                    .frame(width: 60, height: 60)
                    .background(isOn ? Color.white : Theme.control, in: Circle())
                Text(title.uppercased())
                    .font(.caption2.weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(title), \(value)")
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
