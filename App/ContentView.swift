import AVFoundation
import AVKit
import SwiftUI

struct ContentView: View {
    let camera: CameraController
    let motion: MotionTracker

    /// Time for the lens to settle after switching to the widest view for a scan.
    private static let lensSettleDelay: UInt64 = 300_000_000
    /// How long the camera keeps running behind the develop screen before it pauses.
    private static let developIdleLimit: UInt64 = 30_000_000_000
    /// How long the screen stays awake with nothing happening, so a forgotten phone can sleep.
    private static let keepAwakeLimit: UInt64 = 120_000_000_000
    /// How long a scan can run before saying so.
    private static let slowScanDelay: UInt64 = 8_000_000_000

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("camera.ratio") private var ratio = CaptureRatio.threeFour
    @AppStorage("camera.hasScanned") private var hasScanned = false
    @AppStorage("camera.timer") private var timer = 0
    @State private var isScanning = false
    @State private var scanIsSlow = false
    @State private var scanTask: Task<Void, Never>?
    @State private var message: String?
    @State private var showingSettings = false
    @State private var showingRatioMenu = false
    @State private var showingCameraMenu = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var lastPhoto: UIImage?
    @State private var saves = 0
    @GestureState private var pinchStartZoom: Double?
    @State private var focusPoint: CGPoint?
    @State private var shutterBlink = false
    @GestureState private var shutterHeld = false
    @State private var shutterFired = false
    @State private var iconAngle = 0.0
    @State private var idleStop: Task<Void, Never>?
    /// The zoom to go back to after a scan, since scanning switches to the widest lens.
    @State private var zoomBeforeScan: Double?

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
                    suggestedLook: motion.target?.look,
                    onSaved: { thumbnail in
                        withAnimation(.snappy(duration: 0.25)) { lastPhoto = thumbnail }
                        saves += 1
                        camera.closePhoto()
                        // The shot is taken, so the guide has done its job.
                        stopGuiding()
                    },
                    onDiscard: camera.closePhoto
                )
                .id(photo.id)
                .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: camera.capturedPhoto?.id)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onChange(of: camera.errorMessage) { _, newMessage in
            if let newMessage {
                message = newMessage
                camera.errorMessage = nil
            }
        }
        .task(id: camera.capturedPhoto == nil ? message : nil) {
            // Messages fade after a moment, but wait until the camera screen is showing again.
            guard message != nil, camera.capturedPhoto == nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(Theme.quick) { message = nil }
            }
        }
        .task(id: isScanning) {
            scanIsSlow = false
            guard isScanning else { return }
            try? await Task.sleep(nanoseconds: Self.slowScanDelay)
            if !Task.isCancelled {
                scanIsSlow = true
            }
        }
        .task(id: AwakeKey(
            isActive: scenePhase == .active,
            isIdle: isIdle,
            shots: camera.shutterBlinks,
            turns: motion.quarterTurns,
            photo: camera.capturedPhoto?.id,
            guide: motion.guide
        )) {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            guard scenePhase == .active else { return }
            try? await Task.sleep(nanoseconds: Self.keepAwakeLimit)
            if !Task.isCancelled {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onAppear(perform: appear)
        .onChange(of: motion.guide.wantsAutoZoom) { _, wants in
            if wants, let lens = motion.target?.lens {
                motion.noteZoomTaken()
                camera.zoom(to: lens, rate: 2.5)
            }
        }
        .onChange(of: ratio) { _, _ in
            // The shot was framed for the old ratio.
            if !isIdle {
                stopGuiding()
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
            aligned && camera.capturedPhoto == nil
        }
        .sensoryFeedback(.impact(weight: .light), trigger: camera.isCapturing) { _, capturing in
            capturing
        }
        .sensoryFeedback(.success, trigger: saves)
        .sensoryFeedback(.selection, trigger: countdown)
        .onCameraCaptureEvent(isEnabled: camera.status == .ready && camera.capturedPhoto == nil && !showingSettings) { event in
            if event.phase == .ended {
                takePhoto()
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
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
            topRow

            viewfinder

            HintView(
                motion: motion,
                isScanning: isScanning,
                scanIsSlow: scanIsSlow,
                message: message ?? camera.interruption,
                showsFirstHint: !hasScanned
            )
            // Kept small, so the camera gets every bit of room that is left.
            .frame(minHeight: 36)
            .padding(.top, 2)
            .padding(.horizontal, 20)

            // Stays while guiding, so the zoom the shot needs shows as it is reached.
            LensRow(camera: camera, motion: motion, iconAngle: iconAngle)
            .padding(.horizontal, 32)
            .padding(.bottom, 4)

            controls
                .padding(.horizontal, 32)
                .padding(.bottom, 6)
        }
    }

    /// Takes all the room the controls leave. The 3:4 camera picture fills it, so a sliver at each side is out of view.
    private var viewfinder: some View {
        Color.clear
            .overlay {
                viewfinderContent
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)
            }
            .clipped()
    }

    private var viewfinderContent: some View {
        ZStack {
            preview
                .saturation(BaseTone.saturation)
                .contrast(BaseTone.contrast)
                .colorMultiply(Color(red: BaseTone.warmth.red, green: BaseTone.warmth.green, blue: BaseTone.warmth.blue))
                .opacity(camera.isPreviewLive ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: camera.isPreviewLive)

            gestureLayer

            RatioMask(crop: ratio.cropInViewfinder)

            if !isIdle {
                LiveGuide(motion: motion, isPaused: camera.capturedPhoto != nil)
                    .transition(.opacity)
            }

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .thin))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: Theme.keyline, radius: 2)
                    .rotationEffect(.degrees(iconAngle))
                    .allowsHitTesting(false)
            }

            if shutterBlink {
                Color.black
                    .allowsHitTesting(false)
            }
        }
    }

    /// The ratio on the left; flash, camera options and settings on the right.
    private var topRow: some View {
        HStack(spacing: 0) {
            Button {
                showingRatioMenu = true
            } label: {
                HStack(spacing: 9) {
                    RatioIcon(ratio: ratio)
                        .rotationEffect(.degrees(iconAngle))
                    Text(ratio.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                    Image(systemName: showingRatioMenu ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .frame(height: 44)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Aspect, \(ratio.rawValue)")
            .popover(isPresented: $showingRatioMenu) {
                RatioMenu(ratio: $ratio, isPresented: $showingRatioMenu)
            }

            Spacer()

            if camera.hasFlash {
                topButton(symbol: camera.flashMode.symbol, isOn: camera.flashMode != .off, width: 40, label: "Flash, \(camera.flashMode.title)") {
                    camera.cycleFlash()
                }
            }

            Button {
                showingCameraMenu = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(cameraOptionsAreOn ? Theme.accent : Color.white)
                        .rotationEffect(.degrees(iconAngle))
                    Image(systemName: showingCameraMenu ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Camera options")
            .popover(isPresented: $showingCameraMenu) {
                CameraMenu(camera: camera, timer: $timer)
            }

            topButton(symbol: "ellipsis", isOn: false, label: "Settings") {
                showingSettings = true
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var cameraOptionsAreOn: Bool {
        camera.isNightOn || timer != 0 || camera.exposureCompensation != 0
    }

    private func topButton(symbol: String, isOn: Bool, width: CGFloat = 44, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : Color.white)
                .rotationEffect(.degrees(iconAngle))
                .frame(width: width, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var preview: some View {
        #if DEBUG
        if let backdrop = camera.stagedBackdrop {
            Color.clear
                .overlay {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
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
            .updating($pinchStartZoom) { value, start, _ in
                let origin = start ?? camera.zoomDisplay
                start = origin
                motion.noteZoomTaken()
                camera.zoom(to: origin * value.magnification, animated: false)
            }
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

    /// Empty until a photo is saved: the app may add to Photos but not read from it.
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
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    Color.clear
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            .rotationEffect(.degrees(iconAngle))
        }
        .buttonStyle(PressStyle())
        .disabled(lastPhoto == nil)
        .accessibilityHidden(lastPhoto == nil)
        .accessibilityLabel("Open Photos")
    }

    private var shutter: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 68, height: 68)
            Circle()
                .fill(Color.white)
                .frame(width: 57, height: 57)
                .scaleEffect(shutterHeld ? 0.9 : 1)
                .animation(Theme.quick, value: shutterHeld)
        }
        .frame(width: 72, height: 72)
        .contentShape(Circle())
        // Fires on touch down, so the moment you press is the moment you get.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($shutterHeld) { _, held, _ in
                    held = true
                }
                .onChanged { _ in
                    if !shutterFired {
                        shutterFired = true
                        takePhoto()
                    }
                }
        )
        // Follows the gesture state, which also resets if the press is interrupted.
        .onChange(of: shutterHeld) { _, held in
            if !held {
                shutterFired = false
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Take photo")
        .accessibilityValue(motion.guide.isAligned ? "Lined up" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { takePhoto() }
    }

    private var scanButton: some View {
        Button(action: scanButtonTapped) {
            Image(systemName: scanSymbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(scanIsLit ? Theme.accent : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(iconAngle))
                .frame(width: 52, height: 52)
                .background(scanIsLit ? Theme.accent.opacity(0.18) : Theme.control, in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(scanLabel)
    }

    private var isIdle: Bool {
        !isScanning && motion.target == nil
    }

    /// Yellow when a tap starts a scan: before the first one, and again once the shot is lined up.
    private var scanIsLit: Bool {
        isIdle || motion.guide.isAligned
    }

    private var scanSymbol: String {
        if isIdle { return "sparkles" }
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
        if camera.onVideoFrame == nil {
            let tracker = SubjectTracker(motion: motion)
            camera.onVideoFrame = { tracker.process($0) }
        }
        camera.start()
        motion.start()
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
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

    /// Shoots now, or starts the timer. Pressing again during a countdown cancels it.
    private func takePhoto() {
        if let running = countdownTask {
            running.cancel()
            countdownTask = nil
            countdown = nil
            return
        }
        guard timer > 0 else {
            camera.capturePhoto(rotationAngle: motion.captureRotationAngle)
            return
        }
        let seconds = timer
        countdownTask = Task {
            for remaining in stride(from: seconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            camera.capturePhoto(rotationAngle: motion.captureRotationAngle)
        }
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
            stopGuiding(restoringZoom: false)
            startScan()
        } else {
            stopGuiding()
        }
    }

    private func stopGuiding(restoringZoom: Bool = true) {
        scanTask?.cancel()
        scanTask = nil
        message = nil
        withAnimation(Theme.quick) {
            isScanning = false
            motion.setTarget(nil, optics: nil, crop: ratio.cropInViewfinder)
        }
        if restoringZoom {
            restoreZoom()
        }
    }

    private func restoreZoom() {
        if let zoom = zoomBeforeScan {
            camera.zoom(to: zoom)
        }
        zoomBeforeScan = nil
    }

    private func startScan() {
        guard let apiKey = KeyStore.load() else {
            showingSettings = true
            return
        }

        message = nil
        withAnimation(Theme.quick) { isScanning = true }
        if zoomBeforeScan == nil {
            zoomBeforeScan = camera.zoomDisplay
        }
        let scanRatio = ratio
        // However the phone is held, the scan sees the scene the right way up.
        let turns = motion.quarterTurns
        camera.zoom(to: camera.lenses.first ?? 1, animated: false)

        scanTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.lensSettleDelay)
                let frame = try await camera.captureScanFrame(quarterTurns: turns) { [motion] in motion.mark() }
                let scanLens = camera.displayZoom(forFactor: frame.zoomFactor)
                let result = try await ClaudeScanner.scan(frame: frame, ratio: scanRatio, scanLens: scanLens, apiKey: apiKey)
                try Task.checkCancellation()
                guard let optics = camera.optics else { throw ScanError.badResponse }
                let target = ScanTarget(
                    result: result,
                    optics: optics,
                    scanZoomFactor: frame.zoomFactor,
                    scanLens: scanLens,
                    ratio: scanRatio
                )
                hasScanned = true
                withAnimation(Theme.quick) {
                    isScanning = false
                    motion.setTarget(target, optics: optics, crop: scanRatio.cropInViewfinder)
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation(Theme.quick) { isScanning = false }
                restoreZoom()
                message = error.localizedDescription
            }
        }
    }

    /// Anything that counts as using the camera restarts the keep-awake countdown.
    private struct AwakeKey: Equatable {
        let isActive: Bool
        let isIdle: Bool
        let shots: Int
        let turns: Int
        let photo: UUID?
        let guide: GuideState
    }
}

/// The text below the viewfinder: what the shot is and how to get it.
private struct HintView: View {
    let motion: MotionTracker
    let isScanning: Bool
    let scanIsSlow: Bool
    let message: String?
    let showsFirstHint: Bool

    var body: some View {
        VStack(spacing: 2) {
            if let message {
                Text(message)
                    .font(.footnote)
            } else if isScanning {
                Text(scanIsSlow ? "Still looking…" : "Finding your shot…")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
            } else if let target = motion.target {
                Text(motion.guide.isBehind ? "Behind you" : target.tip)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.75))
            } else if showsFirstHint {
                Text("Tap \(Image(systemName: "sparkles")) to scan for a shot")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: .infinity)
        .animation(Theme.quick, value: message)
        .animation(Theme.quick, value: scanIsSlow)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// The zoom choices, kept apart so zooming only redraws this row.
private struct LensRow: View {
    let camera: CameraController
    let motion: MotionTracker
    let iconAngle: Double

    private static let matchTolerance = 0.03

    var body: some View {
        HStack(spacing: 4) {
            ForEach(camera.lenses, id: \.self) { lens in
                let isActive = lens == activeLens
                Button {
                    motion.noteZoomTaken()
                    camera.zoom(to: lens)
                } label: {
                    Text(label(isActive ? camera.zoomDisplay : lens))
                        .font(.footnote.weight(isActive ? .semibold : .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isActive ? Theme.accent : Color.white.opacity(0.6))
                        .rotationEffect(.degrees(iconAngle))
                        .frame(width: 40, height: 40)
                        .background(isActive ? Theme.accent.opacity(0.18) : Theme.control.opacity(0.7), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Zoom \(label(lens))")
            }
        }
        .sensoryFeedback(.selection, trigger: activeLens) { old, _ in
            old != nil
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The lens that shows the live zoom: the nearest one at or below it, so pinching never moves the row.
    private var activeLens: Double? {
        camera.lenses.last { $0 <= camera.zoomDisplay + Self.matchTolerance } ?? camera.lenses.first
    }

    private func label(_ lens: Double) -> String {
        if abs(lens - lens.rounded()) < 0.05 { return "\(Int(lens.rounded()))x" }
        if lens < 1 {
            return String(String(format: "%.1f", lens).dropFirst()) + "x"
        }
        return String(format: "%.1fx", lens)
    }
}
