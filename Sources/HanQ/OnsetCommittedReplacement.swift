import AppKit
import Carbon

extension OnsetRecoveryEngine {
    // A completed late word is already committed input. Replace it through the
    // original AX element, never by queuing physical keys to the current focus.
    func canReplaceCommittedText(_ field:AXUIElement)->Bool {
        if let testCanReplaceText{return testCanReplaceText()}
        var writable:DarwinBoolean=false
        return AXUIElementIsAttributeSettable(field,kAXSelectedTextAttribute as CFString,&writable) == .success && writable.boolValue
    }
    func originalSnapshot(_ field:AXUIElement)->OnsetSnapshot? {
        if let testOriginalSnapshot{return testOriginalSnapshot(field)}
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled(),
              attr(field,kAXSubroleAttribute) as? String != "AXSecureTextField",
              let role=attr(field,kAXRoleAttribute) as? String,OnsetEditableRole.supports(role),
              let text=attr(field,kAXValueAttribute) as? String,
              let raw=attr(field,kAXSelectedTextRangeAttribute),CFGetTypeID(raw)==AXValueGetTypeID() else{return nil}
        var range=CFRange()
        guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0,
              range.location+range.length<=text.utf16.count else{return nil}
        return OnsetSnapshot(element:field,text:text,selection:NSRange(location:range.location,length:range.length))
    }
    func restoreCommittedCaret(_ candidate:OnsetRecoveryPlan,_ snap:OnsetSnapshot)->Bool {
        guard snap.text==candidate.expected else{return false}
        let caret=NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0)
        if snap.selection==caret{return true}
        guard snap.selection==NSRange(location:candidate.caret,length:candidate.roman.utf16.count) else{return false}
        // Cleanup only our exact selection on the original element. It neither
        // activates that element nor writes text to a newly focused field.
        if let testSetRange{return testSetRange(snap.element,caret) == .success}
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled() else{return false}
        var range=CFRange(location:caret.location,length:0)
        return AXUIElementSetAttributeValue(snap.element,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&range)!) == .success
    }
    func cancelCommittedSelection(_ candidate:OnsetRecoveryPlan){
        guard let field=planElement,let snap=originalSnapshot(field),restoreCommittedCaret(candidate,snap) else{park("committed_cancel_unverified");return}
        guard let restored=originalSnapshot(field),restored.text==candidate.expected,
              restored.selection==NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0) else{park("committed_cancel_unverified");return}
        log("committed_replacement_cancelled")
        finishCommittedReplacement(restored)
    }
    func replaceCommitted(_ candidate:OnsetRecoveryPlan,_ selected:OnsetSnapshot){
        guard !replayStarted,let replacement=candidate.replayedText,
              gate?.healthy() ?? true,currentSource()==repairSourceID,
              let live=snapshot(),CFEqual(live.element,selected.element),live.text==candidate.expected,
              live.selection==NSRange(location:candidate.caret,length:candidate.roman.utf16.count) else{cancelCommittedSelection(candidate);return}
        // One request only, including when AX returns an ambiguous error. Read
        // the original target to confirm; never retry the edit or replay keys.
        replayStarted=true;committedReplacementAwaiting=true
        committedReplacementDeadline=ProcessInfo.processInfo.systemUptime+0.15
        let result:AXError
        if let testReplaceText{result=testReplaceText(live.element,replacement)}
        else{result=AXUIElementSetAttributeValue(live.element,kAXSelectedTextAttribute as CFString,replacement as CFString)}
        log(result == .success ? "committed_replacement_requested":"committed_replacement_result_uncertain")
        verifyCommittedReplacement()
    }
    func verifyCommittedReplacement(){
        guard recovering,!rollingBack,committedReplacementAwaiting,let candidate=currentPlan,candidate.isCommittedLate,
              replayStarted,let field=planElement,let replacement=candidate.replayedText else{return}
        guard gate?.healthy() ?? true else{park("committed_gate_closed");return}
        let now=ProcessInfo.processInfo.systemUptime
        if let snap=originalSnapshot(field){
            let expected=(candidate.before as NSString).replacingCharacters(in:NSRange(location:candidate.caret,length:0),with:replacement)
            if snap.text==expected,snap.selection==NSRange(location:candidate.caret+replacement.utf16.count,length:0){
                log("committed_replacement_confirmed");deliveryPrefixConfirmed=true;finishCommittedReplacement(snap);return
            }
            if snap.text != candidate.expected{park("committed_result_changed");return}
            if now>=committedReplacementDeadline {
                guard restoreCommittedCaret(candidate,snap) else{park("committed_cancel_unverified");return}
                guard let restored=originalSnapshot(field),restored.text==candidate.expected,
                      restored.selection==NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0) else{park("committed_cancel_unverified");return}
                log("committed_replacement_not_applied");finishCommittedReplacement(restored);return
            }
        }
        guard now<committedReplacementDeadline else{park("committed_result_unreadable");return}
        scheduleRecovery(0.002){[weak self] in self?.verifyCommittedReplacement()}
    }
    func finishCommittedReplacement(_ snap:OnsetSnapshot){
        committedReplacementAwaiting=false
        collectHeld()
        // Original input is separate from the text replacement. Its existing
        // per-event target/source checks remain mandatory before delivery.
        if !pending.isEmpty{
            guard let live=snapshot(),CFEqual(live.element,snap.element),currentSource()==repairSourceID else{
                park("committed_pending_context_changed");return
            }
            drain([]);return
        }
        guard gate?.finishIfEmpty() ?? true else{
            scheduleRecovery(0.001){[weak self] in guard let self,self.recovering else{return};self.finishCommittedReplacement(snap)};return
        }
        recovering=false;rollingBack=false;replayStarted=false;currentPlan=nil;planElement=nil
        lastEditable=snap;lastSource=currentSource();publishPassedBaseline(snap);log("committed_replacement_finished")
    }
}
