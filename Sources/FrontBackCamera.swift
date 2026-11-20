import AVFoundation
import Observation
import SwiftUI
import UIKit

/// 후면(메인 1x)과 전면 카메라를 동시에 켜고 파일 두 개로 따로 저장한다(#3).
/// - `<yyMMdd-HHmmss>_back.mov`: 후면. 기기가 허용하는 가장 큰 16:9(4K 우선, 안 되면 1080p)
/// - `<yyMMdd-HHmmss>_front.mov`: 전면 16:9, 좌우 반전(미리보기와 같게)
/// 두 파일은 같은 시작 시각과 같은 오디오를 쓴다. 편집기에서 화면 속 화면, 분할, 컷 전환을 자유롭게 하려고 합치지 않는다.
@Observable
final class FrontBackCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    private(set) var isRecording = false
    private(set) var recordingStarted: Date?
    private(set) var status = "준비 중"
    private(set) var formatText = "-"
    private(set) var audioLevel: Float = 0
    private(set) var audioInput = "-"

    @ObservationIgnored let session = AVCaptureMultiCamSession()
    @ObservationIgnored let backPreview: AVCaptureVideoPreviewLayer
    @ObservationIgnored let frontPreview: AVCaptureVideoPreviewLayer

    @ObservationIgnored private let queue = DispatchQueue(label: "fishcut.camera.frontback")
    @ObservationIgnored private let backOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let frontOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let audioOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored private var backDevice: AVCaptureDevice?
    @ObservationIgnored private var frontDevice: AVCaptureDevice?
    @ObservationIgnored private var backConnection: AVCaptureConnection?
    @ObservationIgnored private var frontConnection: AVCaptureConnection?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var audioSettings: [String: Any]?

    // 아래는 모두 `queue`에서만 만진다.
    @ObservationIgnored private var back: Track?
    @ObservationIgnored private var front: Track?
    @ObservationIgnored private var startTime: CMTime?

    private struct Track {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
    }

    override init() {
        backPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        frontPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        backPreview.videoGravity = .resizeAspect
        frontPreview.videoGravity = .resizeAspectFill
        super.init()
    }

    // MARK: 시작과 정지

    func start() async {
        guard Self.isSupported else { return setStatus(CameraError.multiCamUnsupported.localizedDescription) }
        guard await AVCaptureDevice.requestAccess(for: .video),
              await AVCaptureDevice.requestAccess(for: .audio)
        else { return setStatus("카메라/마이크 권한이 필요합니다") }
        queue.async { [self] in
            do {
                if !configured {
                    try configure()
                    configured = true
                }
                session.startRunning()
                setStatus("대기")
            } catch {
                setStatus("설정 실패: \(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if back != nil { stopRecording() }
                if session.isRunning { session.stopRunning() }
                done.resume()
            }
        }
    }

    // MARK: 구성

    private func configure() throws {
        let audio = AVAudioSession.sharedInstance()
        session.automaticallyConfiguresApplicationAudioSession = false
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [])
        try audio.setActive(true)
        if let usb = audio.availableInputs?.first(where: { $0.portType == .usbAudio }) { try? audio.setPreferredInput(usb) }
        let name = audio.currentRoute.inputs.first.map { "\($0.portName) (\($0.portType == .usbAudio ? "USB" : "내장"))" } ?? "-"
        DispatchQueue.main.async { self.audioInput = name }

        guard let backCam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let frontCam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let mic = AVCaptureDevice.default(for: .audio)
        else { throw CameraError.noDevice }
        backDevice = backCam
        frontDevice = frontCam

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let backIn = try AVCaptureDeviceInput(device: backCam)
        let frontIn = try AVCaptureDeviceInput(device: frontCam)
        let micIn = try AVCaptureDeviceInput(device: mic)
        for input in [backIn, frontIn, micIn] {
            guard session.canAddInput(input) else { throw CameraError.noDevice }
            session.addInputWithNoConnections(input)
        }
        for output in [backOutput, frontOutput] as [AVCaptureOutput] + [audioOutput] {
            guard session.canAddOutput(output) else { throw CameraError.noDevice }
            session.addOutputWithNoConnections(output)
        }
        for output in [backOutput, frontOutput] {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: queue)
        }
        audioOutput.setSampleBufferDelegate(self, queue: queue)

        guard let backPort = backIn.ports(for: .video, sourceDeviceType: backCam.deviceType, sourceDevicePosition: .back).first,
              let frontPort = frontIn.ports(for: .video, sourceDeviceType: frontCam.deviceType, sourceDevicePosition: .front).first,
              let micPort = micIn.ports.first(where: { $0.mediaType == .audio })
        else { throw CameraError.noDevice }

        let bc = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
        let fc = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        let ac = AVCaptureConnection(inputPorts: [micPort], output: audioOutput)
        let bp = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: backPreview)
        let fp = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: frontPreview)
        for c in [bc, fc, ac, bp, fp] {
            guard session.canAddConnection(c) else { throw CameraError.noDevice }
            session.addConnection(c)
        }
        // 화면은 LandscapeRight 고정. 후면은 0도, 전면은 센서가 반대로 붙어 있어 180도여야 바로 선다(2026-11-20 iPhone 16 Pro에서 0도는 거꾸로).
        for c in [bc, bp] where c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }
        for c in [fc, fp] where c.isVideoRotationAngleSupported(180) { c.videoRotationAngle = 180 }
        if fc.isVideoMirroringSupported {
            fc.automaticallyAdjustsVideoMirroring = false
            fc.isVideoMirrored = true
        }
        backConnection = bc
        frontConnection = fc

        // 4K 후면 + 1080p 전면부터 시도하고, 하드웨어 한도(hardwareCost > 1)를 넘으면 낮춘다.
        let plans: [(Int32, Int32)] = [(3840, 1920), (1920, 1920), (1920, 1280), (1280, 1280)]
        var chosen: (CMVideoDimensions, CMVideoDimensions)?
        for (bw, fw) in plans {
            guard let bf = Self.multiCamFormat(backCam, width: bw), let ff = Self.multiCamFormat(frontCam, width: fw) else { continue }
            try Self.apply(bf, to: backCam)
            try Self.apply(ff, to: frontCam)
            if session.hardwareCost <= 1 {
                chosen = (CMVideoFormatDescriptionGetDimensions(bf.formatDescription),
                          CMVideoFormatDescriptionGetDimensions(ff.formatDescription))
                break
            }
        }
        guard let chosen else { throw CameraError.noFormat }
        let text = "후면 \(chosen.0.width)×\(chosen.0.height) · 전면 \(chosen.1.width)×\(chosen.1.height) · 30"
        DispatchQueue.main.async { self.formatText = text }
        audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
    }

    /// MultiCam에서 쓸 수 있는 16:9, 30fps 형식 중 주어진 너비
    private static func multiCamFormat(_ device: AVCaptureDevice, width: Int32) -> AVCaptureDevice.Format? {
        device.formats.first { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return f.isMultiCamSupported && d.width == width && d.width * 9 == d.height * 16
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
    }

    private static func apply(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    // MARK: 녹화

    func toggleRecording() {
        queue.async { [self] in
            if back == nil { startRecording() } else { stopRecording() }
        }
    }

    private func startRecording() {
        guard let bd = backDevice, let fd = frontDevice else { return }
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let f = DateFormatter()
            f.dateFormat = "yyMMdd-HHmmss"
            let stamp = f.string(from: Date())
            let bs = CMVideoFormatDescriptionGetDimensions(bd.activeFormat.formatDescription)
            let fs = CMVideoFormatDescriptionGetDimensions(fd.activeFormat.formatDescription)
            back = try makeTrack(docs.appending(path: "\(stamp)_back.mov"), width: Int(bs.width), height: Int(bs.height),
                                 bitRate: bs.width >= 3840 ? 60_000_000 : 20_000_000)
            front = try makeTrack(docs.appending(path: "\(stamp)_front.mov"), width: Int(fs.width), height: Int(fs.height),
                                  bitRate: 16_000_000)
            for t in [back!, front!] { t.writer.startWriting() }
            startTime = nil
            setStatus("녹화 중", recording: true)
        } catch {
            back = nil
            front = nil
            setStatus("녹화 시작 실패: \(error.localizedDescription)")
        }
    }

    private func makeTrack(_ url: URL, width: Int, height: Int, bitRate: Int) throws -> Track {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        return Track(writer: writer, video: video, audio: audio)
    }

    private func stopRecording() {
        guard let b = back, let f = front else { return }
        back = nil
        front = nil
        let started = startTime != nil
        startTime = nil
        setStatus("저장 중", recording: false)
        let group = DispatchGroup()
        for t in [b, f] {
            t.video.markAsFinished()
            t.audio.markAsFinished()
            group.enter()
            if started {
                t.writer.finishWriting { group.leave() }
            } else {
                t.writer.cancelWriting()
                group.leave()
            }
        }
        group.notify(queue: queue) { [self] in
            let ok = started && b.writer.status == .completed && f.writer.status == .completed
            let err = b.writer.error?.localizedDescription ?? f.writer.error?.localizedDescription ?? "프레임 없음"
            setStatus(ok ? "저장됨 \(b.writer.outputURL.lastPathComponent) 외 1개" : "저장 실패: \(err)")
        }
    }

    // MARK: 샘플 버퍼 (세 출력이 같은 큐로 들어온다)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let b = back, let f = front else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output === audioOutput {
            guard let start = startTime, pts >= start else { return }
            for t in [b, f] where t.audio.isReadyForMoreMediaData { t.audio.append(sampleBuffer) }
            return
        }
        // 두 파일의 시작 시각은 어느 카메라든 첫 영상 프레임으로 같게 잡는다.
        if startTime == nil {
            startTime = pts
            b.writer.startSession(atSourceTime: pts)
            f.writer.startSession(atSourceTime: pts)
        }
        guard let start = startTime, pts >= start else { return }
        let track = output === backOutput ? b : f
        if track.video.isReadyForMoreMediaData { track.video.append(sampleBuffer) }
    }

    /// 화면이 0.1초마다 부른다.
    func poll() {
        if let channel = audioOutput.connection(with: .audio)?.audioChannels.first {
            audioLevel = min(max((channel.averagePowerLevel + 50) / 50, 0), 1)
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
}

/// MultiCam 세션의 미리보기 레이어를 그대로 보여 주는 뷰
struct LayerView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    let label: String
    let identifier: String

    final class Host: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.layer.addSublayer(layer)
        v.hosted = layer
        v.isAccessibilityElement = true
        v.accessibilityLabel = label
        v.accessibilityIdentifier = identifier
        return v
    }

    func updateUIView(_ uiView: Host, context: Context) {}
}
