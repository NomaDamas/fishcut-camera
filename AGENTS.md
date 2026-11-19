# Fishcut Camera 규칙

- iOS 앱이다. 프로젝트는 XcodeGen `project.yml`이 정본이고 생성된 `.xcodeproj`는 커밋하지 않는다.
- 작업 목록과 결정은 이 저장소의 GitHub 이슈가 정본이다. main에 직접 push하지 않고 `type/<번호>-설명` 브랜치에서 PR로 올린다.
- 실기기 검증(설치, 녹화, Mac으로 가져와 `ffprobe`로 확인)을 통과하기 전에는 기능을 완료로 보지 않는다. 검증 수치는 PR 본문에 붙인다.
- 기기 UDID, 개인 경로, Apple 계정 같은 개인 값은 저장소에 쓰지 않는다.
