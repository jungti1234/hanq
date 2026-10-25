import Foundation
import ApplicationServices
import Darwin
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
let a=AXUIElementCreateApplication(111),b=AXUIElementCreateApplication(222)
let probe=InputIncidentFocusProbe()
func sample(_ element:AXUIElement?,role:String?="AXGroup",route:Int=1,owner:pid_t?=111)->InputIncidentFocusProbe.Read {
 var read=InputIncidentFocusProbe.Read(target:111);read.observe(element,owner:owner,route:route)
 if element != nil{read.observedRole(role)}
 return read
}
let first=probe.finish(sample(a),generation:1,path:1)!
check(first.role==6 && first.elementRelation==1 && first.ownerRelation==1,"failed group role retains first focus observation")
let same=probe.finish(sample(a),generation:1,path:1)!
check(same.elementRelation==2,"same unsupported element is recognized")
let changed=probe.finish(sample(b,role:"AXTextArea",owner:222),generation:1,path:1)!
check(changed.elementRelation==3 && changed.role==2 && changed.ownerRelation==2,"new element and different owner are distinct fixed observations")
check(probe.finish(sample(b),generation:3,path:1)!.elementRelation==1,"settings generation clears continuity")
check(probe.finish(nil,generation:3,path:1)==nil,"unmeasured/secure/OFF path resets without metadata")
check(probe.finish(sample(b),generation:3,path:1)!.elementRelation==1,"missing read breaks continuity")
var moving=sample(a);moving.observe(b,owner:222,route:1)
check(probe.finish(moving,generation:3,path:1)!.withinRead==2,"existing recheck detects within-read change")
check(probe.finish(sample(a),generation:3,path:1)!.elementRelation==1,"changed read does not establish stable continuity")
var missing=sample(a);missing.observe(nil,owner:nil,route:2)
check(probe.finish(missing,generation:3,path:1)!.withinRead==3,"failed recheck differs from stable focus")
let absent=probe.finish(sample(nil,route:2,owner:nil),generation:3,path:1)!
check(absent.elementRelation==0 && absent.ownerRelation==3 && absent.role==0,"no element is not a negative identity match")
var twice=sample(a,role:"AXTextField",route:2);twice.observe(a,owner:111,route:2)
check(probe.finish(twice,generation:3,path:1)!.withinRead==1,"same recheck and fallback remain distinguishable")
for role in ["AXTextArea","AXTextField","AXComboBox","AXWebArea","AXGroup","AXButton","AXWindow","AXApplication"] {
 check((2...9).contains(InputIncidentFocusEvidence.role(role)),"fixed role whitelist")
}
check(InputIncidentFocusEvidence.role("PRIVATE_ROLE_SENTINEL")==10 && InputIncidentFocusEvidence.role(nil)==1,"unknown/unavailable role never serializes raw string")
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2)==DispatchTimeoutResult.success,"worker lock held")
let began=ProcessInfo.processInfo.systemUptime
for path in 1...3 {
 let lane:InputIncidentTrace.Lane=path==1 ? .onsetAX:.mismatchAX
 let span=trace.beginRead(lane)
 let focus=InputIncidentFocusProbe().finish(sample(a,role:"PRIVATE_ROLE_SENTINEL"),generation:1,path:path)
 trace.endRead(lane,span,outcome:.unsupportedTextField,focus:focus)
}
trace.mark()
check(ProcessInfo.processInfo.systemUptime-began<0.1,"focus metadata never waits for writer lock")
release.signal();check(done.wait(timeout:.now()+2)==DispatchTimeoutResult.success,"lock released")
trace.flush();trace.mark();trace.flush()
let capture=captures.last!,data=try! JSONEncoder().encode(capture)
check(!String(data:data,encoding:.utf8)!.contains("PRIVATE_ROLE_SENTINEL"),"private role excluded")
check((try? RecorderTrace.decode(data)) != nil,"actual producer frames accepted by strict collector")
let ends=capture.frames.filter{$0.focusEvidence != nil}
check(ends.count==3 && ends.map{$0.focusEvidence!.path}==[1,2,3],"all snapshot paths retain evidence on correlated read ends")
check(capture.frames.filter{$0.category==1}.allSatisfy{$0.focusEvidence==nil},"read starts do not claim completed focus")
if let output=CommandLine.arguments.dropFirst().first{try! data.write(to:URL(fileURLWithPath:output))}
var object=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
let original=object["frames"] as! [[String:Any]],index=original.firstIndex{$0["focusEvidence"] != nil}!
let focus=original[index]["focusEvidence"] as! [String:Any]
for patch:[String:Any] in [["path":0],["path":4],["role":11],["role":true],["route":3],["ownerRelation":4],["elementRelation":4],["withinRead":4],["role":"PRIVATE"],["text":"PRIVATE"]] {
 var rows=original;var bad=focus;bad.merge(patch){_,new in new};rows[index]["focusEvidence"]=bad;object["frames"]=rows
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"strict collector rejects invalid/private focus payload")
}
for patch:[String:Any] in [["kind":1],["category":1],["lane":2]] {
 var rows=original;rows[index].merge(patch){_,new in new};object["frames"]=rows
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"focus evidence restricted to matching snapshot completion")
}
var rows=original;rows[index].removeValue(forKey:"readOutcome");object["frames"]=rows
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"unbound focus evidence rejected")
object["frames"]=original.map{row in var row=row;row.removeValue(forKey:"focusEvidence");return row}
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object))) != nil,"old captures remain accepted")
let off=InputIncidentTrace(destination:nil,initiallyEnabled:false,writer:{_ in check(false,"OFF never writes")})
off.endRead(.onsetAX,off.beginRead(.onsetAX),outcome:.unsupportedTextField,focus:first);off.mark();off.flush()
print("PASS \(checks) focus role/identity/gaps/contention/privacy/strict/legacy/OFF checks")
