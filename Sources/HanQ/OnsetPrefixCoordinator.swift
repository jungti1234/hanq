import AppKit
import Carbon

// Experimental, opt-in adjunct to the existing recovery engine. A native Space
// boundary authorizes one prefix edit and its immediate selection restoration.
// Once that edit completes, the editor exclusively owns Undo/Redo and selection.
// Quiet time never authorizes an IME commit.
final class OnsetPrefixCoordinator {
    unowned let e:OnsetRecoveryEngine
    init(_ engine:OnsetRecoveryEngine){e=engine}
    // Timing fixtures substitute only OS observations/requests. Proof, plan,
    // atomic claim, deadlines, selection verification and drain stay production.
    #if PREFIX_TIMING_TEST
    var testTargetPID:pid_t?
    var testFrontPID:(()->pid_t?)?
    var testSecureInput:(()->Bool)?
    var testRangeSupport:((AXUIElement)->Bool)?
    var testRangeRequest:((AXUIElement,CFDictionary)->AXError)?
    #endif
    var targetPID:pid_t? {
        #if PREFIX_TIMING_TEST
        if let testTargetPID{return testTargetPID}
        #endif
        return e.target?.processIdentifier
    }
    var frontPID:pid_t? {
        #if PREFIX_TIMING_TEST
        if let testFrontPID{return testFrontPID()}
        #endif
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    var secureInput:Bool {
        #if PREFIX_TIMING_TEST
        if let testSecureInput{return testSecureInput()}
        #endif
        return IsSecureEventInputEnabled()
    }
    struct Transaction {
        let field:AXUIElement,source:String,before:String,after:String
        let afterSelection:NSRange
    }
    private(set) var transaction:Transaction?
    private(set) var busy=false
    private var lastReadUs=0
    private var deadline=0.0,stable:Double?,caretWritten=false,resultObserved=false
    var trace:((String)->Void)?
    func note(_ value:String){e.log("prefix_candidate_"+value);trace?(value)}
    // Fixed metadata only: no text, absolute ranges, key values or field IDs.
    func measurement(_ stage:String,code:Int32=0,elapsed:Double=0) {
        let now=ProcessInfo.processInfo.systemUptime
        let line="prefix_measure stage=\(stage) op=0 epoch=\(e.recoveryEpoch) ax=\(code) axUs=\(Int(max(0,elapsed)*1_000_000)) readUs=\(lastReadUs) operationMs=\(Int(max(0,now-e.recoveryBegan)*1000)) remainingMs=\(Int((deadline-now)*1000)) written=\(caretWritten) body=\(resultObserved) healthy=\(e.gate?.healthy()==true) hold=\(e.gate?.hasActiveReplayHold()==true)"
        InputDiagnostics.shared.record(line);trace?(line)
    }
    func recordStop(_ reason:String) {
        guard transaction != nil else{return}
        measurement("stop")
        let fixed=OnsetSafetyDiagnostics.reason(reason)
        InputDiagnostics.shared.record("prefix_stop reason=\(fixed)")
        trace?("prefix_stop reason=\(fixed)")
    }
    static func exact(_ lhs:String?,_ rhs:String)->Bool{lhs?.utf16.elementsEqual(rhs.utf16)==true}
    static func exactPrefix(_ text:String,_ prefix:String)->Bool{text.utf16.starts(with:prefix.utf16)}
    // AX ranges are UTF-16. Never guess an endpoint inside the replaced pair.
    static func mappedSelection(_ selection:NSRange,textLength:Int)->NSRange? {
        guard selection.location>=0,selection.length>=0,selection.location<=textLength,
              selection.length<=textLength-selection.location else{return nil}
        func map(_ n:Int)->Int?{if n==1{return nil};return n>=2 ? n-1:n}
        guard let start=map(selection.location),let end=map(NSMaxRange(selection)) else{return nil}
        return NSRange(location:start,length:end-start)
    }
    func close(){transaction=nil;busy=false}
    func supportsRangeEdit(_ field:AXUIElement)->Bool {
        #if PREFIX_TIMING_TEST
        if let testRangeSupport{return testRangeSupport(field)}
        #endif
        var names:CFArray?
        return AXUIElementCopyParameterizedAttributeNames(field,&names) == .success
            && (names as? [String])?.contains("AXReplaceRangeWithText")==true
    }
    func begin(_ plan:OnsetRecoveryPlan,_ snap:OnsetSnapshot,passed:OnsetInputGate.PassedInput)->Bool {
        guard !busy,e.canBeginRepair(),supportsRangeEdit(snap.element),
              let live=e.snapshot(),CFEqual(live.element,snap.element),live.text.utf16.elementsEqual(snap.text.utf16),
              live.selection==snap.selection,e.currentSource()==passed.first.sourceID,
              e.gate?.claimPassed(passed)==true else{return false}
        return performClaimedEdit(plan,snap,source:passed.first.sourceID)
    }
    // Shared transaction body. Caller must have acquired the original-input hold
    // and verified the complete field/source/selection immediately before entry.
    func performClaimedEdit(_ plan:OnsetRecoveryPlan,_ snap:OnsetSnapshot,source:String)->Bool {
        guard e.gate?.hasActiveReplayHold()==true,let replacement=plan.replayedText,
              let afterSelection=Self.mappedSelection(snap.selection,textLength:snap.text.utf16.count),
              Self.exactPrefix(snap.text,plan.roman),plan.roman.utf16.count==2,
              replacement.utf16.count==1 else{e.park("prefix_plan_missing");return true}
        guard snap.text.utf16.count<=4096 else{e.park("prefix_body_changed");return true}
        transaction=Transaction(field:snap.element,source:source,before:snap.text,
                                after:replacement+plan.before,afterSelection:afterSelection)
        start(plan,field:snap.element,source:source)
        var range=CFRange(location:0,length:2)
        let parameters:[String:Any]=["AXReplacementRange":AXValueCreate(.cfRange,&range)!,"AXReplacementText":replacement]
        var ignored:CFTypeRef?
        let result:AXError
        #if PREFIX_TIMING_TEST
        if let testRangeRequest{result=testRangeRequest(snap.element,parameters as CFDictionary)}
        else{result=AXUIElementCopyParameterizedAttributeValue(snap.element,"AXReplaceRangeWithText" as CFString,parameters as CFDictionary,&ignored)}
        #else
        result=AXUIElementCopyParameterizedAttributeValue(snap.element,"AXReplaceRangeWithText" as CFString,parameters as CFDictionary,&ignored)
        #endif
        note(result == .success ? "edit_requested":"edit_uncertain")
        // Never retry even when the request returned an error.
        tick();return true
    }
    func start(_ plan:OnsetRecoveryPlan,field:AXUIElement,source:String){
        e.willBeginRepair();e.recoveryEpoch+=1;e.recoveryBegan=ProcessInfo.processInfo.systemUptime
        e.recovering=true;e.rollingBack=false;e.replayStarted=false;e.deliveryPrefixConfirmed=false
        e.currentPlan=plan;e.planElement=field;e.repairSourceID=source;e.postedBuffered=0
        e.bufferedBase=e.nextBufferedID-Int64(e.pending.count)
        busy=true;stable=nil;caretWritten=false;resultObserved=false;deadline=ProcessInfo.processInfo.systemUptime+0.15
    }
    func tick(){
        guard busy,let transaction else{return}
        guard e.enabled,e.gate?.healthy()==true,e.currentSource()==transaction.source,
              frontPID==targetPID,
              !secureInput else{e.park("prefix_context_changed");return}
        let readBegan=ProcessInfo.processInfo.systemUptime
        let snapshot=e.snapshot()
        let now=ProcessInfo.processInfo.systemUptime
        lastReadUs=Int(max(0,now-readBegan)*1_000_000)
        guard let live=snapshot,CFEqual(live.element,transaction.field) else{
            if now>=deadline{e.park("prefix_result_unreadable")};return
        }
        // AX may block. Start acknowledgment time at the completed observation,
        // and recheck ownership before any write or input release.
        guard e.gate?.healthy()==true,e.currentSource()==transaction.source,
              frontPID==targetPID,
              !secureInput else{e.park("prefix_context_changed");return}
        let expected=transaction.after
        if Self.exact(live.text,expected) {
            if !resultObserved{resultObserved=true;deadline=now+0.12;note("body_observed");measurement("body_observed")}
            let desired=transaction.afterSelection
            if live.selection != desired {
                let native=NSRange(location:1,length:0)
                guard live.selection==native else{e.park("prefix_caret_changed");return}
                if !caretWritten {
                    caretWritten=true;note("selection_restore_requested")
                    let writeBegan=ProcessInfo.processInfo.systemUptime
                    let writeResult=e.setRange(live.element,desired)
                    measurement("selection_write",code:writeResult.rawValue,elapsed:ProcessInfo.processInfo.systemUptime-writeBegan)
                    // A timed-out AX request may already have reached the editor.
                    // Write once, then require the same bounded body/selection
                    // acknowledgment as success. Never retry or infer success
                    // from the return code, and keep definite errors terminal.
                    guard writeResult == .success || writeResult == .cannotComplete else{e.park("prefix_caret_refused");return}
                    if writeResult == .cannotComplete{note("selection_write_uncertain")}
                }
                stable=nil
                if now>=deadline{e.park("prefix_caret_timeout")}
                return
            }
            if let stable,now-stable>=0.025 {finish(live);return}
            if stable==nil{stable=now;measurement("selection_matches")}
        }else if !Self.exact(live.text,transaction.before) {e.park("prefix_body_changed");return}
        if now>=deadline{e.park("prefix_result_timeout")}
    }
    func finish(_ snap:OnsetSnapshot){
        measurement("finish")
        // Keep only the initial edit's input hold. The existing committed-edit
        // drain releases it atomically after any overlapping original keys.
        // No history record, menu observer, or command interceptor survives.
        busy=false;transaction=nil;e.deliveryPrefixConfirmed=true
        note("verified_native_history")
        e.finishCommittedReplacement(snap)
    }
}
