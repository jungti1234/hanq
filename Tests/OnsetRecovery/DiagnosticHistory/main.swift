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
check(evidence.allSatisfy{$0.valid},"all branch payloads valid")

var saved:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,writer:{saved.append($0)})
for value in evidence{trace.onsetObservation(value,capture:value.phase==1 && value.keys==2)}
trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(!saved.isEmpty,"automatic capture without manual marker")
for capture in saved{
    let data=try! JSONEncoder().encode(capture)
    if (try? RecorderTrace.decode(data))==nil {
        try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        check(false,"strict recorder accepts observer and trigger")
    }
    check(true,"strict recorder accepts observer and trigger")
}
let encoded=try! JSONEncoder().encode(saved.first{$0.frames.contains{$0.kind == .onsetObservation}}!)
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
let off=InputIncidentTrace(destination:nil,initiallyEnabled:false,writer:{_ in offWrites+=1})
for value in evidence{off.onsetObservation(value,capture:true)}
off.flush();off.finishCaptureWindowsForTest();off.flush()
check(offWrites==0,"OFF generates no writes");off.stopAndFlush()
try! encoded.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
print("PASS \(checks) retained first-pair diagnostics, ambiguity, lifecycle, privacy and automatic capture checks")
