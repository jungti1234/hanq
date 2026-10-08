import AppKit

func runMixedTransitionTests() {
    var checks=0
    func check(_ condition:Bool,_ message:String){probeTestCheck(condition,message);checks+=1}
    func plan(_ keys:[UInt16],_ source:String=KoreanKeyboardLayout.twoSetID)->MismatchRecoveryPlan {
        var p=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3,sourceID:source)
        for code in keys{_ = p.append(code:code,shift:false)}
        return p
    }
    let keys:[UInt16]=[2,40,3,7,46,7,31,12] // dkfxmxoq: 알트탭
    let p=plan(keys),text="앞🙂dㅏㄹ트탭뒤",caret=NSRange(location:8,length:0)
    let mixed=p.mixedPlan(text:text,selection:caret)
    check(mixed != nil,"reported mixed word is recognized")
    check(mixed?.roman=="dㅏㄹ트탭" && mixed?.replayRoman=="dkfxmxoq","retain exact observed replacement and physical keys separately")
    check(mixed?.matches(text:text,selection:caret)==true,"exact mixed range can enter existing verified recovery")
    check(p.mixedPlan(text:"앞🙂알트탭뒤",selection:NSRange(location:6,length:0))==nil,"normal Korean never repaired")
    check(p.mixedPlan(text:"앞🙂dㅏㄹ트태뒤",selection:caret)==nil,"unobserved character never repaired")
    check(p.mixedPlan(text:"다🙂dㅏㄹ트탭뒤",selection:caret)==nil,"changed prefix never repaired")
    check(p.mixedPlan(text:"앞🙂dㅏㄹ트탭다",selection:caret)==nil,"changed suffix never repaired")
    check(p.mixedPlan(text:text,selection:NSRange(location:8,length:1))==nil,"selection changes cancel proof")
    let prefix="앞🙂dㅏ뒤",prefixCaret=NSRange(location:5,length:0)
    check(p.observedPrefix(text:prefix,selection:prefixCaret),"delayed mixed AX prefix preserves tracked keys")
    check(p.mixedPlan(text:prefix,selection:prefixCaret)==nil,"pending keys not silently dropped from full proof")
    let next=MismatchRecoveryPlan.next(previous:p,text:prefix,selection:prefixCaret,code:40,shift:false)
    check(next?.replayRoman=="dkfxmxoqk" && next?.before=="앞🙂뒤","next key continues mixed delayed prefix")
    let replace=MismatchRecoveryPlan.next(previous:nil,text:"앞🙂old뒤",selection:NSRange(location:3,length:3),code:2,shift:false)
    check(replace?.before=="앞🙂뒤" && replace?.caret==3,"selection replacement tracks first key with UTF-16 baseline")
    check(replace?.matches(text:"앞🙂d뒤",selection:NSRange(location:4,length:0))==true,"first ASCII replacement is detected")
    for range in [NSRange(location:9,length:1),NSRange(location:1,length:Int.max),NSRange(location:NSNotFound,length:0)] {
        check(MismatchRecoveryPlan.next(previous:nil,text:"abc",selection:range,code:2,shift:false)==nil,"invalid selected range rejected")
    }
    let numeric=plan([18,15,40])
    check(numeric.mixedPlan(text:"앞🙂1가뒤",selection:NSRange(location:5,length:0))==nil,"legitimate ASCII numeric prefix preserved")
    for id in KoreanKeyboardLayout.supportedIDs {
        let codes:[UInt16]
        switch id {
        case KoreanKeyboardLayout.twoSetID:codes=[15,40,1]
        case KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID:codes=[40,3,1]
        default:codes=[5,0,45]
        }
        let candidate=plan(codes,id)
        let first=MismatchRecoveryPlan.character(codes[0],false)!
        let suffix=MismatchKeyboardLayout.render(keys:codes.dropFirst().map{($0,false)},sourceID:id)!
        let insertion=first+suffix,observed="앞🙂"+insertion+"뒤"
        check(candidate.mixedPlan(text:observed,selection:NSRange(location:3+insertion.utf16.count,length:0)) != nil,"mixed transition for \(id)")
    }
    // Exercise detection through the actual engine, not only the matcher.
    let engine=MismatchRecoveryEngine(detectionOnly:true),field=AXUIElementCreateApplication(12345)
    engine.enabled=true;engine.locked=field;engine.planElement=field
    engine.lastSource=KoreanKeyboardLayout.twoSetID;engine.testSource={KoreanKeyboardLayout.twoSetID}
    engine.plan=p;engine.planStart=ProcessInfo.processInfo.systemUptime
    engine.testSnapshot={MismatchSnapshot(element:field,text:text,selection:caret)}
    engine.sample()
    check(engine.detectionCount==1 && engine.plan==nil,"engine detects exact mixed insertion")
    let decomposed="앞🙂ㅇㅏㄹㅌㅡㅌㅐㅂ뒤",decomposedCaret=NSRange(location:11,length:0)
    let detached=p.decomposedPlan(text:decomposed,selection:decomposedCaret)
    check(detached?.roman=="ㅇㅏㄹㅌㅡㅌㅐㅂ" && detached?.replayRoman=="dkfxmxoq","exact detached two-set keys retain literal range and original keys")
    check(detached?.matches(text:decomposed,selection:decomposedCaret)==true,"detached range enters exact existing repair proof")
    check(p.decomposedPlan(text:"앞🙂알트탭뒤",selection:NSRange(location:6,length:0))==nil,"normal composed Korean is not repaired")
    check(p.decomposedPlan(text:"앞🙂ㅇㅏㄹㅌㅡㅌㅐㅍ뒤",selection:decomposedCaret)==nil,"different detached key is not repaired")
    check(p.decomposedPlan(text:"다🙂ㅇㅏㄹㅌㅡㅌㅐㅂ뒤",selection:decomposedCaret)==nil,"changed surroundings reject detached repair")
    check(p.decomposedPlan(text:decomposed,selection:NSRange(location:11,length:1))==nil,"selected detached text is not guessed")
    check(p.observedPrefix(text:"앞🙂알트뒤",selection:NSRange(location:5,length:0)),"normal Korean prefix retains physical history")
    check(p.observedPrefix(text:"앞🙂ㅇㅏ뒤",selection:NSRange(location:5,length:0)),"partial detached output retains pending physical history")
    check(p.decomposedPlan(text:"앞🙂ㅇㅏ뒤",selection:NSRange(location:5,length:0))==nil,"partial output cannot drop later observed keys")
    let consonants=plan([2,3,7])
    check(consonants.decomposedPlan(text:"앞🙂ㅇㄹㅌ뒤",selection:NSRange(location:6,length:0))==nil,"intentional standalone consonants stay unchanged")
    let spaced=plan([2,49,40])
    check(spaced.decomposedPlan(text:"앞🙂ㅇ ㅏ뒤",selection:NSRange(location:6,length:0))==nil,"explicit space preserves intentional separation")
    var first=plan([2]);let nextKorean=MismatchRecoveryPlan.next(previous:first,text:"앞🙂ㅇ뒤",selection:NSRange(location:4,length:0),code:40,shift:false)
    check(nextKorean?.decomposedPlan(text:"앞🙂ㅇㅏ뒤",selection:NSRange(location:5,length:0)) != nil,"first normal consonant remains tracked until detached vowel proves failure")
    first.sourceID=KoreanKeyboardLayout.threeSetID
    check(first.decomposedPlan(text:"앞🙂ㅇ뒤",selection:NSRange(location:4,length:0))==nil,"new detached recovery is restricted to verified two-set layout")
    engine.plan=p;engine.planStart=ProcessInfo.processInfo.systemUptime
    engine.testSnapshot={MismatchSnapshot(element:field,text:decomposed,selection:decomposedCaret)}
    engine.sample()
    check(engine.detectionCount==2 && engine.plan==nil,"engine detects detached two-set state through existing recovery gate")
    let firstTyped=plan([2])
    let suggestion="ocs.example.test",suggestedText="앞🙂d"+suggestion+"뒤"
    let suggestionRange=NSRange(location:4,length:suggestion.utf16.count)
    let continued=MismatchRecoveryPlan.next(previous:firstTyped,text:suggestedText,selection:suggestionRange,code:31,shift:false)
    check(continued?.replayRoman=="do" && continued?.before=="앞🙂뒤" && continued?.caret==3,
          "selected autocomplete suffix preserves all physically typed prefix keys")
    check(continued?.matches(text:"앞🙂do뒤",selection:NSRange(location:5,length:0))==true,
          "autocomplete replacement repairs the first letter too")
    let whole=MismatchRecoveryPlan.next(previous:firstTyped,text:"앞🙂d뒤",selection:NSRange(location:3,length:1),code:31,shift:false)
    check(whole?.replayRoman=="o","selecting the typed prefix replaces it rather than extending it")
    let existing=MismatchRecoveryPlan.next(previous:firstTyped,text:"앞🙂d뒤",selection:NSRange(location:4,length:1),code:31,shift:false)
    check(existing?.replayRoman=="o","selection of preexisting surrounding text is not an autocomplete suffix")
    let changed=MismatchRecoveryPlan.next(previous:firstTyped,text:"다🙂d"+suggestion+"뒤",selection:suggestionRange,code:31,shift:false)
    check(changed?.replayRoman=="o","changed surrounding text rejects autocomplete continuation")
    let pending=MismatchRecoveryPlan.next(previous:plan([2,31]),text:suggestedText,selection:suggestionRange,code:9,shift:false)
    check(pending?.replayRoman=="v","autocomplete cannot hide an unobserved pending prefix key")
    let capitalized=MismatchRecoveryPlan.next(previous:firstTyped,text:"앞🙂D"+suggestion+"뒤",selection:suggestionRange,code:31,shift:false)
    check(capitalized?.replayRoman=="do" && capitalized?.before=="앞🙂뒤","autocomplete preserves ASCII capitalization tolerance and original physical keys")
    let delayed=MismatchRecoveryPlan.next(previous:continued,text:suggestedText,selection:suggestionRange,code:9,shift:false)
    check(delayed?.replayRoman=="dov" && delayed?.before=="앞🙂뒤","unchanged autocomplete snapshot preserves keys not yet reflected by AX")
    let caughtUp=MismatchRecoveryPlan.next(previous:delayed,text:"앞🙂dov뒤",selection:NSRange(location:6,length:0),code:46,shift:false)
    check(caughtUp?.replayRoman=="dovm" && caughtUp?.pendingCompletion==nil,"collapsed updated snapshot continues all keys and clears completion state")
    let changedCompletion=MismatchRecoveryPlan.next(previous:continued,text:"앞🙂dxyz뒤",selection:NSRange(location:4,length:3),code:9,shift:false)
    check(changedCompletion?.replayRoman=="v","changed completion cannot borrow unverified pending-prefix evidence")
    print("PASS: \(checks) mixed transition and first selected-key checks")
}
