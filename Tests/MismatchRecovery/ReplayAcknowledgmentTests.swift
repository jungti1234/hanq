import AppKit
import Carbon

func runReplayAcknowledgmentTests(){
    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(12346)
    var checks=0
    func check(_ value:Bool,_ note:String){checks+=1;probeTestCheck(value,note)}
    for mode in ["late_korean","unobserved","changed_field","changed_text"] {
        let p=MismatchRecoveryEngine()
        var plan=MismatchRecoveryPlan(before:"아",caret:1,sourceID:mismatchKoreanID)
        for code:UInt16 in [2,40,1]{_=plan.append(code:code,shift:false)}
        let candidate=plan.interruptedCompositionPlan(text:"아아ㄴ",selection:NSRange(location:3,length:0))!
        let began=ProcessInfo.processInfo.systemUptime
        var text="아아ㄴ",range=NSRange(location:1,length:2),selected:String?="아ㄴ",applied=false
        var posts:[CGEventType]=[],writes=0,selections=0
        p.enabled=true;p.recovering=true;p.replayStarted=true;p.currentPlan=candidate;p.planElement=field
        p.recoveryDeadline=began+(mode=="late_korean" ? 1:0.5)
        p.testSource={mismatchKoreanID};p.testSelectSource={_ in selections+=1;return noErr}
        p.testSetRange={_,_ in writes+=1;return .success}
        p.testSnapshot={
            let elapsed=ProcessInfo.processInfo.systemUptime-began
            if mode=="late_korean",elapsed>=0.42,!applied{text="아안";range=NSRange(location:2,length:0);selected="";applied=true}
            return MismatchSnapshot(element:mode=="changed_field" && elapsed>0.04 ? other:field,
                text:mode=="changed_text" && elapsed>0.04 ? "unrelated":text,selection:range,selectedText:selected)
        }
        p.testPost={event in
            posts.append(event.type)
            if event.type == .keyDown{text="아안ㄴ";range=NSRange(location:3,length:0);selected=""}
        }
        for down in [true,false]{let e=CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:down)!;e.flags=[];p.pending.append(e)}
        p.awaitKorean(candidate,remaining:25)
        let until=Date().addingTimeInterval(1.2)
        while p.recovering && Date()<until{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(!p.recovering,"\(mode): bounded completion")
        check(writes==0 && selections==0,"\(mode): never retry/edit or switch for an unacknowledged replay")
        if mode=="late_korean"{
            check(!p.suspended && p.retained.isEmpty && p.pending.isEmpty,"late acknowledgment resumes original queue")
            check(posts==[.keyDown,.keyUp] && text=="아안ㄴ","pending pair delivered once, no duplicate prefix")
            check(ProcessInfo.processInfo.systemUptime-began>=0.42,"does not invent early acknowledgment")
        }else{
            check(p.suspended && p.retained.count==2 && posts.isEmpty,"\(mode): uncertain result retains the original queue")
            if mode=="unobserved"{check(ProcessInfo.processInfo.systemUptime-began<0.75,"unchanged selection never renews deadline")}
        }
    }
    print("PASS \(checks) replay acknowledgment checks: late result, no acknowledgment, changed field/text, no duplicate keys or renewed deadline")
}
