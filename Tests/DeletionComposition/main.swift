import AppKit
import Carbon
let ko=KoreanKeyboardLayout.twoSetID
let field=AXUIElementCreateApplication(12345)
let positions=Dictionary(uniqueKeysWithValues:PhysicalLetterKeys.letters.map{($0.value.first!,$0.key)})
final class Fixture {
 let barrier=SourceSwitchBarrier(),engine=MismatchRecoveryEngine(detectionOnly:true)
 var text="sample ",clock=ProcessInfo.processInfo.systemUptime,stamp:UInt64=1000
 var codes:[(UInt16,Bool)]=[]
 var reports:[[String:Any]]=[],handoffs:[[String:Any]]=[]
 var forbiddenSideEffects=0
 var captures:[InputIncidentTrace.Capture]=[]
 init() {
  barrier.read={ [unowned self] in .init(field:field,text:text,selection:range) }
  barrier.readFocus={field};barrier.source={ko};barrier.now={ [unowned self] in clock }
  barrier.send={ [unowned self] _ in forbiddenSideEffects+=1 }
  barrier.select={ [unowned self] _ in forbiddenSideEffects+=1;return -50 }
  barrier.applySelection={ [unowned self] _,_ in forbiddenSideEffects+=1;return false }
  let trace=InputIncidentTrace(destination:nil,writer:{ [weak self] capture in self?.captures.append(capture) })
  barrier.incidentTrace=trace
  engine.enabled=true;engine.lastSource=ko;engine.locked=field
  engine.testSource={ko};engine.testFastContext={true}
  engine.testSnapshot={ [unowned self] in .init(element:field,text:text,selection:range) }
  engine.testPost={ [unowned self] _ in forbiddenSideEffects+=1 }
  engine.testPostAtTap={ [unowned self] _,_ in forbiddenSideEffects+=1 }
  engine.testSelectSource={ [unowned self] _ in forbiddenSideEffects+=1;return -50 }
  engine.testSetRange={ [unowned self] _,_ in forbiddenSideEffects+=1;return .cannotComplete }
  engine.incidentTrace=trace
  engine.verifiedDeliveryHistory={ [unowned self] snap,prior in
   let result=barrier.verifiedTwoSetHistory(snap,after:0,allowPrior:prior)
   if let result {handoffs.append(["actual":text,"keys":result.plan.replayRoman,"allowPrior":prior,"count":result.plan.codes.count,"at":clock])}
   return result
  }
 }
 var range:NSRange {NSRange(location:text.utf16.count,length:0)}
 func event(_ code:UInt16,down:Bool=true) {
  clock=ProcessInfo.processInfo.systemUptime;stamp+=1000
  let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];e.timestamp=stamp
  let type:CGEventType=down ? .keyDown:.keyUp
  barrier.observe(type,e)
  precondition(engine.event(type,e) != nil)
 }
 func sample(_ label:String) {
  let before=engine.detectionCount,oldKeys=engine.plan?.replayRoman ?? "nil"
  engine.sample(synchronous:true)
  reports.append(["stage":label,"beforeCandidateKeys":oldKeys,"text":text,"length":text.utf16.count,"ledger":barrier.expected?.0 ?? "nil","candidateKeys":engine.plan?.replayRoman ?? "nil","newDetections":engine.detectionCount-before,"detections":engine.detectionCount])
 }
 func press(_ char:Character) {
  event(positions[char]!);codes.append((positions[char]!,false))
  text="sample "+MismatchKeyboardLayout.render(keys:codes,sourceID:ko)!
  sample("typed \(char)");event(positions[char]!,down:false)
 }
}

