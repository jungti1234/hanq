import AppKit
import Carbon

func runActivationShortcutTests(){
    var checks=0
    for cause in ["focus","permission"] {for stop in 0...4 {
        let s=MismatchActivationShortcut();s.configuration={(49,.maskControl)};s.canPost={true};s.modifiersClear={true}
        var tasks:[(Double,()->Void)]=[],time=0.0,valid=true,permitted=true
        s.canPost={permitted}
        var posted:[(Int64,CGEventType)]=[],released:[(Int64,CGEventType)]=[]
        s.schedule={delay,work in tasks.append((time+delay,work))}
        s.post={posted.append(($0.getIntegerValueField(.keyboardEventKeycode),$0.type))}
        s.releasePosted={event,_ in released.append((event.getIntegerValueField(.keyboardEventKeycode),event.type))}
        probeTestCheck(s.request(marker:0x48414E514155544F,recipient:nil,valid:{valid})==noErr)
        var count=0
        while !tasks.isEmpty {
            if count==stop && stop<4{if cause=="focus"{valid=false}else{permitted=false}}
            tasks.sort{$0.0<$1.0};let task=tasks.removeFirst();time=task.0;task.1();count+=1
        }
        probeTestCheck(!s.busy)
        if stop==0{probeTestCheck(posted.map{$0.0}==[59] && released.map{$0.0}==[59])}
        if stop==1{probeTestCheck(posted.map{$0.0}==[59,49] && released.map{$0.0}==[49,59])}
        if stop==2{probeTestCheck(posted.map{$0.0}==[59,49,49] && released.map{$0.0}==[59])}
        if stop>=3{probeTestCheck(posted.map{$0.0}==[59,49,49,59] && released.isEmpty)}
        checks+=1
    }}
    for block in ["configuration","custom","permission","modifiers","context"] {
        let s=MismatchActivationShortcut();s.configuration={block=="configuration" ? nil:(block=="custom" ? (0,.maskCommand):(49,.maskControl))}
        s.canPost={block != "permission"};s.modifiersClear={block != "modifiers"};s.post={_ in probeTestCheck(false,"blocked shortcut posted")}
        probeTestCheck(s.request(marker:0,recipient:nil,valid:{block != "context"}) != noErr && !s.busy);checks+=1
    }
    let field=AXUIElementCreateApplication(12345),e=MismatchRecoveryEngine()
    var text="앞🙂rks뒤",selection=NSRange(location:6,length:0),source=mismatchKoreanID
    var api:[String]=[],shortcutDowns=0,sessionDowns=0,hidDowns=0,composition:[(UInt16,Bool)]=[],marked:NSRange?,activationReady=false
    var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
    for code:UInt16 in [15,40,1]{_ = candidate.append(code:code,shift:false)}
    e.enabled=true;e.planElement=field;e.testSelectionWritable={_ in true};e.testSource={source};e.observeSourcesForTests=true
    e.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
    e.testSetRange={_,r in selection=r;composition=[];marked=nil;return .success}
    e.testSelectSource={source=$0;api.append($0);return noErr}
    e.testActivationNeeded={!activationReady}
    e.activationShortcut.configuration={(49,.maskControl)};e.activationShortcut.canPost={true};e.activationShortcut.modifiersClear={true}
    e.activationShortcut.post={event in
        if event.type == .keyDown {shortcutDowns+=1;activationReady=true;source=mismatchKoreanID;e.observeRecoverySource(source)}
    }
    e.activationShortcut.releasePosted={_,_ in}
    e.testPostAtTap={event,tap in
        guard event.type == .keyDown else{return}
        let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if tap == .cgSessionEventTap {
            sessionDowns+=1
            let letter=MismatchRecoveryPlan.character(code,false)!
            text=(text as NSString).replacingCharacters(in:selection,with:letter);selection=NSRange(location:selection.location+1,length:0)
        }else{
            hidDowns+=1;composition.append((code,false));let result=MismatchKeyboardLayout.render(keys:composition,sourceID:mismatchKoreanID)!
            let range=marked ?? selection;text=(text as NSString).replacingCharacters(in:range,with:result);marked=NSRange(location:range.location,length:result.utf16.count);selection=NSRange(location:range.location+result.utf16.count,length:0)
        }
    }
    e.beginRecovery(candidate,MismatchSnapshot(element:field,text:text,selection:selection))
    let end=Date().addingTimeInterval(3)
    while e.recovering,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    probeTestCheck(!e.recovering && !e.suspended && text=="앞🙂간뒤" && selection==NSRange(location:4,length:0))
    probeTestCheck(e.koreanRetries==2 && api==[e.englishID,mismatchKoreanID,e.englishID,mismatchKoreanID,e.englishID,mismatchKoreanID,e.englishID])
    probeTestCheck(shortcutDowns==1 && sessionDowns==6 && hidDowns==3 && e.recoverySourceBoundaries.isEmpty && source==mismatchKoreanID)
    probeTestCheck(e.retained.isEmpty && e.pending.isEmpty && !e.activationShortcut.busy);checks+=1
    // A source cycle may already have committed the exact Korean rendering.
    // Reopen only that proven range and preserve the queued vowel's composition.
    let restored=MismatchRecoveryEngine()
    var restoredText="앞🙂간뒤",restoredSelection=NSRange(location:4,length:0),restoredSource=mismatchKoreanID
    var restoredKeys:[(UInt16,Bool)]=[],restoredRange:NSRange?,ready=false,queued=false
    restored.enabled=true;restored.recovering=true;restored.koreanRetries=2;restored.currentPlan=candidate;restored.planElement=field
    restored.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
    restored.testSnapshot={MismatchSnapshot(element:field,text:restoredText,selection:restoredSelection)}
    restored.testSource={restoredSource};restored.testSelectSource={restoredSource=$0;return noErr}
    restored.testActivationNeeded={!ready}
    restored.activationShortcut.configuration={(49,.maskControl)};restored.activationShortcut.canPost={true};restored.activationShortcut.modifiersClear={true}
    restored.activationShortcut.post={if $0.type == .keyDown{ready=true;restoredSource=mismatchKoreanID}}
    restored.activationShortcut.releasePosted={_,_ in}
    restored.testSetRange={_,r in restoredSelection=r;restoredKeys=[];restoredRange=nil;return .success}
    restored.testPostAtTap={event,tap in
        guard event.type == .keyDown else{return};probeTestCheck(tap == .cghidEventTap)
        restoredKeys.append((UInt16(event.getIntegerValueField(.keyboardEventKeycode)),false))
        let result=MismatchKeyboardLayout.render(keys:restoredKeys,sourceID:mismatchKoreanID)!,r=restoredRange ?? restoredSelection
        restoredText=(restoredText as NSString).replacingCharacters(in:r,with:result);restoredRange=NSRange(location:r.location,length:result.utf16.count);restoredSelection=NSRange(location:r.location+result.utf16.count,length:0)
        if !queued{queued=true;for down in [true,false]{let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;key.flags=[];probeTestCheck(restored.event(down ? .keyDown:.keyUp,key)==nil)}}
    }
    restored.prepareFinalActivation(candidate,MismatchSnapshot(element:field,text:"앞🙂rks뒤",selection:NSRange(location:6,length:0)))
    let restoredEnd=Date().addingTimeInterval(3)
    while restored.recovering,Date()<restoredEnd{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    probeTestCheck(!restored.recovering && !restored.suspended && restoredText=="앞🙂가나뒤" && restoredSelection==NSRange(location:5,length:0))
    probeTestCheck(restored.koreanRetries==2 && restored.pending.isEmpty && restored.retained.isEmpty);checks+=1
    checks+=runLateActivationTests()
    checks+=runLatePartialActivationTests()
    print("PASS \(checks) activation fallback checks: configured shortcut, cancellation releases, blocked settings/permissions/modifiers/context, bounded late Roman recovery and internal source ownership")
}

private func runLatePartialActivationTests()->Int {
    let field=AXUIElementCreateApplication(12345),ko=mismatchKoreanID
    for failure in ["ㄱㅏㄴ","가s","rㅏㄴ","ㄱks","ㄱkㄴ","ㄱㅏs"] { for mode in ["recover","already-used","unsupported","deadline"] {
        let e=MismatchRecoveryEngine();var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
        for code:UInt16 in [15,40,1]{_=candidate.append(code:code,shift:false)}
        var text="앞🙂"+failure+"뒤",range=NSRange(location:3+failure.utf16.count,length:0),source=ko
        var keys:[(UInt16,Bool)]=[],marked:NSRange?,queued=false,shortcuts=0,posts=0
        e.enabled=true;e.recovering=true;e.planElement=field;e.locked=field;e.currentPlan=candidate;e.koreanRetries=2;e.intendedSource=ko
        e.recoveryDeadline=ProcessInfo.processInfo.systemUptime+(mode=="deadline" ? 0.1:2.5)
        e.activationFallbackTried=mode=="already-used";e.testActivationNeeded={false}
        e.testSource={source};e.testSelectSource={source=$0;return noErr};e.testSnapshot={.init(element:field,text:text,selection:range)}
        e.activationShortcut.configuration={mode=="unsupported" ? nil:(49,.maskControl)}
        e.activationShortcut.canPost={true};e.activationShortcut.modifiersClear={true}
        e.activationShortcut.post={if $0.type == .keyDown{shortcuts+=1;source=ko}};e.activationShortcut.releasePosted={_,_ in}
        e.testSetRange={_,r in range=r;keys=[];marked=nil;return .success}
        e.testPostAtTap={event,tap in
            guard event.type == .keyDown else{return};probeTestCheck(tap == .cghidEventTap)
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode));posts+=1;keys.append((code,false))
            let value=MismatchKeyboardLayout.render(keys:keys,sourceID:ko)!,r=marked ?? range
            text=(text as NSString).replacingCharacters(in:r,with:value);marked=NSRange(location:r.location,length:value.utf16.count);range=NSRange(location:r.location+value.utf16.count,length:0)
            if !queued {queued=true;for down in [true,false]{let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;key.flags=[];probeTestCheck(e.event(down ? .keyDown:.keyUp,key)==nil)}}
        }
        e.awaitKorean(candidate,remaining:0)
        let end=Date().addingTimeInterval(2)
        while e.recovering,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        if mode=="recover" {
            probeTestCheck(!e.recovering && !e.suspended && text=="앞🙂가나뒤" && range==NSRange(location:5,length:0),"last partial HID result recovers through the unused OS fallback")
            probeTestCheck(shortcuts==1 && posts==4 && e.koreanRetries==2 && e.pending.isEmpty && e.retained.isEmpty)
        }else{probeTestCheck(shortcuts==0 && posts==0 && !e.recovering,"partial fallback respects \(mode)")}
    }}
    return 24
}

