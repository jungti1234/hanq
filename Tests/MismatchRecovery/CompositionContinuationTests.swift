import AppKit
import Carbon

func runCompositionContinuationTests(){
    let ko=mismatchKoreanID,field=AXUIElementCreateApplication(12345)
    var checks=0
    func check(_ value:Bool,_ message:String){probeTestCheck(value,message);checks+=1}
    func plan(_ keys:[UInt16])->MismatchRecoveryPlan {
        var p=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
        for key in keys{_ = p.append(code:key,shift:false)}
        return p
    }
    for prefix in [false,true] { for suffix in ["ㅏ","k"] { for normal in [false,true] {
        let committed=prefix ? "A":"",start=3+committed.utf16.count
        var ledger=MismatchReplayLedger(before:"앞🙂뒤",caret:3)
        if prefix{ledger.append(source:"com.apple.keylayout.ABC",keys:[(0,true)])}
        ledger.append(source:ko,keys:[(15,false),(40,false),(1,false)])
        let p=MismatchRecoveryEngine();var source=ko,text=ledger.text,range=ledger.selection
        var composition:[(UInt16,Bool)]=[],marked:NSRange?,posts:[UInt16]=[]
        p.enabled=true;p.recovering=true;p.planElement=field;p.locked=field;p.ledger=ledger;p.intendedSource=ko
        p.testSource={source};p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:range)}
        p.testSelectionWritable={_ in true};p.testSetRange={_,r in range=r;marked=nil;composition=[];return .success}
        p.testSelectSource={source=$0;marked=nil;composition=[];return noErr}
        func compose(_ code:UInt16){
            composition.append((code,false))
            let value=MismatchKeyboardLayout.render(keys:composition,sourceID:ko)!,r=marked ?? range
            text=(text as NSString).replacingCharacters(in:r,with:value)
            marked=NSRange(location:r.location,length:value.utf16.count);range=NSRange(location:r.location+value.utf16.count,length:0)
        }
        p.testPost={event in
            guard event.type == .keyDown else{return}
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode));posts.append(code);compose(code)
        }
        if normal {
            // The onset reservation blocked mismatch observation, while the
            // delivery barrier still knows every accepted RKS key.
            p.recovering=false
            p.verifiedDeliveryHistory={snap,_ in
                guard snap.text==ledger.text,snap.selection==ledger.selection else{return nil}
                return (ledger.lastTwoSetPlan()!,ProcessInfo.processInfo.systemUptime)
            }
        }else{p.finishDelivery(rollback:false,verifiedSnapshot:p.testSnapshot!()!)}
        let retained=p.plan?.replayRoman
        // A source round trip committed the already correct 간. The next
        // physical K produces loose jamo or ASCII in the editor double.
        let down=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!;down.flags=[]
        probeTestCheck(p.event(.keyDown,down) != nil)
        text=(text as NSString).replacingCharacters(in:range,with:suffix);range=NSRange(location:start+2,length:0)
        let up=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:false)!;up.flags=[]
        _=p.event(.keyUp,up);p.sample(synchronous:true)
        let until=Date().addingTimeInterval(1.5)
        while p.recovering,Date()<until{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(text=="앞🙂"+committed+"가나뒤" && range==NSRange(location:start+2,length:0),"verified 간 + \(suffix) automatically replays the full known RKS K interval: actual=\(text), plan=\(p.plan?.replayRoman ?? "nil"), rollback=\(p.rollbackReason)")
        check((normal ? retained==nil:retained=="rks") && p.plan?.replayRoman=="rksk","verified normal/completed history survives the next recovery")
        check(!p.recovering && !p.suspended && posts==[15,40,1,40] && p.retained.isEmpty,"one full replay; no discarded or duplicate input")
        let next=CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:true)!;next.flags=[]
        probeTestCheck(p.event(.keyDown,next) != nil);compose(1)
        let release=CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:false)!;release.flags=[]
        _=p.event(.keyUp,release);p.sample(synchronous:true)
        check(text=="앞🙂"+committed+"가난뒤" && posts.count==4 && !p.recovering,"a following consonant continues live IME composition without another repair")
    }}}
    let p=plan([15,40,1,40]),range=NSRange(location:5,length:0)
    check(p.interruptedCompositionPlan(text:"앞🙂간ㅏ뒤",selection:range)?.replayRoman=="rksk","complete composed prefix plus detached suffix is proven")
    check(p.interruptedCompositionPlan(text:"앞🙂간k뒤",selection:range)?.replayRoman=="rksk","complete composed prefix plus ASCII suffix is proven")
    check(p.interruptedCompositionPlan(text:"앞🙂간j뒤",selection:range)==nil,"wrong ASCII suffix is never inferred")
    check(p.interruptedCompositionPlan(text:"앞🙂간k뒤",selection:NSRange(location:4,length:0))==nil,"ASCII suffix caret must match")
    check(p.interruptedCompositionPlan(text:"앞🙂간k뒤",selection:NSRange(location:5,length:1))==nil,"ASCII suffix selection is rejected")
    check(p.interruptedCompositionPlan(text:"앞🙂가나뒤",selection:range)==nil,"normal composition is never repaired")
    for (text,r) in [("다🙂간ㅏ뒤",range),("앞🙂간ㅏ다",range),("앞🙂간ㅓ뒤",range),("앞🙂간ㅏ뒤",NSRange(location:4,length:0)),("앞🙂간ㅏ뒤",NSRange(location:5,length:1))] {
        check(p.interruptedCompositionPlan(text:text,selection:r)==nil,"surroundings, unobserved keys, caret and selection must match exactly")
    }
    let later=plan([15,40,1,40,1])
    check(later.interruptedCompositionPlan(text:"앞🙂간ㅏ뒤",selection:range)==nil,"unreflected later key cannot be omitted")
    check(later.observedPrefix(text:"앞🙂간ㅏ뒤",selection:range),"delayed detached prefix keeps all later observed keys")
    check(later.observedPrefix(text:"앞🙂간k뒤",selection:range),"delayed ASCII prefix keeps all later observed keys")
    check(later.interruptedCompositionPlan(text:"앞🙂간k뒤",selection:range)==nil,"ASCII proof cannot omit an unreflected key")
    var existing=MismatchRecoveryPlan(before:"앞🙂간뒤",caret:4);_=existing.append(code:40,shift:false)
    check(existing.interruptedCompositionPlan(text:"앞🙂간ㅏ뒤",selection:range)==nil,"existing document text is not invented as physical key history")
    check(existing.interruptedCompositionPlan(text:"앞🙂간k뒤",selection:range)==nil,"existing syllable cannot supply missing ASCII suffix history")
    var other=p;other.sourceID=KoreanKeyboardLayout.threeSetID
    check(other.interruptedCompositionPlan(text:"앞🙂간ㅏ뒤",selection:range)==nil,"unsupported layout cannot borrow two-set proof")
    check(plan([15,40,1,15]).interruptedCompositionPlan(text:"앞🙂간ㄱ뒤",selection:range)==nil,"intentional standalone consonant is unchanged")
    check(plan([15,40,1,49,40]).interruptedCompositionPlan(text:"앞🙂간 ㅏ뒤",selection:NSRange(location:6,length:0))==nil,"explicit space preserves intentional separation")
    check(plan([15,40,1,40]).interruptedCompositionPlan(text:"앞🙂ㄱㅏㄴㅏ뒤",selection:NSRange(location:7,length:0))==nil,"fully detached output stays on the existing detached-jamo path")
    for reason in ["english","text","caret","long","navigation","source","expiry","field","rollback"] {
        let e=MismatchRecoveryEngine();var ledger=MismatchReplayLedger(before:"앞🙂뒤",caret:3)
        ledger.append(source:ko,keys:reason=="long" ? Array(repeating:(15,false),count:65):[(15,false),(40,false),(1,false)])
        var source=reason=="english" ? e.englishID:ko
        let snap=MismatchSnapshot(element:field,text:reason=="text" ? "앞🙂다뒤":ledger.text,selection:reason=="caret" ? NSRange(location:3,length:0):ledger.selection)
        e.enabled=true;e.recovering=true;e.planElement=field;e.locked=field;e.ledger=ledger;e.intendedSource=source;e.rollingBack=reason=="rollback"
        e.testSource={source};e.testSnapshot={snap};e.testPost={_ in probeTestCheck(false,"continuation invalidation posted a key")}
        e.finishDelivery(rollback:reason=="rollback",verifiedSnapshot:snap)
        if reason=="navigation" {
            let key=CGEvent(keyboardEventSource:nil,virtualKey:124,keyDown:true)!;key.flags=[];_=e.event(.keyDown,key)
        }else if reason=="source"{source=e.englishID;e.sourceChanged(source,snap)}
        else if reason=="expiry"{e.planStart-=6;e.sample(synchronous:true)}
        else if reason=="field"{e.testSnapshot={MismatchSnapshot(element:AXUIElementCreateApplication(67890),text:ledger.text,selection:ledger.selection)};e.sample(synchronous:true)}
        check(e.plan==nil,"\(reason) cannot retain or reuse recovery history")
    }
    for failure in ["rks","rㅏㄴ"] {
        let e=MismatchRecoveryEngine();var text="앞🙂"+failure+"뒤",range=NSRange(location:3+failure.utf16.count,length:0)
        var source=ko,keys:[(UInt16,Bool)]=[],marked:NSRange?,posts:[UInt16]=[]
        let known=plan([15,40,1]),observedAt=ProcessInfo.processInfo.systemUptime
        e.enabled=true;e.locked=field;e.testSource={source};e.testSnapshot={.init(element:field,text:text,selection:range)}
        e.testSelectionWritable={_ in true};e.testSelectSource={source=$0;return noErr}
        e.testSetRange={_,r in range=r;keys=[];marked=nil;return .success}
        e.verifiedDeliveryHistory={snap,allowPrior in
            probeTestCheck(!allowPrior || snap.text != "앞🙂"+failure+"뒤")
            guard snap.text=="앞🙂"+failure+"뒤" else{return nil}
            return (known,observedAt)
        }
        e.testPost={event in
            guard event.type == .keyDown else{return}
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode));posts.append(code);keys.append((code,false))
            let value=MismatchKeyboardLayout.render(keys:keys,sourceID:ko)!,r=marked ?? range
            text=(text as NSString).replacingCharacters(in:r,with:value);marked=NSRange(location:r.location,length:value.utf16.count);range=NSRange(location:r.location+value.utf16.count,length:0)
        }
        e.sample(synchronous:true)
        let end=Date().addingTimeInterval(1.5)
        while e.recovering,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(!e.recovering && !e.suspended && text=="앞🙂간뒤" && posts==[15,40,1],"idle delivery history recovers every known key: \(failure)")
        for code:UInt16 in [40,1] {
            let down=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!;down.flags=[];_=e.event(.keyDown,down);e.testPost!(down)
            let up=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false)!;up.flags=[];_=e.event(.keyUp,up)
        }
        check(text=="앞🙂가난뒤" && posts==[15,40,1,40,1] && !e.recovering,"normal vowel and consonant follow whole-history idle recovery")
    }
    for age in [-1.0,6.0] {
        let e=MismatchRecoveryEngine();e.enabled=true;e.locked=field;e.testSource={ko}
        e.testSnapshot={.init(element:field,text:"앞🙂rks뒤",selection:NSRange(location:6,length:0))}
        e.verifiedDeliveryHistory={_,_ in (plan([15,40,1]),ProcessInfo.processInfo.systemUptime-age)}
        e.testPost={_ in probeTestCheck(false,"invalid-age history posted a key")}
        e.sample(synchronous:true);check(e.plan==nil && !e.recovering,"future or expired transferred history is rejected")
    }
    print("PASS: \(checks) completed recovery continuation checks; 간ㅏ/간k, full history, live suffix, context and intent boundaries")
}
