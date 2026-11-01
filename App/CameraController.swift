import AVFoundation
import CoreImage
import ImageIO
import Observation
import UIKit

/// Field of view of the camera at zoom factor 1, as tangents of the half angles in portrait.
struct CameraOptics {
    let tanHorizontal: Double
    let tanVertical: Double
}

/// A photo on its way to being developed. The screen opens on `placeholder` while `data` is processed.
@Observable
final class CapturedPhoto {
    let id = UUID()
    let placeholder: UIImage?
    fileprivate(set) var data: Data?

    init(placeholder: UIImage? = nil, data: Data? = nil) {
        self.placeholder = placeholder
        self.data = data
    }
}

@Observable
final class CameraController: NSObject {
    enum Status {
        case starting, ready, denied, unavailable
    }

    private(set) var status: Status = .starting
    private(set) var isPreviewLive = false
    private(set) var lenses: [Double] = []
    private(set) var zoomDisplay: Double = 1
    private(set) var hasFlash = false
    private(set) var isCapturing = false
    private(set) var shutterBlinks = 0
    private(set) var interruption: String?
    private(set) var isNightOn = false
    /// The camera reports a scene dark enough that flash or Night would help.
    private(set) var isDarkScene = false
    private(set) var isFocusLocked = false
    /// Brightness set in the controls panel, which stays until changed.
    private(set) var exposureCompensation: Float = 0
    /// Brightness set by dragging after a tap, which goes when the scene changes.
    private(set) var tapExposure: Float = 0
    var flashMode: AVCaptureDevice.FlashMode = .off
    var capturedPhoto: CapturedPhoto?
    var errorMessage: String?

