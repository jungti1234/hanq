import Foundation
import ApplicationServices

var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;precondition(value(),message)}
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
var captures:[InputIncidentTrace.Capture]=[]
var time=100.0
let trace=InputIncidentTrace(destination:nil,clock:{
    if Thread.current.name=="hold-decision-trace" {
        Thread.current.name="held-decision-trace";entered.signal();release.wait()
    }
    return time
},writer:{captures.append($0)})
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
let payload="PRIVATE_DEFERRED_PAYLOAD"
event.keyboardSetUnicodeString(stringLength:payload.utf16.count,unicodeString:Array(payload.utf16))
event.timestamp=123456789;event.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x4852000000000001))
trace.event(.mismatch,.keyDown,event)
trace.decision(.eligibility,.observationAllowed);trace.flush()
Thread {
    trace.withLockedMetadataForTest{entered.signal();release.wait()};finished.signal() // No actual AX query.
}.start()
check(entered.wait(timeout:.now()+2) == .success,"controlled metadata lock acquired")
let targets:[(InputIncidentTrace.DecisionSite,InputIncidentTrace.DecisionReason)]=[
    (.event,.preSwitchKey),(.sample,.snapshotUnavailable),(.eligibility,.onsetRepair),
    (.handoff,.handoffUninitialized),(.repair,.repairBlocked)]
let began=ProcessInfo.processInfo.systemUptime
for (site,reason) in targets{trace.decision(site,reason,event:site == .event ? event:nil)}
trace.decision(.eligibility,.observationAllowed)
check(ProcessInfo.processInfo.systemUptime-began<0.1,"input caller does not wait for held trace lock")
// Later event mutation and tag cleanup must not alter delayed correlation.
event.timestamp=987654321;event.type = .keyUp
event.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x48414B5300000001))
time=200
release.signal();check(finished.wait(timeout:.now()+2) == .success,"metadata lock released")
trace.mark();trace.flush()
let capture=captures[0],decisions=capture.frames.filter{$0.kind == .detectionDecision}
for (site,reason) in targets {
    check(decisions.contains{$0.edge==site.rawValue && $0.category==reason.rawValue},"critical reason survives contention at site \(site.rawValue)")
}
let original=capture.frames.first{$0.kind == .event}!
let delayed=decisions.first{$0.edge==1}!
check(delayed.event==original.event && delayed.inputOrigin==1,"correlation uses caller-time scalar reference, not mutated CGEvent")
check(decisions.allSatisfy{$0.milliseconds==0},"original observation time preserved despite delayed processing")
check(decisions.filter{$0.edge==3}.map{$0.category}==[31,28,31],"one-off blocked transition and return remain ordered")
check(capture.skippedAuxiliary[4]==nil && capture.decisionDelivery.overflow.isEmpty,"trace contention itself loses no accepted decision")
let json=String(data:try! JSONEncoder().encode(capture),encoding:.utf8)!
for secret in [payload,"keyCode","123456789","987654321","com.apple"]{check(!json.contains(secret),"no raw event or input payload exported")}
let collected=try! RecorderTrace.decode(JSONEncoder().encode(capture))
check(collected.decisionDelivery?.capacity==4096 && collected.decisionDelivery?.overflow.isEmpty==true,"real deferred capture accepted by recording tools")

// Saturate a tiny queue while trace metadata is held. Routine calls have only
// two credits; the six reserved important credits remain available to inputs.
let fullEntered=DispatchSemaphore(value:0),fullRelease=DispatchSemaphore(value:0),fullDone=DispatchSemaphore(value:0)
var fullCaptures:[InputIncidentTrace.Capture]=[]
let full=InputIncidentTrace(destination:nil,clock:{
    if Thread.current.name=="hold-full-trace"{Thread.current.name="held-full-trace";fullEntered.signal();fullRelease.wait()}
    return ProcessInfo.processInfo.systemUptime
},decisionCapacity:8,writer:{fullCaptures.append($0)})
Thread{full.withLockedMetadataForTest{fullEntered.signal();fullRelease.wait()};fullDone.signal()}.start()
check(fullEntered.wait(timeout:.now()+2) == .success,"saturation lock held")
let fullBegan=ProcessInfo.processInfo.systemUptime
full.decision(.eligibility,.observationAllowed);full.decision(.sample,.noCandidate)
for _ in 0..<6{full.decision(.event,.preSwitchKey,event:event)}
for _ in 0..<5000{full.decision(.eligibility,.observationAllowed)}
for _ in 0..<10{full.decision(.event,.preSwitchKey,event:event)}
for _ in 0..<3{full.decision(.repair,.repairBlocked)}
check(ProcessInfo.processInfo.systemUptime-fullBegan<1,"full queue rejects immediately without waiting or async allocations per overflow")
fullRelease.signal();check(fullDone.wait(timeout:.now()+2) == .success,"saturation lock released")
full.mark();full.flush()
let first=fullCaptures[0]
check(first.decisionDelivery.capacity==8,"effective queue capacity exported")
check(first.frames.filter{$0.kind == .detectionDecision && $0.edge==1}.count==6,"routine flood cannot consume reserved important slots")
check(first.decisionDelivery.overflow[184]==4096,"overflow counters drain in bounded batches")
check(first.decisionDelivery.overflow[5]==10 && first.decisionDelivery.overflow[268]==3,"overflow separates exact reason/site and input-bound flag")
let collectedOverflow=try! RecorderTrace.decode(JSONEncoder().encode(first))
check(collectedOverflow.decisionDelivery?.overflow["5"]==10,"actual overflow metadata survives strict collector decoding")
full.mark();full.flush()
check(fullCaptures[1].decisionDelivery.overflow[184]==5000,"remaining overflow count is retained for a later snapshot")
full.decision(.repair,.repairBlocked);full.mark();full.flush()
check(fullCaptures[2].frames.contains{$0.kind == .detectionDecision && $0.edge==5},"queue resumes after saturation")

// Multiple producers exercise credit lifetime, FIFO publication and bounded
// deduplication; enough capacity to keep every input-bound observation.
var concurrentCaptures:[InputIncidentTrace.Capture]=[]
let concurrent=InputIncidentTrace(destination:nil,capacity:4096,writer:{concurrentCaptures.append($0)})
DispatchQueue.concurrentPerform(iterations:4){_ in
    for _ in 0..<100{concurrent.decision(.event,.observationBlocked,event:event)}
}
concurrent.mark();concurrent.flush()
check(concurrentCaptures[0].frames.filter{$0.kind == .detectionDecision}.count==400,"concurrent producers retain every accepted input decision")
check(concurrentCaptures[0].decisionDelivery.overflow.isEmpty,"no capacity overflow in concurrent batch")
check(Set(concurrentCaptures[0].frames.map{$0.sequence}).count==concurrentCaptures[0].frames.count,"published frame identities remain unique")
print("PASS \(checks) deferred decisions, five critical sites, event lifetime/privacy, original time, transitions, reserved capacity, explicit overflow and concurrent producer checks; no OS keys/AX calls")
