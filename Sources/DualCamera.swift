import AVFoundation
import CoreImage
import Observation

/// 메인(광각 24mm) 렌즈 하나로 4K를 받아 두 파일을 동시에 쓴다.
/// - 가로: 3840x2160 원본 프레임 그대로
/// - 세로: 같은 프레임의 가운데 1215x2160을 잘라 1080x1920으로 줄인 본
/// 두 파일은 같은 샘플 버퍼(영상 프레임, 오디오)에서 나오므로 같은 시각, 색, 소리를 가진다.
@Observable
final class DualCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sourceSize = CGSize(width: 3840, height: 2160)
    static let cropSize = CGSize(width: 1215, height: 2160)
    static let portraitSize = CGSize(width: 1080, height: 1920)

    let session = AVCaptureSession()
    private(set) var isRecording = false
    private(set) var recordingStarted: Date?
    private(set) var status = "준비 중"
    private(set) var audioInput = "-"
    private(set) var audioInputs: [AudioInputOption] = []
    private(set) var readout = DeviceReadout()
    /// 0...1. 입력 소리 크기(-50dB...0dB)
    private(set) var audioLevel: Float = 0
    private(set) var availableBytes: Int64?
    var settings = CameraSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            let s = settings, old = oldValue
            queue.async { [self] in applyDevice(s, previous: old) }
        }
    }

    /// 4K 두 파일(60 + 24 Mbps)과 오디오를 합친 대략의 1분 용량
    static let bytesPerMinute: Int64 = 640_000_000

    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var pollCount = 0
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private let queue = DispatchQueue(label: "fishcut.camera.capture")
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let audioOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored private let ciContext = CIContext()

    // 아래는 모두 `queue`에서만 만진다.
    @ObservationIgnored private var landscape: Writer?
    @ObservationIgnored private var portrait: Writer?
    @ObservationIgnored private var portraitAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored private var startTime: CMTime?
    @ObservationIgnored private var audioSettings: [String: Any]?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var lockedWhiteBalanceForRecording = false

    private struct Writer {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
    }

    // MARK: 시작

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video),
              await AVCaptureDevice.requestAccess(for: .audio)
        else { return setStatus("카메라/마이크 권한이 필요합니다") }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshAudioInput() }
        }
        let initial = settings
        queue.async { [self] in
            do {
                if !configured {
                    try configure(mic: initial.micUID)
                    configured = true
                }
                applyDevice(initial, previous: nil)
                session.startRunning()
                setStatus("대기")
            } catch {
                setStatus("설정 실패: \(error.localizedDescription)")
            }
        }
    }

    /// 다른 모드로 바꿀 때 카메라를 놓는다. 녹화 중이면 먼저 저장한다.
    func stop() async {
        let s = settings
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if landscape != nil { stopRecording(s) }
                if session.isRunning { session.stopRunning() }
                done.resume()
            }
        }
    }

    private func configure(mic: String?) throws {
        // 오디오 세션은 직접 잡는다. 외부 USB-C 마이크가 있으면 우선 쓴다.
        session.automaticallyConfiguresApplicationAudioSession = false
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [])
        try audio.setActive(true)
        applyMic(mic)
        refreshAudioInput()

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // 가상 장치(렌즈 자동 전환)가 아니라 광각 물리 렌즈를 고른다.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let mic = AVCaptureDevice.default(for: .audio)
        else { throw CameraError.noDevice }
        try camera.lockForConfiguration()
        let format = camera.formats.first { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 3840 && d.height == 2160
                && CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 && $0.minFrameRate <= 24 }
        }
        guard let format else { throw CameraError.noFormat }
        camera.activeFormat = format
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        camera.videoZoomFactor = 1
        camera.unlockForConfiguration()
        device = camera

        session.addInput(try AVCaptureDeviceInput(device: camera))
        session.addInput(try AVCaptureDeviceInput(device: mic))

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else { throw CameraError.noDevice }
        session.addOutput(videoOutput)
        session.addOutput(audioOutput)
        // 가로 고정 UI(LandscapeRight)와 센서 방향이 같아 회전이 필요 없다.
        if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }
        session.commitConfiguration()
        audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
    }

    private static func portLabel(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .usbAudio: "USB"
        case .builtInMic: "내장"
        case .headsetMic: "유선"
        case .bluetoothHFP: "블루투스"
        default: type.rawValue
        }
    }

    private func refreshAudioInput() {
        let audio = AVAudioSession.sharedInstance()
        let input = audio.currentRoute.inputs.first
        let text = input.map { "\($0.portName) (\(Self.portLabel($0.portType)))" } ?? "-"
        let options = (audio.availableInputs ?? []).map {
            AudioInputOption(id: $0.uid, name: "\($0.portName) (\(Self.portLabel($0.portType)))")
        }
        DispatchQueue.main.async {
            self.audioInput = text
            self.audioInputs = options
        }
    }

    /// nil이면 USB 마이크 우선, 없으면 시스템 기본(내장)
    private func applyMic(_ uid: String?) {
        let audio = AVAudioSession.sharedInstance()
        let inputs = audio.availableInputs ?? []
        let pick = uid.flatMap { id in inputs.first { $0.uid == id } } ?? inputs.first { $0.portType == .usbAudio }
        try? audio.setPreferredInput(pick)
    }

    // MARK: 촬영 설정 (모두 `queue`에서)

    private func applyDevice(_ s: CameraSettings, previous: CameraSettings?) {
        if previous?.micUID != s.micUID, previous != nil {
            applyMic(s.micUID)
            refreshAudioInput()
        }
        guard let d = device else { return }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            let frame = CMTime(value: 1, timescale: CMTimeScale(s.fps))
            if d.activeVideoMinFrameDuration != frame || d.activeVideoMaxFrameDuration != frame {
                d.activeVideoMinFrameDuration = frame
                d.activeVideoMaxFrameDuration = frame
            }
            if s.exposureLocked {
                // 셔터 180도: 노출 시간 = 프레임 길이의 절반
                let f = d.activeFormat
                let duration = CMTimeClampToRange(CMTime(value: 1, timescale: CMTimeScale(s.fps * 2)),
                                                  range: CMTimeRange(start: f.minExposureDuration, end: f.maxExposureDuration))
                d.setExposureModeCustom(duration: duration, iso: min(max(s.iso, f.minISO), f.maxISO))
            } else if d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
            if let kelvin = s.kelvin {
                lockWhiteBalance(d, kelvin: kelvin)
            } else if !lockedWhiteBalanceForRecording, d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if s.focusLocked {
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
            } else if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
        } catch {
            setStatus("설정 실패: \(error.localizedDescription)")
        }
        if let c = videoOutput.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = s.stabilization ? .standard : .off
        }
    }

    private func lockWhiteBalance(_ d: AVCaptureDevice, kelvin: Int) {
        guard d.isWhiteBalanceModeSupported(.locked) else { return }
        d.setWhiteBalanceModeLocked(with: Self.clamped(d.deviceWhiteBalanceGains(for: .init(temperature: Float(kelvin), tint: 0)), d))
    }

    /// 화이트 밸런스 게인은 1...maxWhiteBalanceGain 밖이면 변환과 잠금이 예외를 던진다.
    private static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains, _ d: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains
        let hi = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), hi)
        g.greenGain = min(max(g.greenGain, 1), hi)
        g.blueGain = min(max(g.blueGain, 1), hi)
        return g
    }

    /// 지금 기기 색온도(K). 값이 이상하면 nil
    private static func currentKelvin(_ d: AVCaptureDevice) -> Float? {
        let t = d.temperatureAndTintValues(for: clamped(d.deviceWhiteBalanceGains, d)).temperature
        return t.isFinite && t > 0 ? t : nil
    }

    /// 지금 자동 노출의 밝기를 유지하면서 셔터를 180도로 바꾸고 ISO를 고정한다.
    func lockExposureAtCurrent() {
        guard let d = device else { return settings.exposureLocked = true }
        let target = 1 / Double(settings.fps * 2)
        let iso = Float(Double(d.iso) * d.exposureDuration.seconds / target)
        guard iso.isFinite, iso > 0 else { return }
        var s = settings
        s.iso = CameraSettings.nearestISO(iso, min: d.activeFormat.minISO, max: d.activeFormat.maxISO)
        s.exposureLocked = true
        settings = s
    }

    func stepISO(_ direction: Int) {
        guard let d = device else { return }
        let steps = CameraSettings.isoSteps(min: d.activeFormat.minISO, max: d.activeFormat.maxISO)
        let current = CameraSettings.nearestISO(settings.iso, min: d.activeFormat.minISO, max: d.activeFormat.maxISO)
        guard let i = steps.firstIndex(of: current) else { return }
        settings.iso = steps[min(max(i + direction, 0), steps.count - 1)]
    }

    var isoRange: ClosedRange<Float>? {
        device.map { $0.activeFormat.minISO...$0.activeFormat.maxISO }
    }

    /// 지금 자동 색온도 값으로 고정한다(100K 단위).
    func lockWhiteBalanceAtCurrent() {
        guard let d = device, let t = Self.currentKelvin(d) else { return }
        settings.kelvin = Int((t / 100).rounded()) * 100
    }

    /// 미리보기에서 탭한 위치(기기 좌표 0...1)에 초점과 노출을 맞춘다.
    func focus(at point: CGPoint) {
        let locked = settings.focusLocked
        queue.async { [self] in
            guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = point
                let mode: AVCaptureDevice.FocusMode = locked ? .autoFocus : .continuousAutoFocus
                if d.isFocusModeSupported(mode) { d.focusMode = mode }
            }
            if d.exposureMode != .custom, d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = point
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// 화면이 0.1초마다 부른다. 기기가 실제로 쓰는 값, 소리 크기, 남은 용량을 읽는다.
    func poll() {
        if let d = device {
            let seconds = d.exposureDuration.seconds
            let r = DeviceReadout(
                iso: d.iso.isFinite ? Int(d.iso.rounded()) : 0,
                exposureSeconds: seconds.isFinite ? seconds : 0,
                kelvin: Self.currentKelvin(d).map { Int(($0 / 100).rounded()) * 100 } ?? 0,
                exposureLocked: d.exposureMode == .custom || d.exposureMode == .locked,
                whiteBalanceLocked: d.whiteBalanceMode == .locked,
                focusLocked: d.focusMode == .locked
            )
            if r != readout { readout = r }
        }
        if let channel = audioOutput.connection(with: .audio)?.audioChannels.first {
            audioLevel = min(max((channel.averagePowerLevel + 50) / 50, 0), 1)
        }
        if pollCount % 20 == 0 {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            availableBytes = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        pollCount += 1
    }

    // MARK: 녹화

    func toggleRecording() {
        let s = settings
        queue.async { [self] in
            if landscape == nil { startRecording(s) } else { stopRecording(s) }
        }
    }

    private func startRecording(_ s: CameraSettings) {
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let f = DateFormatter()
            f.dateFormat = "yyMMdd-HHmmss"
            let stamp = f.string(from: Date())
            landscape = try makeWriter(url: docs.appending(path: "\(stamp)_16x9.mov"), size: Self.sourceSize, bitRate: 60_000_000, fps: s.fps)
            portrait = try makeWriter(url: docs.appending(path: "\(stamp)_9x16.mov"), size: Self.portraitSize, bitRate: 24_000_000, fps: s.fps)
            portraitAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: portrait!.video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey as String: Int(Self.portraitSize.width),
                    kCVPixelBufferHeightKey as String: Int(Self.portraitSize.height),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ])
            for w in [landscape!, portrait!] { w.writer.startWriting() }
            // 세션 시작 시각은 첫 영상 프레임에서 잡는다(captureOutput).
            startTime = nil
            frameCount = 0
            if s.kelvin == nil, s.lockWhiteBalanceOnRecord, let d = device, d.isWhiteBalanceModeSupported(.locked),
               (try? d.lockForConfiguration()) != nil {
                d.whiteBalanceMode = .locked
                d.unlockForConfiguration()
                lockedWhiteBalanceForRecording = true
            }
            setStatus("녹화 중", recording: true)
        } catch {
            landscape = nil
            portrait = nil
            setStatus("녹화 시작 실패: \(error.localizedDescription)")
        }
    }

    private func makeWriter(url: URL, size: CGSize, bitRate: Int, fps: Int) throws -> Writer {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        return Writer(writer: writer, video: video, audio: audio)
    }

    private func stopRecording(_ s: CameraSettings) {
        guard let l = landscape, let p = portrait else { return }
        if lockedWhiteBalanceForRecording {
            lockedWhiteBalanceForRecording = false
            if s.kelvin == nil { applyDevice(s, previous: s) }
        }
        landscape = nil
        portrait = nil
        portraitAdaptor = nil
        let started = startTime != nil
        startTime = nil
        setStatus("저장 중", recording: false)
        let group = DispatchGroup()
        for w in [l, p] {
            w.video.markAsFinished()
            w.audio.markAsFinished()
            group.enter()
            if started {
                w.writer.finishWriting { group.leave() }
            } else {
                w.writer.cancelWriting()
                group.leave()
            }
        }
        group.notify(queue: queue) { [self] in
            let ok = started && l.writer.status == .completed && p.writer.status == .completed
            setStatus(ok ? "저장됨 \(l.writer.outputURL.lastPathComponent)" : "저장 실패: \(l.writer.error?.localizedDescription ?? p.writer.error?.localizedDescription ?? "프레임 없음")")
        }
    }

    private func setStatus(_ text: String, recording: Bool? = nil) {
        DispatchQueue.main.async {
            self.status = text
            if let recording {
                self.isRecording = recording
                self.recordingStarted = recording ? Date() : nil
            }
        }
    }

    // MARK: 샘플 버퍼 (영상과 오디오가 같은 큐로 들어온다)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let l = landscape, let p = portrait, let adaptor = portraitAdaptor else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output === videoOutput {
            if startTime == nil {
                startTime = pts
                l.writer.startSession(atSourceTime: pts)
                p.writer.startSession(atSourceTime: pts)
            }
            guard l.video.isReadyForMoreMediaData, p.video.isReadyForMoreMediaData,
                  let src = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let pool = adaptor.pixelBufferPool
            else { return }
            var dst: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
            guard let dst else { return }
            // 가운데 1215x2160(왼쪽 1312px, 0.5px 치우침)을 잘라 1080x1920으로 줄인다.
            let cropX = ((Self.sourceSize.width - Self.cropSize.width) / 2).rounded(.down)
            let scale = Self.portraitSize.height / Self.cropSize.height
            let image = CIImage(cvPixelBuffer: src)
                .cropped(to: CGRect(origin: CGPoint(x: cropX, y: 0), size: Self.cropSize))
                // 먼저 원점으로 옮기고 나서 줄인다. `translation.scaledBy`는 줄인 뒤 옮겨서 146px 밀리고 오른쪽이 빈다.
                .transformed(by: CGAffineTransform(translationX: -cropX, y: 0))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            ciContext.render(image, to: dst, bounds: CGRect(origin: .zero, size: Self.portraitSize),
                             colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            CVBufferPropagateAttachments(src, dst)
            l.video.append(sampleBuffer)
            adaptor.append(dst, withPresentationTime: pts)
            frameCount += 1
        } else if let start = startTime, pts >= start {
            if l.audio.isReadyForMoreMediaData, p.audio.isReadyForMoreMediaData {
                l.audio.append(sampleBuffer)
                p.audio.append(sampleBuffer)
            }
        }
    }
}

enum CameraError: LocalizedError {
    case noDevice, noFormat, multiCamUnsupported
    var errorDescription: String? {
        switch self {
        case .noDevice: "카메라나 마이크를 열 수 없습니다"
        case .noFormat: "4K 24/30fps SDR 형식이 없습니다"
        case .multiCamUnsupported: "이 기기는 전후면 동시 촬영을 지원하지 않습니다"
        }
    }
}
