import Foundation
import ApplicationServices

var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;precondition(value(),message)}
var time=100.0
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,capacity:8,clock:{time},writer:{captures.append($0)})
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
let payload="PRIVATE_TYPED_TEXT_CLIPBOARD"
event.keyboardSetUnicodeString(stringLength:payload.utf16.count,unicodeString:Array(payload.utf16))
event.setIntegerValueField(.eventSourceUserData,value:0x123456789)
let flags=event.flags,stamp=event.timestamp,tag=event.getIntegerValueField(.eventSourceUserData)
for _ in 0..<20{trace.event(.main,.keyDown,event);time+=0.001}
trace.mark();trace.flush()
check(captures.count==1,"manual capture persisted off callback")
let capture=captures[0]
check(capture.frames.count==8 && capture.discardedOldFrames>=12,"bounded history retains newest frames")
check(capture.frames.last?.kind == .marker,"explicit symptom marker preserved")
check(capture.frames.map{$0.sequence}.sorted()==capture.frames.map{$0.sequence},"ordered timeline")
check(event.flags==flags && event.timestamp==stamp && event.getIntegerValueField(.eventSourceUserData)==tag,"diagnostics never mutates routing or event")
let json=String(data:try! JSONEncoder().encode(capture),encoding:.utf8)!
for secret in [payload,"keyCode","clipboard","4886718345"]{check(!json.contains(secret),"no input payload or untrusted event tag")}
check(json.contains("\"bestEffort\":true") && json.contains("\"appReceiptVerified\":false"),"capture never claims app receipt or lossless observation")

var correlated:[InputIncidentTrace.Capture]=[]
let flow=InputIncidentTrace(destination:nil,writer:{correlated.append($0)})
let original=CGEvent(keyboardEventSource:nil,virtualKey:2,keyDown:true)!
original.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x4852000000000001))
flow.event(.hid,.keyDown,original)
original.timestamp+=1000 // Quartz may retimestamp before the main tap.
flow.event(.main,.keyDown,original)
original.setIntegerValueField(.eventSourceUserData,value:0) // Existing engine consumes its own origin token.
flow.event(.mismatch,.keyDown,original)
flow.event(.boundary,.keyDown,original)
flow.mark();flow.flush()
let ids=correlated[0].frames.filter{$0.kind == .event}.map{$0.event}
check(ids.count==4 && Set(ids).count==1,"one physical event remains correlated across retimestamp and original tag removal")
let repair=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!
repair.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x48414E5100000001))
flow.event(.main,.keyDown,repair);repair.timestamp+=1000;flow.event(.main,.keyDown,repair)
flow.mark();flow.flush()
let repairIDs=correlated.last!.frames.filter{$0.inputOrigin==2}.map{$0.event}
check(repairIDs.count==2 && Set(repairIDs).count==2,"a session-wide repair marker never falsely identifies multiple keys as one")
let unknown=CGEvent(keyboardEventSource:nil,virtualKey:3,keyDown:true)!
unknown.timestamp=0
flow.event(.hid,.keyDown,unknown);flow.event(.main,.keyDown,unknown)
flow.mark();flow.flush()
let uncertain=correlated.last!.frames.filter{$0.kind == .event}.suffix(2).map{$0.event}
check(Set(uncertain).count==2,"zero timestamps cannot manufacture a cross-stage match")

