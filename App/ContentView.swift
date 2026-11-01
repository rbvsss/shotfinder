import SwiftUI
import UIKit

struct ContentView: View {
    private enum ScanPhase {
        case idle, scanning
        case guiding(ScanTarget)
    }

    /// Time for the lens to settle after switching to the widest view for a scan.
    private static let lensSettleDelay: UInt64 = 300_000_000

    @StateObject private var camera = CameraController()
    @StateObject private var motion = MotionTracker()
    @State private var phase: ScanPhase = .idle
    @State private var scanTask: Task<Void, Never>?
    @State private var scanMessage: String?
    @State private var showingSettings = false
    @State private var wasAligned = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .starting:
                ProgressView()
            case .denied:
                notice("Camera access is off. Turn it on in Settings to use ShotFinder.")
            case .unavailable:
                notice("The camera isn't available on this device.")
            case .ready:
                viewfinder
            }
        }
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
        .onChange(of: isAligned) { _, aligned in
            if aligned && !wasAligned {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            wasAligned = aligned
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(32)
    }

    private var viewfinder: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)

            ZStack(alignment: .top) {
                CameraPreview(session: camera.session)
                GuideOverlay(roll: motion.roll, projection: currentProjection, isAligned: isAligned)
                if case .guiding(let target) = phase {
                    Text(target.label)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.top, 14)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()

            Text(hintText)
                .font(.subheadline)
                .foregroundStyle(hintIsActive ? Color.yellow : Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 16)

            lensPicker

            Spacer(minLength: 0)

            controls
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
        }
    }

    private var lensPicker: some View {
        HStack(spacing: 10) {
            ForEach(camera.lenses, id: \.self) { lens in
                Button {
                    camera.selectLens(lens)
                } label: {
                    Text(lensLabel(lens))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(lens == camera.selectedLens ? Color.yellow : Color.gray)
                        .frame(width: 46, height: 46)
                        .background(lens == camera.selectedLens ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1), in: Circle())
                        .overlay {
                            if lens == suggestedLens && lens != camera.selectedLens {
                                Circle().stroke(Color.yellow, lineWidth: 2)
                            }
                        }
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Group {
                if let photo = camera.lastPhoto {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer()

            Button {
                camera.capturePhoto(rotationAngle: motion.captureRotationAngle)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                ZStack {
                    Circle().stroke(isAligned ? Color.yellow : Color.white, lineWidth: 4)
                        .frame(width: 74, height: 74)
                    Circle().fill(.white)
                        .frame(width: 60, height: 60)
                }
            }
            .accessibilityLabel("Take photo")

            Spacer()

            Button(action: scanButtonTapped) {
                Image(systemName: isIdle ? "sparkles" : "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isIdle ? Color.yellow : Color.white)
                    .frame(width: 52, height: 52)
                    .background(isIdle ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1), in: Circle())
            }
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

    private var suggestedLens: Double? {
        currentTarget?.suggestedLens
    }

    private var currentProjection: GuideProjection? {
        guard let target = currentTarget, let optics = camera.optics else { return nil }
        return target.projection(rotation: motion.rotationSinceMark, optics: optics, zoomFactor: camera.zoomFactor)
    }

    private var isAligned: Bool {
        guard let projection = currentProjection, let target = currentTarget else { return false }
        return projection.isCentered
            && abs(motion.roll) < 1.5 * .pi / 180
            && target.suggestedLens == camera.selectedLens
    }

    private var hintText: String {
        if let scanMessage { return scanMessage }
        switch phase {
        case .idle:
            return "Tap ✦ to scan the scene"
        case .scanning:
            return "Finding your shot..."
        case .guiding(let target):
            if currentProjection == nil { return "Your shot is behind you. Turn around." }
            if isAligned { return "Lined up. Take the shot." }
            return target.tip
        }
    }

    private var hintIsActive: Bool {
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
            let text = String(format: "%.1f", lens)
            return String(text.dropFirst()) + "x"
        }
        if lens == lens.rounded() { return "\(Int(lens))x" }
        return String(format: "%.1fx", lens)
    }

    private func scanButtonTapped() {
        if isIdle {
            startScan()
        } else {
            scanTask?.cancel()
            scanTask = nil
            scanMessage = nil
            phase = .idle
        }
    }

    private func startScan() {
        guard let apiKey = KeyStore.load() else {
            scanMessage = ScanError.missingKey.errorDescription
            showingSettings = true
            return
        }

        scanMessage = nil
        phase = .scanning
        let scanLens = camera.widestLens
        camera.selectLens(scanLens, animated: false)

        scanTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.lensSettleDelay)
                let jpeg = try await camera.captureScanFrame()
                motion.mark()
                let zoomFactor = camera.zoomFactor
                let result = try await ClaudeScanner.scan(jpeg: jpeg, apiKey: apiKey)
                try Task.checkCancellation()
                guard let optics = camera.optics else { throw ScanError.badResponse }
                phase = .guiding(ScanTarget(
                    result: result,
                    optics: optics,
                    scanZoomFactor: zoomFactor,
                    scanLens: scanLens,
                    lenses: camera.lenses
                ))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                phase = .idle
                scanMessage = error.localizedDescription
            }
        }
    }
}
