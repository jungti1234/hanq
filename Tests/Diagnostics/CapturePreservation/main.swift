import Foundation
import ApplicationServices
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
func code(_ op:Int,_ lane:Int,_ detail:Int)->Int{((op-1)*8+lane-1)*32+detail}
func encoded(_ value:InputIncidentTrace.Capture)->Data{do{return try JSONEncoder().encode(value)}catch{fputs("encoding failed\n",stderr);exit(1)}}
func strict(_ value:InputIncidentTrace.Capture)->Bool{(try? RecorderTrace.decode(encoded(value))) != nil}
var time=100.0
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,clock:{time},writer:{captures.append($0)})
trace.captureForTest(.axDelay);trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(captures.count==2,"initial automatic pre and post published")
time=102
trace.sourceBoundary(.manualEditUnverified,queued:17,awaitingOnset:4);trace.flush()
check(captures.count==2,"interval protects new window without immediate write")
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
event.timestamp=123456789
event.keyboardSetUnicodeString(stringLength:7,unicodeString:Array("PRIVATE".utf16))
trace.event(.main,.keyDown,event,duration:0.070);trace.flush()
trace.state(.mismatch,.retained,pending:13)
var control=InputIncidentControl();control.role=1;control.route=18;control.eventType=1
trace.control(.hid,.flagsChanged,event,control)
trace.shape(.mismatchAX,identity:99999,count:10,selected:false,editing:false)
trace.sourceEvidence(.observed,.init(selected:1,confirmed:1,target:1,observedAtMilliseconds:1,targetEventMilliseconds:nil,ageClipped:false,confirmedAtMilliseconds:1,targetAtMilliseconds:nil,confirmedAgeMicros:0,targetAgeMicros:nil,committed:true,deferred:false,candidatePreserved:false,historyPreserved:false))
trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(captures.count==2,"closed protected post also waits for write interval")
for _ in 0..<43{for _ in 0..<100{trace.context()};trace.flush()}
time=110.1;trace.drainCapturesForTest();trace.flush()
check(captures.count==4,"trailing drain publishes frozen pre and post")
let pre=captures[2],post=captures[3]
check(pre.phase==0 && post.phase==1 && pre.incident==post.incident,"deferred pre/post identity remains paired")
check(pre.frames.contains{$0.kind == .sourceBoundary && $0.category==31 && $0.count==17},"important branch survives main ring overwrite")
check(post.frames.contains{$0.kind == .state && $0.count==13},"surrounding post state survives main ring overwrite")
check(post.frames.contains{$0.kind == .controlDecision && $0.controlEvidence?.route==18},"copied control payload is finalized")
check(post.frames.contains{$0.kind == .sourceEvidence && $0.sourceEvidence?.selected==1},"copied source payload is finalized")
check(post.frames.contains{$0.kind == .shape && $0.shapeEvidence?.phase==1},"copied shape payload is finalized")
check(post.capturePreservation?.requests.count==2,"new trigger joins protected window with separate request metadata")
check(post.capturePreservation?.requests.first?.detail==31 && post.capturePreservation?.requests.first?.lane==8,"branch detail and lane correlate without text")
check(post.capturePreservation?.requests.last?.event==post.frames.first{$0.kind == .event}?.event,"callback trigger retains anonymous event correlation")
check(post.capturePreservation?.deferred==true && post.capturePreservation?.closed==true && post.capturePreservation?.postOmittedFrames==0,"deferred coverage explicitly closed without post overflow")
check(post.observationDelivery.overflow.isEmpty && post.decisionDelivery.overflow.isEmpty,"frozen evidence survives with zero delivery overflow")
check(captures.allSatisfy{strict($0)},"all phases accepted by strict collector")
check(!String(decoding:encoded(post),as:UTF8.self).contains("PRIVATE"),"original text never reaches capture metadata")
if CommandLine.arguments.count>1{do{try encoded(post).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}catch{fputs("output failed\n",stderr);exit(1)}}