// A normal character change never triggers an automatic edit or fabricated loss.
var shapeCaptures:[InputIncidentTrace.Capture]=[]
let shape=InputIncidentTrace(destination:nil,clock:{time},writer:{shapeCaptures.append($0)})
shape.shape(.onsetAX,identity:99999999,count:5,selected:false,editing:false)
shape.shape(.onsetAX,identity:99999999,count:6,selected:false,editing:false)
shape.flush();check(shapeCaptures.isEmpty,"normal growth is not an incident")
shape.shape(.onsetAX,identity:99999999,count:4,selected:false,editing:false)
shape.flush();check(shapeCaptures.first?.trigger == .possibleShrink,"unexplained shrink captures evidence, not a diagnosis")
check(!String(data:try! JSONEncoder().encode(shapeCaptures[0]),encoding:.utf8)!.contains("99999999"),"raw AX field identity is not exported")
time+=11
let backspace=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:true)!
shape.event(.main,.keyDown,backspace)
shape.shape(.onsetAX,identity:99999999,count:4,selected:false,editing:false)
shape.shape(.onsetAX,identity:99999999,count:3,selected:false,editing:false)
shape.flush();check(shapeCaptures.count==1,"explicit deletion resets shrink baseline")
time+=11
shape.shape(.onsetAX,identity:99999999,count:2,selected:false,editing:true)
shape.flush();check(shapeCaptures.count==1,"recovery edits are not user-loss claims")
shape.context();shape.shape(.onsetAX,identity:111,count:0,selected:false,editing:false)
shape.flush();check(shapeCaptures.count==1,"source/focus generation is not shrink")

var spans:[InputIncidentTrace.Capture]=[]
let reads=InputIncidentTrace(destination:nil,clock:{time},writer:{spans.append($0)})
let a=reads.beginRead(.onsetAX);time+=0.001
let b=reads.beginRead(.mismatchAX);time+=0.060
reads.endRead(.mismatchAX,b);reads.endRead(.onsetAX,a);reads.flush()
check(spans.first?.trigger == .axDelay,"slow AX captures without extra AX queries")
let frames=spans[0].frames.filter{$0.kind == .read}
check(frames.prefix(2).allSatisfy{$0.category==1},"overlapping read starts retained")
check(Set(frames.map{$0.event}).count==2,"read spans can be correlated independently")

// Slow filesystem/writer cannot block event observation or execute a callback twice.
let started=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
let blocking=InputIncidentTrace(destination:nil,writer:{capture in if capture.phase==0{started.signal();release.wait()}})
blocking.mark();check(started.wait(timeout:.now()+1) == .success,"writer entered")
let began=ProcessInfo.processInfo.systemUptime
for _ in 0..<1000{blocking.event(.main,.keyDown,event)}
check(ProcessInfo.processInfo.systemUptime-began<0.2,"input observer never waits for writer")
release.signal();blocking.flush()

let disabled=InputIncidentTrace(destination:nil)
for _ in 0..<1000{disabled.event(.main,.keyDown,event)}
check(!disabled.enabled && disabled.beginRead(.onsetAX)==nil,"disabled path does not start timers, reads or output")

let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hanq-incident-test-"+UUID().uuidString)
try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? FileManager.default.removeItem(at:root)}
let directory=root.appendingPathComponent("records")
let disk=InputIncidentTrace(destination:directory)
disk.mark();disk.flush()
let files=try! FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
check(files.count==1,"manual marker writes one new prehistory file")
let body=try! Data(contentsOf:files[0]);check((try! JSONSerialization.jsonObject(with:body)) is [String:Any],"saved metadata decodes")
let mode=try! FileManager.default.attributesOfItem(atPath:files[0].path)[.posixPermissions] as! NSNumber
check(mode.intValue==0o600,"incident file is private")
let symlink=root.appendingPathComponent("link")
try! FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:directory)
let refusal=InputIncidentTrace(destination:symlink);refusal.mark();refusal.flush()
check((try! FileManager.default.contentsOfDirectory(atPath:directory.path)).count==1,"symlink output directory refused")
let bad=root.appendingPathComponent("missing/records")
let unavailable=InputIncidentTrace(destination:bad);unavailable.mark();unavailable.flush()
check(!FileManager.default.fileExists(atPath:bad.path),"unavailable destination never changes input or creates parents")
check(InputIncidentTrace.State.event("PRIVATE_TYPED_TEXT")==nil,"unknown state messages cannot enter structured traces")
let post=DispatchSemaphore(value:0)
var preID:Int?
let linked=InputIncidentTrace(destination:nil,writer:{capture in
    if capture.phase==0{preID=capture.incident}else{check(capture.incident==preID,"pre/post captures share incident identity");post.signal()}
})
linked.mark();linked.flush()
check(post.wait(timeout:.now()+2) == .success,"post-incident window is actually persisted")
// The linked writer has a different queue. Drain an in-progress disk publish
// before inspecting its temporary files; the linked signal cannot join it.
disk.flush()
check(!((try! FileManager.default.contentsOfDirectory(atPath:directory.path)).contains{$0.hasPrefix(".partial-")}),"no partial output remains after publication")

