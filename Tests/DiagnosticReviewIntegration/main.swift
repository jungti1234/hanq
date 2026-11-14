import Foundation
import CryptoKit

// A real trace/writer and persistent temporary store, with scalar observations
// only. No singleton, user defaults, input hooks, AX/TIS queries or OS keys.
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ title: String) {
    checks += 1
    if (try? value()) != true { fputs("FAIL integration: \(title)\n", stderr); exit(1) }
}
final class TestClock {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value += 11; lock.unlock() }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("hanq-review-integration-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: root) }
let directory = root.appendingPathComponent("source")
let clock = TestClock()
let policy = DiagnosticLogRetentionPolicy(maximumAutomaticFiles: 4, maximumAutomaticBytes: 1_000_000, maximumManualBytes: 1_000_000)
let trace = InputIncidentTrace(secureInput:{false},destination: directory, persistentOwnership: true, clock: clock.now, retention: policy)
func manifest(_ directory: URL) throws -> [String: Data] {
    Dictionary(uniqueKeysWithValues: try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map {
        ($0.lastPathComponent, Data(SHA256.hash(data: try Data(contentsOf: $0))))
    })
}
func snapshot(_ trace: InputIncidentTrace, to directory: URL, review: Bool = true) throws {
    let done = DispatchSemaphore(value: 0)
    var result: Result<Void, Error>?
    trace.prepareExport(to: directory, reviewMetadata: review) { result = $0; done.signal() }
    check(done.wait(timeout: .now() + 20) == .success, "snapshot completes asynchronously")
    try result!.get()
}
func complete(_ trace: InputIncidentTrace, automatic: Bool = false) {
    clock.advance()
    if automatic { trace.captureForTest(.callbackDelay) } else { trace.mark() }
    trace.flush(); trace.finishCaptureWindowsForTest(); trace.flush()
}
trace.context()
let onsetRead = trace.beginRead(.onsetAX)
let marked = InputIncidentFocusEvidence(markedRangeState: .empty, path: 1, role: 2, route: 1,
                                       ownerRelation: 1, elementRelation: 2, withinRead: 1)
trace.endRead(.onsetAX, onsetRead, outcome: .success, focus: marked)
trace.onsetObservation(.init(episode: 1, phase: 1, reason: 0, keys: 2, baseline: 2, history: 1,
                             whole: 6, draft: 2, insertion: 3, selection: 3, unicode: 6, samples: 3,
                             coalesced: 0, firstKeyAgeMicros: 100000, firstEventTimestampMicros: 1,
                             baselineAgeMicros: 1000, insertionEndRelation: 2))
trace.flush()
let read = trace.beginRead(.mismatchAX)
trace.endRead(.mismatchAX, read)
trace.recoveryFailure(rollback:true,site:"awaitSelection",reason:"selection_failed")
trace.recoveryFailure(rollback:false,site:"attemptRollback",reason:"rollback_text_changed")
trace.recordFailure(action:3,site:"safariInputActivation",reason:"source_switch_timeout")
trace.recordFailure(action:3,site:"safariActivationRetry",reason:"source_switch_timeout")
trace.mark(); trace.flush()
let pending = try manifest(directory)
let pendingFiles = pending.keys.filter { $0.hasPrefix("incident-") }.count
check((1...2).contains(pendingFiles) && pending.keys.contains { $0.hasPrefix("incident-1-0-") }, "real pre-capture exists before export (observed \(pendingFiles), total \(pending.count))")
print("INFO: review integration starts with \(pendingFiles) capture files (one means post is pending)")
DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { trace.finishCaptureWindowsForTest() }
let firstURL = root.appendingPathComponent("first")
try snapshot(trace, to: firstURL)
let first = try DiagnosticReviewSnapshot(directory: firstURL)
check(fm.fileExists(atPath:firstURL.appendingPathComponent("review-catalog.json").path),"writer supplies a lightweight review catalog")
check(first.incidents.count == 1 && first.incidents[0].complete, "review waits for the pending real pre/post pair")
for document in try first.incidents[0].documents.values {
    let rows=document.sections.first(where:{$0.title=="최근 자동 복구 실패 단계와 조건"})?.fields
    check(rows?.count==4 && rows?.first?.value.contains("selection_failed")==true &&
          rows?[1].value.contains("rollback_text_changed")==true &&
          rows?[2].value.contains("Safari 한국어 입력기 재활성화")==true && rows?[2].value.contains("source_switch_timeout")==true &&
          rows?.last?.value.contains("Safari 한국어 자판 재요청 결과 확인")==true && rows?.last?.value.contains("source_switch_timeout")==true && rows?.last?.label.contains("전환 보완 중단")==true, "both manual phases show the original failure followed by the rollback failure")
}
let reviewedLabels = try first.incidents[0].documents.values.flatMap { $0.sections.flatMap { $0.fields.map(\.label) } }
check(reviewedLabels.contains("첫 자음 조합 범위 · 빈 범위"), "manual review shows marked-range classification")
check(reviewedLabels.contains { $0.contains("삽입 끝보다 한 UTF-16 단위 뒤") }, "manual review shows caret crossing")
check(trace.enabled, "review does not disable collection")
let original = try manifest(directory)
let copyURL = root.appendingPathComponent("copy")
try snapshot(trace, to: copyURL)
check(try manifest(directory) == original, "review snapshot does not change captures, ownership index or storage status")
for name in original.keys where name.hasPrefix("incident-") {
    check(try Data(contentsOf: directory.appendingPathComponent(name)) == Data(contentsOf: copyURL.appendingPathComponent(name)), "real review copy preserves each source payload")
}
let frozen = try manifest(firstURL)
let env = DiagnosticReviewEnvironment(
    appVersion: "0.3.1-beta.1", build: "306", macOSVersion: "15.7.9", modelIdentifier: "Mac14,7", keyboardLayout: .twoSet,
    koreanKeyEnabled: true, hanjaKeyEnabled: true, hudEnabled: true, capsLockSwitchEnabled: true, loginItemState: .enabled,
    diagnosticsEnabled: true, inputMonitoringEnabled: true, cachedAccessibilityPermission: true, updateRestricted: false)
// Cloned bytes are isolated from their source. The catalog lists records without
// parsing full bodies, while selecting a changed body fails its original digest.
let lazyURL=root.appendingPathComponent("lazy")
try snapshot(trace,to:lazyURL)
let lazyBefore=try manifest(directory)
let damagedName=(try fm.contentsOfDirectory(atPath:lazyURL.path)).first{$0.hasPrefix("incident-")}!
let damagedPath=lazyURL.appendingPathComponent(damagedName)
var damaged=try Data(contentsOf:damagedPath);damaged[damaged.count-1] ^= 1
try damaged.write(to:damagedPath)
let lazyReview=try DiagnosticReviewSnapshot(directory:lazyURL)
check(lazyReview.incidents.count==1,"catalog listing does not load or parse every capture body")
do{_=try lazyReview.files(selected:Set(lazyReview.incidents.map(\.id)),environment:env);check(false,"changed selected body rejected")}
catch{check(true,"selected body is verified before preview or export")}
check(try manifest(directory)==lazyBefore,"changing a cloned review file cannot change the live original")
let failureSource=root.appendingPathComponent("failure-source")
let failureStore=DiagnosticLogStore(directory:failureSource,policy:policy)
let failureData=try JSONSerialization.data(withJSONObject:["schema":1,"trigger":1,"incident":1,"phase":0,"runID":UUID().uuidString,"frames":[]] as [String:Any])
check(failureStore.save(failureData,incident:1,phase:0,automatic:false) == .saved,"failure tests own a separate store")
let failureBefore=try manifest(failureSource),liveBeforeFailures=try manifest(directory)
let cancelled=DiagnosticSnapshotRequest();cancelled.cancel()
let cancelledURL=root.appendingPathComponent("cancelled")
do{try failureStore.copyExportSnapshot(to:cancelledURL,request:cancelled);check(false,"cancelled preparation rejected")}
catch DiagnosticLogExport.Failure.cancelled{check(true,"cancelled request reports cancellation")}
check(!fm.fileExists(atPath:cancelledURL.path),"cancelled request creates no snapshot")
let noSpace=root.appendingPathComponent("no-space")
do{try failureStore.copyExportSnapshot(to:noSpace,availableBytes:{0});check(false,"low space rejected")}
catch DiagnosticLogExport.Failure.insufficientSpace{check(true,"low space reports its own failure")}
check(!fm.fileExists(atPath:noSpace.path),"low-space failure removes its partial snapshot")
var mid:DiagnosticSnapshotRequest!
mid=DiagnosticSnapshotRequest{phase,_,_ in if phase == .copying{mid.cancel()}}
let midURL=root.appendingPathComponent("mid-cancel")
do{try failureStore.copyExportSnapshot(to:midURL,request:mid);check(false,"in-progress cancellation rejected")}
catch DiagnosticLogExport.Failure.cancelled{check(true,"in-progress cancellation is observed between files")}
check(!fm.fileExists(atPath:midURL.path),"in-progress cancellation removes its partial snapshot")
let timed=root.appendingPathComponent("timed-out")
do{try failureStore.copyExportSnapshot(to:timed,request:DiagnosticSnapshotRequest(timeout:0));check(false,"expired request rejected")}
catch DiagnosticLogExport.Failure.timedOut{check(true,"expired request reports a time bound")}
check(try manifest(failureSource)==failureBefore && manifest(directory)==liveBeforeFailures && trace.enabled,"space, cancellation and timeout failures preserve source and collection")
let selected = Set(first.incidents.map(\.id))
let archive = try DiagnosticReviewArchive(files: first.files(selected: selected, environment: env))
for file in archive.files where file.path.hasPrefix("incident-") || file.path == "storage-status.json" {
    check(try file.data == Data(contentsOf: firstURL.appendingPathComponent(file.path)), "real writer payload is exported byte-for-byte with original name")
}
for _ in 0..<3 { complete(trace, automatic: true) }
let active = root.appendingPathComponent("active")
try snapshot(trace, to: active)
let stored = try DiagnosticReviewSnapshot(directory: active)
check(stored.incidents.filter { !$0.manual }.count == 2, "automatic retention still rotates whole pairs at its own file quota")
check(stored.incidents.filter(\.manual).count == 1, "automatic rotation preserves the existing manual incident")
check(try manifest(firstURL) == frozen, "live collection and rotation do not mutate the reviewed snapshot")
let exported = root.appendingPathComponent("saved.zip")
try archive.save(to: exported)
check(try Data(contentsOf: exported) == Data(contentsOf: archive.url), "selected ZIP remains exact after ongoing live captures")
let extracted = root.appendingPathComponent("extracted")
let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
unzip.arguments = ["-x", "-k", exported.path, extracted.path]
try unzip.run(); unzip.waitUntilExit()
check(unzip.terminationStatus == 0, "real writer ZIP extracts")
for file in archive.files where file.path.hasPrefix("incident-") || file.path == "storage-status.json" {
    check(try Data(contentsOf: extracted.appendingPathComponent("HanQ-Diagnostics").appendingPathComponent(file.path)) == Data(contentsOf: firstURL.appendingPathComponent(file.path)), "extracted original remains exact after collection and rotation")
}
let decoder = Process(); decoder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
decoder.arguments = ["summarize-input-incident.py"] + archive.files.filter { $0.path.hasPrefix("incident-") || $0.path == "storage-status.json" }.map {
    extracted.appendingPathComponent("HanQ-Diagnostics").appendingPathComponent($0.path).path
}
decoder.standardOutput = FileHandle.nullDevice
try decoder.run(); decoder.waitUntilExit()
check(decoder.terminationStatus == 0, "existing strict incident/storage analysis accepts the extracted original files")
let beforeFailure = try manifest(directory)
do { try snapshot(trace, to: copyURL); check(false, "existing destination rejects snapshot") }
catch { check(true, "snapshot destination failure is reported") }
check(try trace.enabled && manifest(directory) == beforeFailure, "failed review leaves collection, source files and status untouched")
complete(trace)
let continued = root.appendingPathComponent("continued")
try snapshot(trace, to: continued)
let continuedReview = try DiagnosticReviewSnapshot(directory: continued)
check(continuedReview.incidents.filter(\.manual).count == 2, "manual capture continues after successful and failed reviews")
trace.stopAndFlush()
let beforeOffReview = try manifest(directory)
let off = root.appendingPathComponent("off")
try snapshot(trace, to: off)
let afterOffReview = try manifest(directory)
check(!trace.enabled && afterOffReview == beforeOffReview, "collection-OFF review is read-only and does not turn collection on")
let legacy = root.appendingPathComponent("legacy-export")
try snapshot(trace, to: legacy, review: false)
check(!fm.fileExists(atPath: legacy.appendingPathComponent("review-dates.json").path), "legacy full export keeps its original file set")
let restarted = InputIncidentTrace(destination: directory, persistentOwnership: true, clock: clock.now, retention: policy)
restarted.flush(); complete(restarted)
let afterRestart = root.appendingPathComponent("restarted")
try snapshot(restarted, to: afterRestart)
let restored = try DiagnosticReviewSnapshot(directory: afterRestart)
check(restored.incidents.filter(\.manual).count == 3, "persistent collection resumes and preserves manual pairs after review/restart")
restarted.stopAndFlush()
print("PASS: review/collection/storage integration \(checks) checks (real writer, temporary store, no installed app)")
