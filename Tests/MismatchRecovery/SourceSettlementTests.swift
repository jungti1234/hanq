import AppKit
import Carbon

func runSourceSettlementTests(){
    let ko=mismatchKoreanID,en="com.apple.keylayout.ABC",field=AXUIElementCreateApplication(12345)
    var checks=0
    func check(_ value:Bool,_ message:String){probeTestCheck(value,message);checks+=1}
    func pump(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    check(MismatchRecoveryEngine.sourceEventTime()>0,"zero CGEvent time uses the monotonic source boundary clock")
    func fixture()->(MismatchRecoveryEngine,()->String,(String)->Void,()->[String]) {
        let p=MismatchRecoveryEngine();var source=ko,selected:[String]=[]
        p.enabled=true;p.recovering=true;p.planElement=field;p.recoverySourceID=ko;p.intendedSource=ko
        p.systemSwitch.reset(ko);p.observeSourcesForTests=true;p.testFastContext={true}
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        var ledger=MismatchReplayLedger(before:"앞🙂뒤",caret:3);ledger.append(source:ko,keys:[(15,false),(40,false),(1,false)])
        p.ledger=ledger;p.testSource={source}
        p.testSnapshot={MismatchSnapshot(element:field,text:ledger.text,selection:ledger.selection)}
        p.testSelectSource={source=$0;selected.append($0);return noErr}
        p.testPost={_ in probeTestCheck(false,"source-only settlement must not post keys")}
        p.testSetRange={_,_ in probeTestCheck(false,"source-only settlement must not edit text");return .failure}
        return(p,{source},{source=$0},{selected})
    }
    for returnDelay in [0.015,0.067,0.09] {
        let (p,current,set,selected)=fixture(),budget=p.recoveryDeadline
        set(en);p.observeRecoverySource(en,at:100)
        // This restoration used to consume the external Korean return as an
        // internal acknowledgement, leaving only the intermediate English intent.
        p.later(0.001){p.restoreInterruptedSource("test"){p.later(0.15){p.drain()}}}
        DispatchQueue.main.asyncAfter(deadline:.now()+returnDelay){set(ko);p.observeRecoverySource(ko,at:200)}
        pump(0.45)
        check(!p.recovering && !p.suspended && current()==ko && p.intendedSource==ko,"external round trip finishes Korean instead of stale English")
        check(p.recoverySourceBoundaries.map{$0.source}==[en,ko],"both external boundaries survive internal restoration")
        check(selected()==[ko] && p.retained.isEmpty,"one known restoration, no final English selection or lost keys")
        check(p.recoveryDeadline==budget,"quiet wait does not extend recovery deadline")
    }
    do {
        let (p,current,set,selected)=fixture()
        set(en);p.observeRecoverySource(en,at:100);p.later(0){p.drain()}
        pump(0.18)
        check(!p.recovering && current()==en && p.intendedSource==en && selected().isEmpty,"a real persistent English choice remains English")
        check(p.recoverySourceBoundaries.count==1 && p.retained.isEmpty,"stable external choice is not discarded")
    }
    do {
        let (p,_,set,selected)=fixture()
        set(en);p.observeRecoverySource(en,at:100)
        var ran=0;p.later(0){ran+=1};pump(0.02)
        check(ran==0 && selected().isEmpty && p.sourceWorkPaused,"no own work runs between external source observations")
        p.userToggleDuringRecovery(at:200);pump(0.02)
        check(!p.sourceWorkPaused && ran==1 && p.intendedSource==ko,"explicit toggle supersedes settlement and resumes once")
        p.closeSession();pump(0.12)
        check(ran==1 && !p.recovering,"stale timer cannot resume cancelled recovery")
    }
    for reason in ["focus","permission","deadline","oscillation","late-poll"] {
        let (p,_,set,selected)=fixture();var now=1.0,ran=false
        p.interactionNow={now};set(en);p.observeRecoverySource(en,at:100)
        p.deferRecovery{ran=true}
        let epoch=p.recoveryEpoch,revision=p.sourceSettlementRevision
        if reason=="focus"{p.testFastContext={false}}
        else if reason=="permission"{p.canObserve={false}}
        else if reason=="deadline"{p.recoveryDeadline=0}
        else if reason=="late-poll"{now=1.31}
        else {
            now=1.25;set(ko);p.observeRecoverySource(ko,at:200)
            now=1.31
        }
        p.pollExternalSource(epoch:epoch,revision:revision)
        check(!p.recovering && p.suspended && !ran && selected().isEmpty,"\(reason) cannot select, edit or resume")
    }
    do {
        let (p,_,set,_)=fixture();var now=1.0
        p.interactionNow={now};set(en);p.observeRecoverySource(en,at:100)
        let old=p.sourceSettlementRevision
        p.cancelExternalSourceSettlement();now=1.01;p.settleExternalSource()
        let next=p.sourceSettlementRevision
        p.pollExternalSource(epoch:p.recoveryEpoch,revision:old)
        check(p.sourceSettlementRevision==next && p.externalSourceSettlement != nil,"old poll cannot finish a newer settlement in the same recovery")
        p.closeSession()
    }
    do {
        let (p,_,set,_)=fixture()
        set(en);p.observeRecoverySource(en,at:100)
        var keys:[CGEvent]=[]
        for down in [true,false] {
            let e=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!
            e.flags=[];e.timestamp=150
            _=p.captureEventOrigin(down ? .keyDown:.keyUp,e)
            probeTestCheck(p.event(down ? .keyDown:.keyUp,e)==nil)
            keys.append(e)
        }
        check(p.pending.count==2 && p.pending.allSatisfy{p.pendingSources[p.bufferedID($0)]==en},"keys during an external English interval retain their language and release pairing")
        set(ko);p.observeRecoverySource(ko,at:200)
        p.closeSession();pump(0.12)
        check(p.retained.count==2 && p.pending.isEmpty && !p.recovering,"cancel during settling preserves all queued keys without posting")
    }
    print("PASS: \(checks) external source settlement checks; round trips, persistent intent, explicit boundaries, bounded wait and cancellation")
}
