import Foundation
import ApplicationServices
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
func code(_ op:Int,_ lane:Int,_ detail:Int=0)->Int {((op-1)*8+lane-1)*32+detail}
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
var captures:[InputIncidentTrace.Capture]=[]
var time=100.0
let trace=InputIncidentTrace(destination:nil,clock:{time},writer:{captures.append($0)})
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
event.timestamp=123456789;let payload="PRIVATE_OBSERVATION_PAYLOAD"
event.keyboardSetUnicodeString(stringLength:payload.utf16.count,unicodeString:Array(payload.utf16))
event.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x4852000000000001))
Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2) == .success,"real metadata lock held")
let began=ProcessInfo.processInfo.systemUptime
for lane in [InputIncidentTrace.Lane.hid,.onset,.mismatch,.boundary]{trace.event(lane,.keyDown,event,consumed:lane == .onset,duration:0.070)}
let span=trace.beginRead(.mismatchAX);check(span != nil,"read start accepted under held lock")
time+=0.125;trace.endRead(.mismatchAX,span)
trace.state(.mismatch,.retained,pending:7)
trace.sourceBoundary(.retained,queued:5,awaitingOnset:2)
trace.shape(.mismatchAX,identity:99999999,count:4,selected:false,editing:false)
trace.shape(.mismatchAX,identity:99999999,count:4,selected:false,editing:false)
trace.decision(.event,.preSwitchKey,event:event)
trace.mark()
check(ProcessInfo.processInfo.systemUptime-began<0.1,"all observation callers return before lock release")
event.timestamp=987654321;event.type = .keyUp;event.setIntegerValueField(.eventSourceUserData,value:0)
release.signal();check(done.wait(timeout:.now()+2) == .success,"held lock released")
trace.flush();trace.mark();trace.flush()
let last=captures.last!,frames=last.frames,events=frames.filter{$0.kind == .event}
check(events.count==4,"all four event stages survive contention")
check(Set(events.map{$0.event}).count==1,"caller-time anonymous identity survives event mutation")
check(events.allSatisfy{$0.edge==1 && $0.durationMicros==70000 && $0.milliseconds==0},"original edge duration and time preserved")
check(events.first{$0.lane == .onset}?.consumed==true && events.filter{!$0.consumed}.count==3,"pass and consumption preserved per lane")
let reads=frames.filter{$0.kind == .read}
check(reads.count==2 && reads[0].category==1 && reads[1].category==2 && reads[0].event==reads[1].event,"both reserved read endpoints survive")
check(reads[1].durationMicros==125000 && reads[1].milliseconds==125,"read elapsed and original end time preserved")
check(frames.contains{$0.kind == .state && $0.category==4 && $0.count==7},"retained recovery state survives")
check(frames.contains{$0.kind == .sourceBoundary && $0.category==6 && $0.count==5 && $0.event==2},"queued boundary counts survive")
check(frames.filter{$0.kind == .shape}.count+(last.observationDelivery.coalesced[code(4,7)] ?? 0)==2,"unchanged shape coalescing explicitly counted")
check(frames.contains{$0.kind == .marker},"manual marker retained")
check(frames.first{$0.kind == .detectionDecision}?.event==events[0].event,"decision and stage observation share original correlation")
check(last.observationDelivery.overflow.isEmpty && last.observationDelivery.omitted.keys.allSatisfy{$0/256+1==10},"no metadata discarded due to trace contention")
check(captures.contains{$0.trigger == .callbackDelay} && captures.contains{$0.trigger == .manual},"delay and manual captures remain requested")
let data=try! JSONEncoder().encode(last),json=String(data:data,encoding:.utf8)!
for secret in [payload,"keyCode","123456789","987654321","99999999"] {check(!json.contains(secret),"raw input or identity never exported")}
check((try? RecorderTrace.decode(data))?.observationDelivery?.capacity==4096,"strict collector accepts actual new metadata")
if let path=CommandLine.arguments.dropFirst().first {try! data.write(to:URL(fileURLWithPath:path))}

