import Foundation
import Darwin
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
let reasons=["","accessibility_permission","secure_input","target_not_frontmost","focused_element_unreadable","secure_field","role_unreadable","not_supported_text_field","active_composition","text_unreadable","selection_unreadable","selection_invalid","focus_changed_during_snapshot","attribute_batch_unreadable","editor_coordinates_unverified"]
for (i,reason) in reasons.enumerated(){check(InputIncidentTrace.ReadOutcome.snapshot(reason).rawValue==i+1,"existing guard result maps to fixed code \(i+1)")}
check(InputIncidentTrace.ReadOutcome.snapshot("secure_text_field")==InputIncidentTrace.ReadOutcome.secureField,"engine secure field spellings agree")
check(InputIncidentTrace.ReadOutcome.snapshot("",includesContent:false)==InputIncidentTrace.ReadOutcome.metadataOnly,"role-only lookup never implies body was read")
check(InputIncidentTrace.ReadOutcome.snapshot("PRIVATE_UNKNOWN_REASON")==InputIncidentTrace.ReadOutcome.other,"unknown strings never enter serialized metadata")
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2)==DispatchTimeoutResult.success,"real worker metadata lock held")
let began=ProcessInfo.processInfo.systemUptime
for reason in InputIncidentTrace.ReadOutcome.allCases {
 let span=trace.beginRead(.onsetAX);trace.endRead(.onsetAX,span,outcome:reason)
}
let old=trace.beginRead(.mismatchAX);trace.endRead(.mismatchAX,old)
trace.mark()
check(ProcessInfo.processInfo.systemUptime-began<0.1,"completed outcome submissions do not wait for held lock")
release.signal();check(done.wait(timeout:.now()+2)==DispatchTimeoutResult.success,"worker released")
trace.flush();trace.mark();trace.flush()
let capture=captures.last!,frames=capture.frames
check(frames.filter{$0.kind == .read && $0.category==1}.allSatisfy{$0.readOutcome==nil},"no premature outcome on read starts")
let ends=frames.filter{$0.kind == .read && $0.category==2}
check(ends.compactMap{$0.readOutcome}==InputIncidentTrace.ReadOutcome.allCases,"all fixed results survive contention in read order")
check(ends.last?.readOutcome==nil,"legacy/uninstrumented span is unmeasured")
check(Set(ends.map{$0.event}).count==18,"outcomes retain individual read correlation")
let data=try! JSONEncoder().encode(capture)
check((try? RecorderTrace.decode(data)) != nil,"strict collector accepts actual result frames")
if let out=CommandLine.arguments.dropFirst().first {try! data.write(to:URL(fileURLWithPath:out))}
var object=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
let base=object["frames"] as! [[String:Any]],index=base.firstIndex{$0["readOutcome"] != nil}!
for bad:Any in [0,18,true,"PRIVATE",["text":"PRIVATE"]] {
 var rows=base;rows[index]["readOutcome"]=bad;object["frames"]=rows
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"strict decoder rejects malformed or private payload")
}
for patch:[String:Any] in [["kind":1],["lane":2],["category":1]] {
 var rows=base;rows[index].merge(patch){_,new in new};object["frames"]=rows
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"outcome is limited to completed AX read")
}
object["frames"]=base.map{row in var r=row;r.removeValue(forKey:"readOutcome");return r}
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object))) != nil,"old capture with no outcome remains valid")
let off=InputIncidentTrace(destination:nil,initiallyEnabled:false,writer:{_ in check(false,"OFF never writes")})
let disabled=off.beginRead(.onsetAX);off.endRead(.onsetAX,disabled,outcome:.textUnreadable);off.mark();off.flush()
check(disabled==nil,"OFF does not allocate read result")
print("PASS \(checks) snapshot outcome mapping/contention/correlation/privacy/legacy/OFF checks")
