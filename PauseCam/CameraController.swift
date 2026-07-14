import AVFoundation
import Combine
import Photos
import UIKit

/// Capture engine built on `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput`
/// feeding an `AVAssetWriter`, which is the only way to get true in-camera
/// pause/resume into a single continuous file (`AVCaptureMovieFileOutput` cannot
/// pause).
///
/// Pause/resume works by keeping a cumulative `timeOffset`: while paused, incoming
/// sample buffers are dropped; on resume, the elapsed gap is added to `timeOffset`,
/// and every subsequent sample's timestamps are shifted back by `timeOffset` before
/// being appended. The same offset is applied to both video and audio so the tracks
/// stay in sync.
final class CameraController: NSObject, ObservableObject {

    enum CaptureState {
        case idle
        case recording
        case paused
        case saving
    }

    /// One native zoom step (a lens switch-over point on virtual devices).
    struct ZoomOption: Identifiable, Equatable {
        let id: Int
        /// Display label in stock-camera convention ("0.5x", "1x", "3x").
        let label: String
        /// The device zoom factor to apply (relative to the virtual device's base).
        let zoomFactor: CGFloat
    }

    private enum SetupError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
        case cannotAddWriterInput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera is available on this device."
            case .cannotAddInput: return "The camera could not be attached to the capture session."
            case .cannotAddOutput: return "The video output could not be attached to the capture session."
            case .cannotAddWriterInput: return "The movie writer rejected its video input."
            }
        }
    }

    // MARK: - Published UI state (main thread only)

    @Published private(set) var state: CaptureState = .idle
    /// Recorded (non-paused) duration in seconds, derived from sample timestamps,
    /// so it naturally freezes while paused.
    @Published private(set) var recordedSeconds: Double = 0
    /// 1-based scene counter; increments on every resume.
    @Published private(set) var sceneNumber = 1
    @Published private(set) var isUsingFrontCamera = false
    /// True while a camera flip is reconfiguring the session; recording must not
    /// start until the swap completes.
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var isCameraAccessDenied = false
    @Published private(set) var isMicAccessDenied = false
    @Published var errorMessage: String?
    @Published var didSaveToPhotos = false
    /// Native zoom steps for the current camera; empty when the camera has a
    /// single lens (no zoom UI is shown then).
    @Published private(set) var zoomOptions: [ZoomOption] = []
    @Published private(set) var selectedZoomID: Int?
    /// Poster frame of the most recently saved clip; drives the thumbnail button.
    @Published private(set) var lastClipThumbnail: UIImage?

    /// Owned by the controller; hosted by `CameraPreview`.
    let previewLayer = AVCaptureVideoPreviewLayer()

    // MARK: - Capture plumbing

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.drewmerc.PauseCam.session")
    /// Single serial queue that receives BOTH video and audio sample buffers and
    /// owns all asset-writer bookkeeping, so the writer state is single-threaded.
    private let writerQueue = DispatchQueue(label: "com.drewmerc.PauseCam.writer")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var hasAudioOutput = false
    private var isConfigured = false

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    // MARK: - Zoom state (sessionQueue only)

    private var pinchStartZoomFactor: CGFloat = 1
    private var maxPinchZoomFactor: CGFloat = 5

    /// The app's own copy of the last saved clip, for the thumbnail button and
    /// in-app playback (add-only Photos access can't read assets back out).
    static let lastClipURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LastClip.mov")

    // MARK: - Writer state (touch only on writerQueue)

    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var outputURL: URL?

    private var isWriterSessionStarted = false
    private var isPaused = false
    private var isResumePending = false
    private var isStopping = false
    /// Source time passed to `startSession(atSourceTime:)` — the raw PTS of the
    /// first video buffer.
    private var sessionStartTime = CMTime.zero
    /// Cumulative duration of all paused gaps; subtracted from every timestamp.
    private var timeOffset = CMTime.zero
    /// Raw (unadjusted) PTS of the last appended video buffer; the resume gap is
    /// measured against this.
    private var lastRawVideoTime = CMTime.zero
    /// Adjusted PTS of the last appended video buffer; guards against
    /// non-increasing timestamps.
    private var lastAdjustedVideoTime: CMTime?
    /// Adjusted end time (PTS + duration) of the last appended audio buffer.
    private var lastAudioEndTime: CMTime?
    /// Observed frame cadence, used so the first resumed frame lands one frame
    /// after the last pre-pause frame instead of on top of it.
    private var lastVideoFrameDuration = CMTime(value: 1, timescale: 30)
    private var lastPublishedSeconds = -1.0

    /// Keeps the process alive long enough to finish writing and saving when a
    /// stop is triggered by backgrounding. Main thread only.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Setup

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        // Best-effort early cleanup of the cached clip on clean exits; the
        // launch-time purge in configure() covers force-kills.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            try? FileManager.default.removeItem(at: CameraController.lastClipURL)
        }
    }

    /// Requests permissions and configures the capture session. Idempotent.
    func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        // Native-camera behavior: the last-clip thumbnail lives only for the
        // current session. Purge any leftover copy from a previous run (also
        // reclaims the storage; deleting at termination isn't reliable on iOS).
        try? FileManager.default.removeItem(at: Self.lastClipURL)

        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
            guard let self else { return }
            guard videoGranted else {
                DispatchQueue.main.async { self.isCameraAccessDenied = true }
                return
            }
            // Microphone is optional: if denied we still record video-only.
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async { self.isMicAccessDenied = !audioGranted }
                self.sessionQueue.async {
                    self.configureSession(audioEnabled: audioGranted)
                }
            }
        }
    }

    private func configureSession(audioEnabled: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .high

        do {
            guard let camera = Self.camera(for: .back) else { throw SetupError.noCamera }
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
            session.addInput(input)
            videoDeviceInput = input

            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            // Prefer complete files over low latency: don't drop late frames.
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
            guard session.canAddOutput(videoOutput) else { throw SetupError.cannotAddOutput }
            session.addOutput(videoOutput)
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.errorMessage = "Camera setup failed: \(error.localizedDescription)"
            }
            return
        }

        if audioEnabled,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                hasAudioOutput = true
            }
        }

        session.commitConfiguration()
        updateZoomOptions()
        session.startRunning()

        DispatchQueue.main.async {
            self.makeRotationCoordinator()
        }
    }

    private static func camera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Prefer virtual multi-lens devices on the back so native zoom
        // switch-overs (0.5x/1x/tele) are available; fall back to the plain
        // wide camera on single-lens hardware like iPads.
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        ).devices.first
    }

    // MARK: - Zoom

    /// sessionQueue only. Rebuilds the zoom steps for the current device and
    /// resets zoom to the wide (1x) lens.
    private func updateZoomOptions() {
        guard let device = videoDeviceInput?.device else { return }
        var factors: [CGFloat] = [1.0]
        factors += device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }

        // Single-lens cameras (iPads, front cameras) get a 2x digital step; the
        // slow ramp rate below makes the 1x -> 2x transition a smooth ~0.5s.
        let isSingleLens = factors.count == 1
        if isSingleLens {
            factors.append(2.0)
        }

        // Stock-camera labeling: when an ultra-wide is the base lens, factor 1.0
        // is "0.5x" and the first switch-over is the "1x" wide lens.
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let normalization = (hasUltraWide && !isSingleLens && factors.count > 1) ? factors[1] : 1.0
        maxPinchZoomFactor = min(
            device.maxAvailableVideoZoomFactor,
            isSingleLens ? 5.0 : normalization * 10
        )

        let options = factors.enumerated().map { index, factor in
            ZoomOption(id: index, label: Self.zoomLabel(factor / normalization), zoomFactor: factor)
        }
        let defaultOption = options.first(where: { $0.zoomFactor == normalization }) ?? options[0]

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = defaultOption.zoomFactor
            device.unlockForConfiguration()
        } catch {
            // Zoom is best-effort; the device still works at its default factor.
        }

        DispatchQueue.main.async {
            self.zoomOptions = options.count > 1 ? options : []
            self.selectedZoomID = options.count > 1 ? defaultOption.id : nil
        }
    }

    private static func zoomLabel(_ displayFactor: CGFloat) -> String {
        let rounded = (displayFactor * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))x"
        }
        return String(format: "%.1fx", rounded)
    }

    /// Zooming is allowed while recording: virtual-device lens switches are
    /// seamless and don't change output dimensions.
    func setZoom(_ option: ZoomOption) {
        selectedZoomID = option.id
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let factor = min(
                    max(option.zoomFactor, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor
                )
                // Rate is in zoom doublings per second: 2.0 means 1x -> 2x
                // takes 0.5s, with the system easing the transition.
                device.ramp(toVideoZoomFactor: factor, withRate: 2.0)
                device.unlockForConfiguration()
            } catch {
                // Best-effort; ignore lock failures.
            }
        }
    }

    func pinchZoomBegan() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            if device.isRampingVideoZoom {
                do {
                    try device.lockForConfiguration()
                    device.cancelVideoZoomRamp()
                    device.unlockForConfiguration()
                } catch {
                    // Best-effort; the pinch still starts from the current factor.
                }
            }
            self.pinchStartZoomFactor = device.videoZoomFactor
        }
    }

    func pinchZoomChanged(scale: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            let target = min(
                max(self.pinchStartZoomFactor * scale, device.minAvailableVideoZoomFactor),
                self.maxPinchZoomFactor
            )
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
            } catch {
                return
            }
            // Highlight a pill only when the pinch lands on (near) a native step.
            DispatchQueue.main.async {
                self.selectedZoomID = self.zoomOptions.first {
                    abs($0.zoomFactor - target) / max(target, 0.01) < 0.03
                }?.id
            }
        }
    }

    // MARK: - Rotation

    /// Must run on the main thread. Recreated whenever the camera changes.
    private func makeRotationCoordinator() {
        guard let device = videoDeviceInput?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if let connection = self.previewLayer.connection,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    // MARK: - Controls (call from the main thread)

    func startRecording() {
        guard state == .idle, !isSwitchingCamera else { return }
        state = .recording
        // The capture angle is fixed for the whole clip; rotating mid-recording
        // would change buffer dimensions and break the writer.
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        writerQueue.async { [weak self] in
            self?.beginWriting(captureAngle: captureAngle)
        }
    }

    func pause() {
        guard state == .recording else { return }
        writerQueue.async { [weak self] in
            guard let self, self.writer != nil, !self.isStopping else { return }
            self.isPaused = true
            self.isResumePending = false
            DispatchQueue.main.async { self.state = .paused }
        }
    }

    func resume() {
        guard state == .paused else { return }
        writerQueue.async { [weak self] in
            guard let self, self.writer != nil, !self.isStopping else { return }
            self.isPaused = false
            self.isResumePending = true
            DispatchQueue.main.async {
                self.state = .recording
                self.sceneNumber += 1
            }
        }
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        state = .saving
        // When the stop comes from backgrounding, the finish/save pipeline is
        // all async I/O — hold a background task so iOS doesn't suspend us
        // mid-write and strand an unfinalized file.
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PauseCam.saveRecording") { [weak self] in
                self?.endBackgroundTaskIfNeeded()
            }
        }
        writerQueue.async { [weak self] in
            self?.finishWriting()
        }
    }

    /// Main thread only.
    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Camera switching is only allowed while idle: changing the input
    /// mid-recording changes buffer dimensions and breaks the asset writer.
    func flipCamera() {
        guard state == .idle, !isSwitchingCamera else { return }
        // Block recording until the swap finishes: beginWriting reads the video
        // connection and device, which must not race the session reconfiguration.
        isSwitchingCamera = true
        let targetFront = !isUsingFrontCamera
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let newCamera = Self.camera(for: targetFront ? .front : .back),
                  let newInput = try? AVCaptureDeviceInput(device: newCamera) else {
                DispatchQueue.main.async {
                    self.isSwitchingCamera = false
                    self.errorMessage = "That camera is unavailable."
                }
                return
            }
            self.session.beginConfiguration()
            let previousInput = self.videoDeviceInput
            if let previousInput {
                self.session.removeInput(previousInput)
            }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoDeviceInput = newInput
            } else if let previousInput, self.session.canAddInput(previousInput) {
                self.session.addInput(previousInput)
            }
            self.session.commitConfiguration()
            self.updateZoomOptions()
            DispatchQueue.main.async {
                self.isUsingFrontCamera = targetFront
                self.makeRotationCoordinator()
                self.isSwitchingCamera = false
            }
        }
    }

    /// `layerPoint` is in the preview layer's coordinate space. Continuous
    /// focus/exposure at the tapped point, with the exposure bias reset so the
    /// EV slider starts from neutral (stock-camera behavior).
    func focus(atLayerPoint layerPoint: CGPoint) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.setExposureTargetBias(0, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                // Focus is best-effort; ignore lock failures.
            }
        }
    }

    /// EV adjustment from the slider next to the focus square; clamped to the
    /// device's supported bias range.
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDeviceInput?.device else { return }
            let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                // Best-effort; ignore lock failures.
            }
        }
    }

    // MARK: - Writer lifecycle (writerQueue)

    private func beginWriting(captureAngle: CGFloat?) {
        guard writer == nil else { return }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PauseCam-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            if let captureAngle,
               let connection = videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(captureAngle) {
                connection.videoRotationAngle = captureAngle
            }

            var videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
            if videoSettings == nil, let device = videoDeviceInput?.device {
                let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(dimensions.width),
                    AVVideoHeightKey: Int(dimensions.height)
                ]
            }
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else { throw SetupError.cannotAddWriterInput }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if hasAudioOutput {
                let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }

            guard writer.startWriting() else {
                throw writer.error ?? SetupError.cannotAddWriterInput
            }

            self.writer = writer
            self.writerVideoInput = videoInput
            self.writerAudioInput = audioInput
            self.outputURL = url
            self.isWriterSessionStarted = false
            self.isPaused = false
            self.isResumePending = false
            self.isStopping = false
            self.timeOffset = .zero
            self.lastAdjustedVideoTime = nil
            self.lastAudioEndTime = nil
            self.lastPublishedSeconds = -1

            DispatchQueue.main.async {
                self.recordedSeconds = 0
                self.sceneNumber = 1
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .idle
                self.errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    private func finishWriting() {
        guard let writer, !isStopping else { return }
        isStopping = true

        guard isWriterSessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            cleanupWriter()
            DispatchQueue.main.async {
                self.state = .idle
                self.errorMessage = "Recording stopped before any video was captured."
                self.endBackgroundTaskIfNeeded()
            }
            return
        }

        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()

        guard let url = outputURL else {
            cleanupWriter()
            DispatchQueue.main.async {
                self.state = .idle
                self.endBackgroundTaskIfNeeded()
            }
            return
        }

        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status == .completed {
                self.saveToPhotos(url: url)
            } else {
                let message = writer.error?.localizedDescription ?? "Unknown writer error."
                // Hop back to the writer queue for cleanup to avoid races with
                // in-flight sample buffer callbacks.
                self.writerQueue.async {
                    self.cleanupWriter()
                    DispatchQueue.main.async {
                        self.state = .idle
                        self.errorMessage = "Recording failed: \(message)"
                        self.endBackgroundTaskIfNeeded()
                    }
                }
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.writerQueue.async {
                    self.cleanupWriter()
                    DispatchQueue.main.async {
                        self.state = .idle
                        self.errorMessage = "Photos access is denied, so the video could not be saved. Allow \"Add Photos Only\" for PauseCam in Settings."
                        self.endBackgroundTaskIfNeeded()
                    }
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                self.writerQueue.async {
                    if success {
                        // Photos has its own copy now; keep ours for the
                        // thumbnail button and in-app playback.
                        self.retainLastClip(from: url)
                    }
                    self.cleanupWriter()
                    DispatchQueue.main.async {
                        self.state = .idle
                        if success {
                            self.didSaveToPhotos = true
                        } else {
                            self.errorMessage = "Could not save to Photos: \(error?.localizedDescription ?? "unknown error")."
                        }
                        self.endBackgroundTaskIfNeeded()
                    }
                }
            }
        }
    }

    /// writerQueue only. Moves the finished clip into Caches as "the last clip"
    /// and refreshes the thumbnail.
    private func retainLastClip(from url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: Self.lastClipURL)
        do {
            try fileManager.moveItem(at: url, to: Self.lastClipURL)
        } catch {
            return
        }
        generateThumbnail(for: Self.lastClipURL)
    }

    private func generateThumbnail(for url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        generator.generateCGImageAsynchronously(for: .zero) { [weak self] cgImage, _, _ in
            guard let cgImage else { return }
            DispatchQueue.main.async {
                self?.lastClipThumbnail = UIImage(cgImage: cgImage)
            }
        }
    }

    /// writerQueue only. Deletes the temp file (Photos makes its own copy).
    private func cleanupWriter() {
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        outputURL = nil
        isWriterSessionStarted = false
        isPaused = false
        isResumePending = false
        isStopping = false
        timeOffset = .zero
        lastAdjustedVideoTime = nil
        lastAudioEndTime = nil
    }

    /// writerQueue only.
    private func handleWriterFailure() {
        guard !isStopping else { return }
        isStopping = true
        let message = writer?.error?.localizedDescription ?? "Unknown writer error."
        writer?.cancelWriting()
        cleanupWriter()
        DispatchQueue.main.async {
            self.state = .idle
            self.errorMessage = "Recording failed: \(message)"
            self.endBackgroundTaskIfNeeded()
        }
    }

    // MARK: - Sample handling (writerQueue)

    private func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard writer != nil, !isStopping else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer else { return }
        if writer.status == .failed {
            handleWriterFailure()
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Start the writer session on the FIRST VIDEO buffer only; audio arriving
        // before it is dropped so the file never opens with a video-less gap.
        if !isWriterSessionStarted {
            guard isVideo, !isPaused, writer.status == .writing else { return }
            writer.startSession(atSourceTime: pts)
            isWriterSessionStarted = true
            isResumePending = false
            sessionStartTime = pts
            lastRawVideoTime = pts
        }

        if isPaused { return }

        if isResumePending {
            // First buffer after resume: fold the paused gap into timeOffset.
            // The gap is measured video-to-video, and audio is dropped until the
            // offset is extended, so both tracks always shift by the same amount
            // and stay in sync.
            guard isVideo else { return }
            let gap = pts - lastRawVideoTime - lastVideoFrameDuration
            if gap.isValid, gap > .zero {
                timeOffset = timeOffset + gap
            }
            isResumePending = false
        }

        guard let input = isVideo ? writerVideoInput : writerAudioInput,
              input.isReadyForMoreMediaData else { return }

        guard let adjusted = offsettingTiming(of: sampleBuffer, by: timeOffset) else { return }
        let adjustedPTS = CMSampleBufferGetPresentationTimeStamp(adjusted)

        if isVideo {
            // Never append non-increasing video timestamps; that corrupts the writer.
            if let last = lastAdjustedVideoTime, adjustedPTS <= last { return }
        } else {
            // Drop audio that would overlap already-appended audio or precede the
            // session start (possible right around a resume boundary).
            if adjustedPTS < sessionStartTime { return }
            if let audioEnd = lastAudioEndTime, adjustedPTS < audioEnd { return }
        }

        guard input.append(adjusted) else {
            if writer.status == .failed {
                handleWriterFailure()
            }
            return
        }

        if isVideo {
            let delta = pts - lastRawVideoTime
            if delta.isValid, delta > .zero, delta.seconds < 0.5 {
                lastVideoFrameDuration = delta
            }
            lastRawVideoTime = pts
            lastAdjustedVideoTime = adjustedPTS
            publishRecordedDuration((adjustedPTS - sessionStartTime).seconds)
        } else {
            let duration = CMSampleBufferGetDuration(adjusted)
            lastAudioEndTime = duration.isValid && duration > .zero
                ? adjustedPTS + duration
                : adjustedPTS
        }
    }

    /// Returns a copy of `sampleBuffer` with all timestamps shifted back by
    /// `offset`, or the original buffer when the offset is zero.
    private func offsettingTiming(of sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        guard let timingInfos = try? sampleBuffer.sampleTimingInfos() else { return nil }
        let shifted = timingInfos.map { info in
            CMSampleTimingInfo(
                duration: info.duration,
                presentationTimeStamp: info.presentationTimeStamp - offset,
                decodeTimeStamp: info.decodeTimeStamp.isValid ? info.decodeTimeStamp - offset : info.decodeTimeStamp
            )
        }
        return try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: shifted)
    }

    /// Publishes the recorded duration to the UI, throttled to ~20 Hz.
    private func publishRecordedDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        guard seconds - lastPublishedSeconds >= 0.05 else { return }
        lastPublishedSeconds = seconds
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .recording else { return }
            self.recordedSeconds = seconds
        }
    }
}

// MARK: - Sample buffer delegates

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Both outputs deliver here on writerQueue.
        append(sampleBuffer, isVideo: output === videoOutput)
    }
}
