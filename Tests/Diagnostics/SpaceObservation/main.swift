import Foundation
import ApplicationServices
import Darwin

var checks=0
func check(_ ok:@autoclosure ()->Bool,_ name:String){checks+=1;precondition(ok(),name)}
var tick:UInt64=1
func key(_ code:UInt16=49,_ down:Bool=true,creator:Int64=0,repeatFlag:Bool=false,replay:Bool=false)->CGEvent {
    let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
    tick+=1;e.timestamp=tick*1_000_000
    e.setIntegerValueField(.eventSourceUnixProcessID,value:creator)
    e.setIntegerValueField(.keyboardEventAutorepeat,value:repeatFlag ? 1:0)
    if replay{e.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x48414E5100000001))}
    return e
}
var time=100.0,rows:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,capacity:64,clock:{time},writer:{rows.append($0)})
trace.event(.hid,.keyDown,key());time+=0.031
trace.event(.hid,.keyUp,key(49,false));time+=0.012
let second=key(creator:123456789)
trace.event(.hid,.keyDown,second);trace.event(.main,.keyDown,second);trace.flush()
check(rows.count==1 && rows[0].trigger == .spaceObservation,"43ms space pair freezes pre without manual mark")
let request=rows[0].capturePreservation!.requests[0]
check(request.trigger==7 && request.detail==1 && request.lane==1 && request.event>0,"rapid condition keeps original event identity and lane")
check(rows[0].frames.filter{$0.kind == .event && $0.edge==1 && $0.lane == .hid}.count==2,"both down edges retained, not one event counted in two lanes")
let evidence=rows[0].frames.last{$0.lane == .hid}!.eventEvidence!
check(evidence.creatorClass==3 && evidence.autoRepeat==false,"creator relation and repeat flag are fixed metadata")
trace.state(.onset,.buffered,pending:1);trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(rows.count==2 && rows[1].frames.contains{$0.kind == .state},"post preserves intervention state")
for capture in rows {check((try? RecorderTrace.decode(JSONEncoder().encode(capture))) != nil,"strict roundtrip accepts trigger7 and space provenance")}
let data=try JSONEncoder().encode(rows[0]);let text=String(decoding:data,as:UTF8.self)
check(!text.contains("123456789") && !text.contains("keyboardEventKeycode"),"raw creator PID and key values excluded")
for changes:[String:Any] in [["creatorClass":4],["creatorClass":NSNull()],["autoRepeat":1],["pid":123456789],["keyClass":2]] {
    var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
    var frames=object["frames"] as! [[String:Any]]
    var e=frames[0]["eventEvidence"] as! [String:Any]
    e.merge(changes){_,n in n};frames[0]["eventEvidence"]=e;object["frames"]=frames
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"invalid creator/repeat or arbitrary PID rejected")
}

for (detail,lane,creator,repeating,replay,consumed) in [(2,InputIncidentTrace.Lane.onset,Int64(0),false,false,true),(3,.main,Int64(getpid()),false,true,false),(4,.hid,Int64(getpid()),true,false,false)] {
    var local:[InputIncidentTrace.Capture]=[]
    let t=InputIncidentTrace(destination:nil,clock:{time},writer:{local.append($0)})
    t.event(lane,.keyDown,key(creator:creator,repeatFlag:repeating,replay:replay),consumed:consumed);t.flush()
    check(local.first?.capturePreservation?.requests.first?.detail==detail,"consumed/replay/repeat requests are distinguished")
    t.stopAndFlush();check(local.allSatisfy{(try? RecorderTrace.decode(JSONEncoder().encode($0))) != nil},"intervention capture remains strict")
}
for separated in [false,true] {
    var local:[InputIncidentTrace.Capture]=[]
    let t=InputIncidentTrace(destination:nil,clock:{time},writer:{local.append($0)})
    t.event(.hid,.keyDown,key());time+=separated ? 0.03:0.081
    if separated {t.event(.hid,.keyDown,key(0));time+=0.01}
    t.event(.hid,.keyDown,key());t.flush();check(local.isEmpty,"ordinary gaps or intervening letter do not trigger")
    t.stopAndFlush()
}
var bounded:[InputIncidentTrace.Capture]=[]
let boundedTrace=InputIncidentTrace(destination:nil,clock:{time},writer:{bounded.append($0)})
for _ in 0..<20 {boundedTrace.event(.hid,.keyDown,key());time+=0.01;boundedTrace.flush()}
check(bounded.first?.captureBacklog?.requested[7]==1,"per-condition one-second admission limit")
boundedTrace.stopAndFlush()
var off:[InputIncidentTrace.Capture]=[]
let disabled=InputIncidentTrace(destination:nil,initiallyEnabled:false,clock:{time},writer:{off.append($0)})
disabled.event(.hid,.keyDown,key(),consumed:true);disabled.flush();check(off.isEmpty,"OFF produces no automatic capture")
var resetRows:[InputIncidentTrace.Capture]=[]
let reset=InputIncidentTrace(destination:nil,clock:{time},writer:{resetRows.append($0)})
reset.event(.hid,.keyDown,key());reset.flush()
reset.setCollectionEnabled(false);reset.flush();reset.setCollectionEnabled(true);reset.flush()
time+=0.02;reset.event(.hid,.keyDown,key());reset.flush()
check(reset.enabled && resetRows.isEmpty,"OFF/ON clears an older space pair boundary")
reset.stopAndFlush()

// The input caller can submit a suspect sequence while the metadata lock is held.
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
var contended:[InputIncidentTrace.Capture]=[]
let busy=InputIncidentTrace(destination:nil,clock:{time},writer:{contended.append($0)})
DispatchQueue.global().async{busy.withLockedMetadataForTest{entered.signal();release.wait()};done.signal()}
entered.wait();let began=ProcessInfo.processInfo.systemUptime
busy.event(.hid,.keyDown,key(),consumed:true)
let elapsed=ProcessInfo.processInfo.systemUptime-began;release.signal();done.wait();busy.flush()
check(elapsed<0.05 && contended.first?.trigger == .spaceObservation,"capture detection never waits in input caller")
busy.stopAndFlush()
var bad=try JSONSerialization.jsonObject(with:data) as! [String:Any]
let preservation=bad["capturePreservation"] as! [String:Any]
for changes:[String:Any] in [["detail":5],["lane":6],["event":0],["text":"PRIVATE"]] {
    let raw=(preservation["requests"] as! [[String:Any]])[0]
    var p=preservation;p["requests"]=[raw.merging(changes){_,n in n}];bad["capturePreservation"]=p
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:bad)))==nil,"invalid space capture cause or content rejected")
}
if CommandLine.arguments.count>1 {try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.withoutOverwriting)}
print("PASS: \(checks) rapid-space/intervention preservation, provenance privacy, bounds/OFF and nonblocking checks; no keys posted")
