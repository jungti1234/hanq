import AppKit
import Carbon
var checks=0
func check(_ v:@autoclosure ()->Bool,_ why:String){checks+=1;if !v(){fputs("FAIL: \(why)\n",stderr);exit(1)}}
let trace=InputIncidentTrace(destination:nil,capacity:4096,writer:{captures.append($0)})
var captures:[InputIncidentTrace.Capture]=[]
func event(_ flags:CGEventFlags=[],key:CGKeyCode=54,tag:Int64=0)->CGEvent {
 let e=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true)!;e.type = .flagsChanged;e.flags=flags;e.timestamp=UInt64(100000+checks)*1000;e.setIntegerValueField(.eventSourceUserData,value:tag);return e
}
let right=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10)
let two=InputSourceSnapshot(id:"private-korean-id",name:"private name",languages:["ko"])
let abc=InputSourceSnapshot(id:"private-english-id",name:"private name",languages:["en"])
func resolution(_ current:InputSourceSnapshot?,_ readable:Bool=true,_ sources:[InputSourceSnapshot]=[two,abc])->KoreanEnglishSwitch.Resolution{
 KoreanEnglishSwitch.resolution(current:current,readable:readable,sources:sources,rememberedKorean:two.id,rememberedEnglish:abc.id)
}
check(resolution(nil).status==1,"missing current distinct")
check(resolution(two,false,[]).status==2,"list lookup failure distinct")
check(resolution(two,true,[]).status==3,"readable empty destinations distinct")
check(resolution(two).target==abc.id && resolution(two).targetClass==2,"Korean selects English")
check(resolution(abc).target==two.id && resolution(abc).targetClass==1,"English selects Korean")
var filter=CommandFilter()
func run(_ flags:CGEventFlags,_ accept:Bool,_ expected:Int) {
 let e=event(flags);var c=InputIncidentControl.begin(trace,.flagsChanged,e)!
 let before=filter.diagnosticState,r=filter.process(type:.flagsChanged,key:54,flags:e.flags,acceptNewPress:accept)
 c.filter(before:before,after:filter.diagnosticState,flags:e.flags,accepted:accept,edge:r.edge,consumed:r.consume,matching:true)
 check(c.filterReason==expected,"real filter reason \(expected)")
 let q=resolution(two);c.query(site:1,status:q.status,current:q.currentClass,target:q.targetClass,available:q.availableCount,korean:q.koreanCount,english:q.englishCount,began:ProcessInfo.processInfo.systemUptime)
 c.route=(r.consume ? InputIncidentControl.Route.filterConsumed:.passed).rawValue
 e.flags=r.flags // diagnostic must retain incoming flags before mutation
 trace.control(.main,.flagsChanged,e,c,consumed:r.consume)
}
run(right,false,5);run(right,true,4);run([],true,3);run(.maskCommand,true,3);run(right,true,1);run(right,true,4);run([],false,2)
check(InputIncidentControl.begin(trace,.keyDown,event([],key:0))==nil,"ordinary letters have no control payload")
let hid=MismatchSwitchGate(accepts:{false},switched:{_ in});hid.incidentTrace=trace
_ = hid.receive(.flagsChanged,event(right,tag:123))
_ = hid.receive(.flagsChanged,event(right))
let accepted=MismatchSwitchGate(accepts:{true},switched:{_ in});accepted.incidentTrace=trace
check(accepted.receive(.flagsChanged,event(right))==nil,"HID accepts/consumes own press")
check(accepted.receive(.flagsChanged,event([]))==nil,"HID drains release")
for condition in [0,1,2,3,4,5,6] {
 let gate=OnsetInputGate(marker:0x48414E5100000001);gate.incidentTrace=trace
 var e=event([])
 switch condition {
 case 1:gate.stop()
 case 2:gate.heartbeat=0;gate.holdUntil=ProcessInfo.processInfo.systemUptime+1
 case 3:gate.beat();gate.holdUntil=ProcessInfo.processInfo.systemUptime-0.01
 case 4:gate.beat();_ = gate.begin();e=event(right)
 case 5:gate.beat();_ = gate.begin()
 case 6:e=event([],tag:gate.marker)
 default:break
 }
 _ = gate.receive(.flagsChanged,e)
}
// Exercise the gate's existing bounded lock failure; diagnostic work is after
// that lock, never inside it.
let lockedGate=OnsetInputGate(marker:0x48414E5100000002);lockedGate.incidentTrace=trace
let gateHeld=DispatchSemaphore(value:0),gateRelease=DispatchSemaphore(value:0),gateDone=DispatchSemaphore(value:0)
Thread{lockedGate.lock.lock();gateHeld.signal();gateRelease.wait();lockedGate.lock.unlock();gateDone.signal()}.start()
_ = gateHeld.wait(timeout:.now()+2)
check(lockedGate.receive(.flagsChanged,event(right)) != nil,"onset lock timeout still passes input")
gateRelease.signal();_ = gateDone.wait(timeout:.now()+2)
trace.flush();trace.mark();trace.flush()
let actualRows=captures.last!.frames.filter{$0.kind == .controlDecision}
for route in [16,17,18,19,20,21,22,24,28,29,6] {check(actualRows.contains{$0.category==route},"actual gate route represented \(route)")}
// Every fixed route survives the typed codec; this is schema coverage, not a
// claim that each main-app early return was reproduced on a physical keyboard.
for reason in 1...30 {var c=InputIncidentControl();c.route=reason;trace.control(.main,.flagsChanged,nil,c)}
var chained=InputIncidentControl();chained.role=1
chained.query(site:2,status:1,current:0,began:ProcessInfo.processInfo.systemUptime)
chained.query(site:1,status:4,current:1,target:2,available:2,korean:1,english:1,began:ProcessInfo.processInfo.systemUptime)
check(chained.priorQuery?.site==2 && chained.priorQuery?.status==1 && chained.queryStatus==4,"external and legacy reads both retained")
trace.control(.main,.flagsChanged,event(right),chained)
trace.flush();trace.mark();trace.flush()
var cap=captures.last!
let rows=cap.frames.filter{$0.kind == .controlDecision}
check(rows.contains{$0.controlEvidence?.incomingFlags==6 && $0.controlEvidence?.filterFlags==6 && $0.controlEvidence?.filterEdge==1},"incoming flags retained despite mutation")
for route in [16,17,18,20,21,22,24,28,29,6] {check(rows.contains{$0.category==route},"control route represented \(route)")}
let encoded=try JSONEncoder().encode(cap)
check((try? RecorderTrace.decode(encoded)) != nil,"strict collector reads controls and new counter codes")
let encodedText=String(data:encoded,encoding:.utf8)!
check(!encodedText.contains("private-") && !encodedText.contains("keyCode") && !encodedText.contains("sourceID"),"raw source and key data absent")
var object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
let index=(object["frames"] as! [[String:Any]]).firstIndex{$0["kind"] as? Int==11}!
for (key,bad) in [("text","private" as Any),("rawFlags",123 as Any),("queryStatus",6 as Any),("filterBefore",4 as Any),("role",true as Any)] {
 var altered=object;var frames=altered["frames"] as! [[String:Any]];var evidence=frames[index]["controlEvidence"] as! [String:Any];evidence[key]=bad;frames[index]["controlEvidence"]=evidence;altered["frames"]=frames
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:altered)))==nil,"reject unknown/private/invalid control \(key)")
}
var badChain=object;var chainedFrames=badChain["frames"] as! [[String:Any]]
let chainedIndex=chainedFrames.firstIndex{($0["controlEvidence"] as? [String:Any])?["priorQuery"] != nil}!
var chainedEvidence=chainedFrames[chainedIndex]["controlEvidence"] as! [String:Any]
var rawQuery=chainedEvidence["priorQuery"] as! [String:Any];rawQuery["sourceID"]="private"
chainedEvidence["priorQuery"]=rawQuery;chainedFrames[chainedIndex]["controlEvidence"]=chainedEvidence;badChain["frames"]=chainedFrames
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:badChain)))==nil,"nested query rejects raw source")
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2) == .success,"hold metadata lock")
var c=InputIncidentControl();c.role=1;c.route=14
let began=ProcessInfo.processInfo.systemUptime
trace.control(.main,.flagsChanged,event(right),c,consumed:true)
check(ProcessInfo.processInfo.systemUptime-began<0.05,"control caller does not wait for diagnostic lock")
Thread.sleep(forTimeInterval:0.06);release.signal();_ = done.wait(timeout:.now()+2)
trace.flush();trace.mark();trace.flush();cap=captures.last!
check(cap.frames.contains{$0.kind == .controlDecision && ($0.observationTiming?.contended == true || ($0.observationTiming?.queueMicros ?? 0)>=50000)},"important wait retained")
// Saturate the actual bounded metadata lane while its worker cannot progress.
let small=InputIncidentTrace(destination:nil,observationCapacity:4,writer:{overflowCaptures.append($0)})
var overflowCaptures:[InputIncidentTrace.Capture]=[]
let held2=DispatchSemaphore(value:0),release2=DispatchSemaphore(value:0),done2=DispatchSemaphore(value:0)
Thread{small.withLockedMetadataForTest{held2.signal();release2.wait()};done2.signal()}.start();_ = held2.wait(timeout:.now()+2)
let floodStart=ProcessInfo.processInfo.systemUptime
for _ in 0..<40{small.control(.main,.flagsChanged,nil,c)}
check(ProcessInfo.processInfo.systemUptime-floodStart<0.05,"queue overflow is nonblocking")
release2.signal();_ = done2.wait(timeout:.now()+2);small.flush();small.mark();small.flush()
let overflow=overflowCaptures.last!
check((overflow.observationDelivery.overflow[((6-1)*8+2-1)*32+9] ?? 0)>0,"overflow identifies main/right Command control")
check((try? RecorderTrace.decode(JSONEncoder().encode(overflow))) != nil,"overflow strict decode")
let off=InputIncidentTrace(destination:nil,initiallyEnabled:false,writer:{_ in})
check(InputIncidentControl.begin(off,.flagsChanged,event(right))==nil,"OFF skips control probe")
let out=CommandLine.arguments.dropFirst().first.map{URL(fileURLWithPath:$0)}
if let out{try encoded.write(to:out)}
print("PASS \(checks) control diagnostics checks; no global posts, physical keys or actual TIS queries")
