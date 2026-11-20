import CoreMotion
import SwiftUI

/// 폰의 좌우 기울기(롤). 화면은 LandscapeRight 고정이라 그 방향 기준으로 계산한다.
@Observable
final class LevelMeter {
    /// 라디안. 0이면 수평. 양수면 폰이 시계 방향으로 기울었다.
    private(set) var roll: Double = 0
    private(set) var available = false
    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        available = true
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            // LandscapeRight 화면: 화면 오른쪽 = 기기 -y, 화면 위 = 기기 +x.
            // 수평이면 중력이 화면 아래(기기 -x)를 향한다.
            self?.roll = atan2(-g.y, -g.x)
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

/// 3분할 그리드. 가로선은 두 비율이 같이 쓴다.
/// 16:9의 세로 3분할(33.3%, 66.7%)은 노란 9:16 틀 가장자리(34.2%, 65.8%)와 거의 겹쳐 따로 그리지 않고,
/// 틀 안에 9:16용 세로 3분할만 그린다.
struct GridOverlay: View {
    /// true면 세로선을 9:16 틀 안 3분할로, false면 16:9 화면 3분할로 그린다.
    var cropThirds = true

    var body: some View {
        GeometryReader { geo in
            let video = CropGuide.videoRect(in: geo.size)
            let crop = CropGuide.cropRect(in: geo.size)
            Path { p in
                for i in 1...2 {
                    let y = video.minY + video.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: video.minX, y: y))
                    p.addLine(to: CGPoint(x: video.maxX, y: y))
                    let x = cropThirds ? crop.minX + crop.width * CGFloat(i) / 3 : video.minX + video.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: video.minY))
                    p.addLine(to: CGPoint(x: x, y: video.maxY))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 수평계. 가운데 고정 눈금(흰색)과 실제 수평선(노랑)을 겹쳐 보여 주고, 1도 안이면 하나로 합쳐 초록이 된다.
struct LevelOverlay: View {
    let roll: Double

    private var degrees: Double { roll * 180 / .pi }
    private var isLevel: Bool { abs(degrees) < 1 }

    var body: some View {
        let shown = abs(degrees) < 20
        ZStack {
            // 고정 눈금: 화면 수평
            HStack(spacing: 64) {
                Capsule().frame(width: 28, height: 1.5)
                Capsule().frame(width: 28, height: 1.5)
            }
            .foregroundStyle(.white.opacity(isLevel ? 0 : 0.8))
            // 실제 수평선
            Capsule()
                .fill(isLevel ? Color.green : .yellow)
                .frame(width: isLevel ? 120 : 64, height: isLevel ? 2 : 1.5)
                .rotationEffect(.radians(-roll))
        }
        .opacity(shown ? 1 : 0)
        .animation(.snappy(duration: 0.2), value: isLevel)
        .sensoryFeedback(.selection, trigger: isLevel) { _, now in now }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("수평계")
        .accessibilityValue(isLevel ? "수평" : "\(Int(abs(degrees).rounded()))도 \(degrees > 0 ? "시계 방향" : "반시계 방향")으로 기울어짐")
        .accessibilityIdentifier("hud.level")
    }
}