// All ready windows drain in one batch, rather than one every ten seconds.
var batchTime=200.0,batchCaptures:[InputIncidentTrace.Capture]=[]
let batch=InputIncidentTrace(destination:nil,clock:{batchTime},writer:{batchCaptures.append($0)})
batch.captureForTest(.axDelay);batch.flush();batch.finishCaptureWindowsForTest();batch.flush()
batchTime=202
for _ in 0..<16{batch.captureForTest(.boundaryInterrupted);batch.flush();batch.finishCaptureWindowsForTest();batch.flush()}
check(batchCaptures.count==2,"sixteen closed automatic windows remain bounded during interval")
batch.captureForTest(.boundaryInterrupted);batch.flush()
batch.mark();batch.flush()
let manual=batchCaptures.last!
check(manual.trigger == .manual && manual.captureBacklog?.pendingAutomatic==16,"manual capture has independent slots when automatic windows are full")
check(manual.captureBacklog?.windowOverflow[5]==1,"automatic window overflow counted by trigger")
batch.finishCaptureWindowsForTest();batch.flush();batchTime=210.1;batch.drainCapturesForTest();batch.flush()
check(batchCaptures.count==36,"all sixteen windows and manual pair eventually published")
check(batchCaptures.filter{$0.capturePreservation?.deferred==true && $0.phase==1}.count==16,"every deferred group receives its protected post")
check(batchCaptures.allSatisfy{strict($0)},"bounded batch payloads pass strict collector")

// A full post does not silently overwrite early post context.
var smallCaptures:[InputIncidentTrace.Capture]=[]
let small=InputIncidentTrace(destination:nil,capacity:8,writer:{smallCaptures.append($0)})
small.captureForTest(.axDelay);small.flush()
for _ in 0..<20{small.context();small.flush()}
small.finishCaptureWindowsForTest();small.flush()
check(smallCaptures.last?.frames.count==8,"post has independent fixed capacity")
check(smallCaptures.last?.capturePreservation?.postOmittedFrames==12,"post tail overflow is explicit")
check(smallCaptures.last?.captureBacklog?.postOverflow[3]==12,"post overflow is counted by window trigger")

// A request list is bounded independently of frame and window capacity.
var listTime=300.0,listCaptures:[InputIncidentTrace.Capture]=[]
let list=InputIncidentTrace(destination:nil,clock:{listTime},writer:{listCaptures.append($0)})
for _ in 0..<33{list.captureForTest(.axDelay);list.flush()}
list.finishCaptureWindowsForTest();list.flush();listTime=310.1;list.drainCapturesForTest();list.flush()
check(listCaptures.filter{$0.phase==1}.count==2,"request thirty-three opens another protected window")
check(listCaptures.filter{$0.phase==1}.reduce(0){$0+($1.capturePreservation?.requests.count ?? 0)}==33,"bounded request lists preserve every admitted request")
check(listCaptures.filter{$0.phase==1}.allSatisfy{($0.capturePreservation?.requests.count ?? 99)<=32},"no request list grows beyond thirty-two")

// Admission under a held metadata lock never blocks the requesting path.
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
var heldCaptures:[InputIncidentTrace.Capture]=[]
let heldTrace=InputIncidentTrace(destination:nil,writer:{heldCaptures.append($0)})
Thread{heldTrace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2) == .success,"controlled lock held")
let began=ProcessInfo.processInfo.systemUptime
for _ in 0..<17{heldTrace.captureForTest(.axDelay)}
check(ProcessInfo.processInfo.systemUptime-began<0.1,"all seventeen callers return before lock release")
release.signal();check(done.wait(timeout:.now()+2) == .success,"controlled lock released")
heldTrace.flush();heldTrace.finishCaptureWindowsForTest();heldTrace.flush()
check(heldCaptures.last?.captureBacklog?.requestOverflow[3]==1,"ingress overflow distinguished from window overflow")
check(heldCaptures.last?.capturePreservation?.requests.count==16,"all admitted contended requests retain scalar context")

// Real timer closes one second after the last merged request.
var timedCaptures:[InputIncidentTrace.Capture]=[]
let timed=InputIncidentTrace(destination:nil,writer:{timedCaptures.append($0)})
timed.captureForTest(.axDelay);timed.flush();Thread.sleep(forTimeInterval:0.6)
timed.captureForTest(.boundaryInterrupted);timed.flush();Thread.sleep(forTimeInterval:0.6);timed.flush()
check(timedCaptures.count==1,"merged request extends post instead of ending at first request plus one second")
Thread.sleep(forTimeInterval:0.6);timed.flush()
check(timedCaptures.count==2 && timedCaptures.last?.capturePreservation?.requests.count==2,"real delayed post includes both trigger requests")

