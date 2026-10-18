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
var identified=valid;let runID=UUID().uuidString;identified["runID"]=runID
let identifiedTrace=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:identified))
check(identifiedTrace.runID==runID,"anonymous run ID accepted")
let identifiedRoundtrip=try RecorderTrace.decode(JSONEncoder().encode(identifiedTrace))
check(identifiedRoundtrip.runID==runID,"run identity survives sanitized roundtrip")
let unidentified=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid))
check(unidentified.runID==nil,"old trace remains unmeasured")
for invalid:Any in ["PRIVATE_RECORDER_TEXT","",NSNull(),42,true] {
 var object=valid;object["runID"]=invalid
 do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:object));fatalError("invalid run ID accepted")}catch{checks+=1}
}
var reasonFrame=frame;reasonFrame["lane"]=4;reasonFrame["kind"]=8;reasonFrame["edge"]=1;reasonFrame["category"]=3;reasonFrame["event"]=12
var reasonTrace=valid;reasonTrace["frames"]=[reasonFrame]
let reasonData=try JSONSerialization.data(withJSONObject:reasonTrace)
let decodedReason=try RecorderTrace.decode(reasonData)
check(decodedReason.frames[0].category==3,"new fixed detection decisions accepted alongside old frames")
var deliveryTrace=valid
deliveryTrace["decisionDelivery"]=["capacity":4096,"overflow":["5":2,"184":3]]
let deliveryValue=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:deliveryTrace))
check(deliveryValue.decisionDelivery?.overflow["5"]==2,"bounded decision delivery metadata preserved")
let deliveryRoundtrip=try RecorderTrace.decode(JSONEncoder().encode(deliveryValue))
check(deliveryRoundtrip.decisionDelivery?.capacity==4096,"optional metadata survives sanitize and encode")
let timing:[String:Any]=["queueMicros":10000,"lockWaitMicros":40000,"contended":true,"clipped":false]
let waitStats:[String:Any]=["processed":3,"contended":1,"totalLockWaitMicros":40000,"maxLockWaitMicros":40000,"maxQueueMicros":50000,"clipped":0]
var timedFrame=reasonFrame;timedFrame["decisionTiming"]=timing
var timedTrace=valid;timedTrace["frames"]=[timedFrame]
timedTrace["decisionDelivery"]=["capacity":4096,"overflow":[:],"waits":["5":waitStats]]
let timed=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:timedTrace))
check(timed.frames[0].decisionTiming?.lockWaitMicros==40000,"per-reason wait timing preserved")
let timedRoundtrip=try RecorderTrace.decode(JSONEncoder().encode(timed))
check(timedRoundtrip.decisionDelivery?.waits?["5"]?.processed==3,"cumulative timing survives strict roundtrip")
let invalidTimings:[[String:Any]]=[
    ["queueMicros":-1,"lockWaitMicros":0,"contended":false,"clipped":false],
    ["queueMicros":0,"lockWaitMicros":60000001,"contended":true,"clipped":false],
    ["queueMicros":0,"lockWaitMicros":1,"contended":false,"clipped":false],
    ["queueMicros":0,"lockWaitMicros":0,"contended":1,"clipped":false],
    ["queueMicros":0,"lockWaitMicros":0,"contended":false,"clipped":false,"text":"PRIVATE_RECORDER_TEXT"]]
for invalid in invalidTimings {
    var row=timedFrame;row["decisionTiming"]=invalid;var value=timedTrace;value["frames"]=[row]
    do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:value));fatalError("invalid timing accepted")}catch{checks+=1}
}
for (key,value) in [("processed",0),("contended",4),("totalLockWaitMicros",-1),("maxLockWaitMicros",50000),("maxQueueMicros",60000001),("clipped",4)] {
    var stats=waitStats;stats[key]=value;var object=timedTrace;object["decisionDelivery"]=["capacity":4096,"overflow":[:],"waits":["5":stats]]
    do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:object));fatalError("invalid wait stats accepted")}catch{checks+=1}
}
var generic=frame;generic["decisionTiming"]=timing
var genericTrace=valid;genericTrace["frames"]=[generic]
do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:genericTrace));fatalError("timing on nondecision accepted")}catch{checks+=1}
let invalidDeliveries:[[String:Any]]=[
    ["capacity":1,"overflow":[:]], ["capacity":4096,"overflow":[:],"coalesced":["76":true]], ["capacity":4096,"overflow":[:],"coalesced":["310":1]], ["capacity":4096,"overflow":["310":1]],
    ["capacity":4096,"overflow":["05":1]], ["capacity":4096,"overflow":["5":-1]],
    ["capacity":4096,"overflow":["5":true]], ["capacity":4096,"overflow":[:],"text":"PRIVATE_RECORDER_TEXT"]]