    /// Reports the real zoom factor as it changes, including during a ramp.
    @ObservationIgnored var onZoomFactorChange: ((Double) -> Void)?
    @ObservationIgnored private(set) var optics: CameraOptics?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "shotfinder.camera.session")
    private let videoQueue = DispatchQueue(label: "shotfinder.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// Each video frame is different, so nothing is worth caching between them.
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var wideFactor: Double = 1
    @ObservationIgnored private var minimumFactor: Double = 1
    @ObservationIgnored private var maximumFactor: Double = 1
    @ObservationIgnored private var zoomObservation: NSKeyValueObservation?
    @ObservationIgnored private var sceneObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingFrame: CheckedContinuation<ScanFrame, Error>?
    @ObservationIgnored private var onPendingFrame: (() -> Void)?
    @ObservationIgnored private var frameRequest = 0
    @ObservationIgnored private var wantsPlaceholder = false
    @ObservationIgnored private var processedData: Data?
    @ObservationIgnored private var captureIsUpright = true
    @ObservationIgnored private var discardsCurrentCapture = false

    private static let scanLongEdge: CGFloat = 1200
    private static let placeholderLongEdge: CGFloat = 1200
    private static let frameTimeout: TimeInterval = 3
    private static let maximumDisplayZoom: Double = 15
    /// Night's limits: slow enough to gather light, short enough to hold by hand.
    private static let nightExposureLimit = CMTime(value: 1, timescale: 4)
    private static let nightBoost: Float = 0.5

    #if DEBUG
    /// Stands in for a real camera so tests can drive the app on a simulator, which has none.
    func stageForTesting(lenses: [Double], backdrop: UIImage?) {
        isStaged = true
        self.lenses = lenses
        stagedBackdrop = backdrop
        hasFlash = true
        isPreviewLive = true
        wideFactor = 2
        maximumFactor = 30
        optics = CameraOptics(tanHorizontal: 0.75, tanVertical: 1)
        status = .ready
    }
    @ObservationIgnored private(set) var isStaged = false
    @ObservationIgnored private(set) var stagedBackdrop: UIImage?
    @ObservationIgnored private var stagedFactor = 2.0

    private func stagedZoom(to factor: Double) {
        stagedFactor = factor
        zoomDisplay = factor / wideFactor
        onZoomFactorChange?(factor)
    }

    private func stagedScanFrame() -> ScanFrame {
        ScanFrame(jpeg: stagedBackdrop?.jpegData(compressionQuality: 0.8) ?? Data(), width: 900, height: 1200, zoomFactor: stagedFactor)
    }

    private func stagedCapture() {
        isCapturing = true
        shutterBlinks &+= 1
        let data = stagedBackdrop?.jpegData(compressionQuality: 0.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.capturedPhoto = CapturedPhoto(placeholder: self.stagedBackdrop)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.isCapturing = false
            self.capturedPhoto?.data = data
        }
    }
    #endif

    func start() {
        #if DEBUG
        guard !isStaged else { return }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configure()
                } else {
                    self?.publish(status: .denied)
                }
            }
        default:
            publish(status: .denied)
        }
    }

    private func publish(status: Status) {
        DispatchQueue.main.async { self.status = status }
    }

    private func configure() {
        sessionQueue.async { [self] in
            guard device == nil else { return }
            guard let camera = Self.bestBackCamera(),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                publish(status: .unavailable)
                return
            }

            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                publish(status: .unavailable)
                return
            }
            session.addInput(input)
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
            // A lighter format than BGRA, since these frames are rarely used.
            let lightFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                videoOutput.availableVideoPixelFormatTypes.contains(lightFormat) ? lightFormat : kCVPixelFormatType_32BGRA]
            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            session.commitConfiguration()

            observeSession(camera)
            monitorDarkScenes()

            device = camera
            optics = Self.optics(for: camera)
            let switchOvers = camera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            let startsUltraWide = camera.deviceType == .builtInTripleCamera || camera.deviceType == .builtInDualWideCamera
            let wide = startsUltraWide ? (switchOvers.first ?? 1) : 1
            wideFactor = wide
            minimumFactor = Double(camera.minAvailableVideoZoomFactor)
            maximumFactor = min(Double(camera.maxAvailableVideoZoomFactor), wide * Self.maximumDisplayZoom)
            let available = Self.lensList(for: camera, wideFactor: wide, switchOvers: switchOvers, maximum: maximumFactor)
            let flash = photoOutput.supportedFlashModes.contains(.on)
            setZoomFactor(wide, animated: false)
            onZoomFactorChange?(wide)

            DispatchQueue.main.async {
                self.lenses = available
                self.hasFlash = flash
                self.status = .ready
            }

            session.startRunning()
            photoOutput.setPreparedPhotoSettingsArray([makeSettings()]) { _, _ in }
            DispatchQueue.main.async { self.isPreviewLive = true }
        }
    }

    private func observeSession(_ camera: AVCaptureDevice) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionFailed(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(subjectAreaChanged), name: AVCaptureDevice.subjectAreaDidChangeNotification, object: camera)

        zoomObservation = camera.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            let factor = Double(device.videoZoomFactor)
            self.onZoomFactorChange?(factor)
            DispatchQueue.main.async { self.zoomDisplay = factor / self.wideFactor }
        }
    }

    private func monitorDarkScenes() {
        let monitor = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.auto) {
            monitor.flashMode = .auto
        }
        monitor.photoQualityPrioritization = .quality
        photoOutput.photoSettingsForSceneMonitoring = monitor
        sceneObservation = photoOutput.observe(\.isFlashScene, options: [.new]) { [weak self] output, _ in
            let isDark = output.isFlashScene
            DispatchQueue.main.async { self?.isDarkScene = isDark }
        }
    }

    @objc private func sessionFailed(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        sessionQueue.async { [self] in
            if error.code == .mediaServicesWereReset, !session.isRunning {
                session.startRunning()
            } else {
                DispatchQueue.main.async { self.errorMessage = "The camera stopped. Reopen the app." }
            }
        }
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        let value = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = value.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        let message: String?
        switch reason {
        case .videoDeviceInUseByAnotherClient:
            message = "Another app is using the camera."
        case .videoDeviceNotAvailableDueToSystemPressure:
            message = "The camera paused because your iPhone is too warm."
        case .videoDeviceNotAvailableInBackground, .none:
            message = nil
        default:
            message = "The camera is paused."
        }
        DispatchQueue.main.async { self.interruption = message }
    }

    @objc private func interruptionEnded() {
        DispatchQueue.main.async { self.interruption = nil }
    }

    /// Pauses the camera during a long stay on the develop screen, and resumes it afterwards.
    func setRunning(_ running: Bool) {
        sessionQueue.async { [self] in
            guard device != nil else { return }
            if !running {
                session.stopRunning()
            } else if !session.isRunning {
                session.startRunning()
            }
        }
    }

    /// Leaves the develop screen. A shot still processing is thrown away when it finishes.
    func closePhoto() {
        discardsCurrentCapture = isCapturing
        capturedPhoto = nil
    }

    /// The zoom as shown on the lens buttons for a raw zoom factor.
    func displayZoom(forFactor factor: Double) -> Double {
        factor / wideFactor
    }

    private static func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        for type in types {
            if let camera = AVCaptureDevice.default(type, for: .video, position: .back) {
                return camera
            }
        }
        return nil
    }

    private static func optics(for camera: AVCaptureDevice) -> CameraOptics? {
        let format = camera.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        let long = max(dimensions.width, dimensions.height)
        let short = min(dimensions.width, dimensions.height)
        let tanLong = tan(Double(format.geometricDistortionCorrectedVideoFieldOfView) * .pi / 360)
        return CameraOptics(tanHorizontal: tanLong * Double(short) / Double(long), tanVertical: tanLong)
    }

    /// Up to four zoom buttons: the phone's real lenses and the optical-quality crop between them.
    /// Longer zooms are still a pinch away.
    private static func lensList(for camera: AVCaptureDevice, wideFactor: Double, switchOvers: [Double], maximum: Double) -> [Double] {
        let minimum = Double(camera.minAvailableVideoZoomFactor)
        var factors = [minimum, wideFactor]
        factors.append(contentsOf: switchOvers)
        let crops = camera.activeFormat.secondaryNativeResolutionZoomFactors.map(Double.init)
        factors.append(contentsOf: crops.isEmpty ? [wideFactor * 2] : crops)
        let longest = switchOvers.last.map { min($0, maximum) } ?? min(wideFactor * 2, maximum)
        let displayValues = factors
            .filter { $0 >= minimum && $0 <= longest }
            .map { $0 / wideFactor }
        let sorted = Array(Set(displayValues)).sorted()
        // If the phone reports more, keep the longest lens rather than a crop below it.
        return sorted.count > 4 ? Array(sorted.prefix(3)) + [sorted[sorted.count - 1]] : sorted
    }

    /// Moves to a zoom given as shown on the lens buttons, where 1 is the main camera.
    func zoom(to display: Double, animated: Bool = true, rate: Float = 8) {
        let factor = min(max(display * wideFactor, minimumFactor), maximumFactor)
        #if DEBUG
        if isStaged {
            stagedZoom(to: factor)
            return
        }
        #endif
        sessionQueue.async { [self] in
            setZoomFactor(factor, animated: animated, rate: rate)
        }
    }

    private func setZoomFactor(_ factor: Double, animated: Bool, rate: Float = 8) {
        guard let camera = device else { return }
        do {
            try camera.lockForConfiguration()
            if animated {
                camera.ramp(toVideoZoomFactor: CGFloat(factor), withRate: rate)
            } else {
                camera.videoZoomFactor = CGFloat(factor)
            }
            camera.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.errorMessage = "Couldn't change the zoom." }
        }
    }

    /// Focuses and meters once on a point given as fractions of the upright viewfinder.
    func focus(atX x: Double, y: Double) {
        isFocusLocked = false
        tapExposure = 0
        applyBias()
        applyFocus(at: CGPoint(x: y, y: 1 - x), focus: .autoFocus, exposure: .autoExpose, watchSubject: true)
    }

    /// Holds focus and exposure at a point until the next tap.
    func lockFocus(atX x: Double, y: Double) {
        isFocusLocked = true
        tapExposure = 0
        applyBias()
        applyFocus(at: CGPoint(x: y, y: 1 - x), focus: .autoFocus, exposure: .autoExpose, watchSubject: false)
    }

    /// When the scene changes after a tap, hand control back to the camera.
    @objc private func subjectAreaChanged() {
        DispatchQueue.main.async {
            self.tapExposure = 0
            self.applyBias()
        }
        applyFocus(at: CGPoint(x: 0.5, y: 0.5), focus: .continuousAutoFocus, exposure: .continuousAutoExposure, watchSubject: false)
    }

    func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        default: flashMode = .off
        }
        if flashMode != .off, isNightOn {
            setNight(false)
        }
    }

    func setExposureCompensation(_ value: Float) {
        exposureCompensation = value
        applyBias()
    }

    /// Follows a drag on the viewfinder. Scene watching pauses so the change doesn't undo itself.
    func setTapExposure(_ value: Float) {
        tapExposure = value
        applyBias()
        setSubjectWatching(false)
    }

    func finishExposureDrag() {
        setSubjectWatching(!isFocusLocked)
    }

    private func setSubjectWatching(_ watching: Bool) {
        sessionQueue.async { [self] in
            guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
            camera.isSubjectAreaChangeMonitoringEnabled = watching
            camera.unlockForConfiguration()
        }
    }

    private func applyBias() {
        let total = exposureCompensation + tapExposure + (isNightOn ? Self.nightBoost : 0)
        sessionQueue.async { [self] in
            guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
            let bias = min(max(total, camera.minExposureTargetBias), camera.maxExposureTargetBias)
            camera.setExposureTargetBias(bias, completionHandler: nil)
            camera.unlockForConfiguration()
        }
    }

    /// Apple keeps its real Night mode to itself, so this allows slower exposures and a little more
    /// brightness, on top of the low-light fusion the camera does for quality-first photos.
    func setNight(_ on: Bool) {
        isNightOn = on
        if on {
            flashMode = .off
        }
        applyBias()
        sessionQueue.async { [self] in
            guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
            if on {
                let format = camera.activeFormat
                let limit = CMTimeMinimum(Self.nightExposureLimit, format.maxExposureDuration)
                camera.activeMaxExposureDuration = limit
                if !camera.isAutoVideoFrameRateEnabled,
                   let slowest = format.videoSupportedFrameRateRanges.map(\.maxFrameDuration).max() {
                    camera.activeVideoMaxFrameDuration = CMTimeMinimum(limit, slowest)
                }
            } else {
                camera.activeMaxExposureDuration = .invalid
                if !camera.isAutoVideoFrameRateEnabled {
                    camera.activeVideoMaxFrameDuration = .invalid
                }
            }
            camera.unlockForConfiguration()
        }
    }

    private func applyFocus(at point: CGPoint, focus: AVCaptureDevice.FocusMode, exposure: AVCaptureDevice.ExposureMode, watchSubject: Bool) {
        sessionQueue.async { [self] in
            guard let camera = device else { return }
            do {
                try camera.lockForConfiguration()
                if camera.isFocusPointOfInterestSupported, camera.isFocusModeSupported(focus) {
                    camera.focusPointOfInterest = point
                    camera.focusMode = focus
                }
                if camera.isExposurePointOfInterestSupported, camera.isExposureModeSupported(exposure) {
                    camera.exposurePointOfInterest = point
                    camera.exposureMode = exposure
                }
                camera.isSubjectAreaChangeMonitoringEnabled = watchSubject
                camera.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { self.errorMessage = "Couldn't set the focus." }
            }
        }
    }

    /// Returns the next video frame as a portrait JPEG small enough to send for scanning.
    /// `onFrame` runs at the moment the frame arrives, before the slower encoding work.
    func captureScanFrame(onFrame: @escaping () -> Void) async throws -> ScanFrame {
        #if DEBUG
        if isStaged {
            onFrame()
            return stagedScanFrame()
        }
        #endif
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                videoQueue.async {
                    self.failPendingFrame(with: CancellationError())
                    self.frameRequest += 1
                    self.pendingFrame = continuation
                    self.onPendingFrame = onFrame
                    let request = self.frameRequest
                    self.videoQueue.asyncAfter(deadline: .now() + Self.frameTimeout) {
                        if request == self.frameRequest {
                            self.failPendingFrame(with: ScanError.cameraNotReady)
                        }
                    }
                }
            }
        } onCancel: {
            videoQueue.async {
                self.failPendingFrame(with: CancellationError())
            }
        }
    }

    private func failPendingFrame(with error: Error) {
        pendingFrame?.resume(throwing: error)
        pendingFrame = nil
        onPendingFrame = nil
    }

    func capturePhoto(rotationAngle: CGFloat) {
        guard !isCapturing else { return }
        #if DEBUG
        if isStaged {
            stagedCapture()
            return
        }
        #endif
        isCapturing = true
        let flash = flashMode
        sessionQueue.async { [self] in
            guard session.isRunning,
                  let connection = photoOutput.connection(with: .video),
                  connection.isActive, connection.isEnabled else {
                finishCapture(error: "The camera isn't ready. Try again.")
                return
            }
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            captureIsUpright = rotationAngle == 90
            let settings = makeSettings()
            if photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func makeSettings() -> AVCapturePhotoSettings {
        let settings = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        return settings
    }

    private func finishCapture(error: String?) {
        let data = processedData
        processedData = nil
        DispatchQueue.main.async {
            self.isCapturing = false
            if self.discardsCurrentCapture {
                self.discardsCurrentCapture = false
                return
            }
            guard let data else {
                self.capturedPhoto = nil
                self.errorMessage = error ?? "Couldn't take the photo."
                return
            }
            if let photo = self.capturedPhoto {
                photo.data = data
            } else {
                self.capturedPhoto = CapturedPhoto(data: data)
            }
        }
    }

    private func showPlaceholder(from pixels: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, Self.placeholderLongEdge / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Rendered right away, so no camera buffer stays held by the image.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = Self.imageContext.createCGImage(
                scaled,
                from: scaled.extent.integral,
                format: .RGBA8,
                colorSpace: colorSpace,
                deferred: false
              ) else { return }
        let placeholder = UIImage(cgImage: rendered)
        DispatchQueue.main.async {
            if self.isCapturing, self.capturedPhoto == nil {
                self.capturedPhoto = CapturedPhoto(placeholder: placeholder)
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if wantsPlaceholder, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            wantsPlaceholder = false
            showPlaceholder(from: pixels)
        }

        guard let continuation = pendingFrame else { return }
        pendingFrame = nil
        onPendingFrame?()
        onPendingFrame = nil
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            continuation.resume(throwing: ScanError.badResponse)
            return
        }

        let zoomFactor = Double(device?.videoZoomFactor ?? 1)
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, Self.scanLongEdge / max(image.extent.width, image.extent.height))
        let width = (image.extent.width * scale).rounded()
        let height = (image.extent.height * scale).rounded()
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: width / image.extent.width,
            y: height / image.extent.height
        ))
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
        if let jpeg = Self.imageContext.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: options) {
            continuation.resume(returning: ScanFrame(jpeg: jpeg, width: Int(width), height: Int(height), zoomFactor: zoomFactor))
        } else {
            continuation.resume(throwing: ScanError.badResponse)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { self.shutterBlinks &+= 1 }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // The viewfinder frame stands in on the develop screen while the photo is processed.
        // It is always portrait, so a sideways shot waits for the real photo instead.
        if captureIsUpright {
            videoQueue.async { self.wantsPlaceholder = true }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        processedData = data
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finishCapture(error: nil)
    }
}
