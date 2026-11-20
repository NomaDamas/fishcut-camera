import AVFoundation
import SwiftUI

/// 촬영 모드. 둘 다 가로로 들고 찍는다.
enum CaptureMode: String, CaseIterable, Identifiable {
    /// 후면 1x 하나로 16:9와 9:16을 동시에 (#1)
    case dualFormat
    /// 후면과 전면을 동시에, 파일 두 개 (#3)
    case frontBack

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dualFormat: "가로+세로"
        case .frontBack: "전후면"
        }
    }
}

/// 가로 고정 촬영 화면. 미리보기 가운데(9:16 틀 안)에는 글자를 두지 않는다.
/// 왼쪽: 마이크, 소리 크기, (전후면 모드) 전면 미리보기, 모드 선택. 오른쪽: 상태 칩, 녹화 버튼과 타이머, 설정.
struct ContentView: View {
    @State private var camera = DualCamera()
    @State private var frontBack = FrontBackCamera()
    @State private var level = LevelMeter()
    @State private var showSettings = false
    @State private var focusMark: CGPoint?
    @AppStorage("captureMode") private var mode: CaptureMode = .dualFormat

    private var isRecording: Bool { mode == .dualFormat ? camera.isRecording : frontBack.isRecording }
    private var recordingStarted: Date? { mode == .dualFormat ? camera.recordingStarted : frontBack.recordingStarted }
    private var status: String { mode == .dualFormat ? camera.status : frontBack.status }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch mode {
            case .dualFormat:
                PreviewView(session: camera.session) { viewPoint, devicePoint in
                    camera.focus(at: devicePoint)
                    withAnimation(.snappy) { focusMark = viewPoint }
                }
                .ignoresSafeArea()
                if camera.settings.showGrid { GridOverlay(cropThirds: true).ignoresSafeArea() }
                CropGuide().ignoresSafeArea()
            case .frontBack:
                LayerView(layer: frontBack.backPreview, label: "후면 미리보기", identifier: "preview.back")
                    .ignoresSafeArea()
                if camera.settings.showGrid { GridOverlay(cropThirds: false).ignoresSafeArea() }
            }
            if camera.settings.showLevel && level.available { LevelOverlay(roll: level.roll) }
            if let focusMark { FocusMark(point: focusMark) { self.focusMark = nil }.ignoresSafeArea() }
            hud
            if isRecording {
                Rectangle()
                    .strokeBorder(.red, lineWidth: 3)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // 카메라는 한 세션만 쥘 수 있어 다른 모드를 먼저 끄고 켠다.
        .task(id: mode) {
            switch mode {
            case .dualFormat:
                await frontBack.stop()
                await camera.start()
            case .frontBack:
                await camera.stop()
                await frontBack.start()
            }
        }
        .task {
            while !Task.isCancelled {
                camera.poll()
                if mode == .frontBack { frontBack.poll() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            level.start()
        }
        .onDisappear { level.stop() }
        .onChange(of: isRecording) { _, recording in
            AccessibilityNotification.Announcement(recording ? "녹화 시작" : "녹화 정지").post()
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(camera: camera) }
    }

    private var hud: some View {
        GeometryReader { geo in
            let side = mode == .dualFormat ? CropGuide.sideWidth(in: geo.size) : 270
            let inset = geo.safeAreaInsets
            HStack(spacing: 0) {
                leftColumn(width: side - inset.leading - 24)
                    .padding(.leading, inset.leading + 12)
                    .frame(width: side, alignment: .leading)
                Spacer(minLength: 0)
                rightColumn
                    .padding(.trailing, inset.trailing + 12)
                    .frame(width: max(side, 230), alignment: .trailing)
            }
            .padding(.vertical, 12)
        }
        .ignoresSafeArea()
        .animation(.snappy, value: isRecording)
    }

    private func leftColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusChip(id: "mic", title: "마이크", value: mode == .dualFormat ? camera.audioInput : frontBack.audioInput, icon: "mic.fill")
            AudioMeter(level: mode == .dualFormat ? camera.audioLevel : frontBack.audioLevel)
                .frame(width: 10)
                .frame(minHeight: 50, maxHeight: 160)
            Spacer(minLength: 0)
            if mode == .frontBack {
                LayerView(layer: frontBack.frontPreview, label: "전면 미리보기", identifier: "preview.front")
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: min(width, 180))
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.6), lineWidth: 1))
            }
            Picker("촬영 모드", selection: $mode) {
                ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: min(width, 200))
            .disabled(isRecording)
            .accessibilityLabel("촬영 모드")
            .accessibilityIdentifier("hud.mode")
            if !status.isEmpty {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("상태")
                    .accessibilityValue(status)
                    .accessibilityIdentifier("hud.status")
            }
        }
    }

    private var rightColumn: some View {
        HStack(alignment: .center, spacing: 16) {
            chips
            // 녹화 버튼은 오른손 엄지가 닿는 세로 가운데, 설정은 아래 구석
            ZStack {
                VStack(spacing: 10) {
                    RecordButton(isRecording: isRecording,
                                 action: mode == .dualFormat ? camera.toggleRecording : frontBack.toggleRecording)
                    RecordTimer(started: recordingStarted)
                }
                .offset(y: 16)
                VStack {
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(isRecording)
                    .accessibilityLabel("촬영 설정")
                    .accessibilityIdentifier("hud.settings")
                }
            }
            .frame(width: 80)
        }
    }

    @ViewBuilder private var chips: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(alignment: .trailing, spacing: 6) {
                switch mode {
                case .dualFormat: dualFormatChips
                case .frontBack:
                    StatusChip(id: "format", title: "형식", value: frontBack.formatText)
                }
                StatusChip(id: "storage", title: "남은 용량", value: storageText, spoken: storageSpoken)
            }
        }
    }

    @ViewBuilder private var dualFormatChips: some View {
        let r = camera.readout
        let s = camera.settings
        let angle = r.shutterAngle(fps: s.fps)
        let is180 = abs(angle - 180) < 5
        StatusChip(id: "format", title: "형식", value: "4K \(s.fps) · SDR")
        StatusChip(id: "shutter", title: "셔터",
                   value: r.shutterDenominator == 0 ? "-" : is180 ? "180°" : "1/\(r.shutterDenominator)",
                   locked: r.exposureLocked, good: r.exposureLocked && is180,
                   spoken: r.shutterDenominator == 0 ? "알 수 없음" : is180 ? "180도, 1/\(r.shutterDenominator)초" : "1/\(r.shutterDenominator)초")
        StatusChip(id: "iso", title: "ISO", value: r.iso == 0 ? "ISO -" : "ISO \(r.iso)", locked: r.exposureLocked)
        StatusChip(id: "wb", title: "색온도", value: r.kelvin == 0 ? "-K" : "\(r.kelvin)K", locked: r.whiteBalanceLocked)
        StatusChip(id: "focus", title: "초점", value: "AF", locked: r.focusLocked)
    }

    private var storageText: String {
        guard let b = camera.availableBytes else { return "-" }
        return "\(b / 1_000_000_000)GB · \(b / DualCamera.bytesPerMinute)분"
    }

    private var storageSpoken: String {
        guard let b = camera.availableBytes else { return "알 수 없음" }
        return "\(b / 1_000_000_000)기가바이트, 약 \(b / DualCamera.bytesPerMinute)분 녹화 가능"
    }
}

