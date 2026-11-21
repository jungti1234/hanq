import AppKit

var checks=0
func check(_ condition:@autoclosure ()->Bool,_ name:String){checks+=1;if !condition(){fputs("FAIL: \(name)\n",stderr);exit(1)}}
let field=AXUIElementCreateApplication(97501),other=AXUIElementCreateApplication(97502)
func snapshot(_ text:String,_ caret:Int?=nil,_ target:AXUIElement=field)->OnsetSnapshot {
    .init(element:target,text:text,selection:NSRange(location:caret ?? text.utf16.count,length:0))
}
func passed(_ keys:[UInt16]=[15,40],_ time:Double=10,_ source:String=onsetKoreanID)->OnsetInputGate.PassedInput {
    .init(first:.init(code:keys[0],shift:false,time:time,sourceID:source),keys:keys.map{($0,false)},pressed:[])
}
// Synthetic snapshots, real observer/composer/trace/strict readers. No AX read,
// global tap, source switch, clipboard, selection write or posted input.
var evidence:[InputIncidentTrace.OnsetObservation]=[],captures:[Bool]=[]
func probe(_ before:String?,_ caret:Int?=nil)->OnsetDiagnosticHistory {
    let p=OnsetDiagnosticHistory();p.emit={evidence.append($0);captures.append($1)}
    if let before{p.remember(snapshot(before,caret),at:9.95)}
    return p
}
let delayed=probe("")
delayed.observe(snapshot("ㄱ"),passed:passed([15]),source:onsetKoreanID,at:10.03)
delayed.observe(snapshot("ㄱ"),passed:passed(),source:onsetKoreanID,at:10.09)
delayed.observe(snapshot("ㄱㅏ"),passed:nil,source:onsetKoreanID,at:10.12)
check(evidence.last?.history==2 && evidence.last?.whole==2 && evidence.last?.insertion==2,"late split is compared after gate rejection")
check(evidence.last?.baseline==2 && evidence.last?.draft==2,"pre-key empty snapshot retained independently")
delayed.observe(snapshot("ㄱㅏ나"),passed:nil,source:onsetKoreanID,at:10.2)
check(evidence.last?.whole==5,"following text retains literal split-prefix comparison")
check(captures.filter{$0}.count==1,"one automatic capture request per observed pair")
let ambiguous=probe("ㄱㅏ")
ambiguous.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.whole==2 && evidence.last?.draft==1 && evidence.last?.insertion==0,"existing draft matching keys remains visibly ambiguous")
let normal=probe("")
normal.observe(snapshot("가"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.whole==3 && evidence.last?.insertion==3 && evidence.last?.unicode==5,"normal composition comparison recorded")
let middle=probe("좌우",1)
middle.observe(snapshot("좌ㄱㅏ우",3),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.whole==7 && evidence.last?.insertion==2 && evidence.last?.selection==3,"surrounding draft isolates inserted span without storing positions")
let quoted = probe("\"뒤", 0)
quoted.observe(snapshot("ㄱ\"뒤", 1), passed: passed([15]), source: onsetKoreanID, at: 10.04)
check(evidence.last?.insertionEndRelation == 1, "first jamo caret at insertion end")
quoted.observe(snapshot("가\"뒤", 1), passed: passed(), source: onsetKoreanID, at: 10.12)
check(evidence.last?.insertionEndRelation == 1, "composed syllable before quote")
quoted.observe(snapshot("가\"뒤", 2), passed: passed(), source: onsetKoreanID, at: 10.13)
check(evidence.last?.insertionEndRelation == 2, "caret crossed one existing unit")
quoted.observe(snapshot("가\"뒤", 3), passed: passed(), source: onsetKoreanID, at: 10.14)
check(evidence.last?.insertionEndRelation == 3, "other distance remains distinct")
let supplementary = probe("🙂뒤", 2)
supplementary.observe(snapshot("🙂가뒤", 3), passed: passed(), source: onsetKoreanID, at: 10.12)
check(evidence.last?.insertionEndRelation == 1, "UTF-16 baseline after surrogate pair")
let selected = OnsetSnapshot(element: field, text: "🙂가뒤", selection: NSRange(location: 3, length: 1))
supplementary.observe(selected, passed: passed(), source: onsetKoreanID, at: 10.13)
check(evidence.last?.insertionEndRelation == 0, "noncollapsed selection has no caret")
let replaced=probe("기존 초안")
replaced.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.draft==3 && evidence.last?.whole==2,"whole-body replacement is not described as insertion into old draft")
let noPrior=probe(nil)
noPrior.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.baseline==1 && evidence.last?.insertion==0,"missing baseline never invented")
let after=probe(nil)
after.remember(snapshot("ㄱ"),at:10.01)
after.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.baseline==4,"post-key-only baseline explicitly identified")
let old=probe(nil)
old.remember(snapshot(""),at:9)
old.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.baseline==3,"old observation identified, never refreshed by timestamp alone")
let literal=probe("")
literal.observe(snapshot("가"),passed:passed(),source:onsetKoreanID,at:10.12)
check(evidence.last?.whole==7 && evidence.last?.unicode==3,"canonical equivalence does not erase modern jamo evidence")
literal.notification(1,at:10.13)
check(evidence.last?.phase==2 && evidence.last?.reason==1,"AX value notification linked without claiming causation")
literal.observe(snapshot("가",nil,other),passed:nil,source:onsetKoreanID,at:10.14)
check(!literal.active && evidence.last?.phase==3 && evidence.last?.reason==3,"field change ends diagnostic episode")
let unsupported=probe("")
unsupported.observe(snapshot("ㄱㅏ"),passed:passed([15,40],10,"unsupported"),source:"unsupported",at:10.12)
check(evidence.last?.whole==0,"unknown layout never falls back")
let uncomposable=probe("")
uncomposable.observe(snapshot("ㄱㄱ"),passed:passed([15,15]),source:onsetKoreanID,at:10.12)
check(evidence.last?.whole==2,"unchanged composition output is not labeled composed")
let lifecycle=probe("")
lifecycle.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.12)
let priorCount=evidence.count
for n in 1...20{lifecycle.observe(snapshot("ㄱㅏ"),passed:nil,source:onsetKoreanID,at:10.12+Double(n)/1000)}
check(evidence.count<=priorCount+1,"unchanged polls coalesced")
lifecycle.observe(snapshot("ㄱㅏ"),passed:nil,source:onsetKoreanID,at:12.01)
check(!lifecycle.active && evidence.last?.reason==1 && evidence.last!.coalesced>0,"two-second expiry records suppression and clears keys")
for n in 0..<100{lifecycle.remember(snapshot("合成",nil,AXUIElementCreateApplication(pid_t(98000+n))),at:13+Double(n)/100)}
check(lifecycle.retainedSnapshots<=16,"idle cache bounded across fields")
lifecycle.reset();check(lifecycle.retainedSnapshots==0,"reset erases diagnostic cache")
// Existing AX results, including failed content reads, reach the ordinary
// automatic/manual incident writer. No synthetic native provenance is supplied.
func read(_ mark:InputIncidentMarkedRange,_ target:AXUIElement?=field,_ range:CFRange?=nil)->OnsetDiagnosticHistory.Read {
    var result=OnsetDiagnosticHistory.Read();result.field=target;result.marked=mark;result.range=range
    result.outcome=mark == .active ? 9:1;return result
}
var markedRead=OnsetDiagnosticHistory.Read()
for (error,expected) in [(AXError.attributeUnsupported,2),(.cannotComplete,3),(.noValue,4),(.failure,6)] {
    markedRead.observeMarkedResult(nil,error:error)
    check(markedRead.markedResult==expected,"original AX error classification preserved")
}
markedRead.observeMarkedResult("not a range" as CFString,error:.success)
check(markedRead.markedResult==5,"invalid success payload is not an empty marked range")
var emptyRange=CFRange(location:0,length:0)
markedRead.observeMarkedResult(AXValueCreate(.cfRange,&emptyRange),error:.success)
check(markedRead.markedResult==1,"successful empty range distinct from no-value error")
var runtime=InputIncidentTrace.OnsetRuntime()
runtime.pending=2;runtime.retainedCurrent=3;runtime.retainedPrevious=4
runtime.valueSubscription=1;runtime.selectionSubscription=2
let measured=probe("")
measured.observe(snapshot("ㄱ"),passed:passed([15]),source:onsetKoreanID,at:10.04,read:read(.empty),runtime:runtime)
check(evidence.last?.runtime?.publicationWindow==1,"first observation within publication deadline")
measured.observe(nil,passed:passed(),source:onsetKoreanID,at:10.12,read:read(.active,field,CFRange(location:0,length:1)),runtime:runtime)
check(evidence.last?.runtime?.markedTransition==3 && evidence.last?.runtime?.markedAnchor==1,"sampled active range covers pre-key caret")
check(evidence.last?.runtime?.readOutcome==9 && evidence.last?.whole==0,"active composition refusal is logged without inventing body")
measured.observe(nil,passed:passed(),source:onsetKoreanID,at:10.13,read:read(.unavailable),runtime:runtime)
check(evidence.last?.runtime?.markedTransition==0,"unknown mark does not imply composition end")
measured.observe(snapshot("ㄱㅏ"),passed:passed(),source:onsetKoreanID,at:10.195,read:read(.empty),runtime:runtime)
check(evidence.last?.runtime?.markedTransition==0 && evidence.last?.runtime?.publicationWindow==2,"195ms miss with unknown interval remains explicit")
check(evidence.last?.runtime?.observedKeys==2 && evidence.last?.runtime?.retainedPrevious==4,"gate and prior-session counts preserved")
measured.observe(nil,passed:passed([15,40,1]),source:onsetKoreanID,at:10.247,read:read(.active,field,CFRange(location:2,length:1)),runtime:runtime)
check(evidence.last?.runtime?.markedAnchor==2 && evidence.last?.runtime?.observedKeys==3,"suffix marked beyond pre-key caret and third key visible")
measured.observe(snapshot("ㄱㅏ나"),passed:nil,source:onsetKoreanID,at:10.4,read:read(.empty),runtime:runtime)
check(evidence.last?.runtime?.markedTransition==4,"active-to-empty samples distinguished from unknown")
measured.observe(nil,passed:nil,source:onsetKoreanID,at:10.41,read:read(.active,other,CFRange(location:0,length:1)),runtime:runtime)
check(evidence.last?.runtime?.focusRelation==3 && evidence.last?.runtime?.markedTransition==0 && evidence.last?.runtime?.markedAnchor==0,"new target cannot inherit composition continuity or anchor")
measured.observe(nil,passed:nil,source:onsetKoreanID,at:10.42,read:read(.unavailable,nil),runtime:runtime)
measured.observe(nil,passed:nil,source:onsetKoreanID,at:10.43,read:read(.active),runtime:runtime)
check(evidence.last?.runtime?.focusRelation==1,"missing focus breaks identity continuity")
measured.notification(1,at:10.44)
check(evidence.last?.runtime==nil,"notification never restamps old AX status as new read")
var malformed=runtime;malformed.publicationWindow=1;malformed.markedAnchor=1
check(!malformed.valid,"anchor without active mark rejected")
malformed.markedAnchor=0;malformed.markedTransition=4
check(!malformed.valid,"end without same field and empty sample rejected")
let rawRuntime=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence.first{$0.runtime != nil}!.runtime!)) as! [String:Any]
check(InputIncidentTrace.OnsetRuntime.parse(rawRuntime) != nil && RecorderOnsetRuntime.parse(rawRuntime) != nil,"product and strict recorder agree")
var invalidRuntime=rawRuntime;invalidRuntime["nativeText"]="secret"
check(InputIncidentTrace.OnsetRuntime.parse(invalidRuntime)==nil && RecorderOnsetRuntime.parse(invalidRuntime)==nil,"runtime rejects arbitrary fields")
invalidRuntime=rawRuntime;invalidRuntime["marked"]=true
check(InputIncidentTrace.OnsetRuntime.parse(invalidRuntime)==nil && RecorderOnsetRuntime.parse(invalidRuntime)==nil,"runtime rejects boolean instead of code")

