import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    private enum ScanPhase {
        case idle, scanning
        case guiding(ScanTarget)
    }

    private struct LensChip: Identifiable {
        let value: Double
        let isTarget: Bool
        var id: Double { value }
    }

    private struct MessageTimer: Equatable {
        let message: String?
        let isHidden: Bool
    }

    /// Time for the lens to settle after switching to the widest view for a scan.
    private static let lensSettleDelay: UInt64 = 300_000_000
    private static let lensMatchTolerance = 0.03

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera: CameraController
    @StateObject private var motion = MotionTracker()
    @AppStorage("camera.ratio") private var ratio = CaptureRatio.threeFour
    @AppStorage("camera.raw") private var rawEnabled = false
    @State private var phase: ScanPhase = .idle
    @State private var scanTask: Task<Void, Never>?
    @State private var scanMessage: String?
    @State private var showingSettings = false
    @State private var lastPhoto: UIImage?
    @State private var pinchStartZoom: Double?
    @State private var focusPoint: CGPoint?
    @State private var shutterBlink = false

    init(camera: @autoclosure @escaping () -> CameraController = CameraController()) {
        _camera = StateObject(wrappedValue: camera())
    }

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()

            switch camera.status {
            case .starting:
                ProgressView()
                    .tint(Theme.paper)
            case .denied:
                permissionNotice
            case .unavailable:
                notice("The camera isn't available on this device.")
            case .ready:
                cameraScreen
            }

            if let photo = camera.capturedPhoto {
                DevelopView(
                    photo: photo,
                    ratio: ratio,
                    onSaved: { thumbnail, rawSaved in
                        lastPhoto = thumbnail
                        camera.capturedPhoto = nil
                        if !rawSaved {
                            scanMessage = "Photo saved, but its RAW file wasn't."
                        }
                    },
                    onDiscard: { camera.capturedPhoto = nil }
                )
                .id(photo.id)
                .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: camera.capturedPhoto?.id)
        .sheet(isPresented: $showingSettings, onDismiss: { scanMessage = nil }) {
            SettingsView()
        }
        .onChange(of: camera.errorMessage) { _, message in
            if let message {
                scanMessage = message
                camera.errorMessage = nil
            }
        }
        .task(id: MessageTimer(message: scanMessage, isHidden: camera.capturedPhoto != nil)) {
            // Messages fade after a moment, but wait until the camera screen is showing again.
            guard scanMessage != nil, camera.capturedPhoto == nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                scanMessage = nil
            }
        }
        .onAppear {
            camera.start()
            motion.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: camera.capturedPhoto?.id) { _, photo in
            camera.setRunning(photo == nil)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Turns made while the app is away can't be measured, so the guide would be wrong.
            if newPhase == .background {
                stopGuiding()
            }
            UIApplication.shared.isIdleTimerDisabled = newPhase == .active
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isAligned) { _, aligned in
            aligned
        }
        .sensoryFeedback(.impact(weight: .light), trigger: camera.isCapturing) { _, capturing in
            capturing
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Theme.text)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.muted)
            .padding(32)
    }

    private var permissionNotice: some View {
        VStack(spacing: 16) {
            notice("Camera access is off. Turn it on in Settings to take photos.")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("OPEN SETTINGS")
                    .font(Theme.label())
                    .foregroundStyle(Theme.paper)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 20)
                    .background(Theme.raised)
            }
            .buttonStyle(PressStyle())
        }
    }

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            viewfinder

            Text(hintText)
                .font(Theme.text)
                .foregroundStyle(hintColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 44)
                .padding(.horizontal, 16)

            lensRow

            Spacer(minLength: 4)

            toolRow
                .padding(.horizontal, 28)

            Spacer(minLength: 4)

            controls
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
        }
    }

    private var viewfinder: some View {
        ZStack(alignment: .top) {
            CameraPreview(session: camera.session)

            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            setFocus(at: value.location, in: geometry.size)
                        }
                    )
                    .simultaneousGesture(pinchGesture)

                if let focusPoint {
                    Rectangle()
                        .stroke(Theme.paper, lineWidth: 1.5)
                        .frame(width: 56, height: 56)
                        .shadow(color: Theme.ink.opacity(0.7), radius: 1)
                        .position(focusPoint)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }

            RatioMask(crop: ratio.cropInViewfinder)
            GuideOverlay(roll: motion.roll, projection: currentProjection, isAligned: isAligned)

            if case .scanning = phase {
                ScanBrackets()
                    .transition(.opacity)
            }

            if let target = currentTarget {
                Text(target.label.uppercased())
                    .font(Theme.label())
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.ink.opacity(0.72))
                    .padding(.top, 14)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if shutterBlink {
                Theme.ink
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.zoomDisplay
                pinchStartZoom = start
                camera.zoom(to: start * value.magnification, animated: false)
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private var lensRow: some View {
        HStack(spacing: 6) {
            ForEach(lensChips) { chip in
                let isSelected = chip.id == activeLensChip?.id
                Button {
                    camera.zoom(to: chip.value)
                } label: {
                    Text(lensLabel(isSelected ? camera.zoomDisplay : chip.value))
                        .font(Theme.label())
                        .foregroundStyle(lensColor(chip, isSelected: isSelected))
                        .frame(minWidth: 52, minHeight: 44)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(chip.isTarget ? "Zoom to the shot" : "Zoom \(lensLabel(chip.value))")
            }
        }
    }

    private func lensColor(_ chip: LensChip, isSelected: Bool) -> Color {
        if chip.isTarget { return Theme.signal }
        return isSelected ? Theme.paper : Theme.muted
    }

    /// The fixed lenses, plus the shot's exact zoom during a scan.
    private var lensChips: [LensChip] {
        var chips = camera.lenses.map { LensChip(value: $0, isTarget: false) }
        if let lens = currentTarget?.lens {
            if let index = chips.firstIndex(where: { abs($0.value - lens) < 0.05 }) {
                chips[index] = LensChip(value: chips[index].value, isTarget: true)
            } else {
                chips.append(LensChip(value: lens, isTarget: true))
            }
        }
        return chips.sorted { $0.value < $1.value }
    }

    /// The chip that shows the live zoom: the nearest one at or below it, so pinching never moves the row.
    private var activeLensChip: LensChip? {
        lensChips.last { $0.value <= camera.zoomDisplay + Self.lensMatchTolerance } ?? lensChips.first
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            if camera.hasFlash {
                toolButton(flashTitle, active: camera.flashMode != .off, alignment: .leading, action: camera.cycleFlash)
                    .accessibilityLabel(flashTitle)
            }
            toolButton(ratio.rawValue, active: true, alignment: camera.hasFlash ? .center : .leading) {
                withAnimation(Theme.quick) { ratio = ratio.next }
            }
            .disabled(!isIdle)
            .opacity(isIdle ? 1 : 0.35)
            .accessibilityLabel("Ratio \(ratio.rawValue)")
            if camera.supportsRAW {
                toolButton("RAW", active: rawEnabled) { rawEnabled.toggle() }
                    .accessibilityValue(rawEnabled ? "On" : "Off")
            }
            toolButton("API KEY", active: false, alignment: .trailing) { showingSettings = true }
                .accessibilityLabel("Claude API key")
        }
    }

    private func toolButton(
        _ title: String,
        active: Bool,
        alignment: Alignment = .center,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(12))
                .foregroundStyle(active ? Theme.paper : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: alignment)
        }
    }

    private var flashTitle: String {
        switch camera.flashMode {
        case .off: return "FLASH OFF"
        case .auto: return "FLASH AUTO"
        default: return "FLASH ON"
        }
    }

    private var controls: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Group {
                    if let lastPhoto {
                        Image(uiImage: lastPhoto)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().strokeBorder(Theme.paper.opacity(0.18), lineWidth: 1)
                    }
                }
                .frame(width: 52, height: 52)
                .clipped()
            }
            .disabled(lastPhoto == nil)
            .accessibilityLabel("Open Photos")

            Spacer()

            Button(action: takePhoto) {
                ZStack {
                    Circle()
                        .stroke(isAligned ? Theme.signal : Theme.paper, lineWidth: 3)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(Theme.paper)
                        .frame(width: 64, height: 64)
                }
            }
            .buttonStyle(PressStyle())
            .disabled(camera.isCapturing)
            .accessibilityLabel("Take photo")

            Spacer()

            Button(action: scanButtonTapped) {
                Group {
                    if isIdle {
                        ScanMark()
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.paper)
                    }
                }
                .frame(width: 52, height: 52)
                .background(Theme.raised)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(isIdle ? "Scan for a shot" : "Stop guiding")
        }
    }

    private var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    private var currentTarget: ScanTarget? {
        if case .guiding(let target) = phase { return target }
        return nil
    }

    private var currentProjection: GuideProjection? {
        guard let target = currentTarget, let optics = camera.optics else { return nil }
        return target.projection(
            rotation: motion.rotationSinceMark,
            optics: optics,
            zoomFactor: camera.zoomFactor,
            crop: ratio.cropInViewfinder
        )
    }

    private var isAligned: Bool {
        guard let projection = currentProjection else { return false }
        return projection.isCentered && projection.isZoomed && abs(motion.roll) < GuideOverlay.levelTolerance
    }

    private var hintText: String {
        if let scanMessage { return scanMessage }
        switch phase {
        case .idle:
            return "Tap the mark to find a shot"
        case .scanning:
            return "Finding your shot"
        case .guiding(let target):
            if currentProjection == nil { return "Your shot is behind you" }
            if isAligned { return "Lined up. Take it." }
            return target.tip
        }
    }

    private var hintColor: Color {
        if isAligned { return Theme.signal }
        if scanMessage != nil { return Theme.paper }
        if case .scanning = phase { return Theme.paper }
        return Theme.muted
    }

    private func lensLabel(_ lens: Double) -> String {
        if lens < 1 {
            return String(String(format: "%.1f", lens).dropFirst()) + "x"
        }
        if abs(lens - lens.rounded()) < 0.05 { return "\(Int(lens.rounded()))x" }
        return String(format: "%.1fx", lens)
    }

    private func setFocus(at location: CGPoint, in size: CGSize) {
        camera.focus(atX: location.x / size.width, y: location.y / size.height)
        withAnimation(Theme.quick) { focusPoint = location }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if focusPoint == location {
                withAnimation(Theme.quick) { focusPoint = nil }
            }
        }
    }

    private func takePhoto() {
        camera.capturePhoto(rotationAngle: motion.captureRotationAngle, raw: rawEnabled && camera.supportsRAW)
        shutterBlink = true
        Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            withAnimation(.easeOut(duration: 0.12)) { shutterBlink = false }
        }
    }

    private func scanButtonTapped() {
        if isIdle {
            startScan()
        } else {
            stopGuiding()
        }
    }

    private func stopGuiding() {
        scanTask?.cancel()
        scanTask = nil
        scanMessage = nil
        withAnimation(Theme.quick) { phase = .idle }
    }

    private func startScan() {
        guard motion.isHeldForScan else {
            scanMessage = "Hold the phone upright to scan."
            return
        }
        guard let apiKey = KeyStore.load() else {
            scanMessage = ScanError.missingKey.errorDescription
            showingSettings = true
            return
        }

        scanMessage = nil
        withAnimation(Theme.quick) { phase = .scanning }
        let scanLens = camera.widestLens
        let scanRatio = ratio
        camera.zoom(to: scanLens, animated: false)

        scanTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.lensSettleDelay)
                let jpeg = try await camera.captureScanFrame()
                motion.mark()
                let zoomFactor = camera.zoomFactor
                let result = try await ClaudeScanner.scan(jpeg: jpeg, ratio: scanRatio, apiKey: apiKey)
                try Task.checkCancellation()
                guard let optics = camera.optics else { throw ScanError.badResponse }
                let target = ScanTarget(
                    result: result,
                    optics: optics,
                    scanZoomFactor: zoomFactor,
                    scanLens: scanLens,
                    ratio: scanRatio
                )
                withAnimation(Theme.quick) { phase = .guiding(target) }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                withAnimation(Theme.quick) { phase = .idle }
                scanMessage = error.localizedDescription
            }
        }
    }
}