private func runLateActivationTests()->Int {
    let field=AXUIElementCreateApplication(12345)
    for mode in ["late","still-roman","edited","wrong-source","unsupported","deadline","already-used"] {
        let e=MismatchRecoveryEngine()
        var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
        for code:UInt16 in [15,40,1]{_ = candidate.append(code:code,shift:false)}
        var text="앞🙂rks뒤",selection=NSRange(location:6,length:0),source=mismatchKoreanID
        var shortcutDowns=0,sessionDowns=0,hidDowns=0,keys:[(UInt16,Bool)]=[],marked:NSRange?,queued=false
        e.enabled=true;e.planElement=field;e.testSelectionWritable={_ in true}
        e.testSource={source};e.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
        e.testSelectSource={source=$0;return noErr}
        // Metadata still looks ready at the pre-edit check. The real editor
        // result, rather than this cached answer, must authorize the fallback.
        e.testActivationNeeded={false}
        e.activationShortcut.configuration={mode=="unsupported" ? nil:(49,.maskControl)}
        e.activationShortcut.canPost={true};e.activationShortcut.modifiersClear={true}
        e.activationShortcut.post={if $0.type == .keyDown{shortcutDowns+=1;source=mismatchKoreanID}}
        e.activationShortcut.releasePosted={_,_ in}
        e.testSetRange={_,range in selection=range;keys=[];marked=nil;return .success}
        e.testPostAtTap={event,tap in
            guard event.type == .keyDown else{return}
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if tap == .cgSessionEventTap{sessionDowns+=1}else{hidDowns+=1}
            if !e.activationFallbackTried || mode=="still-roman" {
                text=(text as NSString).replacingCharacters(in:selection,with:MismatchRecoveryPlan.character(code,false)!)
                selection=NSRange(location:selection.location+1,length:0)
            }else{
                keys.append((code,false));let result=MismatchKeyboardLayout.render(keys:keys,sourceID:mismatchKoreanID)!,range=marked ?? selection
                text=(text as NSString).replacingCharacters(in:range,with:result);marked=NSRange(location:range.location,length:result.utf16.count);selection=NSRange(location:range.location+result.utf16.count,length:0)
            }
            if mode=="late",tap == .cghidEventTap,!queued {
                queued=true
                for down in [true,false]{let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;event.flags=[];probeTestCheck(e.event(down ? .keyDown:.keyUp,event)==nil)}
            }
        }
        let observed=MismatchSnapshot(element:field,text:text,selection:selection)
        if mode=="late"{e.beginRecovery(candidate,observed)}else{
            e.recovering=true;e.koreanRetries=2;e.currentPlan=candidate
            e.recoveryDeadline=ProcessInfo.processInfo.systemUptime+(mode=="deadline" ? 0.1:2.5)
            if mode=="already-used"{e.activationFallbackTried=true}
            if mode=="edited"{text="앞🙂변경뒤"}
            if mode=="wrong-source"{source=e.englishID}
            e.retryKorean(candidate,observed)
        }
        let end=Date().addingTimeInterval(3)
        while e.recovering,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        probeTestCheck(!e.recovering && e.koreanRetries==2,"late activation failed to terminate: \(mode)")
        if mode=="late" {
            probeTestCheck(!e.suspended && text=="앞🙂가나뒤" && selection==NSRange(location:5,length:0))
            probeTestCheck(shortcutDowns==1 && sessionDowns==6 && hidDowns==7 && e.pending.isEmpty && e.retained.isEmpty)
        }else if mode=="still-roman" {
            probeTestCheck(shortcutDowns==1 && hidDowns==3 && text=="앞🙂rks뒤" && e.rollbackReason=="korean_retry_exhausted")
        }else{probeTestCheck(shortcutDowns==0 && hidDowns==0 && sessionDowns==0,"unsafe late retry: \(mode)")}
    }
    return 7
}
