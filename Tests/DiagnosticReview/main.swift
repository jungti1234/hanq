import Foundation
import Darwin

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ title: String) {
    checks += 1
    if (try? condition()) != true { fputs("FAIL: \(title)\n", stderr); exit(1) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("hanq-review-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: root) }
let live = root.appendingPathComponent("live")
let store = DiagnosticLogStore(directory: live, policy: .incidentDefault)
let run = UUID().uuidString
func capture(_ id: Int, _ phase: Int, runID: String? = nil, trigger: Int? = nil) throws -> Data {
    let cause = trigger ?? (id == 6 ? 2 : 1)
    let frames: [[String: Any]] = [
        ["kind": 1, "category": 0, "durationMicros": 700, "event": 998877, "eventEvidence": ["keyClass": 2, "timestampMicros": 123456789], "text": "SECRET_INPUT", "workEvidence": ["cpuState": 1, "cpuMicros": 90]],
        ["kind": 11, "category": 0, "controlEvidence": ["runtime": 3, "incomingFlags": 7]],
        ["kind": 6, "category": 1], ["kind": 6, "category": 5],
        ["kind": 7, "category": 8], ["kind": 10, "edge": 2, "sourceEvidence": ["selected": 1, "confirmed": 1, "target": 6]], ["kind": 8, "category": 10], ["kind": 8, "category": 999],
        ["kind": 1, "workEvidence": ["cpuState": 3]],
        ["kind": 2, "category": 2, "durationMicros": 95000], ["kind": 999, "text": "SECRET_UNKNOWN"]]
    let object: [String: Any] = ["schema": 1, "build": "296", "runID": runID ?? run,
        "incident": id, "phase": phase, "trigger": cause,
        "frames": frames, "discardedOldFrames": 4,
        "clipboard": "SECRET_CLIPBOARD", "password": "SECRET_PASSWORD", "path": "/SECRET/PATH",
        "capturePreservation": ["postOmittedFrames": 2, "endedOnShutdown": phase == 1, "requests": [["trigger": cause, "detail": cause == 6 ? 1 : 0]]],
        "observationDelivery": ["overflow": ["1": 3], "coalesced": ["1": 5], "omitted": ["1": 7]]]
    return try JSONSerialization.data(withJSONObject: object)
}
for id in 1...7 { for phase in 0...1 { check(store.save(try capture(id, phase), incident: id, phase: phase, automatic: id == 6) == .saved, "fixture saves") } }
let snapshotURL = root.appendingPathComponent("snapshot")
try store.copyExportSnapshot(to: snapshotURL, reviewMetadata: true)
check(fm.fileExists(atPath: snapshotURL.appendingPathComponent("review-dates.json").path), "source creation dates accompany review snapshot")
let snapshot = try DiagnosticReviewSnapshot(directory: snapshotURL)
check(snapshot.incidents.count == 7, "full list is not limited to five visible rows")
check(snapshot.incidents.first?.number == 7, "latest first")
check(snapshot.incidents.allSatisfy(\.complete), "pre and post group into one incident")
check(snapshot.incidents.filter { !$0.manual }.count == 1, "automatic and manual are labeled by trigger")
let environment = DiagnosticReviewEnvironment(
    appVersion: "0.3.1-beta.1", build: "306", macOSVersion: "15.7.9", modelIdentifier: "Mac14,7", keyboardLayout: .twoSet,
    koreanKeyEnabled: true, hanjaKeyEnabled: true, hudEnabled: true, capsLockSwitchEnabled: true, loginItemState: .enabled,
    diagnosticsEnabled: true, inputMonitoringEnabled: true, cachedAccessibilityPermission: true, updateRestricted: false)
let selection = Set([snapshot.incidents[0].id])
let files = try snapshot.files(selected: selection, environment: environment)
check(files.count == 5, "one incident exports summary, environment, two phases, storage status")
check(files.contains { $0.path == "environment.json" }, "environment is unconditional")
let rawFiles = files.filter { $0.path.hasPrefix("incident-") }
check(rawFiles.count == 2, "whole original pre and post pair included")
let text = files.map(\.readableText).joined()
for secret in ["SECRET_INPUT", "SECRET_CLIPBOARD", "SECRET_PASSWORD", "SECRET_UNKNOWN", "SECRET/PATH", "keyClass", "timestampMicros", "incomingFlags", "998877", "123456789"] {
    check(!text.contains(secret), "preview does not display arbitrary strings or raw event metadata: \(secret)")
}
let before = rawFiles.first { (try? JSONSerialization.jsonObject(with: $0.data) as? [String: Any])?["phase"] as? Int == 0 }!
for file in rawFiles {
    check(try file.data == Data(contentsOf: live.appendingPathComponent(file.path)), "selected log keeps exact original filename and source bytes")
}
check(try files.last!.data == Data(contentsOf: snapshotURL.appendingPathComponent("storage-status.json")), "storage status keeps exact writer-snapshot bytes")
let rawObject = try JSONSerialization.jsonObject(with: before.data) as! [String: Any]
let rawFrames = rawObject["frames"] as! [[String: Any]]
check(rawObject["runID"] as? String == run && rawFrames.count == 11, "raw run identity and every frame survive")
check(rawFrames.last?["kind"] as? Int == 999 && rawFrames.last?["text"] as? String == "SECRET_UNKNOWN", "unknown raw fields and synthetic sentinel values are not silently projected away")
check((rawFrames[0]["eventEvidence"] as? [String: Any])?["timestampMicros"] as? Int == 123456789, "original event timing survives export")
check(before.readableText == before.previewDocument?.readableText, "screen interpretation stays separate from original bytes")
for phrase in ["전환 대기 기한 초과", "보정 시작", "허용 상태 관측", "95000µs", "자리 부족", "반복 관측 묶음", "후보와 본문 불일치", "해석하지 못한 판단 사유", "두벌식", "시스템 키보드 배열", "스레드 변경 관측 수　1"] {
    check(before.readableText.contains(phrase), "readable fixed-label interpretation: \(phrase)")
}
check(files.last!.readableText.contains("내역 (누적)"), "storage counters retain concise cumulative scope")
let exportedSummary = String(data: files.first!.data, encoding: .utf8)!
check(exportedSummary == files.first!.readableText, "summary preview and exported text match exactly")
check(files.first!.readableText.contains("기록 수　1건")
      && files.first!.readableText.contains("발생 전·후 모두 있음"), "summary preview provides selection and complete-pair information")
check(!exportedSummary.contains("incident-") && !exportedSummary.contains("합산하지"), "summary keeps only selected-record facts")
let environmentObject = try JSONSerialization.jsonObject(with: files[1].data) as! [String: Any]
check(environmentObject["sections"] == nil && environmentObject["formatVersion"] == nil && environmentObject["title"] == nil,
      "environment exports data values rather than a serialized preview document")
check(environmentObject["koreanKeyEnabled"] as? Bool == true && environmentObject["build"] as? String == "306"
      && environmentObject["keyboardLayout"] as? String == "twoSet", "environment preserves typed booleans, identifiers and layout classification")
check(environmentObject["collectedAt"] is String && files[1].readableText.contains("수집 시각"), "environment collection time is a real value rather than a repeated disclaimer")
for phrase in ["검토창을 연 시점", "항상 포함", "관측 결과만으로", "시각 중첩과 CPU", "선택한 기록의 결과 아님", "검토 시점"] {
    check(!files.map(\.readableText).joined().contains(phrase), "fixed boilerplate removed from previews: \(phrase)")
}
let unknownEnvironment = DiagnosticReviewEnvironment(
    appVersion: "test", build: "306", macOSVersion: "15.7.9", modelIdentifier: nil, keyboardLayout: .unknownOrOther,
    koreanKeyEnabled: false, hanjaKeyEnabled: true, hudEnabled: false, capsLockSwitchEnabled: nil, loginItemState: .requiresApproval,
    diagnosticsEnabled: false, inputMonitoringEnabled: false, cachedAccessibilityPermission: false, updateRestricted: true)
let unknownEnvironmentFile = try DiagnosticReviewFile(environment: unknownEnvironment)
check(unknownEnvironmentFile.readableText.contains("한영키 설정　꺼짐") && unknownEnvironmentFile.readableText.contains("Caps Lock 전환　미확인")
      && unknownEnvironmentFile.readableText.contains("로그인 자동 실행　승인 필요"), "environment preview changes with observed values and preserves unknown/approval states")
check(files.last!.readableText.contains("자동 기록　2개 ·") && files.last!.readableText.contains("수동 기록　12개 ·"), "storage preview labels file counts separately from incident counts")
check(files.last!.readableText.contains("기록된 내역 없음") && !files.last!.readableText.contains("저장 시도")
      && !files.last!.readableText.contains("저장 성공") && !files.last!.readableText.contains("(바이트)"), "zero issue counters and internal totals do not clutter storage preview")
let two = try snapshot.files(selected: Set(snapshot.incidents.prefix(2).map(\.id)), environment: environment)
check(two.count == 7, "multi-select preserves both complete pairs")
let five = try snapshot.files(selected: Set(snapshot.incidents.prefix(5).map(\.id)), environment: environment)
check(five.count == 13, "five incidents include ten pre/post files and all mandatory documents")
check(five.first!.readableText.contains("기록 수　5건"), "pre/post pairs count as five incidents")
check(five.filter { $0.path.hasPrefix("incident-") }.allSatisfy { file in
    (try? Data(contentsOf: snapshotURL.appendingPathComponent(file.path))) == file.data
}, "all five selected pairs retain original bytes")
check(try snapshot.files(selected: Set(snapshot.incidents.suffix(5).map(\.id)), environment: environment).count == 13, "older incidents beyond the first five remain selectable")
do {
    _ = try snapshot.files(selected: Set(snapshot.incidents.prefix(6).map(\.id)), environment: environment)
    check(false, "six incidents rejected")
} catch DiagnosticReviewError.tooManySelections { check(true, "six incidents rejected by count") }
do { _ = try snapshot.files(selected: [], environment: environment); check(false, "empty selection rejected") } catch { check(true, "empty selection rejected") }
do { _ = try snapshot.files(selected: ["absent"], environment: environment); check(false, "unknown selection rejected") } catch { check(true, "unknown selection rejected") }

// The live store changes after review, but the reviewed snapshot and ZIP stay fixed.
check(store.save(try capture(8, 0), incident: 8, phase: 0, automatic: false) == .saved, "new live incident")
let archive = try DiagnosticReviewArchive(files: files)
let original = try Data(contentsOf: archive.url)
check(original.count == archive.bytes && archive.sourceBytes == files.reduce(0) { $0 + $1.data.count }, "actual compressed and source sizes")
let output = root.appendingPathComponent("selected.zip")
try archive.save(to: output)
check(try Data(contentsOf: output) == original, "saved ZIP exactly matches reviewed ZIP")
let extracted = root.appendingPathComponent("extracted")
let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); unzip.arguments = ["-x", "-k", output.path, extracted.path]
try unzip.run(); unzip.waitUntilExit(); check(unzip.terminationStatus == 0, "actual ZIP extracts")
for file in files {
    check(try Data(contentsOf: extracted.appendingPathComponent("HanQ-Diagnostics").appendingPathComponent(file.path)) == file.data, "all reviewed file bytes match extraction")
}
let extractedNames = try fm.subpathsOfDirectory(atPath: extracted.path)
check(!extractedNames.contains { $0.contains("review-dates") || $0.contains("ownership") || $0.contains("사건-02") }, "only selected shareable files are archived")
let sentinel = root.appendingPathComponent("sentinel"); try Data("preserved".utf8).write(to: sentinel)
let symlinkURL = root.appendingPathComponent("link.zip"); try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: sentinel)
try archive.save(to: symlinkURL)
check(try String(contentsOf: sentinel, encoding: .utf8) == "preserved", "publication does not follow destination symlink")
check(try Data(contentsOf: symlinkURL) == original, "publication replaces link with reviewed ZIP")
do { try archive.save(to: root.appendingPathComponent("missing/fail.zip")); check(false, "invalid destination fails") } catch { check(true, "invalid destination fails") }
check(try Data(contentsOf: output) == original, "failed save preserves existing export")
var damaged = original; damaged[0] ^= 1; try damaged.write(to: archive.url)
do { try archive.save(to: output); check(false, "same-size tamper rejected") } catch { check(true, "same-size tamper rejected") }
check(try Data(contentsOf: output) == original, "tamper failure preserves destination")
check(!((try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".HanQ-Review-") }), "failed publication cleans temporary copies")

