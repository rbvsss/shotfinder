import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// Field of view of the camera at zoom factor 1, as tangents of the half angles in portrait.
struct CameraOptics {
    let tanHorizontal: Double
    let tanVertical: Double
}

/// A photo that has been taken but not developed or saved yet.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    let data: Data
    let rawData: Data?
}

final class CameraController: NSObject, ObservableObject {
    enum Status {
        case starting, ready, denied, unavailable
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var lenses: [Double] = []
    @Published private(set) var zoomDisplay: Double = 1
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var hasFlash = false
    @Published private(set) var supportsRAW = false
    @Published private(set) var isCapturing = false
    @Published var capturedPhoto: CapturedPhoto?
    @Published var errorMessage: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "shotfinder.camera.session")
    private let videoQueue = DispatchQueue(label: "shotfinder.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext()
    private var device: AVCaptureDevice?
    private var wideFactor: Double = 1
    private var pendingFrame: CheckedContinuation<Data, Error>?
    private var processedData: Data?
    private var rawData: Data?

    private static let scanLongEdge: CGFloat = 1200
    private static let maximumDisplayZoom: Double = 15

    var zoomFactor: Double {
        Double(device?.videoZoomFactor ?? 1)
    }

    var widestLens: Double {
        lenses.first ?? 1
    }

    var optics: CameraOptics? {
        guard let format = device?.activeFormat else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        let long = max(dimensions.width, dimensions.height)
        let short = min(dimensions.width, dimensions.height)
        let tanLong = tan(Double(format.videoFieldOfView) * .pi / 360)
        return CameraOptics(tanHorizontal: tanLong * Double(short) / Double(long), tanVertical: tanLong)
    }

    #if DEBUG
    /// Stands in for a real camera so tests can capture the screen on a simulator, which has none.
    func stageForScreenshots(lenses: [Double], supportsRAW: Bool) {
        isStaged = true
        self.lenses = lenses
        self.supportsRAW = supportsRAW
        hasFlash = true
        status = .ready
    }
    private(set) var isStaged = false
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
            let rawAvailable = photoOutput.isAppleProRAWSupported
            photoOutput.isAppleProRAWEnabled = rawAvailable

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            session.commitConfiguration()

            device = camera
            let switchOvers = camera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            let startsUltraWide = camera.deviceType == .builtInTripleCamera || camera.deviceType == .builtInDualWideCamera
            let wide = startsUltraWide ? (switchOvers.first ?? 1) : 1
            wideFactor = wide
            let available = Self.lensList(for: camera, wideFactor: wide, switchOvers: switchOvers)
            let flash = photoOutput.supportedFlashModes.contains(.on)
            setZoomFactor(wide, animated: false)

            session.startRunning()
            DispatchQueue.main.async {
                self.lenses = available
                self.zoomDisplay = 1
                self.hasFlash = flash
                self.supportsRAW = rawAvailable
                self.status = .ready
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

    private static func lensList(for camera: AVCaptureDevice, wideFactor: Double, switchOvers: [Double]) -> [Double] {
        let minimum = Double(camera.minAvailableVideoZoomFactor)
        let maximum = Double(camera.maxAvailableVideoZoomFactor)
        var factors = [minimum, wideFactor, wideFactor * 2]
        factors.append(contentsOf: switchOvers)
        let displayValues = factors
            .filter { $0 >= minimum && $0 <= maximum }
            .map { $0 / wideFactor }
        return Array(Set(displayValues)).sorted()
    }

    /// Moves to a zoom given as shown on the lens buttons, where 1 is the main camera.
    func zoom(to display: Double, animated: Bool = true) {
        guard let camera = device else { return }
        let lowest = Double(camera.minAvailableVideoZoomFactor) / wideFactor
        let highest = min(Double(camera.maxAvailableVideoZoomFactor) / wideFactor, Self.maximumDisplayZoom)
        let clamped = min(max(display, lowest), highest)
        zoomDisplay = clamped
        let factor = clamped * wideFactor
        sessionQueue.async { [self] in
            setZoomFactor(factor, animated: animated)
        }
    }

    private func setZoomFactor(_ factor: Double, animated: Bool) {
        guard let camera = device else { return }
        do {
            try camera.lockForConfiguration()
            if animated {
                camera.ramp(toVideoZoomFactor: CGFloat(factor), withRate: 8)
            } else {
                camera.videoZoomFactor = CGFloat(factor)
            }
            camera.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.errorMessage = "Couldn't change the zoom." }
        }
    }

    /// Focuses and meters on a point given as fractions of the upright viewfinder.
    func focus(atX x: Double, y: Double) {
        let point = CGPoint(x: y, y: 1 - x)
        sessionQueue.async { [self] in
            guard let camera = device else { return }
            do {
                try camera.lockForConfiguration()
                if camera.isFocusPointOfInterestSupported, camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusPointOfInterest = point
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposurePointOfInterestSupported, camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposurePointOfInterest = point
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { self.errorMessage = "Couldn't set the focus." }
            }
        }
    }

    func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        default: flashMode = .off
        }
    }

    /// Returns the next video frame as a portrait JPEG small enough to send for scanning.
    func captureScanFrame() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            videoQueue.async {
                self.pendingFrame?.resume(throwing: CancellationError())
                self.pendingFrame = continuation
            }
        }
    }

    func capturePhoto(rotationAngle: CGFloat, raw: Bool) {
        guard !isCapturing else { return }
        isCapturing = true
        let flash = flashMode
        sessionQueue.async { [self] in
            guard session.isRunning else {
                finishCapture(error: "The camera isn't running. Try again.")
                return
            }
            if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            processedData = nil
            rawData = nil
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
        if raw, let format = photoOutput.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) {
            return AVCapturePhotoSettings(rawPixelFormatType: format, processedFormat: processed)
        }
        let settings = processed.map { AVCapturePhotoSettings(format: $0) } ?? AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        return settings
    }

    private func finishCapture(error: String?) {
        let photo = processedData.map { CapturedPhoto(data: $0, rawData: rawData) }
        processedData = nil
        rawData = nil
        DispatchQueue.main.async {
            self.isCapturing = false
            if let photo {
                self.capturedPhoto = photo
            } else {
                self.errorMessage = error ?? "Couldn't take the photo."
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let continuation = pendingFrame else { return }
        pendingFrame = nil
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            continuation.resume(throwing: ScanError.badResponse)
            return
        }

        let image = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, Self.scanLongEdge / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
        if let jpeg = imageContext.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: options) {
            continuation.resume(returning: jpeg)
        } else {
            continuation.resume(throwing: ScanError.badResponse)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
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
