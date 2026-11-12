import Foundation
import Darwin

var checks=0
func check(_ value:@autoclosure ()->Bool,_ title:String){checks+=1;if !value(){fputs("FAIL: \(title)\n",stderr);exit(1)}}
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(secureInput:{false},destination:nil,writer:{captures.append($0)})
var value=InputIncidentTrace.BoundaryEvidence(transaction:1,phase:2,reason:0,text:1,start:3,end:3,expected:1,reported:1,change:0,resolution:5,
    seed:1,mutation:10,revision:2,observations:1,suppressed:0,coalesced:0,fieldRelation:1,
    baselineAgeMicros:60000000,mutationAgeMicros:3,requestAgeMicros:1000,sampleAgeMicros:0)
trace.boundaryComparison(value);trace.mark();trace.flush()
value.phase=3;value.reason=1;value.start=2;value.end=2;value.change=2;value.resolution=2;value.observations=2
trace.boundaryComparison(value);trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(captures.count==2,"one manual pre/post window")
for capture in captures {
    let data=try! JSONEncoder().encode(capture)
    check((try? RecorderTrace.decode(data)) != nil,"actual comparison producer accepted by strict recorder")
    let frames=capture.frames.filter{$0.boundaryEvidence != nil}
    check(frames.count==1 && frames[0].kind.rawValue==14 && frames[0].lane.rawValue==8,"comparison has dedicated frame, never a false source commit or wait")
    check(try! JSONEncoder().encode(frames[0]).count<1024,"fixed comparison record stays below 1KiB in producer fixture")
    if capture.phase==1 {check(frames[0].boundaryEvidence?.phase==3 && frames[0].boundaryEvidence?.resolution==2,"post-window preserves evidence attached after append")}
    if CommandLine.arguments.count>1 {try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]+"-\(capture.phase).json"))}
}
let data=try! JSONEncoder().encode(captures[0])
var object=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
let original=object["frames"] as! [[String:Any]],index=original.firstIndex{$0["kind"] as? Int==14}!
let evidence=original[index]["boundaryEvidence"] as! [String:Any]
check(InputIncidentTrace.BoundaryEvidence.parse(evidence) != nil,"review parser accepts actual producer")
for patch:[String:Any] in [["transaction":0],["phase":4],["phase":true],["reason":1],["text":6],["start":4],["end":false],["expected":3],["change":5],["resolution":6],["seed":14],["mutation":14],["revision":-1],["revision":1.5],["observations":1000001],["suppressed":-1],["fieldRelation":3],["baselineAgeMicros":60000001],["sampleAgeMicros":NSNull()],["actualLocation":77],["body":"PRIVATE"],["baselineAgeMicros":true]] {
    var bad=evidence;bad.merge(patch){_,new in new}
    check(InputIncidentTrace.BoundaryEvidence.parse(bad)==nil,"review rejects invalid/private comparison payload")
    var rows=original;rows[index]["boundaryEvidence"]=bad;object["frames"]=rows
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"strict recorder rejects invalid/private comparison payload")
}
for patch:[String:Any] in [["kind":7],["lane":2],["count":1],["edge":1],["event":1],["onsetEvidence":["keys":1]],["body":"PRIVATE"]] {
    var rows=original;rows[index].merge(patch){_,new in new};object["frames"]=rows
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"comparison restricted to its dedicated metadata frame")
}
var old=original.filter{$0["kind"] as? Int != 14};object["frames"]=old
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object))) != nil,"legacy record without comparisons remains accepted")
let off=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:false,writer:{_ in fatalError("OFF must not write")})
off.boundaryComparison(value);off.mark();off.flush()
print("PASS \(checks) boundary comparison wire checks")
