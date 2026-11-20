import Foundation

/// 사용자가 고르는 촬영 설정. 앱을 다시 열어도 유지된다.
/// 기본값은 촬영 노하우(렌즈 1x 고정, 30fps, 셔터 180도, 장소마다 ISO와 색온도 고정)를 따른다.
struct CameraSettings: Codable, Equatable {
    var fps = 30
    /// 켜면 셔터 180도(1/(fps*2)초)와 `iso`로 노출을 고정한다. 끄면 자동 노출이다.
    var exposureLocked = false
    var iso: Float = 800
    /// nil이면 자동 색온도. 값이 있으면 그 켈빈으로 고정한다.
    var kelvin: Int?
    /// 자동 색온도일 때 녹화하는 동안만 지금 색온도를 잠근다(Blackmagic의 Lock White Balance on Record).
    var lockWhiteBalanceOnRecord = true
    var focusLocked = false
    /// 기본 끔. 보정은 녹화 프레임만 잘라 내서 미리보기의 9:16 틀과 파일 구도가 어긋날 수 있다(실기기 확인 전).
    var stabilization = false
    /// nil이면 USB 마이크를 우선 쓰고 없으면 내장 마이크.
    var micUID: String?
    var showGrid = true
    var showLevel = true

    init() {}

    /// 예전에 저장한 설정에 새 항목이 없어도 기본값으로 읽는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraSettings()
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        exposureLocked = try c.decodeIfPresent(Bool.self, forKey: .exposureLocked) ?? d.exposureLocked
        iso = try c.decodeIfPresent(Float.self, forKey: .iso) ?? d.iso
        kelvin = try c.decodeIfPresent(Int.self, forKey: .kelvin)
        lockWhiteBalanceOnRecord = try c.decodeIfPresent(Bool.self, forKey: .lockWhiteBalanceOnRecord) ?? d.lockWhiteBalanceOnRecord
        focusLocked = try c.decodeIfPresent(Bool.self, forKey: .focusLocked) ?? d.focusLocked
        stabilization = try c.decodeIfPresent(Bool.self, forKey: .stabilization) ?? d.stabilization
        micUID = try c.decodeIfPresent(String.self, forKey: .micUID)
        showGrid = try c.decodeIfPresent(Bool.self, forKey: .showGrid) ?? d.showGrid
        showLevel = try c.decodeIfPresent(Bool.self, forKey: .showLevel) ?? d.showLevel
    }

    static let frameRates = [24, 30]
    static let whiteBalancePresets: [(kelvin: Int, name: String)] = [(5600, "햇빛"), (3200, "전구")]
    /// 1/3 스톱 간격 ISO
    static let isoLadder: [Float] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                     1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400]

    static func isoSteps(min lo: Float, max hi: Float) -> [Float] {
        isoLadder.filter { $0 >= lo && $0 <= hi }
    }

    static func nearestISO(_ value: Float, min lo: Float, max hi: Float) -> Float {
        let steps = isoSteps(min: lo, max: hi)
        return steps.min { abs(log2($0 / value)) < abs(log2($1 / value)) } ?? Swift.min(Swift.max(value, lo), hi)
    }

    private static let key = "cameraSettings.v1"

    static func load() -> CameraSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(CameraSettings.self, from: data)
        else { return CameraSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// 기기가 실제로 쓰고 있는 값. 화면의 상태 칩은 요청한 값이 아니라 이 값을 보여 준다.
struct DeviceReadout: Equatable {
    var iso = 0
    var exposureSeconds = 0.0
    var kelvin = 0
    var exposureLocked = false
    var whiteBalanceLocked = false
    var focusLocked = false

    func shutterAngle(fps: Int) -> Double { exposureSeconds * Double(fps) * 360 }
    var shutterDenominator: Int { exposureSeconds > 0 ? Int((1 / exposureSeconds).rounded()) : 0 }
}

struct AudioInputOption: Identifiable, Hashable {
    let id: String
    let name: String
}
