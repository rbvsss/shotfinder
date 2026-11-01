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

    /// Time for the lens to settle after switching to the widest view for a scan.
    private static let lensSettleDelay: UInt64 = 300_000_000
    private static let lensMatchTolerance = 0.03

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
                    onSaved: { thumbnail in
                        lastPhoto = thumbnail
                        camera.capturedPhoto = nil
                    },
                    onDiscard: { camera.capturedPhoto = nil }
                )
                .id(photo.id)
                .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: camera.capturedPhoto?.id)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Camera problem", isPresented: cameraErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.errorMessage ?? "")
        }
        .onAppear {
            camera.start()
            motion.start()
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
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.signal)
        }
    }

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            viewfinder

            Text(hintText)
                .font(Theme.text)
                .foregroundStyle(hintIsActive ? Theme.signal : Theme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 44)
                .padding(.horizontal, 16)

            lensRow

            Spacer(minLength: 4)

            toolRow
                .padding(.horizontal, 16)

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
                Text(target.label)
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
                let isSelected = abs(chip.value - camera.zoomDisplay) < Self.lensMatchTolerance
                Button {
                    camera.zoom(to: chip.value)
                } label: {
                    Text(lensLabel(chip.value))
                        .font(Theme.label())
                        .foregroundStyle(lensColor(chip, isSelected: isSelected))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 2)
                        .background(isSelected ? Theme.raised : Color.clear)
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

    /// The fixed lenses, plus the shot's exact zoom and the current zoom when they differ.
    private var lensChips: [LensChip] {
        var chips = camera.lenses.map { LensChip(value: $0, isTarget: false) }
        func isNew(_ value: Double) -> Bool {
            !chips.contains { abs($0.value - value) < 0.05 }
        }
        if let lens = currentTarget?.lens {
            if isNew(lens) {
                chips.append(LensChip(value: lens, isTarget: true))
            } else if let index = chips.firstIndex(where: { abs($0.value - lens) < 0.05 }) {
                chips[index] = LensChip(value: chips[index].value, isTarget: true)
            }
        }
        if isNew(camera.zoomDisplay) {
            chips.append(LensChip(value: camera.zoomDisplay, isTarget: false))
        }
        return chips.sorted { $0.value < $1.value }
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            if camera.hasFlash {
                toolButton(flashTitle, active: camera.flashMode != .off, action: camera.cycleFlash)
                    .accessibilityLabel("Flash \(flashTitle)")
            }
            toolButton(ratio.rawValue, active: false) {
                withAnimation(Theme.quick) { ratio = ratio.next }
            }
            .accessibilityLabel("Ratio \(ratio.rawValue)")
            if camera.supportsRAW {
                toolButton("RAW", active: rawEnabled) { rawEnabled.toggle() }
                    .accessibilityValue(rawEnabled ? "On" : "Off")
            }
            toolButton("KEY", active: false) { showingSettings = true }
                .accessibilityLabel("Claude API key")
        }
    }

    private func toolButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(12))
                .foregroundStyle(active ? Theme.signal : Theme.paper.opacity(0.75))
                .frame(maxWidth: .infinity, minHeight: 44)
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
                        Theme.raised
                    }
                }
                .frame(width: 52, height: 52)
                .clipped()
            }
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
                            .fill(Theme.signal)
                            .frame(width: 24, height: 24)
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
            return "Tap ✦ to find a shot"
        case .scanning:
            return "Finding your shot"
        case .guiding(let target):
            if currentProjection == nil { return "Your shot is behind you" }
            if isAligned { return "Lined up. Take it." }
            return target.tip
        }
    }

    private var hintIsActive: Bool {
        if scanMessage != nil { return true }
        if case .scanning = phase { return true }
        return isAligned
    }

    private var cameraErrorBinding: Binding<Bool> {
        Binding(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.errorMessage = nil } }
        )
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
            scanTask?.cancel()
            scanTask = nil
            scanMessage = nil
            withAnimation(Theme.quick) { phase = .idle }
        }
    }

    private func startScan() {
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