var checks=0
func check(_ value:Bool,_ message:String){checks+=1;if !value{fputs("FAIL: \(message)\n",stderr);exit(1)}}
func prepared()->Fixture {
 let f=Fixture()
 for c in "ekfwptlo" {f.press(c)}
 f.event(51);f.codes.removeLast();f.text="sample 달제시";f.sample("post-delete");f.event(51,down:false)
 return f
}
for kind in ["live","committed","ascii","detached","delayed-detached","switch","repeat-delete"] {
 let f=prepared();f.event(positions["e"]!)
 if kind=="delayed-detached" {f.event(positions["e"]!,down:false);f.event(positions["o"]!)}
 switch kind {
 case "live":f.text="sample 달제싣"
 case "ascii":f.text="sample 달제시e"
 case "delayed-detached":f.text="sample 달제시ㄷㅐ"
 default:f.text="sample 달제시ㄷ"
 }
 f.sample("post-consonant")
 let failure=["ascii","delayed-detached"].contains(kind)
 check(f.engine.detectionCount==(failure ? 1:0),"\(kind): only proved ASCII/detached failure is repaired")
 if !failure {
  check(f.barrier.expected?.0==f.text && f.barrier.expected?.1==f.range,"\(kind): exact body/caret history remains switchable")
  f.event(positions["e"]!,down:false)
  if kind=="switch" {
   var chosen=ko,requests=0
   f.barrier.source={chosen};f.barrier.select={chosen=$0;requests+=1;return noErr}
   check(f.barrier.request("com.apple.keylayout.ABC"),"source request accepted after committed consonant")
   for _ in 0..<8 {f.barrier.step()}
   check(!f.barrier.busy && chosen=="com.apple.keylayout.ABC" && requests==1,"first source switch succeeds without repair or extra input")
  }else{
   f.event(positions["o"]!)
   f.text=kind=="detached" ? "sample 달제시ㄷㅐ":"sample 달제시대"
   f.sample("post-vowel")
   check(f.engine.detectionCount==(kind=="detached" ? 1:0),"\(kind): normal next syllable preserved, actual detached vowel still repaired")
   if kind=="repeat-delete" {
    f.event(positions["o"]!,down:false);f.event(51);f.text="sample 달제시ㄷ";f.event(51,down:false)
    f.event(positions["o"]!);f.text="sample 달제시대";f.sample("retyped-vowel")
    check(f.engine.detectionCount==0 && f.barrier.expected?.0==f.text,"second deletion keeps the proved syllable boundary")
   }
  }
 }
 check(f.forbiddenSideEffects==0,"\(kind): no global posting, source choice or AX edit")
}
func keys(_ roman:String)->[(UInt16,Bool)] {roman.map{(positions[$0]!,false)}}
let field2=AXUIElementCreateApplication(12346)
for reason in ["normal","text","caret","selection","field","source","expiry","boundary"] {
 let f=prepared();f.event(positions["e"]!);f.text="sample 달제시ㄷ"
 let snapshot=MismatchSnapshot(element:reason=="field" ? field2:field,text:reason=="text" ? "changed 달제시ㄷ":f.text,
  selection:NSRange(location:reason=="caret" ? 0:f.text.utf16.count,length:reason=="selection" ? 1:0))
 if reason=="source" {f.barrier.source={"com.apple.keylayout.ABC"}}
 if reason=="expiry" {f.clock+=6}
 let h=f.barrier.verifiedTwoSetHistory(snapshot,after:reason=="boundary" ? UInt64.max:0)
 check((h != nil)==(reason=="normal"),"deletion continuation retains \(reason) guard")
 if let h {check(h.plan.replayRoman=="e","handoff includes only post-commit consonant, never old 8-key prefix")}
 check(f.forbiddenSideEffects==0,"context checks have no effects")
}
for inserted in ["간ㅏ","간k"] {
 var p=MismatchRecoveryPlan(before:"sample ",caret:7);p.codes=keys("rksk");p.roman="rksk"
 check(p.partialFailurePlan(text:"sample "+inserted,selection:NSRange(location:9,length:0)) != nil,"required \(inserted) recovery retained")
}
let vowel=Fixture()
for c in "rksr" {vowel.press(c)}
vowel.event(51);vowel.codes.removeLast();vowel.text="sample 간";vowel.sample("deleted");vowel.event(51,down:false)
vowel.event(positions["k"]!);vowel.text="sample 간ㅏ";vowel.sample("failed-vowel")
check(vowel.engine.detectionCount==1,"post-delete vowel-only failure still starts full engine detection")
check(vowel.forbiddenSideEffects==0,"vowel failure has no real effects")

