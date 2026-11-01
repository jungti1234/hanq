import AppKit
import Carbon

func runPostedOnsetHistoryTests() {
    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(54321)
    let ko=KoreanKeyboardLayout.twoSetID
    var checks=0
    func check(_ condition:Bool,_ message:String){checks+=1;if !condition{fputs("FAIL posted onset history: \(message)\n",stderr);exit(1)}}
    func codes(_ roman:String)->[UInt16] {
        roman.map{c in c==" " ? 49:PhysicalLetterKeys.letters.first{$0.value==String(c)}!.key}
    }
    func event(_ code:UInt16,_ timestamp:CGEventTimestamp=0)->CGEvent {
        let e=CGEvent(keyboardEventSource:CGEventSource(stateID:.hidSystemState),virtualKey:code,keyDown:true)!
        e.flags=[];e.timestamp=timestamp;return e
    }
    for test in ["split","normal","unreflected","field","prefix","selection","boundary","expiry"] {
        let b=SourceSwitchBarrier();var clock=ProcessInfo.processInfo.systemUptime
        let before="앞🙂 뒤",caret=4
        var text=before,range=NSRange(location:caret,length:0)
        b.now={clock};b.source={ko};b.ready={true};b.readFocus={field}
        b.read={.init(field:field,text:text,selection:range)}
        b.send={_ in check(false,"history observation must not post")}
        b.applySelection={_,_ in check(false,"history observation must not select");return false}
        b.beginOnsetReplay(field:field,before:before,caret:caret)
        let keys=codes("dkssud rmsep sork")
        let first=event(keys[0])
        b.observePostedOnsetEvent(first)
        check(first.timestamp==0 && first.flags.isEmpty,"new post time must not mutate the event")
        for code in keys.dropFirst(){b.observe(.keyDown,event(code,MismatchRecoveryEngine.sourceEventTime()))}
        let inserted=test=="normal" ? "안녕 근데 내가":"안녕 근ㄷㅔ 내가"
        text=(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:inserted)
        range=NSRange(location:caret+inserted.utf16.count,length:0)
        if test=="unreflected"{b.observe(.keyDown,event(0,MismatchRecoveryEngine.sourceEventTime()))}
        if test=="prefix"{text="변"+String(text.dropFirst())}
        if test=="selection"{range.length=1}
        if test=="expiry"{clock+=6}
        let snap=MismatchSnapshot(element:test=="field" ? other:field,text:text,selection:range)
        let result=b.verifiedTwoSetHistory(snap,after:test=="boundary" ? UInt64.max:0)
        if ["split","normal"].contains(test) {
            check(result?.plan.codes.count==17,"zero-time first post must not poison later physical history")
            check((result?.plan.partialFailurePlan(text:text,selection:range) != nil)==(test=="split"),"normal Korean remains unchanged; only exact split is a failure")
            let engine=MismatchRecoveryEngine(detectionOnly:true)
            engine.enabled=true;engine.locked=field;engine.testSource={ko};engine.testSnapshot={snap}
            engine.verifiedDeliveryHistory={observed,prior in b.verifiedTwoSetHistory(observed,after:0,allowPrior:prior)}
            engine.testPost={_ in check(false,"detection-only fixture must not post")}
            engine.sample(synchronous:true)
            check(engine.detectionCount==(test=="split" ? 1:0),"real mismatch engine receives and detects the split full history")
        }else{check(result==nil,"\(test) must still reject unproved history")}
    }
    for intended in [false,true] {
        let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0)
        b.source={ko};b.readFocus={field};b.read={.init(field:field,text:text,selection:range)}
        b.beginOnsetReplay(field:field,before:"",caret:0)
        let keys=codes(intended ? "sosork":"sork")
        b.observePostedOnsetEvent(event(keys[0]))
        for code in keys.dropFirst(){b.observe(.keyDown,event(code,MismatchRecoveryEngine.sourceEventTime()))}
        text="내내가";range=NSRange(location:text.utf16.count,length:0)
        let result=b.verifiedTwoSetHistory(.init(element:field,text:text,selection:range),after:0)
        check((result != nil)==intended,"repeated body needs all observed components; never guess-delete repetition")
        check(result?.plan.partialFailurePlan(text:text,selection:range)==nil,"intentional repetition is not a repair")
    }
    do {
        let b=SourceSwitchBarrier();b.source={ko};b.readFocus={field}
        b.beginOnsetReplay(field:field,before:"",caret:0)
        b.observe(.keyDown,event(15))
        check(b.verifiedTwoSetHistory(.init(element:field,text:"ㄱ",selection:NSRange(location:1,length:0)),after:0)==nil,"unproved zero-time physical event is not upgraded to a posted replay")
    }
    do {
        let b=SourceSwitchBarrier();b.source={ko};b.readFocus={field}
        b.beginOnsetReplay(field:field,before:"",caret:0)
        let first=event(15,100);b.observePostedOnsetEvent(first)
        check(first.timestamp==100,"existing nonzero event time is preserved")
        check(b.verifiedTwoSetHistory(.init(element:field,text:"ㄱ",selection:NSRange(location:1,length:0)),after:200)==nil,"nonzero old history remains older than the user boundary")
    }
    print("PASS \(checks) posted-onset zero-time history, whole split detection, normal/intentional repetition and safety boundaries; no OS keys")
}