/// 16:9 미리보기 위에 9:16 잘림 영역(가운데 1215/3840)만 밝게 두고 양옆을 어둡게 한다.
struct CropGuide: View {
    var body: some View {
        GeometryReader { geo in
            let video = Self.videoRect(in: geo.size)
            let crop = Self.cropRect(in: geo.size)
            Path { p in
                p.addRect(video)
                p.addRect(crop)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(.yellow, lineWidth: 1.5)
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("9:16 세로본 영역")
        .accessibilityValue("화면 가운데 \(Int(DualCamera.cropSize.width / DualCamera.sourceSize.width * 100))퍼센트 너비")
        .accessibilityIdentifier("guide.crop")
    }

    /// 화면 안에서 16:9 영상이 그려지는 영역(미리보기는 resizeAspect)
    static func videoRect(in size: CGSize) -> CGRect {
        fit(CGSize(width: 16, height: 9), in: size)
    }

    /// 화면 안에서 9:16 세로본으로 잘리는 영역
    static func cropRect(in size: CGSize) -> CGRect {
        let video = videoRect(in: size)
        let w = video.width * DualCamera.cropSize.width / DualCamera.sourceSize.width
        return CGRect(x: video.midX - w / 2, y: video.minY, width: w, height: video.height)
    }

    /// 화면에서 9:16 틀 바깥 한쪽의 너비
    static func sideWidth(in size: CGSize) -> CGFloat {
        (size.width - cropRect(in: size).width) / 2
    }

    private static func fit(_ ratio: CGSize, in box: CGSize) -> CGRect {
        let scale = min(box.width / ratio.width, box.height / ratio.height)
        let s = CGSize(width: ratio.width * scale, height: ratio.height * scale)
        return CGRect(x: (box.width - s.width) / 2, y: (box.height - s.height) / 2, width: s.width, height: s.height)
    }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// (화면 좌표, 기기 좌표 0...1)
    let onTap: (CGPoint, CGPoint) -> Void

    final class Layer: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint, CGPoint) -> Void)?

        /// 미리보기 연결은 기본 90도(세로)라 화면 고정 방향(가로)인 0도로 맞춘다.
        /// 연결은 세션 구성이 끝나야 생기므로 레이아웃 때마다 확인한다.
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = preview.connection, c.videoRotationAngle != 0, c.isVideoRotationAngleSupported(0) {
                c.videoRotationAngle = 0
            }
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            onTap?(p, preview.captureDevicePointConverted(fromLayerPoint: p))
        }

        /// VoiceOver 두 번 탭: 가운데에 초점
        override func accessibilityActivate() -> Bool {
            onTap?(CGPoint(x: bounds.midX, y: bounds.midY), CGPoint(x: 0.5, y: 0.5))
            return true
        }
    }

    func makeUIView(context: Context) -> Layer {
        let view = Layer()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(Layer.tapped(_:))))
        view.isAccessibilityElement = true
        view.accessibilityLabel = "카메라 미리보기"
        view.accessibilityHint = "두 번 탭하면 가운데에 초점과 노출을 맞춥니다"
        view.accessibilityIdentifier = "preview"
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: Layer, context: Context) {
        uiView.onTap = onTap
        uiView.setNeedsLayout()
    }
}
