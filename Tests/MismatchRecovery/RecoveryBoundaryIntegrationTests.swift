import AppKit
import Carbon

// Exercise the old rollback/acknowledgment protections with actual engine-owned
// replay holds. Every snapshot, selection, source and post is injected.
func runRecoveryBoundaryIntegrationTests(){
    let field=AXUIElementCreateApplication(12345),ko=mismatchKoreanID
    var checks=0
    func check(_ condition:Bool,_ note:String){checks+=1;probeTestCheck(condition,note)}
    func key(_ code:CGKeyCode,_ down:Bool)->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e
    }
    for mode in ["late_ack","no_ack","rollback_before_replay","rollback_after_replay"] {
        let p=MismatchRecoveryEngine()
        var plan=MismatchRecoveryPlan(before:"아",caret:1,sourceID:ko)
        for code:UInt16 in [2,40,1]{_=plan.append(code:code,shift:false)}
        let candidate=plan.interruptedCompositionPlan(text:"아아ㄴ",selection:NSRange(location:3,length:0))!
        let began=ProcessInfo.processInfo.systemUptime
        probeTestCheck(candidate.expected != nil,"fixture has a valid complete original body")
        var text=candidate.expected!,range=NSRange(location:1,length:2),selected:String?="아ㄴ"
        var posts:[String]=[],writeCount=0,sourceCount=0,unsafePost=false,firstReturnedAt:Double?
        p.enabled=true;p.recovering=true;p.replayStarted=mode != "rollback_before_replay";p.currentPlan=candidate;p.planElement=field;p.locked=field
        p.recoverySourceID=ko;p.intendedSource=ko;p.lastSource=ko
        p.recoveryDeadline=began+(mode=="no_ack" ? 0.5:1)
        let originalDeadline=p.recoveryDeadline
        p.testFastContext={true};p.testSource={ko}
        p.testSelectSource={_ in sourceCount+=1;return noErr}
        p.testSnapshot={
            if mode=="late_ack",ProcessInfo.processInfo.systemUptime-began>=0.42,text==candidate.expected {
                text="아안";range=NSRange(location:2,length:0);selected=""
            }
            return .init(element:field,text:text,selection:range,selectedText:selected)
        }
        p.testSetRange={_,wanted in
            writeCount+=1
            DispatchQueue.main.asyncAfter(deadline:.now()+0.015){range=wanted;selected=""}
            return .success
        }
        p.testPost={event in
            let code=event.getIntegerValueField(.keyboardEventKeycode)
            posts.append("\(event.type == .keyDown ? "d":"u")\(code)")
            if (posts.count>1 || mode=="rollback_before_replay"),firstReturnedAt==nil{firstReturnedAt=ProcessInfo.processInfo.systemUptime}
            if code==1,event.type == .keyDown {
                if mode=="rollback_before_replay" {
                    unsafePost=range != NSRange(location:3,length:0) || selected?.isEmpty != true
                    text="아아ㄴs";range=NSRange(location:4,length:0);selected=""
                }else{text="아안ㄴ";range=NSRange(location:3,length:0);selected=""}
            }
        }
        if mode=="rollback_before_replay"{p.pending=[key(1,true),key(1,false)]}
        else{p.post(key(2,true));p.pending=[key(2,false),key(1,true),key(1,false)]}
        if mode.hasPrefix("rollback"){p.abort("selection_not_applied")}
        else{
            p.awaitKorean(candidate,remaining:2)
            RunLoop.current.run(until:Date().addingTimeInterval(0.10))
            check(posts==["d2"] && p.pending.count==3,"\(mode): awaiting acknowledgment preserves release and following pair")
            check(p.recoveryDeadline==originalDeadline && writeCount==0 && sourceCount==0,"\(mode): waiting performs no edit/source change/deadline renewal")
        }
        let end=Date().addingTimeInterval(1.2)
        while p.recovering && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(!p.recovering,"\(mode): bounded completion")
        if mode=="no_ack" {
            check(p.suspended && p.retained.count==3 && posts==["d2"],"unacknowledged prefix retains all original pending edges")
        }else if mode=="rollback_after_replay" {
            check(p.suspended && p.retained.count==3 && posts==["d2"] && writeCount==0,"replayed prefix cannot authorize an intact-body rollback or release a selected queue")
            let beforePosts=posts.count
            var ledger=MismatchReplayLedger(before:"아",caret:1);ledger.append(source:ko,keys:plan.codes)
            text="unrelated";range=NSRange(location:9,length:0);selected=""
            p.recovering=true;p.suspended=false;p.rollingBack=false;p.currentPlan=candidate;p.planElement=field
            p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+0.5;p.pending=[key(2,false)]
            p.verifyBuffered(ledger,before:.init(element:field,text:"아안",selection:ledger.selection),remaining:0)
            RunLoop.current.run(until:Date().addingTimeInterval(0.03))
            check(posts.count==beforePosts && p.suspended && p.retained.count==4,"parking clears the old replay hold while preserving all retained input across a later cycle")
        }else{
            let expected=mode=="rollback_before_replay" ? ["d1","u1"]:["d2","u2","d1","u1"]
            check(posts==expected && p.pending.isEmpty && p.retained.isEmpty,"\(mode): prefix release and following pair occur exactly once in order")
            check(!unsafePost,"\(mode): follow-up never replaces the repair selection")
            check(sourceCount==0,"\(mode): no source switch solely to release a hold")
            if mode=="late_ack" {
                check(text=="아안ㄴ" && writeCount==0 && (firstReturnedAt ?? began)-began>=0.42,"late result resumes the original queue only after actual snapshot acknowledgment")
            }else{
                check(text=="아아ㄴs" && writeCount==1 && (firstReturnedAt ?? began)-began>=0.03,"rollback supersedes range once and waits for a stable caret before all returned events")
            }
        }
        p.closeSession()
    }
    print("PASS \(checks) recovery boundary integration checks: owned holds with delayed/no acknowledgment, stable rollback, exact order and cross-cycle cleanup; no OS keys")
}
