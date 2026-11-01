import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// Field of view of the camera at zoom factor 1, as tangents of the half angles in portrait.
struct CameraOptics {
    let tanHorizontal: Double
    let tanVertical: Double
}

final class CameraController: NSObject, ObservableObject {
    enum Status {
        case starting, ready, denied, unavailable
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var lenses: [Double] = []
    @Published private(set) var selectedLens: Double = 1
    @Published private(set) var lastPhoto: UIImage?
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

    private static let scanLongEdge: CGFloat = 1200

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

    func displayZoom(forFactor factor: Double) -> Double {
        factor / wideFactor
    }

    func start() {
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
            session.commitConfiguration()

            device = camera
            let switchOvers = camera.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            let startsUltraWide = camera.deviceType == .builtInTripleCamera || camera.deviceType == .builtInDualWideCamera
            let wide = startsUltraWide ? (switchOvers.first ?? 1) : 1
            wideFactor = wide
            let available = Self.lensList(for: camera, wideFactor: wide, switchOvers: switchOvers)
            setZoomFactor(wide, animated: false)

            session.startRunning()
            DispatchQueue.main.async {
                self.lenses = available
                self.selectedLens = 1
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

    func selectLens(_ display: Double, animated: Bool = true) {
        selectedLens = display
        let factor = display * wideFactor
        sessionQueue.async { [self] in
            setZoomFactor(factor, animated: animated)
        }
    }

    private func setZoomFactor(_ factor: Double, animated: Bool) {
        guard let camera = device else { return }
        let clamped = min(max(factor, Double(camera.minAvailableVideoZoomFactor)), Double(camera.maxAvailableVideoZoomFactor))
        do {
            try camera.lockForConfiguration()
            if animated {
                camera.ramp(toVideoZoomFactor: CGFloat(clamped), withRate: 8)
            } else {
                camera.videoZoomFactor = CGFloat(clamped)
            }
            camera.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.errorMessage = "Couldn't change the zoom." }
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

    func capturePhoto(rotationAngle: CGFloat) {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            settings.photoQualityPrioritization = .quality
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func save(photo data: Data) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }, completionHandler: { [weak self] success, _ in
            guard !success else { return }
            DispatchQueue.main.async {
                self?.errorMessage = "Couldn't save the photo. Check Photos access in Settings."
            }
        })
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
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.errorMessage = "Couldn't take the photo." }
            return
        }
        save(photo: data)
        var thumbnail: UIImage?
        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
            let scale = 160 / min(image.size.width, image.size.height)
            thumbnail = image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale))
        }
        DispatchQueue.main.async { self.lastPhoto = thumbnail }
    }
}
