import Foundation
import ApplicationServices
var checks=0
func check(_ ok:@autoclosure()->Bool,_ message:String){checks+=1;if !ok(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
var wall=100.0,cpu:UInt64?=100_000_000,cpuCalls=0,wallCalls=0,captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,clock:{wallCalls+=1;return wall},callbackCPU:{cpuCalls+=1;return cpu},writer:{captures.append($0)})
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
event.timestamp=1_000_000_000_000
let secret="PRIVATE_INDIRECT_INPUT_SENTINEL";event.keyboardSetUnicodeString(stringLength:secret.utf16.count,unicodeString:Array(secret.utf16))
func capture()->InputIncidentTrace.Capture{trace.flush();trace.finishCaptureWindowsForTest();trace.drainCapturesForTest();trace.flush();trace.mark();trace.flush();let value=captures.last!;trace.finishCaptureWindowsForTest();trace.flush();return value}
func work()->InputIncidentTrace.WorkEvidence{capture().frames.last{$0.workEvidence != nil}!.workEvidence!}
check(trace.beginCallback(.keyUp)==nil && cpuCalls==0,"up events do not sample CPU")
let span=trace.beginCallback(.keyDown);wall+=0.020;cpu!+=2_000_000
trace.event(.main,.keyDown,event,duration:0.020,started:span)
let w=work();check(w.clockValid && abs(w.endedAtMicros-w.beganAtMicros-20_000)<=1 && w.cpuMicros==2000 && w.cpuState==1,"same-thread wall and CPU independently recorded")
let read=trace.beginRead(.onsetAX);wall+=0.005;trace.endRead(.onsetAX,read);let rw=work()
check(rw.cpuState==0 && rw.cpuMicros==nil && abs(rw.endedAtMicros-rw.beganAtMicros-5000)<=1,"existing snapshot interval; no per-AX CPU sample")
check(cpuCalls==2,"only callback start/end sample CPU")
let unavailable=trace.beginCallback(.keyDown);cpu=nil;wall+=0.001;trace.event(.mismatch,.keyDown,event,started:unavailable)
check(work().cpuState==2 && work().cpuMicros==nil,"failed CPU sample distinct from zero")
cpu=100;let reversed=trace.beginCallback(.keyDown);cpu=99;wall+=0.001;trace.event(.onset,.keyDown,event,started:reversed)
check(work().cpuState==4 && work().cpuMicros==nil,"counter reversal explicit")
let cross=trace.beginCallback(.keyDown),done=DispatchSemaphore(value:0)
Thread{trace.event(.hid,.keyDown,event,started:cross);done.signal()}.start()
check(done.wait(timeout:.now()+2) == .success,"cross-thread end returns")
check(work().cpuState==3 && work().cpuMicros==nil,"cross-thread subtraction forbidden")
let backwards=trace.beginCallback(.keyDown);wall-=0.01;trace.event(.main,.keyDown,event,started:backwards)
let bw=work();check(!bw.clockValid && bw.cpuState==5 && bw.beganAtMicros==0 && bw.endedAtMicros==0,"invalid wall explicit, no invented duration")
wall+=0.02
var probe=InputIncidentShapeProbe()
func observe(_ range:NSRange,identity:UInt=1,generation:Int32=trace.collectionGeneration)->InputIncidentTrace.ShapeChange{
 probe.observe(identity:identity,text:"abcde",selection:range,generation:generation)
}
check(observe(NSRange(location:3,length:0)).selectionMotion==0,"first observation unknown")
check(observe(NSRange(location:3,length:0)).selectionMotion==1,"same cursor")
check(observe(NSRange(location:2,length:0)).selectionMotion==2,"backward cursor")
check(observe(NSRange(location:4,length:0)).selectionMotion==3,"forward cursor")
check(observe(NSRange(location:1,length:2)).selectionMotion==4,"selection started")
check(observe(NSRange(location:1,length:3)).selectionMotion==6,"selection changed")
check(observe(NSRange(location:1,length:0)).selectionMotion==5,"selection collapsed")
check(observe(NSRange(location:9,length:0)).selectionMotion==7,"invalid range explicit")
check(observe(NSRange(location:2,length:0),identity:2).selectionMotion==0,"new field unknown")
check(observe(NSRange(location:3,length:0),identity:2,generation:trace.collectionGeneration+2).selectionMotion==0,"new generation unknown")
// Trace must not promote a probe-relative movement across a context boundary or missing sample.
var p=InputIncidentShapeProbe()
func shape(_ n:Int){let change=p.observe(identity:3,text:"abcde",selection:NSRange(location:n,length:0),generation:trace.collectionGeneration);trace.shape(.onsetAX,identity:3,count:5,selected:false,editing:false,change:change);trace.flush()}
shape(3);shape(2);check(capture().shapeBaselines!.first{$0.lane == .onsetAX}!.current.evidence.selectionMotion==2,"motion survives encode snapshot")
trace.context();trace.flush();shape(1);check(capture().shapeBaselines!.first{$0.lane == .onsetAX}!.current.evidence.selectionMotion==0,"invalidated shape cannot infer movement")
let missed=p.observe(identity:3,text:"abcde",selection:NSRange(location:0,length:0),generation:trace.collectionGeneration);check(missed.selectionMotion==2,"deliberate unsubmitted observation")
shape(2);check(capture().shapeBaselines!.first{$0.lane == .onsetAX}!.current.evidence.selectionMotion==0,"sample gap cannot infer movement")
let c=capture(),data=try! JSONEncoder().encode(c),sanitized=try! RecorderTrace.decode(data),roundtrip=try! RecorderTrace.decode(JSONEncoder().encode(sanitized))
check(roundtrip.frames.contains{$0.workEvidence?.cpuState==1},"strict collector and sanitize retain measurements")
let json=String(data:data,encoding:.utf8)!
for name in [secret,"keyCode","characters","clipboard","location","threadID"]{check(!json.contains(name),"private payload excluded: \(name)")}
var object=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
let rows=object["frames"] as! [[String:Any]],index=rows.firstIndex{$0["workEvidence"] != nil}!,base=rows[index]["workEvidence"] as! [String:Any]
for (key,value) in [("text",secret as Any),("beganAtMicros",-1),("cpuState",true),("cpuMicros",true),("clockValid",1),("endedAtMicros",-1)]{
 var badRows=rows,bad=base;bad[key]=value;badRows[index]["workEvidence"]=bad;object["frames"]=badRows
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"strict invalid/private work rejected \(key)")
}
object["frames"]=rows.map{row -> [String:Any] in var r=row;r.removeValue(forKey:"workEvidence");return r}
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object))) != nil,"old logs remain compatible and unmeasured")
let off=InputIncidentTrace(destination:nil,initiallyEnabled:false,clock:{wallCalls+=1;return wall},callbackCPU:{cpuCalls+=1;return cpu},writer:{_ in})
let oldCPU=cpuCalls,oldWall=wallCalls
check(off.beginCallback(.keyDown)==nil && cpuCalls==oldCPU && wallCalls==oldWall,"OFF does not read either clock")
let stale=trace.beginCallback(.keyDown);trace.setCollectionEnabled(false);trace.event(.main,.keyDown,event,started:stale);trace.flush()
check(cpuCalls==oldCPU+1,"disabled completion does not sample CPU or emit work")
if let output=CommandLine.arguments.dropFirst().first{try! data.write(to:URL(fileURLWithPath:output))}
print("PASS \(checks) indirect timing/cursor/privacy/compatibility checks; no keys posted or AX queries")
