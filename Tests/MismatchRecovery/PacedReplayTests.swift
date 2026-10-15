import AppKit
import Carbon

func runPacedReplayTests(){
    let field=AXUIElementCreateApplication(12345)
    func pump(_ until:()->Bool){
        let deadline=Date().addingTimeInterval(3)
        while !until(),Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        probeTestCheck(until(),"paced replay did not complete within test deadline")
    }
    let layouts:[(String,[(UInt16,Bool)])]=[
        (KoreanKeyboardLayout.twoSetID,[(15,false),(40,false),(1,false)]),
        (KoreanKeyboardLayout.threeSetID,[(40,false),(3,false),(1,false)]),
        (KoreanKeyboardLayout.threeSet390ID,[(40,false),(3,false),(1,false)]),
        (KoreanKeyboardLayout.gongjinID,[(5,false),(0,false),(45,false)]),
        (KoreanKeyboardLayout.hncID,[(5,false),(0,false),(45,false)]),
        (KoreanKeyboardLayout.twoSetID,[(15,true),(40,false),(1,false)])]
    var checks=0
    for (sourceID,keys) in layouts {
    for suffix in [false,true] where !suffix || sourceID==KoreanKeyboardLayout.twoSetID {
    for fallbackWorks in [true,false] where fallbackWorks || (!suffix && sourceID==KoreanKeyboardLayout.twoSetID && !keys[0].1) {
        let p=MismatchRecoveryEngine()
        var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3,sourceID:sourceID)
        for (code,shift) in keys{probeTestCheck(candidate.append(code:code,shift:shift))}
        var text=candidate.expected!,selection=NSRange(location:3+candidate.roman.utf16.count,length:0)
        if sourceID==KoreanKeyboardLayout.twoSetID,!keys[0].1 {
            text="앞🙂ㄱㅏㄴ뒤"
            candidate=candidate.decomposedPlan(text:text,selection:selection)!
        }
        let original=MismatchSnapshot(element:field,text:text,selection:selection)
        var source=sourceID,composition:[(UInt16,Bool)]=[],marked:NSRange?
        var sessionDowns=0,hidDowns=0,hidUps=0,queued=false
        var stamps:[Double]=[]
        p.enabled=true;p.planElement=field;p.testSelectionWritable={_ in true};p.testSource={source}
        p.testSelectSource={source=$0;composition=[];marked=nil;return noErr}
        p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
        p.testSetRange={_,r in selection=r;composition=[];marked=nil;return .success}
        p.testPostAtTap={event,tap in
            probeTestCheck(OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)))
            guard event.type == .keyDown else{if tap == .cghidEventTap{hidUps+=1};return}
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode)),shift=event.flags.contains(.maskShift)
            if tap == .cgSessionEventTap || !fallbackWorks {
                // Model the observed failure: every ordinary replay remains
                // uncomposed despite a successfully selected Korean source.
                if tap == .cgSessionEventTap{sessionDowns+=1}
                else{hidDowns+=1;stamps.append(ProcessInfo.processInfo.systemUptime)}
                let letter=MismatchRecoveryPlan.character(code,shift)!
                text=(text as NSString).replacingCharacters(in:selection,with:letter)
                selection=NSRange(location:selection.location+letter.utf16.count,length:0)
            }else{
                hidDowns+=1;stamps.append(ProcessInfo.processInfo.systemUptime)
                composition.append((code,shift))
                let value=MismatchKeyboardLayout.render(keys:composition,sourceID:sourceID)!
                let r=marked ?? selection
                text=(text as NSString).replacingCharacters(in:r,with:value)
                marked=NSRange(location:r.location,length:value.utf16.count)
                selection=NSRange(location:r.location+value.utf16.count,length:0)
                if suffix,!queued {
                    queued=true
                    for down in [true,false] {
                        let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!
                        probeTestCheck(p.event(down ? .keyDown:.keyUp,key)==nil)
                    }
                }
            }
        }
        p.beginRecovery(candidate,original)
        pump{!p.recovering}
        if !fallbackWorks {
            probeTestCheck(text=="앞🙂"+candidate.replayRoman+"뒤" && source==sourceID)
            probeTestCheck(p.rollbackReason=="korean_retry_exhausted" && p.koreanRetries==2)
            probeTestCheck(sessionDowns==keys.count*2 && hidDowns==keys.count && hidUps==keys.count)
            probeTestCheck(p.pending.isEmpty && p.retained.isEmpty && !p.suspended && p.ledger==nil)
            checks+=1;continue
        }
        let all=keys+(suffix ? [(40,false)]:[])
        let expected=MismatchKeyboardLayout.render(keys:all,sourceID:sourceID)!
        probeTestCheck(text=="앞🙂"+expected+"뒤" && selection==NSRange(location:3+expected.utf16.count,length:0),"layout=\(sourceID) suffix=\(suffix) actual=\(text) expected=\(expected) rollback=\(p.rollbackReason) routes=\(sessionDowns)/\(hidDowns) retries=\(p.koreanRetries) suspended=\(p.suspended) budget=\(p.recoveryDeadline-ProcessInfo.processInfo.systemUptime)")
        probeTestCheck(sessionDowns==keys.count*2 && hidDowns==all.count && hidUps==all.count)
        probeTestCheck(p.koreanRetries==2 && p.rollbackReason.isEmpty && p.retained.isEmpty && p.pending.isEmpty)
        probeTestCheck(p.ledger?.text==text && source==sourceID)
        for i in 1..<keys.count{probeTestCheck(stamps[i]-stamps[i-1]>=0.010,"final replay is still a burst")}
        checks+=1
    }
    }
    }
    for reason in ["cancelled","source","focus","deadline"] {
        let p=MismatchRecoveryEngine();var source=mismatchKoreanID,context=true
        var candidate=MismatchRecoveryPlan(before:"",caret:0)
        for code:UInt16 in [15,40,1]{_ = candidate.append(code:code,shift:false)}
        p.enabled=true;p.recovering=true;p.koreanRetries=2;p.recoverySourceID=mismatchKoreanID
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+1
        p.testSource={source};p.testFastContext={context}
        var edges:[CGEventType]=[]
        p.testPostAtTap={event,tap in
            probeTestCheck(tap == .cghidEventTap);edges.append(event.type)
            if event.type == .keyUp {
                switch reason {
                case "cancelled":p.park("test_cancelled")
                case "source":source=p.englishID
                case "focus":context=false
                default:p.recoveryDeadline=0
                }
            }
        }
        let pending=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
        p.pending=[pending]
        p.replayPacedCandidate(candidate)
        pump{!p.recovering}
        probeTestCheck(edges == [.keyDown,.keyUp] && p.retained.count==1 && p.retained[0] === pending)
        checks+=1
    }
    // The source pulse occurs after the final up, while no more replay keys
    // remain. It must settle before result verification rather than park.
    do {
        let p=MismatchRecoveryEngine();var source=mismatchKoreanID,text="",selection=NSRange(location:0,length:0),edges:[CGEventType]=[]
        var candidate=MismatchRecoveryPlan(before:"",caret:0);_=candidate.append(code:15,shift:false)
        p.enabled=true;p.recovering=true;p.koreanRetries=2;p.recoverySourceID=mismatchKoreanID;p.intendedSource=mismatchKoreanID
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2;p.locked=field;p.planElement=field;p.currentPlan=candidate
        p.testSource={source};p.observeSourcesForTests=true;p.systemSwitch.reset(source);p.testFastContext={true}
        p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
        p.testSelectSource={source=$0;return noErr}
        p.testPostAtTap={event,_ in
            edges.append(event.type)
            if event.type == .keyDown{text="ㄱ";selection=NSRange(location:1,length:0)}
            else{source=p.englishID;DispatchQueue.main.asyncAfter(deadline:.now()+0.04){source=mismatchKoreanID}}
        }
        p.replayPacedCandidate(candidate);pump{!p.recovering}
        probeTestCheck(!p.suspended && p.rollbackReason.isEmpty && text=="ㄱ" && source==mismatchKoreanID)
        probeTestCheck(edges == [.keyDown,.keyUp] && p.koreanRetries==2 && p.ledger?.text==text,"completed pair verified exactly once after real source observation")
        checks+=1
    }
    print("PASS \(checks) paced HID fallback checks: failed bursts, five layouts, Shift, queued composition, balanced cancellation, source/focus/deadline safety")
}
