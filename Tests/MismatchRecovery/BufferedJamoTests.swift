import AppKit
import Carbon

func runBufferedJamoTests(){
    let field=AXUIElementCreateApplication(12345),ko=KoreanKeyboardLayout.twoSetID
    var checks=0
    func check(_ condition:Bool,_ message:String){probeTestCheck(condition,message);checks+=1}
    func ledger(_ prefix:Bool=false)->MismatchReplayLedger {
        var value=MismatchReplayLedger(before:"앞🙂뒤",caret:3)
        if prefix{value.append(source:"com.apple.keylayout.ABC",keys:[(0,true)])}
        value.append(source:ko,keys:[(15,false),(40,false),(1,false)])
        return value
    }
    // The first R has already been verified as ㄱ. K/S were delivered later.
    // Reopening only K/S would lose the initial consonant and cannot form 간.
    for prefix in [false,true] {
    for initialRetries in [0,1] {
        let expected=ledger(prefix),committed=prefix ? "A":""
        var text="앞🙂"+committed+"ㄱㅏㄴ뒤",selection=NSRange(location:6+committed.utf16.count,length:0)
        var source=ko,composition:[(UInt16,Bool)]=[],marked:NSRange?,posted:[UInt16]=[],queued=false
        let p=MismatchRecoveryEngine()
        p.enabled=true;p.recovering=true;p.planElement=field;p.intendedSource=ko;p.recoverySourceID=ko
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5;p.koreanRetries=initialRetries
        p.testSource={source};p.testSelectSource={source=$0;composition=[];marked=nil;return noErr}
        p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
        p.testSelectionWritable={_ in true}
        p.testSetRange={_,range in selection=range;composition=[];marked=nil;return .success}
        p.testPostAtTap={event,_ in
            guard event.type == .keyDown else{return}
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            posted.append(code);composition.append((code,event.flags.contains(.maskShift)))
            let insertion=MismatchKeyboardLayout.render(keys:composition,sourceID:ko)!,range=marked ?? selection
            text=(text as NSString).replacingCharacters(in:range,with:insertion)
            marked=NSRange(location:range.location,length:insertion.utf16.count)
            selection=NSRange(location:range.location+insertion.utf16.count,length:0)
            if !queued {
                queued=true
                for down in [true,false] {
                    let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;key.flags=[]
                    probeTestCheck(p.event(down ? .keyDown:.keyUp,key)==nil)
                }
            }
        }
        let before=MismatchSnapshot(element:field,text:"앞🙂"+committed+"ㄱ뒤",selection:NSRange(location:4+committed.utf16.count,length:0))
        p.verifyBuffered(expected,before:before,remaining:0,roman:"ks")
        check(p.currentPlan?.roman=="ㄱㅏㄴ" && p.currentPlan?.replayRoman=="rks","whole delivered interval proven without an observed source change")
        check(p.koreanRetries==initialRetries+1 && p.ledgerAfterRepair?.text==expected.text,"existing retry budget and ledger retained")
        let end=Date().addingTimeInterval(2)
        while p.recovering,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(!p.recovering && !p.suspended && p.retained.isEmpty && p.pending.isEmpty,"repair and queued vowel complete")
        check(text=="앞🙂"+committed+"가나뒤" && selection==NSRange(location:5+committed.utf16.count,length:0),"prefix, suffix, UTF-16 caret and live composition preserved")
        check(posted==[15,40,1,40] && p.ledger?.text==text && source==ko,"all original keys replayed once and queued key follows")
    }
    }
    let expected=ledger()
    for (text,range) in [("다🙂ㄱㅏㄴ뒤",NSRange(location:6,length:0)),("앞🙂ㄱㅏㄴ다",NSRange(location:6,length:0)),("앞🙂ㄱㅏ뒤",NSRange(location:5,length:0)),("앞🙂ㄱㅏㅁ뒤",NSRange(location:6,length:0)),("앞🙂ㄱㅏㄴ뒤",NSRange(location:5,length:0)),("앞🙂ㄱㅏㄴ뒤",NSRange(location:6,length:1)),("앞🙂간뒤",NSRange(location:4,length:0))] {
        check(expected.decomposedPlan(text:text,selection:range)==nil,"changed surroundings, partial/unobserved keys, caret/selection or normal Korean rejected")
    }
    var other=expected;other.segments[0].source=KoreanKeyboardLayout.threeSetID
    check(other.decomposedPlan(text:"앞🙂ㄱㅏㄴ뒤",selection:NSRange(location:6,length:0))==nil,"other layouts rejected")
    var over=expected;over.segments[0].keys=Array(repeating:(15,false),count:65)
    check(over.decomposedPlan(text:"앞🙂"+String(repeating:"ㄱ",count:65)+"뒤",selection:NSRange(location:68,length:0))==nil,"64-key bound retained")
    for reason in ["field","retries","deadline","sourceOnly","source"] {
        let p=MismatchRecoveryEngine();var edits=0,posts=0
        p.enabled=true;p.recovering=true;p.planElement=field;p.intendedSource=ko;p.recoverySourceID=ko
        p.koreanRetries=reason=="retries" ? 2:0
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+(reason=="deadline" ? 0.3:2.5)
        p.testSource={reason=="source" ? p.englishID:ko};p.testSelectSource={_ in -50}
        let snap=MismatchSnapshot(element:reason=="field" ? AXUIElementCreateApplication(67890):field,text:"앞🙂ㄱㅏㄴ뒤",selection:NSRange(location:6,length:0))
        p.testSnapshot={snap};p.testSetRange={_,_ in edits+=1;return .success};p.testPost={_ in posts+=1}
        let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!;p.pending=[key]
        p.verifyBuffered(expected,before:snap,remaining:0,roman:"ks",sourceOnly:reason=="sourceOnly")
        check(!p.recovering && p.suspended && edits==0 && posts==0 && p.retained.count==1,"unsafe or unavailable \(reason) retains pending input without editing")
    }
    for failure in ["가s","ㄱㅏㄴ","rㅏㄴ","ㄱks","ㄱkㄴ","ㄱㅏs"] { for initialRetries in [0,1,2] {
        let p=MismatchRecoveryEngine();var source=ko,text="앞🙂"+failure+"뒤"
        var range=NSRange(location:3+failure.utf16.count,length:0),composition:[(UInt16,Bool)]=[],marked:NSRange?,posts:[UInt16]=[]
        var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
        for code:UInt16 in [15,40,1]{_=candidate.append(code:code,shift:false)}
        candidate.roman="ㄱㅏㄴ";candidate.verifiedReplacement=candidate.roman
        p.enabled=true;p.recovering=true;p.locked=field;p.planElement=field;p.currentPlan=candidate
        p.intendedSource=ko;p.recoverySourceID=ko;p.koreanRetries=initialRetries;p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        p.testSource={source};p.testSelectSource={source=$0;composition=[];marked=nil;return noErr}
        p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:range)}
        p.testSetRange={_,r in range=r;composition=[];marked=nil;return .success}
        p.testPostAtTap={event,_ in
            guard event.type == .keyDown else{return}
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode));posts.append(code);composition.append((code,false))
            let value=MismatchKeyboardLayout.render(keys:composition,sourceID:ko)!,r=marked ?? range
            text=(text as NSString).replacingCharacters(in:r,with:value);marked=NSRange(location:r.location,length:value.utf16.count);range=NSRange(location:r.location+value.utf16.count,length:0)
        }
        p.awaitKorean(candidate,remaining:0)
        let end=Date().addingTimeInterval(1.5)
        while p.recovering,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        if initialRetries==2 {
            check(p.suspended && posts.isEmpty && text=="앞🙂"+failure+"뒤","partial replay cannot add an extra retry or OS activation")
        }else {
            check(!p.recovering && !p.suspended && text=="앞🙂간뒤" && range==NSRange(location:4,length:0),"partial replay uses the remaining direct retry: \(failure)")
            check(posts==[15,40,1] && p.koreanRetries==initialRetries+1,"partial replay preserves whole history and retry count")
            let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!;key.flags=[]
            _=p.event(.keyDown,key)
            p.testPostAtTap!(key,.cgSessionEventTap)
            let release=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:false)!;release.flags=[];_=p.event(.keyUp,release)
            check(text=="앞🙂가나뒤" && !p.recovering,"next normal vowel continues live partial-result recovery")
        }
    }}
    var exact=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
    for code:UInt16 in [15,40,1]{_=exact.append(code:code,shift:false)}
    for failure in ["ㄱks","ㄱkㄴ","ㄱㅏs","rㅏs","가s","ㄱㅏㄴ"] {
        check(exact.partialFailurePlan(text:"앞🙂"+failure+"뒤",selection:NSRange(location:3+failure.utf16.count,length:0))?.replayRoman=="rks","all and only traced segment outputs accepted")
    }
    for (body,range) in [("앞🙂ㄱkx뒤",NSRange(location:6,length:0)),("다🙂ㄱks뒤",NSRange(location:6,length:0)),("앞🙂ㄱks다",NSRange(location:6,length:0)),("앞🙂ㄱk뒤",NSRange(location:5,length:0)),("앞🙂ㄱks뒤",NSRange(location:5,length:0)),("앞🙂ㄱks뒤",NSRange(location:6,length:1)),("앞🙂간뒤",NSRange(location:4,length:0))] {
        check(exact.partialFailurePlan(text:body,selection:range)==nil,"unobserved output, changed boundary/caret/selection and normal result rejected")
    }
    var different=exact;different.sourceID=KoreanKeyboardLayout.threeSetID
    check(different.fragmentedCompositionPlan(text:"앞🙂ㄱks뒤",selection:NSRange(location:6,length:0))==nil,"fragment proof limited to two-set")
    var large=exact;large.codes=Array(repeating:(15,false),count:65)
    check(large.fragmentedCompositionPlan(text:"앞🙂"+String(repeating:"ㄱ",count:65)+"뒤",selection:NSRange(location:68,length:0))==nil,"fragment proof retains 64-key limit")
    print("PASS: \(checks) buffered detached-jamo checks; full interval replay, queued composition and bounded safety")
}
