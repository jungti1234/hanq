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
let trace = InputIncidentTrace(destination: directory, persistentOwnership: true, clock: clock.now, retention: policy)
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
let read = trace.beginRead(.mismatchAX)
trace.endRead(.mismatchAX, read)
trace.mark(); trace.flush()
let pending = try manifest(directory)
let pendingFiles = pending.keys.filter { $0.hasPrefix("incident-") }.count
check((1...2).contains(pendingFiles) && pending.keys.contains { $0.hasPrefix("incident-1-0-") }, "real pre-capture exists before export (observed \(pendingFiles), total \(pending.count))")
print("INFO: review integration starts with \(pendingFiles) capture files (one means post is pending)")
DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { trace.finishCaptureWindowsForTest() }
let firstURL = root.appendingPathComponent("first")
try snapshot(trace, to: firstURL)
let first = try DiagnosticReviewSnapshot(directory: firstURL)
check(first.incidents.count == 1 && first.incidents[0].complete, "review waits for the pending real pre/post pair")
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
