import Foundation
import Darwin

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; if !value() { fatalError(message) } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("hanq-recorder-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: root) }
let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("output")
try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let frame: [String: Any] = ["sequence": 1, "milliseconds": 42, "lane": 2, "kind": 4, "event": 0, "edge": 0, "category": 0, "inputOrigin": 0, "consumed": false, "durationMicros": 0, "count": 0, "selected": false, "field": 0]
let valid: [String: Any] = ["schema": 1, "build": "235", "bestEffort": true, "appReceiptVerified": false, "correlationIsHeuristic": true, "lossCountersMayLag": true, "skippedEvents": [:], "skippedAuxiliary": [:], "trigger": 1, "incident": 1, "phase": 0, "discardedOldFrames": 0, "frames": [frame]]
func file(_ value: [String: Any], phase: Int = 0) throws -> URL {
    let path = source.appendingPathComponent("incident-1-\(phase)-" + UUID().uuidString + ".json")
    try RecorderSession.writeJSON(value, to: path); return path
}
let preexisting = try file(valid)
let session = try RecorderSession(source: source, outputRoot: output, product: ["pid": 123])
try session.collect(scenario: "ordinary")
check(session.copied == 0, "preexisting captures cannot become new observations")
let fresh = try file(valid)
try session.collect(scenario: "ordinary")
check(session.copied == 1, "new valid metadata copied")
check(session.builds == ["235"], "build comes from product capture")
check(!FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("incidents").appendingPathComponent(preexisting.lastPathComponent).path), "old metadata excluded")
check(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("incidents").appendingPathComponent(fresh.lastPathComponent).path), "fresh capture preserved")
try session.collect(scenario: "ordinary"); check(session.copied == 1, "capture copied only once")
for position in ["top", "frame", "build"] {
    var value = valid
    if position == "top" { value["text"] = "PRIVATE_RECORDER_TEXT" }
    if position == "frame" { var row = frame; row["keyCode"] = 15; value["frames"] = [row] }
    if position == "build" { value["build"] = "PRIVATE_RECORDER_TEXT" }
    _ = try file(value)
}
let publicFile = try file(valid); chmod(publicFile.path, 0o644)
let link = source.appendingPathComponent("incident-1-0-" + UUID().uuidString + ".json")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
let oversized = source.appendingPathComponent("incident-1-0-" + UUID().uuidString + ".json")
try RecorderSession.write(Data(repeating: 32, count: 4 * 1024 * 1024 + 1), to: oversized)
try session.collect(scenario: "ordinary")
check(session.rejected == 6 && session.copied == 1, "unknown payload, key values, non-build text, public mode, links and oversized input rejected")
try session.record("trial_started", scenario: "append")
try session.record("observed_loss", scenario: "append")
try session.record("observed_normal", scenario: "append")
check(session.observations == 2, "observations are human reports")
do { try session.record("PRIVATE_RECORDER_TEXT", scenario: "ordinary"); fatalError("arbitrary event accepted") } catch { checks += 1 }
do { try session.record("observed_loss", scenario: "PRIVATE_RECORDER_TEXT"); fatalError("arbitrary scenario accepted") } catch { checks += 1 }
try session.record("product_exited", scenario: "append")
try session.finish(scenario: "append")
try session.finish(scenario: "append")
let result = try JSONSerialization.jsonObject(with: Data(contentsOf: session.directory.appendingPathComponent("result.json"))) as! [String: Any]
check(result["chatgptReceiptVerified"] as? Bool == false, "metadata never proves ChatGPT delivery")
check(result["collectionComplete"] as? Bool == true, "completed collection recorded")
do { try session.collect(scenario: "ordinary"); fatalError("finished session collected again") } catch { checks += 1 }
for url in try FileManager.default.contentsOfDirectory(at: session.directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
    let contents = try String(contentsOf: url, encoding: .utf8)
    check(!contents.contains("PRIVATE_RECORDER_TEXT"), "no arbitrary text in output")
    var info = stat(); check(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "private output mode")
}
var info = stat(); check(lstat(session.directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "private session mode")
let replaced = try RecorderSession(source: source, outputRoot: output, product: [:])
let moved = root.appendingPathComponent("moved")
try FileManager.default.moveItem(at: source, to: moved)
try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
do { try replaced.collect(scenario: "ordinary"); fatalError("replaced source accepted") } catch { checks += 1 }
try replaced.finish(scenario: "ordinary")
check(replaced.collectionWarning != nil, "source replacement still preserves partial result")
let limited = try RecorderSession(source: source, outputRoot: output, product: [:])
for _ in 0..<511 { try limited.record("trial_started", scenario: "ordinary") }
do { try limited.record("trial_started", scenario: "ordinary"); fatalError("event cap exceeded") } catch { checks += 1 }
try limited.finish(scenario: "ordinary")
check(FileManager.default.fileExists(atPath: limited.directory.appendingPathComponent("result.json").path), "event cap leaves a final-result slot")
print("PASS: \(checks) recorder metadata/privacy, source identity, bounded files, private modes, lifecycle and result checks; no global input or ChatGPT access")