// Every two-set initial, including Shift doubles, preserves the exact suffix
// plan at a proved commit boundary inside a Unicode document.
for (code,_) in PhysicalLetterKeys.letters {
 for shifted in [false,true] {
  guard let c=MismatchKeyboardLayout.output(code:code,shift:shifted,sourceID:ko),
        c.unicodeScalars.count==1,let scalar=c.unicodeScalars.first,
        (0x3131...0x314e).contains(scalar.value) else{continue}
  var ledger=MismatchReplayLedger(before:"앞🙂e\u{301} 뒤",caret:3)
  ledger.append(source:ko,keys:keys("ekfwptl"));ledger.postDeletionPrefixCount=7
  ledger.append(source:ko,keys:[(code,shifted)])
  let split=ledger.committingDeletionPrefix()
  check(split?.segments.count==2 && split?.postDeletionPrefixCount==nil,"initial/Shift creates one explicit boundary")
  check(split?.text=="앞🙂달제시"+String(c)+"e\u{301} 뒤","all surrounding UTF16 is preserved")
  check(split?.lastTwoSetPlan()?.codes.count==1,"only the new initial is eligible for replay")
 }
}
for kind in ["none","zero","future","vowel","source","switch"] {
 var ledger=MismatchReplayLedger(before:"",caret:0);ledger.append(source:ko,keys:keys("ekfwptl"))
 ledger.postDeletionPrefixCount=kind=="none" ? nil:(kind=="zero" ? 0:(kind=="future" ? 9:7))
 ledger.append(source:kind=="switch" ? "com.apple.keylayout.ABC":ko,keys:keys(kind=="vowel" ? "k":"e"))
 if kind=="source" {ledger.segments[0].source=KoreanKeyboardLayout.threeSetID}
 check(ledger.committingDeletionPrefix()==nil,"invalid/unproved \(kind) cannot create a boundary")
}

// An explicit source round trip commits the old interval. A deletion marker
// must never be reused for an unrelated later Korean interval.
do {
 let b=SourceSwitchBarrier();var selected=ko,text="base 달제싣",r=NSRange(location:8,length:0)
 var prior=MismatchReplayLedger(before:"base ",caret:5);prior.append(source:ko,keys:keys("ekfwptle"));prior.postDeletionPrefixCount=7
 b.read={.init(field:field,text:text,selection:r)};b.source={selected};b.select={selected=$0;return noErr};b.send={_ in check(false,"no real input queued")}
 b.adoptVerifiedReplay(prior,snapshot:.init(element:field,text:text,selection:r))
 for id in ["com.apple.keylayout.ABC",ko] {
  check(b.request(id),"explicit source boundary requested")
  for _ in 0..<8{b.step()}
  check(!b.busy && selected==id,"explicit source boundary completes")
 }
 let base=text
 for (index,c) in "ekfwptle".enumerated() {
  let e=CGEvent(keyboardEventSource:nil,virtualKey:positions[c]!,keyDown:true)!;e.flags=[];e.timestamp=UInt64(10000+index)
  b.observe(.keyDown,e)
  text=base+MismatchKeyboardLayout.render(roman:String("ekfwptle".prefix(index+1)),sourceID:ko)!
  r=NSRange(location:text.utf16.count,length:0)
 }
 text=base+"달제시ㄷ";r=NSRange(location:text.utf16.count,length:0)
 let history=b.verifiedTwoSetHistory(.init(element:field,text:text,selection:r),after:0)
 check(history?.plan.codes.count==8,"new interval cannot inherit an old deletion commit allowance: \(history?.plan.replayRoman ?? "nil")")
}

// Browser NBSPs in the acknowledged old prefix must stay literal outside the
// new recovery range, rather than being reconstructed from old physical keys.
do {
 let b=SourceSwitchBarrier();var text="sample ",range=NSRange(location:7,length:0)
 b.source={ko};b.read={.init(field:field,text:text,selection:range)}
 let input=keys("rks")+[(49,false)]+keys("ekfwptlo")
 for (i,key) in input.enumerated() {
  let e=CGEvent(keyboardEventSource:nil,virtualKey:key.0,keyDown:true)!;e.flags=[];e.timestamp=UInt64(i+1000)
  b.observe(.keyDown,e);text=b.expected!.0;range=b.expected!.1
 }
 text=text.replacingOccurrences(of:"간 ",with:"간\u{a0}")
 let del=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:true)!;del.flags=[];b.observe(.keyDown,del)
 text="sample 간\u{a0}달제시";range=NSRange(location:text.utf16.count,length:0)
 let e=CGEvent(keyboardEventSource:nil,virtualKey:positions["e"]!,keyDown:true)!;e.flags=[];e.timestamp=10000
 b.observe(.keyDown,e);text+="ㄷ";range=NSRange(location:text.utf16.count,length:0)
 let h=b.verifiedTwoSetHistory(.init(element:field,text:text,selection:range),after:0)
 check(h?.plan.replayRoman=="e" && h?.plan.before=="sample 간\u{a0}달제시","verified old editor representation stays literal outside replay range")
}
print("PASS: \(checks) post-deletion composition checks; full engine/history, normal/live, ASCII/jamo, delayed output, first switch, repeated delete and context guards; no OS posts")
