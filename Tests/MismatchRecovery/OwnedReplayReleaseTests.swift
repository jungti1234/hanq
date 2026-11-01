import AppKit
import Carbon

// Engine-only regressions for the two boundaries seen in the Edge report.
// No OS key posting, AX writes, source selection or simulated IME key loss.
func runOwnedReplayReleaseTests(){
    let ko=mismatchKoreanID,field=AXUIElementCreateApplication(12345)
    var checks=0
    func check(_ value:Bool,_ message:String){checks+=1;probeTestCheck(value,message)}
    func pump(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    func candidate(_ roman:String="dks")->MismatchRecoveryPlan {
        var p=MismatchRecoveryPlan(before:"아",caret:1,sourceID:ko)
        for letter in roman {
            let code=PhysicalLetterKeys.letters.first{$0.value==String(letter)}!.key
            probeTestCheck(p.append(code:code,shift:false))
        }
        return p
    }
    func detection()->MismatchRecoveryEngine {
        let p=MismatchRecoveryEngine(detectionOnly:true)
        p.enabled=true;p.locked=field;p.planElement=field;p.lastSource=ko;p.testSource={ko}
        p.plan=candidate();p.planStart=ProcessInfo.processInfo.systemUptime
        p.testPost={_ in probeTestCheck(false,"detection posted an OS key")}
        p.testSelectSource={_ in probeTestCheck(false,"detection selected a source");return noErr}
        return p
    }
    func event(_ code:CGKeyCode,_ down:Bool)->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
        e.flags=[];return e
    }
    for outcome in ["normal","unverified","new_down","field","deadline","source"] {
        let p=MismatchRecoveryEngine();var text="아안",range=NSRange(location:2,length:0),source=ko
        var ledger=MismatchReplayLedger(before:"아",caret:1)
        ledger.append(source:ko,keys:candidate().codes)
        p.enabled=true;p.recovering=true;p.replayStarted=true;p.locked=field;p.planElement=field
        p.ledger=ledger;p.recoverySourceID=ko;p.intendedSource=ko;p.lastSource=ko
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        p.testSource={source};p.testFastContext={true}
        var wrongField=false,posts:[String]=[],selections=0
        p.testSnapshot={.init(element:wrongField ? AXUIElementCreateApplication(67890):field,text:text,selection:range)}
        p.testSetRange={_,_ in selections+=1;return .failure}
        p.testSelectSource={_ in OSStatus(-1)}
        p.testPost={posts.append("\($0.type == .keyDown ? "down":"up"):\($0.getIntegerValueField(.keyboardEventKeycode))")}
        for (code,down):(CGKeyCode,Bool) in [(1,true),(1,false),(32,true),(2,true)] {
            check(p.event(down ? .keyDown:.keyUp,event(code,down))==nil,"following input is owned by the ordered recovery queue")
        }
        p.drain(verifiedSnapshot:p.testSnapshot!()!)
        check(posts==["down:1","up:1","down:32","down:2"],"the original batch is posted once in its original order")
        if outcome=="new_down" {check(p.event(.keyDown,event(40,true))==nil,"new down remains queued")}
        check(p.event(.keyUp,event(32,false))==nil && p.event(.keyUp,event(2,false))==nil,"late releases are first captured by the recovery owner")
        if outcome=="field" {wrongField=true}
        if outcome=="deadline" {p.recoveryDeadline=0}
        if outcome=="source" {source=p.englishID}
        pump(0.04)
        if ["field","deadline","source"].contains(outcome) {
            check(posts.count==4 && p.suspended && p.retained.count==2,"\(outcome) cannot deliver releases to an unproved context")
        }else if outcome=="new_down" {
            check(posts.count==4 && p.pending.count==3,"a release cannot jump over an unposted key-down")
            p.park("test_finished")
        }else {
            check(posts==["down:1","up:1","down:32","down:2","up:32","up:2"],"posted downs receive their ordered releases without waiting for a text acknowledgement")
            check(p.recovering && p.ledger?.text=="아안" && selections==0,"releasing a held key does not acknowledge text or authorize an edit")
            text=outcome=="normal" ? "아안녕":"아안ㅕㅇ";range=NSRange(location:text.utf16.count,length:0)
            pump(0.4)
            check(posts.count==6 && selections==0,"verification cannot guess a missing consonant or reinsert any key")
            if outcome=="normal" {
                check(!p.recovering && !p.suspended && p.ledger?.text==text && p.pending.isEmpty,"only complete text and caret finish recovery")
            }else{
                check(!p.recovering && p.suspended && p.ledger?.text=="아안" && p.retained.isEmpty,"unknown text still safe-stops without acknowledging its body, after balancing only already-posted holds")
            }
        }
        p.closeSession()
    }
    check(candidate("dkssud").partialFailurePlan(text:"아안ㅕㅇ",selection:NSRange(location:4,length:0))==nil,"incomplete reported text never becomes a complete-key proof")
    print("PASS: \(checks) owned replay release checks; ordered owned releases, no guessed replay, field/source/deadline safety")
}