for delivery in invalidDeliveries {
    var value=valid;value["decisionDelivery"]=delivery
    do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:value));fatalError("invalid delivery metadata accepted")}catch{checks+=1}
}
for (name,value) in [("kind",9),("edge",6),("category",32),("count",1),("field",999),("lane",1)] {
 var row=reasonFrame;row[name]=value;var trace=valid;trace["frames"]=[row]
 do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:trace));fatalError("invalid decision accepted")}catch{checks+=1}
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
let observations:[String:Any] = ["capacity":8,"readCapacity":1,"processed":["6":4],"overflow":["1124":2],"omitted":["2338":1],"coalesced":["960":1]]
let actualObservation=valid.merging(["observationDelivery":observations]){_,new in new}
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:actualObservation)))?.observationDelivery?.capacity==8,"typed observation counters accepted")
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid)))?.observationDelivery==nil,"old missing observations remain unmeasured")
for invalid in [observations.merging(["capacity":3]){_,n in n},observations.merging(["readCapacity":0]){_,n in n},observations.merging(["overflow":["2560":1]]){_,n in n},observations.merging(["overflow":["06":1]]){_,n in n},observations.merging(["overflow":["4":1]]){_,n in n},observations.merging(["coalesced":["6":1]]){_,n in n},observations.merging(["text":"PRIVATE"]){_,n in n}] {
 let row=valid.merging(["observationDelivery":invalid]){_,n in n}
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:row)))==nil,"invalid observation payload rejected")
}
let genericTiming:[String:Any] = ["queueMicros":10000,"lockWaitMicros":40000,"contended":true,"clipped":false]
let genericStats:[String:Any] = ["processed":3,"contended":1,"totalLockWaitMicros":40000,"maxLockWaitMicros":40000,"maxQueueMicros":50000,"clipped":0]
let timedObs=observations.merging(["processed":["1124":3],"waits":["1124":genericStats]]){_,n in n}
let observedFrame=frame.merging(["kind":6,"lane":4,"category":4,"observationTiming":genericTiming]){_,n in n}
let generalObservationTimedTrace243=valid.merging(["observationDelivery":timedObs,"frames":[observedFrame],"captureTiming":genericTiming]){_,n in n}
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:generalObservationTimedTrace243)))?.frames.first?.observationTiming?.contended==true,"general individual timing and totals accepted")
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:actualObservation)))?.observationDelivery?.waits==nil,"old observations have unmeasured waits")
for bad in [genericTiming.merging(["lockWaitMicros":-1]){_,n in n},genericTiming.merging(["contended":false]){_,n in n},genericTiming.merging(["text":"PRIVATE"]){_,n in n}] {
 let badFrame=observedFrame.merging(["observationTiming":bad]){_,n in n}
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid.merging(["frames":[badFrame]]){_,n in n})))==nil,"invalid general frame timing rejected")
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid.merging(["captureTiming":bad]){_,n in n})))==nil,"invalid capture timing rejected")
}
for bad in [timedObs.merging(["waits":[:]]){_,n in n},timedObs.merging(["waits":["1124":genericStats.merging(["processed":2]){_,n in n}]]){_,n in n},timedObs.merging(["waits":["1124":genericStats.merging(["text":"PRIVATE"]){_,n in n}]]){_,n in n}] {
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid.merging(["observationDelivery":bad]){_,n in n})))==nil,"invalid general totals rejected")
}
let timerWait=frame.merging(["kind":9,"category":9,"observationTiming":genericTiming]){_,n in n}
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid.merging(["frames":[timerWait]]){_,n in n}))) != nil,"typed timer wait frame accepted")
for bad in [timerWait.merging(["edge":32]){_,n in n},timerWait.merging(["category":10]){_,n in n},timerWait.merging(["event":1]){_,n in n},observedFrame.merging(["kind":8]){_,n in n}] {
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:valid.merging(["frames":[bad]]){_,n in n})))==nil,"invalid wait frame or kind mixing rejected")
}
print("PASS: \(checks) recorder metadata/privacy, source identity, bounded files, private modes, lifecycle and result checks; no global input or ChatGPT access")