// Separate reservations: normal events4, state3, shape1, read pair1.
let entered=DispatchSemaphore(value:0),unblock=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
var fullCaptures:[InputIncidentTrace.Capture]=[]
let full=InputIncidentTrace(destination:nil,observationCapacity:8,readCapacity:1,writer:{fullCaptures.append($0)})
Thread{full.withLockedMetadataForTest{entered.signal();unblock.wait()};finished.signal()}.start()
check(entered.wait(timeout:.now()+2) == .success,"saturation lock held")
for _ in 0..<4{full.event(.hid,.keyUp,event)}
full.event(.hid,.keyUp,event,consumed:true,duration:0.070)
for _ in 0..<3{full.state(.mismatch,.retained,pending:9)}
full.state(.mismatch,.retained,pending:10)
full.context();full.sourceBoundary(.retained,queued:2,awaitingOnset:0);full.mark()
full.shape(.onsetAX,identity:1,count:5,selected:false,editing:false)
for _ in 0..<5000{full.shape(.onsetAX,identity:1,count:4,selected:false,editing:false)}
let accepted=full.beginRead(.onsetAX),rejected=full.beginRead(.mismatchAX)
check(accepted != nil && rejected==nil,"read pair reservation independent of full event and metadata queues")
full.endRead(.onsetAX,accepted);full.endRead(.mismatchAX,rejected)
for _ in 0..<3000{full.endRead(.onsetAX,accepted)}
unblock.signal();check(finished.wait(timeout:.now()+2) == .success,"saturation released")
full.flush();full.mark();full.flush()
let saturated=fullCaptures.last!,delivery=saturated.observationDelivery
check(delivery.overflow[code(1,1,6)]==1,"overflow separates event edge and consumed flag")
check(delivery.overflow[code(5,4,4)]==1,"overflow names retained state")
check(delivery.overflow[code(6,2)]==1 && delivery.overflow[code(7,8,6)]==1 && delivery.overflow[code(8,2)]==1,"context boundary and marker omissions accounted")
check(delivery.overflow[code(4,6)]==5000,"bounded drains eventually report exact shape flood")
check(delivery.overflow[code(2,7)]==1 && delivery.omitted[code(3,7)]==1,"rejected read start and unavailable paired end distinguished")
check(delivery.omitted[code(3,6)]==3000,"duplicate read endpoints are bounded before dispatch and explicitly counted")
check(saturated.frames.filter{$0.kind == .read}.count==2,"accepted read pair ends even when other pools are full")
check(fullCaptures.contains{$0.trigger == .callbackDelay},"overflowed delayed event still triggers capture")
check(delivery.omitted.keys.contains{ $0/256+1==10 },"capture coalescing/throttle explicitly counted")
check((try? RecorderTrace.decode(JSONEncoder().encode(saturated))) != nil,"actual saturation counters pass strict collector")
let next=full.beginRead(.onsetAX)
check(next != nil,"completed read releases reserved pair while old span remains retained by caller")
full.endRead(.onsetAX,next);full.flush()
var concurrentCaptures:[InputIncidentTrace.Capture]=[]
let concurrent=InputIncidentTrace(destination:nil,writer:{concurrentCaptures.append($0)})
DispatchQueue.concurrentPerform(iterations:100){_ in
    concurrent.event(.hid,.keyDown,event)
    concurrent.state(.mismatch,.buffered,pending:2)
    let read=concurrent.beginRead(.mismatchAX);concurrent.endRead(.mismatchAX,read)
}
concurrent.flush();concurrent.mark();concurrent.flush()
let c=concurrentCaptures.last!
check(c.frames.filter{$0.kind == .event}.count==100 && c.frames.filter{$0.kind == .state}.count==100,"concurrent producers retain events and buffered state")
check(c.frames.filter{$0.kind == .read && $0.category==1}.count==100 && c.frames.filter{$0.kind == .read && $0.category==2}.count==100,"concurrent read pairs remain uniquely paired")
check(c.observationDelivery.overflow.isEmpty && Set(c.frames.filter{$0.kind == .read}.map{$0.event}).count==100,"concurrent delivery stays within reservations and read identities do not collide")
print("PASS \(checks) observation contention, scalar lifetime, stage consumption/delay, read pair reservation, retained state, saturation counters, triggers and privacy checks; no AX/global keys")
