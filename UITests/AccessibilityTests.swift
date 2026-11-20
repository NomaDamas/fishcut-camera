import XCTest

/// 화면의 모든 컨트롤이 접근성 이름과 식별자를 갖는지, Apple 접근성 감사를 통과하는지 확인한다.
/// VoiceOver 사용자와 접근성 트리로 폰을 조작하는 에이전트가 같은 이름으로 앱을 다룬다.
final class AccessibilityTests: XCTestCase {
    private let hudIDs = ["hud.record", "hud.timer", "hud.settings", "hud.status", "meter.audio", "guide.crop",
                          "chip.mic", "chip.format", "chip.shutter", "chip.iso", "chip.wb", "chip.focus", "chip.storage", "hud.mode"]
    private let settingsIDs = ["settings.fps", "settings.exposureLock", "settings.whiteBalance",
                               "settings.whiteBalanceLockNow", "settings.grid", "settings.level", "settings.focusLock", "settings.stabilization",
                               "settings.mic", "settings.done"]

    override func setUp() { continueAfterFailure = true }

    func testHUDAndSettings() throws {
        // 화면은 LandscapeRight 고정이다. 기기 방향 landscapeLeft가 그 화면 방향이다.
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["hud.record"].waitForExistence(timeout: 10))
        for id in hudIDs {
            let e = app.descendants(matching: .any)[id]
            XCTAssertTrue(e.exists, "없음: \(id)")
            XCTAssertFalse(e.label.isEmpty, "이름 없음: \(id)")
        }
        attach(app, "hud")
        // 촬영 화면의 상태 칩은 글자를 키우면 9:16 틀을 가리므로 크기 상한을 두고
        // 길게 누르면 큰 글자 보기(Large Content Viewer)를 띄운다. 그래서 이 화면만 Dynamic Type 검사를 뺀다.
        try audit(app, types: XCUIAccessibilityAuditType.all.subtracting(.dynamicType))

        app.buttons["hud.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        // 한 번에 크게 넘기면 가운데 줄을 건너뛰므로 조금씩 끌어 올리며 본 식별자를 모은다.
        var seen = Set<String>()
        let list = app.collectionViews.firstMatch
        for _ in 0..<12 {
            for id in settingsIDs where app.descendants(matching: .any)[id].exists { seen.insert(id) }
            if seen.count == settingsIDs.count { break }
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            from.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        for id in settingsIDs { XCTAssertTrue(seen.contains(id), "없음: \(id)") }
        // 목록이 내비게이션 막대 유리 밑으로 들어간 상태는 대비 검사가 막대 뒤 글자를 섞어 읽으므로
        // 시트를 닫았다가 다시 열어 처음 상태에서 검사한다.
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.buttons["hud.settings"].waitForExistence(timeout: 5))
        app.buttons["hud.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        attach(app, "settings")
        // 시스템 Form과 내비게이션 막대가 그리는 두 요소는 Dynamic Type 검사에서 뺀다.
        // 막대 버튼은 iOS가 큰 글자 보기로 대신하고, 섹션 머리글은 iOS 기본 스타일 그대로다(우리 코드에서 크기를 막지 않음).
        try audit(app, types: .all) { issue in
            issue.auditType == .dynamicType && ["settings.done"].contains(issue.element?.identifier ?? "")
                || issue.auditType == .dynamicType && ["화이트 밸런스"].contains(issue.element?.label ?? "")
        }
    }

    /// 전후면 모드: 모드를 바꾸면 후면/전면 미리보기와 형식 칩이 나오고, 접근성 감사를 통과한다.
    /// 시뮬레이터는 MultiCam을 지원하지 않아 상태 줄에 지원하지 않는다고 나온다.
    func testFrontBackMode() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["hud.record"].waitForExistence(timeout: 10))
        app.buttons["전후면"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview.front"].waitForExistence(timeout: 5))
        for id in ["preview.back", "preview.front", "chip.format", "chip.storage", "hud.record", "hud.mode", "hud.status"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].exists, "없음: \(id)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["chip.iso"].exists, "전후면 모드에 후면 전용 칩이 남아 있음")
        attach(app, "frontback")
        try audit(app, types: XCUIAccessibilityAuditType.all.subtracting(.dynamicType))
        app.buttons["가로+세로"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chip.iso"].waitForExistence(timeout: 5))
    }

    private func audit(_ app: XCUIApplication, types: XCUIAccessibilityAuditType,
                       ignore: @escaping (XCUIAccessibilityAuditIssue) -> Bool = { _ in false }) throws {
        try app.performAccessibilityAudit(for: types) { issue in
            if ignore(issue) { return true }
            print("AUDIT", issue.auditType, issue.element?.identifier ?? "-", issue.element?.label ?? "-", issue.element?.elementType.rawValue ?? -1, issue.element.map { "\($0.frame)" } ?? "-", issue.compactDescription)
            return false
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