// Shutdown flushes a deferred window and identifies shortened post coverage.
var exitTime=400.0,exitCaptures:[InputIncidentTrace.Capture]=[]
let exiting=InputIncidentTrace(destination:nil,clock:{exitTime},writer:{exitCaptures.append($0)})
exiting.captureForTest(.axDelay);exiting.flush();exiting.finishCaptureWindowsForTest();exiting.flush();exitTime=402
exiting.sourceBoundary(.manualEditUnverified,queued:8,awaitingOnset:1);exiting.flush();exiting.stopAndFlush()
check(exitCaptures.count==4,"normal shutdown drains deferred pre and post before pausing collection")
check(exitCaptures.last?.capturePreservation?.endedOnShutdown==true,"shortened shutdown coverage is explicit")

// OFF cancels pending writes and reports discarded protected requests on next ON.
var offTime=500.0,offCaptures:[InputIncidentTrace.Capture]=[]
let off=InputIncidentTrace(destination:nil,clock:{offTime},writer:{offCaptures.append($0)})
func toggle(_ value:Bool){var done=false;off.setCollectionEnabled(value){done=true};let end=Date().addingTimeInterval(2);while !done && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.01))};check(done,"toggle completed")}
off.captureForTest(.axDelay);off.flush();off.finishCaptureWindowsForTest();off.flush();offTime=502
off.sourceBoundary(.manualEditUnverified,queued:8,awaitingOnset:1);off.flush();toggle(false)
let count=offCaptures.count;offTime=512;off.drainCapturesForTest();off.flush()
check(offCaptures.count==count,"OFF prevents pending protected writes")
toggle(true);off.mark();off.flush()
check(offCaptures.last?.captureBacklog?.discardedOnDisable[5]==1,"discarded request reason survives next ON")
check(offCaptures.last?.frames.contains{$0.kind == .sourceBoundary && $0.count==8}==false,"old collection frames cannot leak into new ON generation")

// The actual deferred timer drains without another input or capture request.
var trailingTime=600.0,trailingCaptures:[InputIncidentTrace.Capture]=[]
let trailing=InputIncidentTrace(destination:nil,clock:{trailingTime},writer:{trailingCaptures.append($0)})
trailing.captureForTest(.axDelay);trailing.flush();trailing.finishCaptureWindowsForTest();trailing.flush()
trailingTime=609.8;trailing.sourceBoundary(.manualEditUnverified,queued:7,awaitingOnset:0);trailing.flush();trailing.finishCaptureWindowsForTest();trailing.flush()
check(trailingCaptures.count==2,"completed deferred window awaits real trailing timer")
trailingTime=610.1;Thread.sleep(forTimeInterval:0.35);trailing.flush()
check(trailingCaptures.count==4,"real trailing timer saves deferred evidence without a new trigger")

// A stalled writer cannot postpone the protected snapshot until after overwrite.
let writerHeld=DispatchSemaphore(value:0),writerRelease=DispatchSemaphore(value:0)
var stalledTime=700.0,stalledCaptures:[InputIncidentTrace.Capture]=[],writeCalls=0
let stalled=InputIncidentTrace(destination:nil,clock:{stalledTime},writer:{value in
    writeCalls+=1;if writeCalls==1{writerHeld.signal();writerRelease.wait()};stalledCaptures.append(value)
})
stalled.captureForTest(.axDelay)
check(writerHeld.wait(timeout:.now()+2) == .success,"writer intentionally stalled")
stalled.finishCaptureWindowsForTest();stalledTime=702
stalled.sourceBoundary(.manualEditUnverified,queued:29,awaitingOnset:3);stalled.flushCaptureWorkerForTest();stalled.finishCaptureWindowsForTest()
for _ in 0..<43{for _ in 0..<100{stalled.context()};stalled.flushCaptureWorkerForTest()}
stalledTime=710.1;stalled.drainCapturesForTest()
writerRelease.signal();stalled.flush()
check(stalledCaptures.count==4,"writer resumes and receives both complete groups")
check(stalledCaptures.contains{$0.phase==0 && $0.frames.contains{$0.kind == .sourceBoundary && $0.category==31 && $0.count==29}},"deferred pre was frozen before writer and ring overwrite")
check(stalledCaptures.allSatisfy{strict($0)},"stalled writer snapshots remain strict and bounded")

