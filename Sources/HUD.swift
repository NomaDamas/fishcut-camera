import SwiftUI

/// 상태 칩. 값과 잠금 상태를 글자와 아이콘으로 함께 보여 준다(색만으로 구분하지 않는다).
struct StatusChip: View {
    let id: String
    let title: String
    let value: String
    var icon: String?
    /// nil이면 잠금 개념이 없는 칩
    var locked: Bool?
    /// 기준 값(셔터 180도 등)일 때 초록
    var good = false
    /// VoiceOver가 읽을 값. nil이면 `value`
    var spoken: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(value)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
            if let locked {
                Image(systemName: locked ? "lock.fill" : "a.circle")
                    .font(.caption2)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .foregroundStyle(good ? Color.green : .white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: .capsule)
        .animation(.snappy, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        // 카메라 화면은 글자를 키우면 9:16 틀을 가린다. 대신 길게 누르면 큰 글자 보기를 띄운다.
        .accessibilityShowsLargeContentViewer {
            Label("\(title) \(spoken ?? value)", systemImage: icon ?? "info.circle")
        }
        .accessibilityLabel(title)
        .accessibilityValue([spoken ?? value, locked.map { $0 ? "잠금" : "자동" }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("chip.\(id)")
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// 세로 소리 크기 미터. 0...1, 0.9 넘으면 빨강(소리가 찢어질 수 있음).
struct AudioMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * CGFloat(level)
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(level > 0.9 ? Color.red : level > 0.75 ? .yellow : .green)
                    .frame(height: max(h, 2))
            }
            .animation(.linear(duration: 0.1), value: level)
        }
        .accessibilityElement()
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
        .accessibilityLabel("입력 소리 크기")
        .accessibilityValue("\(Int(level * 100))퍼센트\(level > 0.9 ? ", 너무 큼" : "")")
        .accessibilityIdentifier("meter.audio")
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 31)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.25), value: isRecording)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityLabel(isRecording ? "녹화 정지" : "녹화 시작")
        .accessibilityValue(isRecording ? "녹화 중" : "대기")
        .accessibilityIdentifier("hud.record")
    }
}

struct RecordTimer: View {
    let started: Date?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(started == nil ? .white.opacity(0.4) : .red).frame(width: 7, height: 7)
            if let started {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
            } else {
                Text("0:00")
            }
        }
        .font(.footnote.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("녹화 시간")
        .accessibilityIdentifier("hud.timer")
    }
}

/// 탭한 위치의 초점 표시. 잠깐 보이고 사라진다.
struct FocusMark: View {
    let point: CGPoint
    let done: () -> Void
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(shown ? 1 : 1.4)
            .opacity(shown ? 1 : 0)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: point) {
                shown = false
                withAnimation(.snappy) { shown = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut) { shown = false }
                try? await Task.sleep(for: .seconds(0.3))
                done()
            }
    }
}

/// 설정 시트 하나. 표준 Form 컨트롤만 써서 VoiceOver와 자동화 도구가 그대로 읽고 조작할 수 있다.
struct SettingsSheet: View {
    @Bindable var camera: DualCamera
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("프레임", selection: $camera.settings.fps) {
                        ForEach(CameraSettings.frameRates, id: \.self) { Text("\($0)fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.fps")
                } header: {
                    Text("프레임")
                } footer: {
                    Text(camera.settings.fps == 24
                        ? "24fps는 셔터 1/48초라 한국 조명(60Hz)에서 깜빡일 수 있습니다."
                        : "30fps, 셔터 180도는 1/60초입니다. 한국 조명에서 깜빡임이 없습니다.")
                }

                Section {
                    Toggle("셔터 180° + ISO 고정", isOn: Binding(
                        get: { camera.settings.exposureLocked },
                        set: { on in if on { camera.lockExposureAtCurrent() } else { camera.settings.exposureLocked = false } }
                    ))
                    .accessibilityIdentifier("settings.exposureLock")
                    if camera.settings.exposureLocked {
                        Stepper {
                            LabeledContent("ISO", value: "\(Int(camera.settings.iso))")
                        } onIncrement: {
                            camera.stepISO(1)
                        } onDecrement: {
                            camera.stepISO(-1)
                        }
                        .accessibilityIdentifier("settings.iso")
                    }
                } header: {
                    Text("노출")
                } footer: {
                    Text("켜는 순간의 밝기를 유지하도록 ISO를 계산합니다. 장소를 옮기면 얼굴 밝기를 보고 ISO를 다시 맞추세요.")
                }

                Section {
                    Picker("색온도", selection: $camera.settings.kelvin) {
                        Text("자동").tag(Int?.none)
                        ForEach(CameraSettings.whiteBalancePresets, id: \.kelvin) { p in
                            Text("\(p.kelvin)K \(p.name)").tag(Int?.some(p.kelvin))
                        }
                        if let k = camera.settings.kelvin, !CameraSettings.whiteBalancePresets.contains(where: { $0.kelvin == k }) {
                            Text("\(k)K").tag(Int?.some(k))
                        }
                    }
                    .accessibilityIdentifier("settings.whiteBalance")
                    Button("지금 색으로 고정") { camera.lockWhiteBalanceAtCurrent() }
                        .accessibilityIdentifier("settings.whiteBalanceLockNow")
                    Toggle("녹화 중 자동 색온도 잠금", isOn: $camera.settings.lockWhiteBalanceOnRecord)
                        .disabled(camera.settings.kelvin != nil)
                        .accessibilityIdentifier("settings.whiteBalanceOnRecord")
                } header: {
                    Text("화이트 밸런스")
                } footer: {
                    Text("노란 전구 조명이면 3200K, 그 밖에는 5600K. 흰 종이로 화면을 채우고 「지금 색으로 고정」을 눌러도 됩니다.")
                }

                Section {
                    Toggle("3분할 그리드", isOn: $camera.settings.showGrid)
                        .accessibilityIdentifier("settings.grid")
                    Toggle("수평계", isOn: $camera.settings.showLevel)
                        .accessibilityIdentifier("settings.level")
                } header: {
                    Text("화면 보조선")
                } footer: {
                    Text("그리드 가로선은 두 비율이 같이 쓰고, 노란 틀 가장자리가 16:9의 세로 3분할 위치와 거의 같습니다. 틀 안 세로선은 9:16용 3분할입니다. 수평이 맞으면 수평선이 초록으로 바뀌고 진동이 옵니다.")
                }

                Section("초점과 손떨림") {
                    Toggle("초점 잠금", isOn: $camera.settings.focusLocked)
                        .accessibilityIdentifier("settings.focusLock")
                    Toggle("손떨림 보정", isOn: $camera.settings.stabilization)
                        .accessibilityIdentifier("settings.stabilization")
                }

                Section {
                    Picker("입력", selection: $camera.settings.micUID) {
                        Text("자동 (USB 우선)").tag(String?.none)
                        ForEach(camera.audioInputs) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .accessibilityIdentifier("settings.mic")
                    LabeledContent("지금 쓰는 입력", value: camera.audioInput)
                } header: {
                    Text("마이크")
                }

                Section("파일") {
                    LabeledContent("가로 16:9", value: "3840×2160 HEVC")
                    LabeledContent("세로 9:16", value: "1080×1920 HEVC")
                    LabeledContent("색", value: "SDR (Rec.709)")
                }
            }
            .navigationTitle("촬영 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                        .buttonStyle(.glassProminent)
                        // 기본 파랑은 흰 글자와 대비가 4.5:1에 조금 못 미친다
                        .tint(Color(red: 0, green: 0.36, blue: 0.85))
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
