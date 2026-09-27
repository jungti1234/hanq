import AppKit
import Carbon

func runLayoutTests(){
    let ids=[KoreanKeyboardLayout.twoSetID,KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID,MismatchKeyboardLayout.gongjinID,MismatchKeyboardLayout.hncID]
    let field=AXUIElementCreateApplication(12345)
    for id in ids {
        probeTestCheck(MismatchKeyboardLayout.supports(id),"installed layout unavailable: \(id)")
        let compatibility=MismatchKeyboardLayout.load(id)!.kind == .twoSet
        let initial:Character=compatibility ? "ㄱ":"ᄀ"
        let vowel:Character=compatibility ? "ㅏ":"ᅡ"
        let final:Character=compatibility ? "ㄴ":"ᆫ"
        func key(_ char:Character)->(UInt16,Bool){
            for code in (0...50).map(UInt16.init) {
                if MismatchKeyboardLayout.output(code:code,shift:false,sourceID:id)==char{return (code,false)}
            }
            probeTestCheck(false,"missing physical key for \(char)");return (0,false)
        }
        let keys=[key(initial),key(vowel),key(final)]
        probeTestCheck(MismatchKeyboardLayout.render(keys:keys,sourceID:id)=="간")
        var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3,sourceID:id)
        for (code,shift) in keys{_ = candidate.append(code:code,shift:shift)}
        probeTestCheck(candidate.matches(text:candidate.expected!,selection:NSRange(location:3+candidate.roman.utf16.count,length:0)))
        probeTestCheck(candidate.restoredKoreanPlan(text:"앞🙂간뒤",selection:NSRange(location:4,length:0))?.sourceID==id)
        probeTestCheck(candidate.restoredKoreanPlan(text:"앞🙂가뒤",selection:NSRange(location:4,length:0))==nil)
        var ledger=MismatchReplayLedger(before:"",caret:0)
        ledger.append(source:id,keys:keys);ledger.append(source:"com.apple.keylayout.ABC",keys:[(0,false)]);ledger.append(source:id,keys:keys)
        probeTestCheck(ledger.text=="간a간")
        probeTestCheck(MismatchRecoveryPlan.matchesRestoredBatch(roman:candidate.replayRoman,inserted:"간",sourceID:id))
        probeTestCheck(!MismatchRecoveryPlan.matchesRestoredBatch(roman:candidate.replayRoman,inserted:"가",sourceID:id))
        let p=MismatchRecoveryEngine();p.enabled=true;p.planElement=field;p.testSource={id};p.testSelectionWritable={_ in true}
        p.testSnapshot={MismatchSnapshot(element:field,text:candidate.expected!,selection:NSRange(location:3+candidate.roman.utf16.count,length:0))}
        var targets:[String]=[];p.testSelectSource={target in targets.append(target);return noErr};p.testPost={_ in}
        p.beginRecovery(candidate,p.testSnapshot!()!)
        probeTestCheck(p.recoverySourceID==id && p.intendedSource==id)
        p.userToggleDuringRecovery();probeTestCheck(p.intendedSource==p.englishID)
        p.userToggleDuringRecovery();probeTestCheck(p.intendedSource==id)
        p.restoreInterruptedSource("layout_test",resume:{})
        probeTestCheck(targets==[p.englishID,id],"source restoration switched to wrong layout")
        p.closeSession()
        if !compatibility {
            let digit=(18...29).map(UInt16.init).first{MismatchKeyboardLayout.expectsHangul(code:$0,shift:false,sourceID:id)}!
            var digits=MismatchRecoveryPlan(before:"",caret:0,sourceID:id);_ = digits.append(code:digit,shift:false)
            probeTestCheck(digits.matches(text:digits.roman,selection:NSRange(location:digits.roman.utf16.count,length:0)),"three-set digit jamo ignored")
        }
    }
    var old=MismatchRecoveryPlan(before:"",caret:0,sourceID:ids[0]);_ = old.append(code:0,shift:false)
    let next=MismatchRecoveryPlan.next(previous:old,text:"a",selection:NSRange(location:1,length:0),code:0,shift:false,sourceID:ids[1])!
    probeTestCheck(next.before=="a" && next.roman=="a" && next.sourceID==ids[1],"candidate crossed Korean layout change")
    probeTestCheck(MismatchKeyboardLayout.render(roman:"rks",sourceID:"third.party.unknown")==nil)
    probeTestCheck(!MismatchKeyboardLayout.supports("com.apple.keylayout.ABC"))
    let data=try! Data(contentsOf:URL(fileURLWithPath:"Tests/MismatchRecovery/NativeLayoutExpectations.json"))
    let corpus=try! JSONSerialization.jsonObject(with:data) as! [[String:String]]
    for row in corpus {
        probeTestCheck(MismatchKeyboardLayout.render(roman:row["keys"]!,sourceID:row["source"]!)==row["text"]!,"native reference differs: \(row)")
    }
    print("PASS: \(corpus.count) independently observed native IME strings")
    print("PASS: 5 Apple Korean layouts, physical initial/vowel/final and numeric keys, exact source restoration/boundaries, wrong results rejected, no unknown-layout fallback")
}
