import AppKit
import Carbon

extension OnsetRecoveryEngine {
    // A completed late word is already committed input. Replace it through the
    // original AX element, never by queuing physical keys to the current focus.
    func canReplaceCommittedText(_ field:AXUIElement)->Bool {
        // This provider advertised a writable selection but did not confirm the
        // actual edit. The empty-composer handoff preserves original IME input;
        // never select/hold a late word here based only on the advertised flag.
        guard (testTargetBundleID?() ?? target?.bundleIdentifier) != "com.openai.codex" else{return false}
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
        beginCommittedCaretRestoration(candidate)
    }
    func beginCommittedCaretRestoration(_ candidate:OnsetRecoveryPlan){
        if committedCaretRestoring{verifyCommittedCaretRestoration();return}
        guard let field=planElement,let snap=originalSnapshot(field),
              snap.text==candidate.expected else{park("committed_cancel_unverified");return}
        let caret=NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0)
        if snap.selection==caret{log("committed_replacement_cancelled");finishCommittedReplacement(snap);return}
        guard snap.selection==NSRange(location:candidate.caret,length:candidate.roman.utf16.count) else{park("committed_cancel_unverified");return}
        // A successful range setter is not an acknowledgment. Issue cleanup
        // once, then wait for the original element's actual caret within the
        // existing input hold. Never repeat the uncertain text operation.
        committedCaretRestoring=true;committedReplacementAwaiting=true
        committedCaretRestoreDeadline=ProcessInfo.processInfo.systemUptime+0.12
        guard restoreCommittedCaret(candidate,snap) else{park("committed_cancel_unverified");return}
        verifyCommittedCaretRestoration()
    }
    func verifyCommittedCaretRestoration(){
        guard recovering,!rollingBack,committedCaretRestoring,
              let candidate=currentPlan,candidate.isCommittedLate,let field=planElement else{return}
        guard gate?.healthy() ?? true else{park("committed_gate_closed");return}
        if let restored=originalSnapshot(field){
            guard restored.text==candidate.expected else{park("committed_result_changed");return}
            let caret=NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0)
            if restored.selection==caret{
                log("committed_replacement_cancelled");finishCommittedReplacement(restored);return
            }
            guard restored.selection==NSRange(location:candidate.caret,length:candidate.roman.utf16.count) else{park("committed_cancel_unverified");return}
        }
        guard ProcessInfo.processInfo.systemUptime<committedCaretRestoreDeadline else{park("committed_cancel_unverified");return}
        scheduleRecovery(0.002){[weak self] in self?.verifyCommittedCaretRestoration()}
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
        if committedCaretRestoring{verifyCommittedCaretRestoration();return}
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
                beginCommittedCaretRestoration(candidate);return
            }
        }
        guard now<committedReplacementDeadline else{park("committed_result_unreadable");return}
        scheduleRecovery(0.002){[weak self] in self?.verifyCommittedReplacement()}
    }
    func finishCommittedReplacement(_ snap:OnsetSnapshot){
        committedReplacementAwaiting=false;committedCaretRestoring=false
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