var boundaryCaptures:[InputIncidentTrace.Capture]=[]
let boundaryTrace=InputIncidentTrace(destination:nil,writer:{boundaryCaptures.append($0)})
boundaryTrace.sourceBoundary(.retained,queued:13,awaitingOnset:2);boundaryTrace.flush()
check(boundaryCaptures.first?.trigger == .boundaryInterrupted,"source-boundary retention captures immediately without a length shrink")
check(boundaryCaptures.first?.frames.last?.kind == .sourceBoundary && boundaryCaptures.first?.frames.last?.count==13,"queued counts are distinct from character loss")
check(InputIncidentTrace.BoundaryStage.event("PRIVATE_TYPED_TEXT")==nil,"unknown boundary payload cannot enter trace")
let heldLock=DispatchSemaphore(value:0),unlock=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
var contendedCaptures:[InputIncidentTrace.Capture]=[]
let contended=InputIncidentTrace(destination:nil,clock:{
    if Thread.current.name=="incident-test-lock-holder" {
        Thread.current.name="incident-test-lock-released";heldLock.signal();unlock.wait()
    }
    return ProcessInfo.processInfo.systemUptime
},writer:{contendedCaptures.append($0)})
Thread {
    Thread.current.name="incident-test-lock-holder";contended.context();finished.signal()
}.start()
check(heldLock.wait(timeout:.now()+2) == .success,"controlled contention acquired")
let contentionBegan=ProcessInfo.processInfo.systemUptime
contended.event(.boundary,.keyDown,event);contended.mark()
let nonblocking=ProcessInfo.processInfo.systemUptime-contentionBegan<0.1
unlock.signal();check(finished.wait(timeout:.now()+2) == .success,"controlled contention released")
contended.flush()
check(nonblocking,"event and manual marker never wait for the diagnostic lock")
check(contendedCaptures.first?.trigger == .manual,"manual capture is not silently discarded during contention")
check(contendedCaptures.first?.skippedEvents[InputIncidentTrace.Lane.boundary.rawValue]==1,"a skipped boundary event is explicitly accounted for")
check(contendedCaptures.first?.skippedAuxiliary[InputIncidentTrace.Lane.main.rawValue]==1,"missing marker metadata is distinct from a skipped input event")

for (name,raw) in [("waiting_for_snapshot",13),("waiting_for_text",14),("waiting_for_caret",15),("waiting_for_repair",16),("waiting_for_repair_receipt",17),("waiting_for_onset_receipt",18),("waiting_for_replay_receipt",19),("waiting_for_focus",20),("waiting_for_selection_commit",21),("waiting_for_source_commit",22)] {
 check(InputIncidentTrace.BoundaryStage.event(name)?.rawValue==raw,"fixed wait reason IDs remain compatible")
}

for (name,raw) in [("editor_diverged_input_resumed",23),("editor_insertion_style_matched",24),("editor_terminal_lf_matched",25),("editor_terminal_lf_style_matched",26),("editor_text_prefix_pending",27),("source_initial_body_removed",28)] {
 check(InputIncidentTrace.BoundaryStage.event(name)?.rawValue==raw,"fixed editor comparison IDs contain no text or key payload")
}

print("PASS \(checks) incident privacy, bounded history, overlap, shrink exclusions, nonblocking and filesystem checks; no global taps or OS posts")