// Different runs can reuse incident numbers; an absent phase is explicitly visible.
let secondRun = root.appendingPathComponent("other-run")
try fm.createDirectory(at: secondRun, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let names = ["incident-1-0-a.json", "incident-1-0-b.json"]
for (index, name) in names.enumerated() {
    let path = secondRun.appendingPathComponent(name)
    try capture(1, 0, runID: index == 0 ? run : UUID().uuidString).write(to: path)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}
for (name, data) in [("review-dates.json", try JSONEncoder().encode([names[0]: 1000.0, names[1]: 2000.0])), ("storage-status.json", Data("{\"schema\":1,\"status\":{}}".utf8))] {
    let path = secondRun.appendingPathComponent(name); try data.write(to: path); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}
let other = try DiagnosticReviewSnapshot(directory: secondRun)
check(other.incidents.count == 2 && other.incidents.allSatisfy { !$0.complete }, "run identity separates reused IDs and shows incomplete captures")
check(other.incidents[0].savedAt! > other.incidents[1].savedAt!, "source creation date ordering")
let incompleteFiles = try other.files(selected: Set(other.incidents.map(\.id)), environment: environment)
check(incompleteFiles.first!.readableText.contains("발생 후 기록 없음"), "incomplete summary identifies the missing phase")
check(incompleteFiles.last!.readableText.contains("미확인") && !incompleteFiles.last!.readableText.contains("기록된 내역 없음"), "missing storage counters are not treated as zero failures")
let invalid = secondRun.appendingPathComponent(names[0]); try Data("{}".utf8).write(to: invalid)
do { _ = try DiagnosticReviewSnapshot(directory: secondRun); check(false, "invalid capture fails visibly") } catch { check(true, "invalid capture fails visibly") }
check(fm.fileExists(atPath: live.path), "review never deletes live store")
for phase in 0...1 { check(store.save(try capture(9, phase, trigger: 6), incident: 9, phase: phase, automatic: true) == .saved, "recovery-start fixture saves") }
let recoveryURL = root.appendingPathComponent("recovery-review")
try store.copyExportSnapshot(to: recoveryURL, reviewMetadata: true)
let recovery = try DiagnosticReviewSnapshot(directory: recoveryURL)
let recoveryFiles = try recovery.files(selected: [recovery.incidents.first!.id], environment: environment)
check(recoveryFiles.contains { $0.readableText.contains("최초 보정 감지 사유　영문 결과 불일치") }, "first detector reason survives readable projection")
do {
    _ = try DiagnosticReviewArchive(files: [DiagnosticReviewFile("../outside.json", "bad", original: Data(), preview: environment.preview)])
    check(false, "unsafe export path rejected")
} catch { check(true, "unsafe export path rejected") }

func previewSnapshot(_ frames: [[String: Any]], status: [String: Any] = [:]) throws -> DiagnosticReviewSnapshot {
    let directory = root.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let name = "incident-1-0-fixture.json"
    let capture: [String: Any] = ["schema": 1, "runID": UUID().uuidString, "incident": 1, "phase": 0, "trigger": 3, "frames": frames]
    for (name, object) in [(name, capture), ("review-dates.json", [name: 1000.0]), ("storage-status.json", ["schema": 1, "status": status])] as [(String, [String: Any])] {
        let path = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    return try DiagnosticReviewSnapshot(directory: directory)
}
func projected(_ frames: [[String: Any]]) throws -> DiagnosticReviewDocument {
    try previewSnapshot(frames).incidents[0].documents[0]!
}
let issues: [String: Any] = ["automaticFiles": 8, "automaticBytes": 2_000_000, "manualFiles": 2,
    "manualBytes": 1024, "limited": 4, "retired": 0, "unavailable": 2,
    "encodingFailures": 0, "statusWriteFailures": 1, "lastFailureStage": 17,
    "lastErrno": 13, "unknownFutureField": "SYNTHETIC_ORIGINAL_ONLY"]
let issueSnapshot = try previewSnapshot([], status: issues)
let issueFiles = try issueSnapshot.files(selected: [issueSnapshot.incidents[0].id], environment: environment)
let issueFile = issueFiles.last!
check(issueFile.readableText.contains("한도로 저장 생략　4회") && issueFile.readableText.contains("저장 불가　2회")
      && issueFile.readableText.contains("저장 상태 기록 실패　1회"), "nonzero failure and omission counters remain visible")
check(!issueFile.readableText.contains("기한 경과") && !issueFile.readableText.contains("진단 파일 생성 실패"), "zero issue details are omitted from preview only")
check(!issueFile.readableText.contains("lastErrno") && !issueFile.readableText.contains("SYNTHETIC_ORIGINAL_ONLY"), "internal error details remain outside readable preview")
check(try issueFile.data == Data(contentsOf: issueSnapshot.directory.appendingPathComponent("storage-status.json"))
      && String(data: issueFile.data, encoding: .utf8)!.contains("SYNTHETIC_ORIGINAL_ONLY"), "storage simplification preserves every original byte including unknown fields")
let missingPhaseFiles = try issueSnapshot.files(selected: [issueSnapshot.incidents[0].id], environment: environment)
check(missingPhaseFiles.first!.readableText.contains("발생 후 기록 없음"), "summary never hides incomplete capture")
let startedRead = try projected([["kind": 2, "category": 1, "durationMicros": 0]])
check(startedRead.readableText.contains("최대 접근성 조회 시간　미측정"), "unfinished AX read is not reported as a completed zero-duration lookup")
let invalidClock = try projected([
    ["kind": 1, "durationMicros": 0, "workEvidence": ["clockValid": false, "cpuState": 5]],
    ["kind": 2, "category": 2, "durationMicros": 0, "workEvidence": ["clockValid": false, "cpuState": 5]]])
check(invalidClock.readableText.contains("최대 입력 처리 시간　미측정") && invalidClock.readableText.contains("최대 접근성 조회 시간　미측정"), "invalid wall clock is not displayed as zero duration")
let zeroRead = try projected([["kind": 2, "category": 2, "durationMicros": 0]])
check(zeroRead.readableText.contains("최대 접근성 조회 시간　0µs"), "completed zero-duration legacy lookup remains a valid measurement")
let queued = try projected([["kind": 6, "category": 8], ["kind": 7, "category": 2], ["kind": 10, "edge": 7]])
for label in ["후속 입력 임시 보관", "후속 입력 대기열 보관", "영문 소스에서 관측 생략"] {
    check(queued.readableText.contains(label), "existing fixed state is not silently omitted: \(label)")
}
print("PASS: diagnostic review \(checks) checks (selection, original bytes, parsed preview, ZIP integrity, failure preservation)")