check(evidence.allSatisfy{$0.valid},"all branch payloads valid")

// Product sample() -> memory observer -> manual capture, with only
// OS-facing reads injected. All original events must still pass the real gate.
var engineCaptures:[InputIncidentTrace.Capture]=[]
let engineTrace=InputIncidentTrace(secureInput:{false},destination:nil,writer:{engineCaptures.append($0)})
let engine=OnsetRecoveryEngine(),engineGate=OnsetInputGate(marker:8123)
engine.decisionTrace=engineTrace;engine.gate=engineGate;engine.enabled=true
engine.testSource={onsetKoreanID};engine.canBeginRepair={false}
var snapshotReads=0,rangeWrites=0,posts=0
engine.testSetRange={_,_ in rangeWrites+=1;return .success}
engine.testPost={_ in posts+=1}
engine.testSnapshot={
    snapshotReads+=1;engine.unavailableReason=""
    engine.diagnosticRead=read(.unavailable)
    return snapshot("ㄱㅏ")
}
engineGate.configureEarly(false,sourceID:onsetKoreanID,normal:[15,40],shifted:[])
engineGate.configurePassedBaseline(1,sourceID:onsetKoreanID);engineGate.beat()
for code:UInt16 in [15,40] {
    for down in [true,false] {
        let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
        event.flags=[]
        check(engineGate.receive(event.type,event) != nil,"integration passes original event")
    }
}
engine.sample();engineTrace.flush();check(engineCaptures.isEmpty,"normal first-pair observation remains memory only");engineTrace.mark();engineTrace.flush();engineTrace.finishCaptureWindowsForTest();engineTrace.flush()
let recorded=engineCaptures.flatMap{$0.frames}.compactMap{$0.onsetObservation?.runtime}
check(recorded.contains{$0.marked==1 && $0.observedKeys==2 && $0.receiverCoverage==1},"actual engine sample is wired to product incident writer")
check(snapshotReads==1 && rangeWrites==0 && posts==0,"diagnostics add no read, selection write or replay")
engine.unavailableReason="secure_field"
engine.testSnapshot={engine.unavailableReason="secure_field";return nil}
engine.sample();check(!engine.diagnosticHistory.active,"secure field clears diagnostic history")
engine.enabled=false;engineTrace.stopAndFlush()

