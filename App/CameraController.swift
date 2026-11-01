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
final class CapturedPhoto: Identifiable {
    let id = UUID()
    let placeholder: UIImage?
    fileprivate(set) var data: Data?
    fileprivate(set) var rawData: Data?

    init(placeholder: UIImage? = nil, data: Data? = nil, rawData: Data? = nil) {
        self.placeholder = placeholder
        self.data = data
        self.rawData = rawData
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
    private(set) var supportsRAW = false
    private(set) var isCapturing = false
    private(set) var shutterBlinks = 0
    private(set) var interruption: String?
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
    private let imageContext = CIContext()
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var wideFactor: Double = 1
    @ObservationIgnored private var minimumFactor: Double = 1
    @ObservationIgnored private var maximumFactor: Double = 1
    @ObservationIgnored private var zoomObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingFrame: CheckedContinuation<ScanFrame, Error>?
    @ObservationIgnored private var onPendingFrame: (() -> Void)?
    @ObservationIgnored private var frameRequest = 0
    @ObservationIgnored private var wantsPlaceholder = false
    @ObservationIgnored private var processedData: Data?
    @ObservationIgnored private var rawData: Data?
    @ObservationIgnored private var rawRequested = false
    @ObservationIgnored private var captureIsUpright = true

    private static let scanLongEdge: CGFloat = 1200
    private static let placeholderLongEdge: CGFloat = 1200
    private static let frameTimeout: TimeInterval = 3
    private static let maximumDisplayZoom: Double = 15

    #if DEBUG
    /// Stands in for a real camera so tests can capture the screen on a simulator, which has none.
    func stageForScreenshots(lenses: [Double], backdrop: UIImage?) {
        isStaged = true
        self.lenses = lenses
        stagedBackdrop = backdrop
        supportsRAW = true
        hasFlash = true
        isPreviewLive = true
        status = .ready
    }
    @ObservationIgnored private(set) var isStaged = false
    @ObservationIgnored private(set) var stagedBackdrop: UIImage?
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
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
            // Lets a shot taken while the last one is still finishing begin straight away.
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            session.commitConfiguration()
            let rawAvailable = photoOutput.isAppleProRAWEnabled

            observeSession(camera)

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
                self.zoomDisplay = 1
                self.hasFlash = flash
                self.supportsRAW = rawAvailable
                self.status = .ready
            }

            session.startRunning()
            photoOutput.setPreparedPhotoSettingsArray([makeSettings(raw: false)]) { _, _ in }
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

    /// Pauses the camera after a long stay on the develop screen, to save heat and battery.
    func setRunning(_ running: Bool) {
        sessionQueue.async { [self] in
            guard device != nil, session.isRunning != running else { return }
            if running {
                session.startRunning()
            } else {
                session.stopRunning()
            }
        }
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

    /// The phone's real lenses and optical-quality crops, as shown on the zoom buttons.
    private static func lensList(for camera: AVCaptureDevice, wideFactor: Double, switchOvers: [Double], maximum: Double) -> [Double] {
        let minimum = Double(camera.minAvailableVideoZoomFactor)
        var factors = [minimum, wideFactor]
        factors.append(contentsOf: switchOvers)
        let crops = camera.activeFormat.secondaryNativeResolutionZoomFactors.map(Double.init)
        factors.append(contentsOf: crops.isEmpty ? [wideFactor * 2] : crops)
        let displayValues = factors
            .filter { $0 >= minimum && $0 <= maximum }
            .map { $0 / wideFactor }
        return Array(Set(displayValues)).sorted()
    }

    /// Moves to a zoom given as shown on the lens buttons, where 1 is the main camera.
    func zoom(to display: Double, animated: Bool = true, rate: Float = 8) {
        let factor = min(max(display * wideFactor, minimumFactor), maximumFactor)
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
        applyFocus(at: CGPoint(x: y, y: 1 - x), focus: .autoFocus, exposure: .autoExpose, watchSubject: true)
    }

    /// When the scene changes after a tap, hand control back to the camera.
    @objc private func subjectAreaChanged() {
        applyFocus(at: CGPoint(x: 0.5, y: 0.5), focus: .continuousAutoFocus, exposure: .continuousAutoExposure, watchSubject: false)
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
        try await withTaskCancellationHandler {
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

    func capturePhoto(rotationAngle: CGFloat, raw: Bool) {
        guard !isCapturing else { return }
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
            processedData = nil
            rawData = nil
            rawRequested = raw
            captureIsUpright = rotationAngle == 90
            let settings = makeSettings(raw: raw)
            if photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func makeSettings(raw: Bool) -> AVCapturePhotoSettings {
        let processed: [String: Any]? = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? [AVVideoCodecKey: AVVideoCodecType.hevc]
            : nil
        let settings: AVCapturePhotoSettings
        if raw, let format = photoOutput.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: format, processedFormat: processed)
        } else {
            settings = processed.map { AVCapturePhotoSettings(format: $0) } ?? AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        return settings
    }

    private func finishCapture(error: String?) {
        let data = processedData
        let raw = rawData
        let rawMissing = rawRequested && raw == nil
        processedData = nil
        rawData = nil
        rawRequested = false
        DispatchQueue.main.async {
            self.isCapturing = false
            guard let data else {
                self.capturedPhoto = nil
                self.errorMessage = error ?? "Couldn't take the photo."
                return
            }
            if let photo = self.capturedPhoto {
                photo.data = data
                photo.rawData = raw
            } else {
                self.capturedPhoto = CapturedPhoto(data: data, rawData: raw)
            }
            if rawMissing {
                self.errorMessage = "This shot has no RAW file, but the photo is fine."
            }
        }
    }

    private func showPlaceholder(from pixels: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, Self.placeholderLongEdge / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = imageContext.createCGImage(scaled, from: scaled.extent.integral) else { return }
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
        if let jpeg = imageContext.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: options) {
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
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finishCapture(error: nil)
    }
}
