import Foundation
import ApplicationServices

var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
func strict(_ capture:InputIncidentTrace.Capture)->Bool {
    (try? RecorderTrace.decode(JSONEncoder().encode(capture))) != nil
}
var time=100.0,captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,capacity:32,clock:{time},writer:{captures.append($0)})
trace.shape(.mismatchAX,identity:1,count:17,selected:false,editing:false)
trace.decision(.handoff,.handoffAccepted)
trace.flush()
trace.recoveryStarted(.mismatch,reason:.interruptedComposition)
trace.flush()
check(captures.count==1 && captures[0].trigger == .recoveryStarted,"recovery captures immediately without a manual mark or delay")
let first=captures[0],request=first.capturePreservation!.requests[0]
check(request.detail==4 && request.lane==4 && request.milliseconds==0,"first detector branch and original time preserved")
check(first.frames.contains{$0.kind == .detectionDecision && $0.category==25},"handoff before detection preserved")
check(first.frames.contains{$0.kind == .shape && $0.count==17},"pre-edit shape preserved")
trace.state(.mismatch,.replay,pending:2);trace.flush()
trace.finishCaptureWindowsForTest();trace.flush()
check(captures.count==2 && captures[1].frames.contains{$0.kind == .state && $0.category==3},"following recovery state paired with pre")

// A second recovery inside the publication interval owns its own frozen pre.
time=102
trace.shape(.onsetAX,identity:2,count:23,selected:false,editing:false);trace.flush()
trace.recoveryStarted(.onset,reason:.firstConsonant);trace.flush()
check(captures.count==2,"publication is throttled while pre is already frozen")
trace.state(.onset,.finished);trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
for _ in 0..<20 {for _ in 0..<20{trace.context()};trace.flush()}
time=114;trace.drainCapturesForTest();trace.flush()
check(captures.count==4,"deferred recovery pre/post published after interval")
let second=captures[2]
check(second.incident != first.incident && second.capturePreservation!.requests.first!.detail==7,"later recovery cannot replace first cause")
check(second.frames.contains{$0.kind == .shape && $0.count==23},"deferred pre survives ring overwrite")
check(captures[3].frames.contains{$0.kind == .state && $0.category==5},"frozen post survives ring overwrite")
check(captures.allSatisfy(strict),"strict collector accepts recovery captures and capture counters")

// Ordinary metadata congestion and an occupied worker lock cannot block the
// input caller or consume the recovery's separate capture admission credits.
let blocked=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
var congested:[InputIncidentTrace.Capture]=[]
let busy=InputIncidentTrace(destination:nil,observationCapacity:4,writer:{congested.append($0)})
DispatchQueue.global().async {
    busy.withLockedMetadataForTest {blocked.signal();release.wait()}
    done.signal()
}
blocked.wait()
for _ in 0..<40{busy.context()}
let began=ProcessInfo.processInfo.systemUptime
busy.recoveryStarted(.mismatch,reason:.romanMismatch)
let elapsed=ProcessInfo.processInfo.systemUptime-began
release.signal();done.wait();busy.flush()
check(elapsed<0.05,"recovery capture submission never waits for metadata lock")
check(congested.count==1 && congested[0].capturePreservation!.requests[0].detail==1,"cause has independent admission under metadata overflow")
check(!congested[0].observationDelivery.overflow.isEmpty,"test actually exhausted ordinary metadata slots")
busy.stopAndFlush()
check(congested.allSatisfy(strict),"congested capture remains strict and bounded")

// Keep unknown cause codes, crossed lanes, and arbitrary payloads out of export.
let encoded=try JSONEncoder().encode(first)
var object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
let preservation=object["capturePreservation"] as! [String:Any]
let originalRequest=(preservation["requests"] as! [[String:Any]])[0]
for changes:[String:Any] in [["detail":11],["detail":7],["lane":2],["text":"PRIVATE"],["event":1]] {
    var bad=preservation;bad["requests"]=[originalRequest.merging(changes){_,new in new}]
    object["capturePreservation"]=bad
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"invalid detection/payload rejected")
}
var off:[InputIncidentTrace.Capture]=[]
let disabled=InputIncidentTrace(destination:nil,initiallyEnabled:false,writer:{off.append($0)})
disabled.recoveryStarted(.mismatch,reason:.interruptedComposition);disabled.flush()
check(off.isEmpty,"diagnostics OFF does not collect or capture")
if CommandLine.arguments.count>1 {try JSONEncoder().encode(second).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
print("PASS: \(checks) recovery start preservation, independent admission, strict privacy and OFF checks")