var saved:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(secureInput:{false},destination:nil,writer:{saved.append($0)})
for value in evidence{trace.onsetObservation(value,capture:value.phase==1 && value.keys==2)}
trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(saved.isEmpty,"ordinary first-pair comparison creates no automatic archive")
trace.mark();trace.flush()
for capture in saved{
    let data=try! JSONEncoder().encode(capture)
    if (try? RecorderTrace.decode(data))==nil {
        try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        check(false,"strict recorder accepts observer and trigger")
    }
    check(true,"strict recorder accepts observer and trigger")
}
trace.mark();trace.flush()
check(saved.contains { $0.trigger == .manual && $0.frames.contains { $0.onsetObservation?.insertionEndRelation == 2 } }, "manual capture preserves earlier overshoot")
let encoded=try! JSONEncoder().encode(saved.last{$0.frames.contains{$0.onsetObservation?.runtime != nil}}!)
let text=String(data:encoded,encoding:.utf8)!
for secret in ["ㄱ","가","좌우","기존 초안","ᄀ","keycode","sourceID","selectionLocation"]{check(!text.contains(secret),"encoded capture contains no raw payload: \(secret)")}
var object=try! JSONSerialization.jsonObject(with:encoded) as! [String:Any]
var frames=object["frames"] as! [[String:Any]]
let index=frames.firstIndex{$0["kind"] as? Int==15}!
var row=frames[index]["onsetObservation"] as! [String:Any]
row["text"]="sensitive";frames[index]["onsetObservation"]=row;object["frames"]=frames
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"arbitrary payload rejected")
row.removeValue(forKey:"text");row["whole"]=true;frames[index]["onsetObservation"]=row;object["frames"]=frames
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"boolean disguised as comparison rejected")
trace.stopAndFlush()
var offWrites=0
let off=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:false,writer:{_ in offWrites+=1})
for value in evidence{off.onsetObservation(value,capture:true)}
off.flush();off.finishCaptureWindowsForTest();off.flush()
check(offWrites==0,"OFF generates no writes");off.stopAndFlush()
var secureWrites=0
let secure=InputIncidentTrace(secureInput:{true},destination:nil,writer:{_ in secureWrites+=1})
for value in evidence{secure.onsetObservation(value,capture:true)}
secure.flush();secure.finishCaptureWindowsForTest();secure.flush()
check(secureWrites==0,"secure input generates no runtime writes");secure.stopAndFlush()
try! encoded.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
print("PASS \(checks) retained first-pair diagnostics, ambiguity, lifecycle, privacy and memory-only/manual capture checks")
