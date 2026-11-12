import Foundation
import ApplicationServices
import Carbon

var checks=0
var failureEvidence:(()->Void)?
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){failureEvidence?();fputs("FAIL: \(message)\n",stderr);exit(1)}}
func strict(_ capture:InputIncidentTrace.Capture)->Bool{(try? RecorderTrace.decode(JSONEncoder().encode(capture))) != nil}
var time=100.0,captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(secureInput:{false},destination:nil,clock:{time},writer:{captures.append($0)})
failureEvidence={
    trace.flush()
    fputs("ENV secureNow=\(IsSecureEventInputEnabled()) enabled=\(trace.enabled) generation=\(trace.collectionGeneration) onsetCounts=\(captures.map{$0.frames.filter{$0.kind == .onsetDecision}.count})\n",stderr)
    if CommandLine.arguments.count>1 {
        try? JSONEncoder().encode(captures).write(to:URL(fileURLWithPath:CommandLine.arguments[1]+".failure.json"))
    }
}
trace.shape(.onsetAX,identity:1,count:1,selected:false,editing:false)
trace.flush()
for _ in 0..<200{trace.onsetDecision(.reservation,.baselineMissing,firstTime:99.9,keys:1)}
trace.onsetDecision(.publication,.publicationObserved,firstTime:99.9,keys:1)
trace.flush();trace.mark();trace.flush()
check(captures.count==1,"manual pre captured")
let before=captures[0],decisions=before.frames.filter{$0.kind == .onsetDecision}
check(decisions.count==2,"same attempt/reason/key count is bounded and coalesced")
check(decisions.allSatisfy{$0.lane == .onset && $0.onsetEvidence?.keys==1 && (99_990...100_010).contains($0.onsetEvidence?.firstKeyAgeMicros ?? -1)},"counts and measured age retained")
check(before.observationDelivery.coalesced[1361]==199,"onset metadata coalescing has its own fixed code")
check(before.frames.filter{$0.kind == .shape}.allSatisfy{$0.shapeEvidence?.editing==false},"diagnostic branch records never become edit states")
time=100.2
trace.onsetDecision(.history,.proofCurrent,firstTime:99.9,keys:2)
trace.onsetDecision(.history,.historyCandidate,firstTime:99.9,keys:2)
trace.onsetDecision(.history,.proofCurrent,firstTime:99.9,keys:2)
trace.onsetDecision(.history,.historyCandidate,firstTime:99.9,keys:2)
trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(captures.count==2,"manual post saved")
check(captures[1].frames.filter{$0.kind == .onsetDecision}.count==2,"alternating sample stages do not flood the ring")
check(captures[1].frames.filter{$0.kind == .onsetDecision}.allSatisfy{$0.onsetEvidence != nil},"post-window copies include finalized evidence")
check(captures.allSatisfy(strict),"new frames and observation counters pass strict collector")
let encoded=try! JSONEncoder().encode(before)
let raw=String(data:encoded,encoding:.utf8)!
for forbidden in ["sourceID","keycode","clipboard","text\":","com.openai","arbitrary prior"]{check(!raw.contains(forbidden),"no payload \(forbidden)")}

let object=try! JSONSerialization.jsonObject(with:encoded) as! [String:Any]
func invalid(_ update:(inout [String:Any])->Void){
    var value=object,rows=value["frames"] as! [[String:Any]]
    let index=rows.firstIndex{($0["kind"] as? Int)==13}!
    update(&rows[index]);value["frames"]=rows
    let data=try! JSONSerialization.data(withJSONObject:value)
    check((try? RecorderTrace.decode(data))==nil,"invalid onset evidence rejected")
}
invalid{$0["category"]=26};invalid{$0["edge"]=5};invalid{$0["lane"]=4};invalid{$0["event"]=1}
invalid{$0["onsetEvidence"]=["keys":true]};invalid{$0["onsetEvidence"]=["keys":17]}
invalid{$0["onsetEvidence"]=["keys":1,"firstKeyAgeMicros":-1]}
invalid{$0["onsetEvidence"]=["keys":1,"firstKeyAgeMicros":60_000_001]}
invalid{$0["onsetEvidence"]=["keys":1,"firstKeyAgeMicros":0.5]}
invalid{$0["onsetEvidence"]=["keys":1,"text":"private"]}
invalid{$0["kind"]=6}

var disabledCaptures:[InputIncidentTrace.Capture]=[]
let off=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:false,writer:{disabledCaptures.append($0)})
for _ in 0..<100{off.onsetDecision(.publication,.representationMissing,firstTime:99,keys:1)}
off.mark();off.flush();check(disabledCaptures.isEmpty,"OFF creates no branch capture")
off.stopAndFlush()

trace.setCollectionEnabled(false);trace.flush();trace.setCollectionEnabled(true);trace.flush()
trace.onsetDecision(.reservation,.baselineMissing,firstTime:99.9,keys:1)
trace.flush();trace.mark();trace.flush()
check(captures.last!.frames.filter{$0.kind == .onsetDecision}.count==1,"new ON generation clears coalescing state")
trace.stopAndFlush()

var saturated:[InputIncidentTrace.Capture]=[]
let busy=InputIncidentTrace(secureInput:{false},destination:nil,observationCapacity:4,writer:{saturated.append($0)})
let start=ProcessInfo.processInfo.systemUptime
busy.withLockedMetadataForTest{for i in 0..<1000{busy.onsetDecision(.history,.historyRejected,firstTime:Double(i),keys:2)}}
let elapsed=ProcessInfo.processInfo.systemUptime-start
busy.flush();busy.mark();busy.flush();busy.stopAndFlush()
check(elapsed<0.5,"caller never waits for a held metadata lock")
check(saturated.contains{!$0.observationDelivery.overflow.isEmpty},"saturation counted without blocking input")
check(saturated.allSatisfy(strict),"saturated metadata remains strict and bounded")
if CommandLine.arguments.count>1{try! encoded.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
print("PASS \(checks) onset decision capture, privacy, strict compatibility, OFF and contention checks")
