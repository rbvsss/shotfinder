import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct ContentView: View {
    let camera: CameraController
    let motion: MotionTracker

    /// Time for the lens to settle after switching to the widest view for a scan.
    private static let lensSettleDelay: UInt64 = 300_000_000
    /// How long the camera keeps running behind the develop screen before it pauses.
    private static let developIdleLimit: UInt64 = 30_000_000_000

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("camera.ratio") private var ratio = CaptureRatio.threeFour
    @AppStorage("camera.raw") private var rawEnabled = false
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var message: String?
    @State private var showingSettings = false
    @State private var lastPhoto: UIImage?
    @State private var pinchStartZoom: Double?
    @State private var focusPoint: CGPoint?
    @State private var shutterBlink = false
    @State private var shutterDown = false
    @State private var iconAngle = 0.0
    @State private var idleStop: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .starting, .ready:
                cameraScreen
            case .denied:
                permissionNotice
            case .unavailable:
                notice("The camera isn't available on this device.")
            }

            if let photo = camera.capturedPhoto {
                DevelopView(
                    photo: photo,
                    ratio: ratio,
                    onSaved: { thumbnail, rawSaved in
                        lastPhoto = thumbnail
                        leaveDevelop()
                        if !rawSaved {
                            message = "Photo saved, but its RAW file wasn't."
                        }
                    },
                    onDiscard: leaveDevelop
                )
                .id(photo.id)
                .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: camera.capturedPhoto?.id)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingSettings, onDismiss: { message = nil }) {
            SettingsView(supportsRAW: camera.supportsRAW)
        }
        .onChange(of: camera.errorMessage) { _, newMessage in
            if let newMessage {
                message = newMessage
                camera.errorMessage = nil
            }
        }
        .task(id: MessageTimer(message: message, isHidden: camera.capturedPhoto != nil)) {
            // Messages fade after a moment, but wait until the camera screen is showing again.
            guard message != nil, camera.capturedPhoto == nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(Theme.quick) { message = nil }
            }
        }
        .onAppear(perform: appear)
        .onChange(of: motion.guide.wantsAutoZoom) { _, wants in
            if wants, let lens = motion.target?.lens {
                motion.noteZoomTaken()
                camera.zoom(to: lens, rate: 2.5)
            }
        }
        .onChange(of: camera.capturedPhoto?.id) { _, id in
            keepCameraRunning(whileDeveloping: id != nil)
        }
        .onChange(of: scenePhase) { _, phase in
            handle(phase)
        }
        .onChange(of: motion.quarterTurns) { _, turns in
            rotateIcons(toQuarterTurns: turns)
        }
        .onChange(of: camera.shutterBlinks) { _, _ in
            blinkShutter()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: motion.guide.isAligned) { _, aligned in
            aligned
        }
        .sensoryFeedback(.impact(weight: .light), trigger: camera.isCapturing) { _, capturing in
            capturing
        }
        .onCameraCaptureEvent(isEnabled: camera.capturedPhoto == nil && camera.status == .ready) { event in
            if event.phase == .ended {
                takePhoto()
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
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
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    private var cameraScreen: some View {
        VStack(spacing: 0) {
            viewfinder

            HintView(
                motion: motion,
                isScanning: isScanning,
                message: message ?? camera.interruption,
                isPaused: camera.capturedPhoto != nil
            )
            .frame(minHeight: 64)
            .padding(.horizontal, 20)

            Spacer(minLength: 0)

            controls
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
        }
    }

    private var viewfinder: some View {
        ZStack {
            preview
                .opacity(camera.isPreviewLive ? 1 : 0)
                .animation(.easeIn(duration: 0.25), value: camera.isPreviewLive)

            gestureLayer

            RatioMask(crop: ratio.cropInViewfinder)

            if motion.target != nil {
                LiveGuide(motion: motion, isPaused: camera.capturedPhoto != nil)
                    .transition(.opacity)
            }

            if isScanning {
                ScanBrackets()
                    .transition(.opacity)
            }

            if shutterBlink {
                Color.black
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
        .overlay(alignment: .top) { topControls }
        .overlay(alignment: .bottom) {
            if !camera.lenses.isEmpty {
                LensRow(camera: camera, motion: motion, iconAngle: iconAngle)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        #if DEBUG
        if let backdrop = camera.stagedBackdrop {
            Image(uiImage: backdrop)
                .resizable()
                .scaledToFill()
        } else {
            CameraPreview(session: camera.session, isLive: camera.isPreviewLive)
        }
        #else
        CameraPreview(session: camera.session, isLive: camera.isPreviewLive)
        #endif
    }

    private var gestureLayer: some View {
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .shadow(color: Theme.keyline, radius: 1)
                    .position(focusPoint)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.zoomDisplay
                pinchStartZoom = start
                motion.noteZoomTaken()
                camera.zoom(to: start * value.magnification, animated: false)
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private var topControls: some View {
        HStack {
            if camera.flashMode != .off {
                Image(systemName: camera.flashMode == .on ? "bolt.fill" : "bolt.badge.automatic.fill")
                    .font(.body.weight(.medium))
                    .rotationEffect(.degrees(iconAngle))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityLabel(camera.flashMode == .on ? "Flash on" : "Flash auto")
                    .transition(.opacity)
            }

            Spacer()

            optionsMenu
        }
        .padding(12)
    }

    private var optionsMenu: some View {
        Menu {
            if camera.hasFlash {
                Picker(selection: flashBinding) {
                    Text("Auto").tag(AVCaptureDevice.FlashMode.auto)
                    Text("On").tag(AVCaptureDevice.FlashMode.on)
                    Text("Off").tag(AVCaptureDevice.FlashMode.off)
                } label: {
                    Label("Flash", systemImage: "bolt")
                }
                .pickerStyle(.menu)
            }

            Picker(selection: $ratio) {
                ForEach(CaptureRatio.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            } label: {
                Label("Aspect Ratio", systemImage: "aspectratio")
            }
            .pickerStyle(.menu)
            .disabled(!isIdle)

            Divider()

            Button("Settings", systemImage: "gearshape") {
                showingSettings = true
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(iconAngle))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel("Options")
    }

    private var flashBinding: Binding<AVCaptureDevice.FlashMode> {
        Binding(
            get: { camera.flashMode },
            set: { newValue in
                withAnimation(Theme.quick) { camera.flashMode = newValue }
            }
        )
    }

    private var controls: some View {
        HStack {
            photoWell

            Spacer()

            shutter

            Spacer()

            scanButton
        }
    }

    private var photoWell: some View {
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
                    Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            .rotationEffect(.degrees(iconAngle))
        }
        .disabled(lastPhoto == nil)
        .accessibilityLabel("Open Photos")
    }

    private var shutter: some View {
        ZStack {
            Circle()
                .stroke(motion.guide.isAligned ? Color.accentColor : Color.white, lineWidth: 3)
                .frame(width: 76, height: 76)
            Circle()
                .fill(Color.white)
                .frame(width: 64, height: 64)
                .scaleEffect(shutterDown ? 0.9 : 1)
                .animation(Theme.quick, value: shutterDown)
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
        // Fires on touch down, so the moment you press is the moment you get.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !shutterDown {
                        shutterDown = true
                        takePhoto()
                    }
                }
                .onEnded { _ in
                    shutterDown = false
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Take photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { takePhoto() }
    }

    private var scanButton: some View {
        Button(action: scanButtonTapped) {
            Image(systemName: scanSymbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(iconAngle))
                .frame(width: 52, height: 52)
                .background(Theme.control, in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(scanLabel)
    }

    private var isIdle: Bool {
        !isScanning && motion.target == nil
    }

    private var scanSymbol: String {
        if isIdle { return "viewfinder" }
        return motion.guide.isAligned ? "arrow.clockwise" : "xmark"
    }

    private var scanLabel: String {
        if isIdle { return "Scan for a shot" }
        return motion.guide.isAligned ? "Scan again" : "Stop guiding"
    }

    private func appear() {
        camera.onZoomFactorChange = { [motion] factor in
            motion.setZoomFactor(factor)
        }
        camera.start()
        motion.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Turns made while the app is away can't be measured, so the guide would be wrong.
            stopGuiding()
            motion.stop()
        case .active:
            motion.start()
            if camera.status == .denied {
                camera.start()
            }
        default:
            break
        }
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }

    /// Stays running briefly so returning to the camera is instant, then pauses to save heat.
    private func keepCameraRunning(whileDeveloping developing: Bool) {
        idleStop?.cancel()
        guard developing else {
            camera.setRunning(true)
            return
        }
        idleStop = Task {
            try? await Task.sleep(nanoseconds: Self.developIdleLimit)
            if !Task.isCancelled {
                camera.setRunning(false)
            }
        }
    }

    private func leaveDevelop() {
        camera.setRunning(true)
        camera.capturedPhoto = nil
    }

    private func rotateIcons(toQuarterTurns turns: Int) {
        let target = -Double(turns) * 90
        var delta = (target - iconAngle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        if reduceMotion {
            iconAngle += delta
        } else {
            withAnimation(.snappy(duration: 0.3)) { iconAngle += delta }
        }
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
    }

    private func blinkShutter() {
        shutterBlink = true
        Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            withAnimation(.easeOut(duration: 0.12)) { shutterBlink = false }
        }
    }

    private func scanButtonTapped() {
        if isIdle {
            startScan()
        } else if motion.guide.isAligned {
            stopGuiding()
            startScan()
        } else {
            stopGuiding()
        }
    }

    private func stopGuiding() {
        scanTask?.cancel()
        scanTask = nil
        message = nil
        withAnimation(Theme.quick) {
            isScanning = false
            motion.setTarget(nil, optics: nil, crop: ratio.cropInViewfinder)
        }
    }

    private func startScan() {
        guard motion.isHeldForScan else {
            message = "Hold your iPhone upright to scan."
            return
        }
        guard let apiKey = KeyStore.load() else {
            message = ScanError.missingKey.errorDescription
            showingSettings = true
            return
        }

        message = nil
        withAnimation(Theme.quick) { isScanning = true }
        let scanLens = camera.lenses.first ?? 1
        let scanRatio = ratio
        camera.zoom(to: scanLens, animated: false)

        scanTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.lensSettleDelay)
                let tracker = motion
                let frame = try await camera.captureScanFrame { tracker.mark() }
                let result = try await ClaudeScanner.scan(frame: frame, ratio: scanRatio, apiKey: apiKey)
                try Task.checkCancellation()
                guard let optics = camera.optics else { throw ScanError.badResponse }
                let target = ScanTarget(
                    result: result,
                    optics: optics,
                    scanZoomFactor: frame.zoomFactor,
                    scanLens: scanLens,
                    ratio: scanRatio
                )
                withAnimation(Theme.quick) {
                    isScanning = false
                    motion.setTarget(target, optics: optics, crop: scanRatio.cropInViewfinder)
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                withAnimation(Theme.quick) { isScanning = false }
                message = error.localizedDescription
            }
        }
    }

    private struct MessageTimer: Equatable {
        let message: String?
        let isHidden: Bool
    }
}

/// The text below the viewfinder: what the shot is and what to do next.
private struct HintView: View {
    let motion: MotionTracker
    let isScanning: Bool
    let message: String?
    let isPaused: Bool

    var body: some View {
        VStack(spacing: 2) {
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            } else if isScanning {
                Text("Finding your shot")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let target = motion.target {
                Text(target.displayLabel)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                detail(for: target)
            } else {
                Text("Tap the viewfinder button to find a shot")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder
    private func detail(for target: ScanTarget) -> some View {
        if motion.guide.isBehind {
            Text("Your shot is behind you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if motion.guide.isAligned {
            Text("Ready")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            HStack(spacing: 6) {
                LiveDirection(motion: motion, isPaused: isPaused)
                    .fixedSize()
                Text(target.tip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Zoom choices in one glass capsule. Kept apart so zooming only redraws this row.
private struct LensRow: View {
    let camera: CameraController
    let motion: MotionTracker
    let iconAngle: Double

    private struct Chip: Identifiable {
        let value: Double
        let isTarget: Bool
        var id: Double { value }
    }

    private static let matchTolerance = 0.03

    var body: some View {
        HStack(spacing: 0) {
            ForEach(chips) { chip in
                let isActive = chip.id == activeChip?.id
                Button {
                    motion.noteZoomTaken()
                    camera.zoom(to: chip.value)
                } label: {
                    Text(label(isActive ? camera.zoomDisplay : chip.value))
                        .font(.footnote.weight(isActive ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(color(chip, isActive: isActive))
                        .rotationEffect(.degrees(iconAngle))
                        .frame(minWidth: 48, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chip.isTarget ? "Zoom to the shot" : "Zoom \(label(chip.value))")
            }
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .sensoryFeedback(.selection, trigger: activeChip?.id)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The real lenses, plus the shot's exact zoom during a scan.
    private var chips: [Chip] {
        var chips = camera.lenses.map { Chip(value: $0, isTarget: false) }
        if let lens = motion.target?.lens {
            if let index = chips.firstIndex(where: { abs($0.value - lens) < 0.05 }) {
                chips[index] = Chip(value: chips[index].value, isTarget: true)
            } else {
                chips.append(Chip(value: lens, isTarget: true))
            }
        }
        return chips.sorted { $0.value < $1.value }
    }

    /// The chip that shows the live zoom: the nearest one at or below it, so pinching never moves the row.
    private var activeChip: Chip? {
        chips.last { $0.value <= camera.zoomDisplay + Self.matchTolerance } ?? chips.first
    }

    private func color(_ chip: Chip, isActive: Bool) -> Color {
        if chip.isTarget { return .accentColor }
        return isActive ? .primary : .secondary
    }

    private func label(_ lens: Double) -> String {
        if lens < 1 {
            return String(String(format: "%.1f", lens).dropFirst()) + "x"
        }
        if abs(lens - lens.rounded()) < 0.05 { return "\(Int(lens.rounded()))x" }
        return String(format: "%.1fx", lens)
    }
}