// An older deferred pre cannot be retired by a newer immediate automatic pre.
let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hanq-capture-order-"+UUID().uuidString)
defer{try? FileManager.default.removeItem(at:folder)}
var orderTime=800.0
let ordered=InputIncidentTrace(destination:folder,clock:{orderTime})
ordered.captureForTest(.axDelay);ordered.flush();ordered.finishCaptureWindowsForTest();ordered.flush()
orderTime=802;ordered.sourceBoundary(.manualEditUnverified,queued:31,awaitingOnset:1);ordered.flush()
orderTime=811;ordered.captureForTest(.callbackDelay);ordered.flush()
func stored()->[URL]{((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}}
check(stored().count==2,"new automatic pre waits behind older unfinished deferred pre")
ordered.finishCaptureWindowsForTest();ordered.flush();orderTime=822;ordered.drainCapturesForTest();ordered.flush()
check(stored().count==6,"chronological store receives all three pre/post groups")
let orderedDocs=stored().compactMap{try? RecorderTrace.decode(Data(contentsOf:$0))}
check(orderedDocs.count==6 && Set(orderedDocs.map{$0.incident})==Set([1,2,3]),"strict saved incidents have no retired deferred group")
check(orderedDocs.compactMap{$0.storageBeforeWrite?.retired}.allSatisfy{$0==0},"ordered automatic publication has zero retirement")

// OFF also accounts for a protected post already queued behind a stalled writer.
let cancelHeld=DispatchSemaphore(value:0),cancelRelease=DispatchSemaphore(value:0)
var cancelTime=900.0,cancelCaptures:[InputIncidentTrace.Capture]=[],cancelWrites=0
let cancel=InputIncidentTrace(destination:nil,clock:{cancelTime},writer:{value in
 cancelWrites+=1;if cancelWrites==1{cancelHeld.signal();cancelRelease.wait()};cancelCaptures.append(value)
})
cancel.captureForTest(.axDelay)
check(cancelHeld.wait(timeout:.now()+2) == .success,"OFF test writer held")
cancel.finishCaptureWindowsForTest();cancelTime=902
cancel.sourceBoundary(.manualEditUnverified,queued:5,awaitingOnset:0);cancel.flushCaptureWorkerForTest()
var cancelled=false;cancel.setCollectionEnabled(false){cancelled=true};cancelRelease.signal()
let cancelDeadline=Date().addingTimeInterval(2)
while !cancelled && Date()<cancelDeadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
check(cancelled,"OFF crosses writer barrier and completes")
var resumed=false;cancel.setCollectionEnabled(true){resumed=true}
let resumeDeadline=Date().addingTimeInterval(2)
while !resumed && Date()<resumeDeadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
check(resumed,"ON after cancelled publication completes")
cancel.mark();cancel.flush()
check(cancelCaptures.last?.captureBacklog?.discardedOnDisable[3]==1,"queued original post cancellation counted by trigger")
check(cancelCaptures.last?.captureBacklog?.discardedOnDisable[5]==1,"deferred window cancellation counted independently")

// Strict metadata rejects arbitrary strings and unknown nested fields.
var object=(try! JSONSerialization.jsonObject(with:encoded(post))) as! [String:Any]
var preserved=object["capturePreservation"] as! [String:Any];preserved["text"]="PRIVATE";object["capturePreservation"]=preserved
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"unknown preservation payload rejected")
object=(try! JSONSerialization.jsonObject(with:encoded(post))) as! [String:Any]
var backlog=object["captureBacklog"] as! [String:Any];backlog["windowOverflow"]=["6":1];object["captureBacklog"]=backlog
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"invalid trigger counter rejected")
print("PASS \(checks) protected capture pre/post, deferred batch, anonymous linkage, bounds, nonblocking admission, timers, OFF, shutdown and strict privacy checks; no AX/global keys")
