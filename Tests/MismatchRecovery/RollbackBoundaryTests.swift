import AppKit
import Carbon

// Original-field rollback must supersede an outstanding selection write, not
// accept a single optimistic caret read and forward keys into that selection.
// All AX/source/event operations are injected; no OS key posting or UI writes.
func runRollbackBoundaryTests(){
    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(12346)
    var checks=0
    func check(_ value:Bool,_ note:String){checks+=1;probeTestCheck(value,note)}
    func pump(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    for mode in ["optimistic_caret","ordinary_caret","delayed_restore","ignored_restore","changed_text","changed_field","selection_at_delivery","contradiction_at_delivery","late_selection_write","transient_read","cancelled"] {
        let p=MismatchRecoveryEngine()
        var plan=MismatchRecoveryPlan(before:"아",caret:1,sourceID:mismatchKoreanID)
        for code:UInt16 in [2,40,1]{_=plan.append(code:code,shift:false)}
        let candidate=plan.interruptedCompositionPlan(text:"아아ㄴ",selection:NSRange(location:3,length:0))!
        let caret=NSRange(location:3,length:0),repair=NSRange(location:1,length:2)
        var text="아아ㄴ",actual=mode=="ordinary_caret" || mode=="late_selection_write" ? caret:repair
        var requests=0,posted:[CGEventType]=[],unsafePost=false
        var restored=false,firstPostTime:Double?
        var readyReads=0,outageAt:Double?
        let began=ProcessInfo.processInfo.systemUptime
        p.enabled=true;p.recovering=true;p.currentPlan=candidate;p.planElement=field
        p.recoveryDeadline=began+1
        p.testSource={mismatchKoreanID};p.testSelectSource={_ in noErr}
        p.testSnapshot={
            if mode=="transient_read",restored,p.snapshotStage=="rollback" {
                readyReads+=1
                if readyReads==2{outageAt=ProcessInfo.processInfo.systemUptime;p.unavailableReason="editor_coordinates_unverified";return nil}
            }
            var range=actual
            if mode=="optimistic_caret" && !restored{range=caret}
            if p.snapshotStage=="delivery" && ["selection_at_delivery","contradiction_at_delivery"].contains(mode){
                actual=repair;range=mode=="contradiction_at_delivery" ? caret:repair
            }
            let selected=actual.length>0 ? (text as NSString).substring(with:actual):""
            return MismatchSnapshot(element:mode=="changed_field" ? other:field,text:mode=="changed_text" ? "changed":text,selection:range,selectedText:selected)
        }
        p.testSetRange={_,range in
            requests+=1
            if mode != "ignored_restore" {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.015){actual=range;restored=true}
            }
            return .success
        }
        p.testPost={event in
            if event.type == .keyDown {
                unsafePost = unsafePost || actual != caret || !restored
                firstPostTime=ProcessInfo.processInfo.systemUptime
                text=(text as NSString).replacingCharacters(in:actual,with:"s")
                actual=NSRange(location:actual.location+1,length:0)
            }
            posted.append(event.type)
        }
        for down in [true,false]{
            let key=CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:down)!
            key.flags=[];p.pending.append(key)
        }
        if mode=="late_selection_write"{
            DispatchQueue.main.asyncAfter(deadline:.now()+0.005){actual=repair}
        }
        p.abort("selection_not_applied")
        if mode=="cancelled"{p.park("test_cancelled")}
        pump(0.3)
        let mustRetain=["ignored_restore","changed_text","changed_field","selection_at_delivery","contradiction_at_delivery"].contains(mode)
        check(!p.recovering,"\(mode): bounded rollback")
        if mustRetain{
            check(posted.isEmpty,"\(mode): preserve queue on unproved insertion point")
            check(p.retained.count==2,"\(mode): retain both edges")
            if mode=="changed_text" || mode=="changed_field"{check(requests==0,"\(mode): no selection write to changed context")}
        }else if mode=="cancelled"{
            check(posted.isEmpty,"cancelled rollback never posts")
        }else{
            check(!unsafePost,"\(mode): never post into an unrestored or still-selected field")
            check(posted==[.keyDown,.keyUp],"\(mode): return each edge once")
            check(requests==1,"\(mode): supersede a possible outstanding range write once")
            if let outageAt{check((firstPostTime ?? began)-outageAt>=0.025,"failed read resets the stable caret interval")}
            check(text=="아아ㄴs","\(mode): preserve the complete original body")
            check((firstPostTime ?? began)-began>=0.03,"\(mode): require fresh stable caret observations")
        }
    }
    let text="앞🙂뒤"
    check(MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:1,length:0),selectedText:""),"known empty caret")
    check(MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:1,length:0),selectedText:nil),"unavailable selected text at caret stays unknown")
    check(!MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:1,length:0),selectedText:"🙂"),"nonempty selected text contradicts caret")
    check(MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:1,length:2),selectedText:"🙂"),"UTF16 selection matches")
    check(!MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:1,length:2),selectedText:nil),"selected range requires known text")
    check(!MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:1,length:2),selectedText:"앞"),"different selected text rejected")
    check(!MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:5,length:0),selectedText:""),"out of range caret rejected")
    check(!MismatchTextReader.selectionMatches(text:text,selection:NSRange(location:-1,length:1),selectedText:"앞"),"negative range rejected")
    check(MismatchRecoveryEngine.failureReasonCode("selection_not_applied")==3,"keep original selection reason code")
    check(MismatchRecoveryEngine.failureReasonCode("delivery_deadline")==20,"keep original deadline reason code")
    check(MismatchRecoveryEngine.failureReasonCode("partial_replay_retry_exhausted")==26,"keep last original reason code")
    check(MismatchRecoveryEngine.failureReasonCode("rollback_delivery_context_changed")==27,"identify first returned-key boundary")
    check(MismatchRecoveryEngine.failureReasonCode("rollback_caret_timeout")==29,"identify unconfirmed rollback caret")
    check(MismatchRecoveryEngine.failureReasonCode("unknown")==0,"unknown reasons are not fabricated")
    print("PASS \(checks) rollback boundary checks: optimistic caret, contradictory selection, late write, delivery recheck, cancellation")
}
