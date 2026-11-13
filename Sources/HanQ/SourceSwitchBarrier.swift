import AppKit
import Carbon

/// Keep a user source boundary behind text already submitted to the editor.
/// The ledger is evidence for ordering, never a replacement for editor text.
final class SourceSwitchBarrier {
    var sourceEvidence:MismatchSourceEvidence?
    private var deferredHistoryEpoch:Int?
    var didConfirmSource:(String,CGEventTimestamp)->Void = {_,_ in}
    var incidentTrace=InputIncidentTrace.shared
    var diagnostic:(InputIncidentTrace.BoundaryEvidence)->Void = {_ in}
    private var diagnosticGeneration:Int32=0
    private var diagnosticHistory=BoundaryDiagnosticHistory()
    private var diagnosticTransaction:BoundaryDiagnosticTransaction?
    private var diagnosticSequence=0
    struct Snapshot { let field:AXUIElement; let text:String; let selection:NSRange }
    static let marker:Int64 = 0x4851535749544348
    var read:()->Snapshot? = {nil}
    struct SwitchWindow {let pid:pid_t,window:AXUIElement,stamp:CGEventTimestamp,at:Double}
    var readForOutsideSwitch:(()->(Snapshot?,(pid_t,AXUIElement)?))?
    var readFocus:(()->AXUIElement?)?
    // Only an explicit switch can arm this guard. A layout report cannot
    // authorize an edit to text the application already owns.
    enum InitialLayout {case conflicting, ready, unknown, sourceChanged}
    var initialLayout:(()->InitialLayout)?
    var fieldWindow:(AXUIElement)->AXUIElement? = { field in
        var raw:CFTypeRef?
        guard AXUIElementCopyAttributeValue(field,kAXWindowAttribute as CFString,&raw) == .success,
              let raw,CFGetTypeID(raw)==AXUIElementGetTypeID() else{return nil}
        return (raw as! AXUIElement)
    }
    private struct Entry {let field:AXUIElement;let at:Double}
    private struct HeldStart {let snapshot:Snapshot;let window:AXUIElement;let until:Double}
    private var entry:Entry?
    private struct UnfocusedSwitch {
        let began:Double, pid:pid_t
        let window:AXUIElement?
        var usedPrior=false
        var first:CGEventTimestamp=0
        var sampled=0
        var firstCheck=InputIncidentTrace.SwitchKeyCheck.firstNotSeen
    }
    private var unfocusedSwitch:UnfocusedSwitch?
    var frontPID:()->pid_t? = {NSWorkspace.shared.frontmostApplication?.processIdentifier}
    var frontWindow:(pid_t)->AXUIElement? = { pid in
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.003)
        var raw:CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&raw) == .success,
              let raw,CFGetTypeID(raw)==AXUIElementGetTypeID() else{return nil}
        return (raw as! AXUIElement)
    }

    func didSwitchWithoutField(_ id:String,at timestamp:CGEventTimestamp,prior:SwitchWindow?=nil) {
        unfocusedSwitch=nil
        guard id==KoreanKeyboardLayout.twoSetID,timestamp != 0,let pid=frontPID() else{return}
        let began=now(),current=frontWindow(pid)
        if let prior {
            guard prior.pid==pid,prior.stamp==timestamp,
                  current.map({CFEqual($0,prior.window)}) != false else{return}
            if current==nil,!(0...0.15).contains(now()-prior.at){return}
        }
        unfocusedSwitch=UnfocusedSwitch(began:began,pid:pid,window:current ?? prior?.window,usedPrior:current==nil && prior != nil)
    }
    func cancelUnfocusedSwitch(){unfocusedSwitch=nil}
    func unfocusedKeyCheck(_ timestamp:CGEventTimestamp,needsReadyLayout:Bool=false)->InputIncidentTrace.SwitchKeyCheck {
        guard let attempt=unfocusedSwitch else{return .noSwitch}
        guard timestamp != 0 else{return .timestampMissing}
        guard attempt.first != 0 else{return attempt.firstCheck}
        guard attempt.first==timestamp else{return .firstDiffers}
        guard now()-attempt.began<=2.5 else{return .expired}
        guard frontPID()==attempt.pid else{return .appChanged}
        guard let original=attempt.window else{return .originalWindowMissing}
        guard let current=frontWindow(attempt.pid) else{return .currentWindowMissing}
        guard CFEqual(original,current) else{return .windowChanged}
        guard !needsReadyLayout || initialLayout?() == .ready else{return .layoutNotReady}
        return attempt.usedPrior ? .matchedPreSwitchWindow:.matched
    }
    // Only remember the identity of a key that is passing normally. Changing
    // focus on that first key is application behavior; never hold it here.
    private func observeUnfocusedInput(_ type:CGEventType,_ event:CGEvent) {
        guard var attempt=unfocusedSwitch else{return}
        let elapsed=now()-attempt.began
        guard elapsed>=0,elapsed<=2.5 else{unfocusedSwitch=nil;return}
        if type == .keyUp{return}
        if type == .flagsChanged {
            let code=event.getIntegerValueField(.keyboardEventKeycode)
            if [54,56,60].contains(code),event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty{return}
        }
        guard isInitialLetter(event) else{unfocusedSwitch=nil;return}
        if attempt.sampled==0 {
            guard elapsed<=MismatchSourceEvidence.confirmationSeconds,event.timestamp != 0,
                  frontPID()==attempt.pid else{unfocusedSwitch=nil;return}
            // A window change can keep the same process and the same layout.
            if let original=attempt.window {
                if let current=frontWindow(attempt.pid) {
                    if CFEqual(original,current){attempt.first=event.timestamp}
                    else{attempt.firstCheck = .firstWindowChanged}
                }else{attempt.firstCheck = .firstWindowMissing}
            }else{attempt.firstCheck = .originalWindowMissing}
        }
        if attempt.sampled<2,elapsed<=MismatchSourceEvidence.confirmationSeconds {
            attempt.sampled+=1
            unfocusedSwitch=attempt
            guard incidentTrace.enabled,let initialLayout else{return}
            let stage:InputIncidentTrace.BoundaryStage
            switch initialLayout() {
            case .conflicting:stage = .unfocusedLayoutConflict
            case .ready:stage = .unfocusedLayoutReady
            case .unknown:stage = .unfocusedLayoutUnknown
            case .sourceChanged:stage = .unfocusedSourceChanged
            }
            incidentTrace.sourceBoundary(stage,queued:0,awaitingOnset:0)
        }
        unfocusedSwitch=attempt
    }
    private var resumedOriginalBatch=false
    private var heldStart:HeldStart?
    private struct NativeBatch {
        let field:AXUIElement,window:AXUIElement
        let layout:InitialLayout
        var keys:[(UInt16,Bool)]=[]
        var expected:String?
    }
    private var nativeBatch:NativeBatch?
    private var nextLayoutCheck=0.0
    static func classifyInitialLayout(first:String,layout:String,override:String?,last:String)->InitialLayout {
        let target=KoreanKeyboardLayout.twoSetID, keyboard="com.apple.keylayout.2SetHangul"
        guard first==last else{return .unknown}
        guard first==target else{return first=="unknown" ? .unknown:.sourceChanged}
        if layout=="com.apple.keylayout.ABC",override==nil{return .conflicting}
        let korean=[target,keyboard]
        return korean.contains(layout) && (override==nil || korean.contains(override!)) ? .ready:.unknown
    }
    var source:()->String = InputSourceAccess.currentID
    var ready:()->Bool = {true}
    var select:(String)->OSStatus = InputSourceAccess.select
    var selectionPending:()->Bool = {false}
    var cancelSelection:()->Void = {}
    private var switchSnapshot:Snapshot?
    var didSelect:(CGEventTimestamp)->Void = {_ in}
    var send:(CGEvent)->Void = {$0.post(tap:.cgSessionEventTap)}
    var retained:([CGEvent])->Void = {_ in}
    var cancelledModifiers:([CGEvent])->Void = {_ in}
    var trace:(String)->Void = {_ in}
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    private(set) var busy=false
    private var field:AXUIElement?
    private var transactionField:AXUIElement?
    private var ledger:MismatchReplayLedger?
    private var priorKeyLedger:MismatchReplayLedger?
    private var deletionHistory:(field:AXUIElement,ledger:MismatchReplayLedger,started:CGEventTimestamp)?
    private var lastKeyAt=0.0
    private var priorKeyAt=0.0
    private var historyStarted:CGEventTimestamp=0
    private var selectedRange:NSRange?
    private var pendingSelectAll=false
    private var awaitingSelection=false
    private var selectionAttempts=0
    private var selectionRetryAt=0.0
    var applySelection:(AXUIElement,NSRange)->Bool = { field,range in
        var value=CFRange(location:range.location,length:range.length)
        guard let raw=AXValueCreate(.cfRange,&value) else{return false}
        return AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,raw) == .success
    }
    private var queued:[CGEvent]=[]
    private var deliveredHeld:Set<Int64>=[]
    private var target:String?
    private var targetTimestamp:CGEventTimestamp=0
    private var awaitingReplay=false
    private var externalEditPending=false
    private struct ManualEdit {let token:Int;let field:AXUIElement;let source:String}
    private var manualEdit:ManualEdit?
    private var manualEditSequence=0
    private func isReady()->Bool {manualEdit==nil && ready()}
    private var waitingForRepairBoundary=false
    private struct DeliveryKey:Hashable {
        let identity:UInt64;let code:Int64
        init(_ event:CGEvent) {
            let token=event.getIntegerValueField(.eventSourceUserData)
            identity=token==0 ? event.timestamp:UInt64(bitPattern:token)
            code=event.getIntegerValueField(.keyboardEventKeycode)
        }
    }
    private var repairInFlight:Set<DeliveryKey>=[]
    private struct OnsetDeliveryKey:Hashable {
        let identity:UInt64
        let tagged:Bool
        let code:Int64
        init(_ event:CGEvent){
            let raw=event.getIntegerValueField(.eventSourceUserData)
            tagged=KeyboardStateMirror.isDeliveryOrigin(raw)
            identity=tagged ? UInt64(bitPattern:raw):event.timestamp
            code=event.getIntegerValueField(.keyboardEventKeycode)
        }
    }
    private var onsetInFlight:[OnsetDeliveryKey:[CGEvent]]=[:]
    private var onsetPendingCount=0
    // Discard only observation history; a live edit, selection, queued event
    // or outstanding receipt still belongs to its original transaction.
    func prepareFreshMismatchObservation()->Bool {
        guard !busy,!pendingSelectAll,!awaitingSelection,manualEdit==nil,
              queued.isEmpty,repairInFlight.isEmpty,onsetInFlight.isEmpty,!awaitingReplay else{return false}
        resetObservation();externalEditPending=false;cancelUnfocusedSwitch()
        return true
    }
    var diagnosticCounts:(queued:Int,awaitingOnset:Int) {(queued.count,onsetPendingCount)}
    /// The main tap precedes the onset gate. A key seen here may be held there,
    /// so do not predict it until that gate reports its actual delivery decision.
    func observeBeforeOnset(_ type:CGEventType,_ event:CGEvent,waiting:Bool,checkpoint:((InputIncidentTrace.RoutingStage)->Void)?=nil) {
        if type == .keyDown,(waiting || !onsetInFlight.isEmpty) {
            guard onsetPendingCount<256,let copy=event.copy() else{fail("delivery_limit");return}
            onsetInFlight[OnsetDeliveryKey(event),default:[]].append(copy)
            onsetPendingCount+=1
            trace("onset_delivery_waiting")
            return
        }
        observe(type,event,historyTimestamp:event.timestamp,checkpoint:checkpoint)
    }
    func confirmOnsetDelivery(_ event:CGEvent,passed:Bool) {
        let key=OnsetDeliveryKey(event)
        guard var occurrences=onsetInFlight[key],!occurrences.isEmpty else{return}
        // The onset gate queues receipts in event order. Autorepeat can reuse
        // the press token, so keep each occurrence until its own receipt.
        let original=occurrences.removeFirst()
        onsetInFlight[key]=occurrences.isEmpty ? nil:occurrences
        onsetPendingCount-=1
        trace(original.timestamp==event.timestamp ? "onset_delivery_confirmed":"onset_delivery_retimed")
        if passed {observe(.keyDown,original)}
    }
    private var deadline=0.0
    private var repairWaitStarted:Double?
    private var generation=0
    private var scheduled=false
    private var waitReason:String?
    private var mismatchedSnapshot:Snapshot?
    private var lastTextMatch:TextMatch?
    private var replaySource=CGEventSource(stateID:.privateState)

    var expected:(String,NSRange)? {
        guard let ledger else{return nil}
        return (ledger.text,selectedRange ?? ledger.selection)
    }
    func matches(_ snap:Snapshot)->Bool {
        resolveDeletionBoundary(snap)
        guard let expected,snap.selection==expected.1 else{return false}
        return matchesText(snap)
    }
    private enum TextMatch {case exact,style,terminalLF,terminalLFStyle}
    private func textMatch(_ snap:Snapshot,_ ledger:MismatchReplayLedger,allowEmptyInsertion:Bool=false)->TextMatch? {
        textMatch(snap,ledger,renderedInsertion:ledger.insertion,allowEmptyInsertion:allowEmptyInsertion)
    }
    private func textMatch(_ snap:Snapshot,_ ledger:MismatchReplayLedger,renderedInsertion:String,allowEmptyInsertion:Bool=false)->TextMatch? {
        let before=ledger.before as NSString
        let longContext=before.length>=256
        // Compare canonically equivalent text without repeatedly traversing
        // bridged strings through Swift's equality slow path. NFC is applied
        // only to comparison copies; editor text and UTF-16 ranges stay intact.
        func wellFormed(_ raw:CFString)->Bool {
            let length=CFStringGetLength(raw)
            func valid(_ units:UnsafeBufferPointer<UniChar>)->Bool {
                var i=0
                while i<units.count {
                    let unit=units[i];i+=1
                    if (0xd800...0xdbff).contains(unit) {
                        guard i<units.count,(0xdc00...0xdfff).contains(units[i]) else{return false}
                        i+=1
                    } else if (0xdc00...0xdfff).contains(unit) {return false}
                }
                return true
            }
            return withExtendedLifetime(raw) {
                if let pointer=CFStringGetCharactersPtr(raw){return valid(UnsafeBufferPointer(start:pointer,count:length))}
                var buffer=[UniChar](repeating:0,count:length)
                return buffer.withUnsafeMutableBufferPointer {units in
                    if length>0{CFStringGetCharacters(raw,CFRange(location:0,length:length),units.baseAddress!)}
                    return valid(UnsafeBufferPointer(units))
                }
            }
        }
        func sameText(_ left:String,_ right:String)->Bool {
            // Short comparisons do not pay for normalization or validation.
            guard longContext,left.utf16.count>=256,right.utf16.count>=256 else{return left==right}
            let leftRaw=left as CFString,rightRaw=right as CFString
            // A foreign NSString can contain unpaired surrogates. Swift
            // repairs those during equality; preserve that exact fallback.
            guard wellFormed(leftRaw),wellFormed(rightRaw) else{return left==right}
            return (left.precomposedStringWithCanonicalMapping as NSString)
                .isEqual(to:right.precomposedStringWithCanonicalMapping)
        }
        let predicted=before.replacingCharacters(in:NSRange(location:ledger.caret,length:0),with:renderedInsertion)
        if sameText(snap.text,predicted){return .exact}
        guard !ledger.segments.isEmpty,allowEmptyInsertion || !renderedInsertion.isEmpty else{return nil}
        var wanted=predicted as NSString
        var removedLF=false
        // An empty final web paragraph can expose one AX-only LF, then omit it
        // on typing. Only that original suffix after the insertion may disappear.
        if snap.text.utf16.count+1==wanted.length,ledger.caret==before.length-1,
           ledger.caret>=0,before.substring(from:ledger.caret)=="\n" {
            wanted=wanted.substring(to:wanted.length-1) as NSString;removedLF=true
        }
        guard snap.text.utf16.count==wanted.length else{return nil}
        let insertion=NSRange(location:ledger.caret,length:renderedInsertion.utf16.count)
        let actual=snap.text as NSString
        guard NSMaxRange(insertion)<=wanted.length else{return nil}
        guard sameText(actual.substring(to:insertion.location),wanted.substring(to:insertion.location)),
              sameText(actual.substring(from:NSMaxRange(insertion)),wanted.substring(from:NSMaxRange(insertion))) else{return nil}
        func fold(_ value:String)->[UInt32] {
            value.unicodeScalars.map{(65...90).contains($0.value) ? $0.value+32:($0.value==160 ? 32:$0.value)}
        }
        let actualInsertion=actual.substring(with:insertion),wantedInsertion=wanted.substring(with:insertion)
        guard fold(actualInsertion)==fold(wantedInsertion) else{return nil}
        if removedLF{return sameText(actualInsertion,wantedInsertion) ? .terminalLF:.terminalLFStyle}
        return .style
    }
    func matchesText(_ snap:Snapshot)->Bool {
        resolveDeletionBoundary(snap)
        guard let ledger else{return false};return textMatch(snap,ledger) != nil
    }
    private func resolvingDeletionBoundary(_ snap:Snapshot,_ candidate:MismatchReplayLedger)->MismatchReplayLedger {
        // Accept only the complete, normally composed new consonant run after
        // the verified deletion prefix. ASCII or detached vowels still fail.
        guard candidate.postDeletionPrefixCount != nil,textMatch(snap,candidate)==nil,
              let committed=candidate.committingDeletionPrefix(),
              snap.selection==committed.selection,textMatch(snap,committed) != nil else{return candidate}
        // The old interval is now acknowledged document text, not replay keys.
        // Bind its actual spelling/space representation outside the new range.
        guard let last=committed.segments.last else{return candidate}
        let length=MismatchReplayLedger.render(last).utf16.count
        let start=snap.selection.location-length
        let text=snap.text as NSString
        guard start>=0,NSMaxRange(NSRange(location:start,length:length))<=text.length else{return candidate}
        var result=MismatchReplayLedger(before:text.replacingCharacters(in:NSRange(location:start,length:length),with:""),caret:start)
        result.append(source:last.source,keys:last.keys)
        return result
    }
    private func resolveDeletionBoundary(_ snap:Snapshot) {
        guard let candidate=ledger,candidate.postDeletionPrefixCount != nil,
              selectedRange==nil,let field,CFEqual(field,snap.field) else{return}
        let resolved=resolvingDeletionBoundary(snap,candidate)
        if diagnosticEnabled(),candidate.selection != resolved.selection || candidate.postDeletionPrefixCount != resolved.postDeletionPrefixCount {noteDiagnosticHistory(13)}
        ledger=resolved
    }
    private func noteTextMatch(_ snap:Snapshot) {
        guard let ledger else{return}
        let result=textMatch(snap,ledger)
        guard let match=result else{noteDiagnosticComparison(snap,match:nil);return}
        mismatchedSnapshot=nil
        if pendingSelectAll,(match == .terminalLF || match == .terminalLFStyle),
           selectedRange==NSRange(location:0,length:ledger.text.utf16.count) {
            selectedRange=NSRange(location:0,length:snap.text.utf16.count)
            noteDiagnosticHistory(9)
        }
        noteDiagnosticComparison(snap,match:match)
        guard lastTextMatch != match else{return};lastTextMatch=match
        switch match {
        case .exact:break
        case .style:trace("editor_insertion_style_matched")
        case .terminalLF:trace("editor_terminal_lf_matched")
        case .terminalLFStyle:trace("editor_terminal_lf_style_matched")
        }
    }
    private func isPendingTextPrefix(_ snap:Snapshot)->Bool {
        guard var candidate=ledger,let last=candidate.segments.last else{return false}
        for count in stride(from:last.keys.count,through:0,by:-1) {
            candidate.segments[candidate.segments.count-1].keys=Array(last.keys.prefix(count))
            if textMatch(snap,candidate,allowEmptyInsertion:true) != nil{return true}
        }
        return false
    }
    /// Select-all is an explicit request for the current editor body. Some
    /// editors expose an initial prompt as AXValue and remove it on typing.
    /// Acknowledge that removal only when every observed key, across all source
    /// segments, accounts for the entire current body. Never rewrite text or
    /// accept a partial delivery, a changed field, or an arbitrary new baseline.
    private func acknowledgeInitialBodyRemoval(_ snap:Snapshot) {
        guard pendingSelectAll,let field,CFEqual(field,snap.field),
              let previous=ledger,!previous.before.isEmpty,
              !previous.insertion.isEmpty,snap.text==previous.insertion,
              snap.selection==NSRange(location:snap.text.utf16.count,length:0) ||
                snap.selection==NSRange(location:0,length:snap.text.utf16.count) else{return}
        var acknowledged=MismatchReplayLedger(before:"",caret:0)
        acknowledged.segments=previous.segments
        ledger=acknowledged
        selectedRange=NSRange(location:0,length:snap.text.utf16.count)
        noteDiagnosticHistory(9,baseline:true)
        trace("select_all_initial_body_removed")
    }
    /// A source request also provides an explicit boundary. Only accept an
    /// initial body disappearing at offset zero when all observed keys account
    /// for the complete current text and its end caret. This proves delivery
    /// without treating arbitrary editor changes as a new baseline.
    private func acknowledgeSourceInitialBodyRemoval(_ snap:Snapshot) {
        guard target != nil,switchSnapshot == nil,!pendingSelectAll,
              !awaitingSelection,
              let field,CFEqual(field,snap.field),let previous=ledger,
              previous.caret==0,!previous.before.isEmpty,!previous.insertion.isEmpty else{return}
        var acknowledged=MismatchReplayLedger(before:"",caret:0)
        acknowledged.segments=previous.segments
        guard textMatch(snap,acknowledged) != nil,
              snap.selection==acknowledged.selection,!isPendingTextPrefix(snap) else{return}
        ledger=acknowledged;selectedRange=nil;mismatchedSnapshot=nil;noteDiagnosticHistory(9,baseline:true)
        trace("source_initial_body_removed")
    }
    func resetObservation(){entry=nil;nativeBatch=nil;let revision=diagnosticHistory.revision;diagnosticHistory=BoundaryDiagnosticHistory();diagnosticHistory.revision=revision;deferredHistoryEpoch=nil;field=nil;ledger=nil;priorKeyLedger=nil;deletionHistory=nil;mismatchedSnapshot=nil;lastTextMatch=nil;lastKeyAt=0;priorKeyAt=0;historyStarted=0;selectedRange=nil;pendingSelectAll=false;awaitingSelection=false;selectionAttempts=0}
    // Backspace can remove one component of live Hangul rather than commit the
    // remaining syllable. Reuse only our observed key prefix, after the editor
    // proves its entire text and caret. Never decompose existing editor text.
    private func restoreDeletionHistory(_ snap:Snapshot) {
        guard let saved=deletionHistory else{return}
        deletionHistory=nil
        guard CFEqual(saved.field,snap.field),
              let last=saved.ledger.segments.last,last.source==source() else{return}
        // Render only within this restoration attempt. Earlier source segments
        // are identical for every candidate; text and caret share one rendering.
        // No result survives a new snapshot, field or input-source check.
        let committed=saved.ledger.segments.dropLast().map{MismatchReplayLedger.render($0)}.joined()
        func adopt(_ candidate:MismatchReplayLedger,_ insertion:String)->Bool {
            guard textMatch(snap,candidate,renderedInsertion:insertion) != nil,
                  NSRange(location:candidate.caret+insertion.utf16.count,length:0)==snap.selection else{return false}
            var candidate=candidate
            candidate.postDeletionPrefixCount=candidate.segments.last?.source==mismatchKoreanID ? candidate.segments.last?.keys.count:nil
            field=snap.field;ledger=candidate;historyStarted=saved.started;noteDiagnosticHistory(8,baseline:true);return true
        }
        if adopt(saved.ledger,committed+MismatchReplayLedger.render(last)){return}
        // Deleting the last medial can leave the initial detached from the
        // preceding committed syllable (이거 -> 이ㄱ, never 익). Try boundaries
        // only between keys we observed; accept solely the exact editor result.
        guard last.keys.count>1 else{return}
        for split in stride(from:last.keys.count-1,through:1,by:-1) {
            let left=(source:last.source,keys:Array(last.keys.prefix(split)))
            let right=(source:last.source,keys:Array(last.keys.dropFirst(split)))
            var candidate=saved.ledger
            candidate.segments[candidate.segments.count-1]=left
            candidate.segments.append(right)
            if adopt(candidate,committed+MismatchReplayLedger.render(left)+MismatchReplayLedger.render(right)){return}
        }
    }
    // The main tap records accepted keys before the mismatch tap reads their
    // pre-insertion snapshot. Offer either complete ledger, never inferred text.
    private func discardInvalidDeferredHistory() {
        if let saved=deferredHistoryEpoch,sourceEvidence?.retains(saved) != true {
            if let evidence=sourceEvidence{incidentTrace.sourceEvidence(.rejected,evidence.diagnostic(selected:source()))}
            resetObservation()
        }
    }
    func verifiedTwoSetHistory(_ snap:MismatchSnapshot,after boundary:CGEventTimestamp,allowPrior:Bool=false)->(plan:MismatchRecoveryPlan,lastKeyAt:Double)? {
        discardInvalidDeferredHistory()
        if let saved=deferredHistoryEpoch {
            guard sourceEvidence?.permitsHistory(saved)==true else{return nil}
            if let evidence=sourceEvidence{incidentTrace.sourceEvidence(.resumed,evidence.diagnostic(selected:source(),history:true))}
            deferredHistoryEpoch=nil
        }
        guard !busy else{incidentTrace.decision(.handoff,.handoffBusy);return nil}
        guard isReady() else{incidentTrace.decision(.handoff,.handoffNotReady);return nil}
        guard !externalEditPending else{incidentTrace.decision(.handoff,.handoffExternalEdit);return nil}
        guard selectedRange==nil else{incidentTrace.decision(.handoff,.handoffSelection);return nil}
        guard let field,CFEqual(field,snap.element) else{incidentTrace.decision(.handoff,.handoffField);return nil}
        guard source()==mismatchKoreanID else{incidentTrace.decision(.handoff,.handoffSource);return nil}
        guard historyStarted>boundary else{incidentTrace.decision(.handoff,historyStarted==0 ? .handoffUninitialized:.handoffBoundary);return nil}
        resolveDeletionBoundary(.init(field:snap.element,text:snap.text,selection:snap.selection))
        let histories=allowPrior ? [(ledger,lastKeyAt),(priorKeyLedger,priorKeyAt)]:[(ledger,lastKeyAt)]
        var rejection=InputIncidentTrace.DecisionReason.handoffNoHistory
        for (candidate,at) in histories {
            guard var candidate else{continue}
            guard now()-at>=0,now()-at<=5 else{rejection = .handoffExpired;continue}
            candidate=resolvingDeletionBoundary(.init(field:snap.element,text:snap.text,selection:snap.selection),candidate)
            guard let plan=candidate.lastTwoSetPlan() else{continue}
            let normal=candidate.selection==snap.selection && InputFocusAccess.sameText(candidate.text,snap.text)
            guard normal || plan.matches(text:snap.text,selection:snap.selection) ||
                plan.partialFailurePlan(text:snap.text,selection:snap.selection) != nil else{rejection = .handoffTextMismatch;continue}
            incidentTrace.decision(.handoff,.handoffAccepted)
            return (plan,at)
        }
        incidentTrace.decision(.handoff,rejection)
        return nil
    }
    /// The onset engine has selected its exact replacement on this field.
    /// Seed prediction before posting, then observe each posted event once.
    /// This is not editor acknowledgment: selection/switch still requires the
    /// resulting full text and caret, and isReady() must wait for replay delivery.
    func beginOnsetReplay(field:AXUIElement,before:String,caret:Int) {
        guard !busy,caret>=0,caret<=before.utf16.count else{return}
        resetObservation()
        self.field=field;ledger=MismatchReplayLedger(before:before,caret:caret)
        noteDiagnosticHistory(4,baseline:true)
    }
    /// A completed boundary leaves prediction history for the next key. A new
    /// focused field must start its own history before that key is submitted.
    /// Never rebase an active transaction or treat a missing reply as a move.
    private func refreshIdleField() {
        guard !busy,isReady(),let field else{return}
        let focused:AXUIElement?
        if let readFocus {focused=readFocus()} else{focused=read()?.field}
        guard let focused,!CFEqual(field,focused) else{return}
        resetObservation()
        trace("observation_field_changed")
    }
    /// Explicit manual replacement owns this field until its full result is
    /// verified. A switch pressed meanwhile waits, never selects against the
    /// pre-replacement body. No AX read or input blocking occurs here.
    func beginManualEdit(field:AXUIElement,source:String)->Int? {
        guard manualEdit==nil,!busy,ready(),!externalEditPending,
              repairInFlight.isEmpty,onsetInFlight.isEmpty,!awaitingReplay else{return nil}
        manualEditSequence+=1
        manualEdit=ManualEdit(token:manualEditSequence,field:field,source:source)
        resetObservation();externalEditPending=true
        trace("manual_edit_started")
        return manualEditSequence
    }
    func finishManualEdit(_ token:Int,snapshot:Snapshot?) {
        guard let edit=manualEdit,edit.token==token else{return}
        manualEdit=nil
        guard let snapshot,CFEqual(edit.field,snapshot.field),source()==edit.source,
              snapshot.selection.location>=0,snapshot.selection.length>=0,
              NSMaxRange(snapshot.selection)<=snapshot.text.utf16.count else {
            if busy{fail("manual_edit_unverified")}
            else{resetObservation();repairInFlight.removeAll();externalEditPending=false;trace("manual_edit_unverified")}
            return
        }
        resetObservation();repairInFlight.removeAll();externalEditPending=false
        field=snapshot.field;ledger=MismatchReplayLedger(before:snapshot.text,caret:snapshot.selection.location)
        selectedRange=snapshot.selection.length>0 ? snapshot.selection:nil
        noteDiagnosticHistory(5,baseline:true)
        trace("manual_edit_verified")
        if busy{schedule()}
    }
    /// A repair owns its replay and acknowledges the final editor state itself.
    /// Its marked events must not leave our pre-repair prediction alive.
    func noteExternalEdit() {
        manualEdit=nil;manualEditSequence+=1
        resetObservation()
        repairInFlight.removeAll()
        externalEditPending=true
    }
    /// The main tap can see a key while repair is busy, but the downstream
    /// repair tap can receive it after repair finishes. Track that delivered
    /// key after the verified replay, instead of silently losing its history.
    func confirmDelivery(_ type:CGEventType,_ event:CGEvent,passed:Bool) {
        guard type == .keyDown,repairInFlight.remove(DeliveryKey(event)) != nil else{return}
        if passed {observe(type,event)}
    }
    func adoptVerifiedReplay(_ replay:MismatchReplayLedger, snapshot:MismatchSnapshot) {
        guard manualEdit==nil,replay.text==snapshot.text,replay.selection==snapshot.selection else{return}
        guard transactionField == nil || CFEqual(transactionField!,snapshot.element) else{return}
        field=snapshot.element;ledger=replay;selectedRange=nil;externalEditPending=false
        priorKeyLedger=nil;lastKeyAt=now();historyStarted=MismatchRecoveryEngine.sourceEventTime()
        noteDiagnosticHistory(6,baseline:true)
        trace("repair_history_adopted")
    }
    /// The onset engine reports its own successful posts synchronously. A
    /// newly created CGEvent still has timestamp zero here; Quartz stamps the
    /// delivered copy later. Use the post observation time for history only,
    /// without changing the event or inventing receipt by the editor.
    func observePostedOnsetEvent(_ event:CGEvent) {
        let timestamp=event.timestamp>0 ? event.timestamp:MismatchRecoveryEngine.sourceEventTime()
        observe(event.type,event,historyTimestamp:timestamp)
    }
    func observe(_ type:CGEventType,_ event:CGEvent) {
        observe(type,event,historyTimestamp:event.timestamp)
    }
    private func observe(_ type:CGEventType,_ event:CGEvent,historyTimestamp:CGEventTimestamp,checkpoint:((InputIncidentTrace.RoutingStage)->Void)?=nil) {
        defer{checkpoint?(.ledger)}
        sourceEvidence?.observeInteraction(type,event)
        let heldCode=event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {deliveredHeld.insert(heldCode)}
        if type == .keyUp {deliveredHeld.remove(heldCode)}
        if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type){resetObservation();return}
        guard type == .keyDown else{return}
        if externalEditPending {
            guard isReady() else{
                if repairInFlight.count<256 {repairInFlight.insert(DeliveryKey(event))}
                return
            }
            externalEditPending=false
        }
        // A native Cmd+A may only commit live composition. Until a real
        // source/repair transaction owns input, the next original key belongs
        // to the editor. Rebase from its actual selection, never the requested
        // full range, when observing that key below.
        if pendingSelectAll && !busy {
            resetObservation()
            trace("native_select_all_input_resumed")
        }
        let flags=event.flags.intersection([.maskCommand,.maskControl,.maskAlternate])
        if heldCode==51,flags.isEmpty,!event.flags.contains(.maskShift) {
            let snap=read()
            if let snap {restoreDeletionHistory(snap)}
            var saved:(field:AXUIElement,ledger:MismatchReplayLedger,started:CGEventTimestamp)?
            if let snap,let field,CFEqual(field,snap.field),selectedRange==nil,
               matches(snap),var previous=ledger,let last=previous.segments.last,
               last.source==source(),!last.keys.isEmpty {
                previous.segments[previous.segments.count-1].keys.removeLast()
                saved=(field,previous,historyStarted)
            }
            resetObservation();deletionHistory=saved
            return
        }
        if event.getIntegerValueField(.keyboardEventKeycode)==0,flags == .maskCommand,!event.flags.contains(.maskShift) {
            refreshIdleField()
            if ledger == nil,let snap=read(){field=snap.field;ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location);noteDiagnosticHistory(3,baseline:true)}
            selectedRange=ledger.map{NSRange(location:0,length:$0.text.utf16.count)}
            noteDiagnosticHistory(3)
            pendingSelectAll=selectedRange != nil
            selectionAttempts=0
            if pendingSelectAll {
                deadline=now()+1
                trace(busy ? "waiting_for_select_all":"observing_native_select_all")
                schedule()
            }
            return
        }
        guard flags.isEmpty,let code=UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)),
              MismatchRecoveryPlan.character(code,event.flags.contains(.maskShift)) != nil else{resetObservation();return}
        let selected=source(),deferred=sourceEvidence?.deferredSource(for:selected)
        discardInvalidDeferredHistory()
        let id=deferred ?? selected
        checkpoint?(.source)
        guard id.hasPrefix("com.apple.keylayout." ) || MismatchKeyboardLayout.supports(id) else{resetObservation();return}
        refreshIdleField()
        checkpoint?(.focus)
        if ledger == nil {
            guard let snap=read(),snap.selection.location>=0,snap.selection.length>=0,
                  NSMaxRange(snap.selection)<=snap.text.utf16.count else{return}
            restoreDeletionHistory(snap)
            if ledger == nil {
                field=snap.field
                ledger=MismatchReplayLedger(before:(snap.text as NSString).replacingCharacters(in:snap.selection,with:""),caret:snap.selection.location)
                noteDiagnosticHistory(1,baseline:true)
            }
        }
        checkpoint?(.snapshot)
        if let selectedRange,let previous=ledger {ledger=MismatchReplayLedger(before:(previous.text as NSString).replacingCharacters(in:selectedRange,with:""),caret:selectedRange.location);self.selectedRange=nil;noteDiagnosticHistory(11)}
        guard (ledger?.segments.reduce(0,{$0+$1.keys.count}) ?? 0)<128 else{resetObservation();return}
        // A completed switch can preserve the proved body/ledger but starts a
        // new (empty) source interval. Timestamp its first accepted key rather
        // than treating the old ledger as an already initialized new interval.
        if ledger?.segments.last?.source != id || ledger?.segments.last?.keys.isEmpty == true {
            historyStarted=historyTimestamp
        }
        priorKeyLedger=ledger;priorKeyAt=lastKeyAt;lastKeyAt=now()
        ledger?.append(source:id,keys:[(code,event.flags.contains(.maskShift))])
        noteDiagnosticHistory(10)
        if deferred != nil,let evidence=sourceEvidence {
            deferredHistoryEpoch=evidence.epoch
            incidentTrace.sourceEvidence(.deferred,evidence.diagnostic(selected:selected,history:true),event:event)
        }

    }
    /// Reserve the edit boundary in the HID stream, before a later right
    /// Command can be consumed by the repair's source gate. Queue the original
    /// events at the normal session tap, preserving its single delivery path.
    func beginRepairBoundary(_ type:CGEventType,_ event:CGEvent) {
        if !busy,externalEditPending,!isReady(),type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode)==0,
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift]) == .maskCommand {
            // Let the repair verify its current text before beginning a new
            // editing command. Keep the whole shortcut and its following keys
            // in the same ordered path used outside a repair.
            busy=true;waitingForRepairBoundary=true;deadline=now()+1
            trace("select_all_waiting_for_repair");schedule()
        }
    }
    private func isInitialLetter(_ event:CGEvent)->Bool {
        guard event.type == .keyDown,event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskSecondaryFn,.maskAlphaShift]).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat)==0,
              let code=UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)) else{return false}
        return PhysicalLetterKeys.letters[code] != nil
    }
    // Called before a native key passes, or immediately before the first
    // queued key is posted. Never derive ownership from a displayed string.
    private func holdFirstIfNeeded(_ event:CGEvent,alreadyQueued:Bool)->Bool {
        guard let candidate=entry,heldStart==nil else{return heldStart != nil}
        let age=now()-candidate.at
        guard age>=0,age<=MismatchSourceEvidence.confirmationSeconds else{entry=nil;return false}
        if event.type == .keyUp{return false}
        if event.type == .flagsChanged {
            if !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty{entry=nil}
            return false
        }
        guard isInitialLetter(event),let initialLayout else{entry=nil;return false}
        entry=nil // at most once, including the ordinary fast path
        guard initialLayout() == .conflicting,isReady(),!externalEditPending,
              repairInFlight.isEmpty,onsetInFlight.isEmpty else{return false}
        guard let snap=read(),CFEqual(candidate.field,snap.field),let window=fieldWindow(snap.field) else{
            if alreadyQueued{fail("initial_context_changed");return true}
            return false
        }
        // A layout report is not an editor receipt. Give it a few polls, not
        // an entire source-switch transaction, to catch up. Never renew on input.
        let limit=min(candidate.at+1,now()+0.080)
        if !busy{busy=true;transactionField=snap.field;deadline=limit}
        heldStart=HeldStart(snapshot:snap,window:window,until:limit);nextLayoutCheck=now()+0.016
        trace("initial_layout_wait");schedule();return true
    }
    private func initialDeliveryReady()->Bool {
        guard let h=heldStart else{return true}
        let expired=now()>=h.until
        guard !externalEditPending else{fail("initial_context_changed");return false}
        guard expired || now()>=nextLayoutCheck else{schedule();return false}
        nextLayoutCheck=now()+0.016
        guard let phase=initialLayout?(), phase != .sourceChanged else{fail("initial_source_changed");return false}
        // Some input methods can continue to produce correct text while the
        // layout API keeps reporting ABC. That report alone must not park
        // original input indefinitely or authorize rewriting a draft.
        guard phase == .ready || (expired && phase == .conflicting) else{
            if expired{fail("initial_layout_deadline")}else{schedule()};return false
        }
        // Nothing in this batch has reached the editor. Even identical letters
        // in a draft cannot be a receipt for one of these owned events.
        guard let snap=read(),CFEqual(snap.field,h.snapshot.field),
              let win=fieldWindow(snap.field),CFEqual(win,h.window),
              snap.selection==h.snapshot.selection,snap.text.utf16.elementsEqual(h.snapshot.text.utf16),
              initialLayout?() == phase else{fail("initial_context_changed");return false}
        if !snap.text.isEmpty {
            nativeBatch=NativeBatch(field:snap.field,window:win,layout:phase)
        }
        resumedOriginalBatch = phase == .conflicting
        heldStart=nil;deadline=now()+1;trace(phase == .ready ? "initial_layout_ready":"initial_original_resumed");return true
    }
    private func recordNativeBatchEdge(_ event:CGEvent) {
        guard nativeBatch != nil,event.type != .keyUp else{return}
        if event.type == .flagsChanged,event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty{return}
        guard isInitialLetter(event),nativeBatch!.keys.count<64,
              let code=UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)) else{nativeBatch=nil;return}
        nativeBatch!.keys.append((code,event.flags.contains(.maskShift)));nativeBatch!.expected=nil
    }
    // Acknowledges transport only, after all owned edges returned through the
    // tap. The original AX body may have disappeared when native input began.
    // Discard all typed-history authority: a matching draft is never evidence
    // that we may erase any of it on a later key.
    private func finishNativeBatchIfMatched(_ s:Snapshot)->Bool {
        guard let batch=nativeBatch,!batch.keys.isEmpty,target==nil,queued.isEmpty,
              !awaitingReplay,!awaitingSelection,!externalEditPending,repairInFlight.isEmpty,onsetInFlight.isEmpty,
              CFEqual(batch.field,s.field),s.selection==NSRange(location:s.text.utf16.count,length:0) else{return false}
        if batch.expected==nil{nativeBatch!.expected=MismatchKeyboardLayout.render(keys:batch.keys,sourceID:KoreanKeyboardLayout.twoSetID)}
        guard let predicted=nativeBatch?.expected,predicted.utf16.elementsEqual(s.text.utf16),
              let win=fieldWindow(s.field),CFEqual(win,batch.window),
              source()==KoreanKeyboardLayout.twoSetID,initialLayout?() == batch.layout else{return false}
        resetObservation();field=s.field;ledger=MismatchReplayLedger(before:s.text,caret:s.selection.location)
        trace("initial_native_batch_observed");return true
    }
    // The editor may continue to report ASCII after an ABC-layout fallback.
    // Once every original has returned through the tap, stale text alone owns
    // no more input. Do not make the next chord join that completed batch.
    private func finishFallbackTransportIfDrained()->Bool {
        guard resumedOriginalBatch,busy,target==nil,heldStart==nil,!pendingSelectAll,
              !awaitingSelection,!waitingForRepairBoundary,!awaitingReplay,!externalEditPending,
              queued.isEmpty,repairInFlight.isEmpty,onsetInFlight.isEmpty,isReady() else{return false}
        resumedOriginalBatch=false;generation+=1;scheduled=false;busy=false
        transactionField=nil;waitReason=nil;repairWaitStarted=nil
        // This is a transport completion, not a verified editor state.
        finishDiagnosticRequest(4);resetObservation();trace("initial_transport_completed")
        return true
    }
    /// Called before the normal key filters. Only our own one-at-a-time replay bypasses the queue.
    func receive(_ type:CGEventType,_ event:CGEvent)->Bool {
        if event.getIntegerValueField(.eventSourceUserData)==Self.marker {
            event.setIntegerValueField(.eventSourceUserData,value:0)
            awaitingReplay=false;schedule();return false
        }
        if finishFallbackTransportIfDrained(){return false}
        beginRepairBoundary(type,event)
        if unfocusedSwitch != nil{observeUnfocusedInput(type,event)}
        if !busy,entry != nil { _=holdFirstIfNeeded(event,alreadyQueued:false) }
        guard busy else{return false}
        if heldStart != nil,type == .flagsChanged,
           !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty {
            fail("initial_context_changed");return false
        }
        // A native select-all has already reached the editor. Before any AX
        // source-switch write, a contradictory body cannot authorize repair.
        // Resume its original keys instead of parking them behind stale history.
        if target == nil,pendingSelectAll,!awaitingSelection,selectionAttempts==0,
           !externalEditPending,isReady(),
           repairInFlight.isEmpty,onsetInFlight.isEmpty,!awaitingReplay,queued.isEmpty {
            let code=event.getIntegerValueField(.keyboardEventKeycode)
            if type == .flagsChanged,code==55{return false} // unmapped left Command
            if type == .keyDown,let snap=mismatchedSnapshot,!isPendingTextPrefix(snap) {
                fail("native_select_all_diverged_input_resumed")
                return false
            }
        }
        // A non-switch modifier starts a new chord. If queued first it would
        // prevent the following original key from using this escape path.
        let startsNewInput = type == .keyDown || (type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) != 54)
        if startsNewInput,target != nil,switchSnapshot == nil,!externalEditPending,manualEdit==nil,
           !pendingSelectAll,!awaitingSelection,
           isReady(),repairInFlight.isEmpty,onsetInFlight.isEmpty,!awaitingReplay,
           queued.allSatisfy({$0.type == .flagsChanged && $0.getIntegerValueField(.keyboardEventKeycode)==54}),
           let snap=mismatchedSnapshot {
            if isPendingTextPrefix(snap) {
                trace("editor_text_prefix_pending")
            }else{
                // The editor contradicts every pending prefix. Cancel the switch
                // before taking this physical key; do not replay unverified text.
                let modifiers=queued;queued=[]
                fail("editor_diverged_input_resumed")
                cancelledModifiers(modifiers)
                return false
            }
        }
        guard [.keyDown,.keyUp,.flagsChanged].contains(type) else{fail("context_interrupted");return false}
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        let releaseDelivered = type == .keyUp && deliveredHeld.remove(code) != nil
        if releaseDelivered && !queued.contains(where:{$0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode)==code}) {return false}
        guard queued.count<256,let copy=event.copy() else{fail("buffer_limit");return false}
        queued.append(copy);trace("key_queued");schedule();return !releaseDelivered
    }
    @discardableResult func request(_ id:String,at timestamp:CGEventTimestamp=0,recordWindow:((SwitchWindow)->Void)?=nil)->Bool {
        cancelUnfocusedSwitch()
        if heldStart != nil{fail("initial_source_changed")}
        entry=nil;nativeBatch=nil;resumedOriginalBatch=false
        discardInvalidDeferredHistory()
        refreshIdleField()
        if let edit=manualEdit {
            if !busy{transactionField=edit.field}
            busy=true;target=id;targetTimestamp=timestamp;deadline=now()+1;waitReason=nil;lastTextMatch=nil
            beginDiagnosticRequest(at:deadline-1);trace("waiting_for_editor");schedule();return true
        }
        if ledger == nil {
            let snap:Snapshot?
            if let recordWindow,let readForOutsideSwitch,id==KoreanKeyboardLayout.twoSetID,timestamp != 0,
               !busy,isReady(),!externalEditPending,repairInFlight.isEmpty,onsetInFlight.isEmpty,!awaitingReplay {
                let at=now(),(editor,origin)=readForOutsideSwitch()
                snap=editor
                if editor==nil,let (pid,window)=origin{recordWindow(SwitchWindow(pid:pid,window:window,stamp:timestamp,at:at))}
            }else{snap=read()}
            if let snap{field=snap.field;ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location);selectedRange=snap.selection;noteDiagnosticHistory(2,baseline:true)}
        }
        guard field != nil,ledger != nil else{return false}
        if !busy { transactionField=field }
        busy=true;target=id;targetTimestamp=timestamp;deadline=now()+1.0;waitReason=nil;lastTextMatch=nil;beginDiagnosticRequest(at:deadline-1);trace("waiting_for_editor");schedule();return true
    }
    private func wait(_ reason:String) {
        if waitReason != reason {waitReason=reason;trace(reason)}
        schedule()
    }
    private func waitForMatch(_ snap:Snapshot) {
        let textMatches=matchesText(snap)
        mismatchedSnapshot=textMatches ? nil:snap
        wait(textMatches ? "waiting_for_caret":"waiting_for_text")
    }
    private func schedule(){
        guard busy || pendingSelectAll,!scheduled else{return};scheduled=true
        let token=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+(heldStart==nil ? 0.002:0.016)){[weak self] in
            guard let self,self.generation==token else{return}
            self.scheduled=false;self.step()
        }
    }
    private func observeNativeSelection() {
        guard pendingSelectAll else{return}
        guard now()<deadline else {
            resetObservation();trace("native_select_all_observation_expired");return
        }
        // Read-only observation cannot compete with an edit that owns input.
        guard isReady(),!externalEditPending,repairInFlight.isEmpty,
              onsetInFlight.isEmpty,!awaitingReplay else{schedule();return}
        guard let snap=read() else{schedule();return}
        guard let field,CFEqual(field,snap.field) else {
            resetObservation();trace("native_select_all_context_changed");return
        }
        if !matchesText(snap){acknowledgeInitialBodyRemoval(snap)}
        noteTextMatch(snap)
        guard matches(snap) else{schedule();return}
        pendingSelectAll=false
        trace("native_select_all_observed")
    }
    func step(){
        guard busy else{observeNativeSelection();return}
        if let h=heldStart,now()>=h.until,!isReady(){fail("initial_layout_deadline");return}
        // A repair has its own bounded edit/verification transaction. Do not
        // expire our editor-ack deadline or compete with its AX reads meanwhile.
        if !isReady() {
            if repairWaitStarted == nil {repairWaitStarted=now()}
            guard now()-repairWaitStarted!<3 else{fail("repair_deadline");return}
            wait("waiting_for_repair");return
        }
        if repairWaitStarted != nil {repairWaitStarted=nil;deadline=now()+1}
        guard initialDeliveryReady() else{return}
        guard now()<deadline else{fail("deadline");return}
        guard repairInFlight.isEmpty else{wait("waiting_for_repair_receipt");return}
        guard onsetInFlight.isEmpty else{wait("waiting_for_onset_receipt");return}
        // The next replay cannot advance until the previous event reaches the
        // main tap. AX work here only delays that acknowledgment.
        guard !awaitingReplay else{wait("waiting_for_replay_receipt");return}
        if finishFallbackTransportIfDrained(){return}
        if waitingForRepairBoundary {
            guard !externalEditPending,let field,ledger != nil else{fail("repair_not_verified");return}
            if transactionField == nil {transactionField=field}
            waitingForRepairBoundary=false
        }
        if target == nil,!pendingSelectAll,!awaitingSelection,
           !externalEditPending,!queued.isEmpty {
            // Release a key already delivered by this transaction even if focus
            // moved; a release cannot insert text and must not leave a held key.
            if let next=queued.first,next.type == .keyUp,
               deliveredHeld.contains(next.getIntegerValueField(.keyboardEventKeycode)) {
                replayNext();return
            }
            let focused:AXUIElement?
            if let readFocus {focused=readFocus()} else{focused=read()?.field}
            guard let focused else{wait("waiting_for_focus");return}
            guard let transactionField,CFEqual(transactionField,focused) else{fail("focus_changed");return}
            replayNext();return
        }
        // A missing AX reply is not evidence that another field owns focus.
        // Keep later keys queued and retry within the existing deadline.
        guard let snap=read() else{wait("waiting_for_snapshot");return}
        guard let transactionField,CFEqual(transactionField,snap.field) else{fail("focus_changed");return}
        if externalEditPending {
            guard isReady() else{wait("waiting_for_repair");return}
            ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location)
            selectedRange=snap.selection;field=snap.field;externalEditPending=false
            noteDiagnosticHistory(12,baseline:true)
            trace("repair_acknowledged")
        }
        if !matchesText(snap) {acknowledgeSourceInitialBodyRemoval(snap)}
        noteTextMatch(snap)
        if pendingSelectAll {
            guard isReady() else{wait("waiting_for_repair");return}
            if !matchesText(snap) {acknowledgeInitialBodyRemoval(snap)}
            guard matchesText(snap) else{waitForMatch(snap);return}
            guard let selectedRange else{schedule();return}
            // The original Cmd+A already belongs to the editor. Observe its
            // result without a competing AX selection or composition cursor key.
            guard snap.selection==selectedRange else{waitForMatch(snap);return}
            pendingSelectAll=false
        }
        if awaitingSelection {
            guard matches(snap) else{
                // Some editors acknowledge the AX write before their pending
                // composition update replaces the selection. Reapply only the
                // explicit selection, with unchanged text and bounded retries.
                if selectionAttempts<3,now()>=selectionRetryAt,matchesText(snap),let selectedRange {
                    guard applySelection(snap.field,selectedRange) else{fail("select_all_failed");return}
                    selectionAttempts+=1;selectionRetryAt=now()+0.01;trace("select_all_retried")
                }
                waitForMatch(snap);return
            }
            awaitingSelection=false
        }
        if let target {
            guard isReady() else{wait("waiting_for_repair");return}
            if switchSnapshot == nil {
                guard matches(snap) else{waitForMatch(snap);return}
                switchSnapshot=snap
            }
            let result=select(target)
            if selectionPending(){wait("waiting_for_source_commit");return}
            guard result==noErr,source()==target else{fail("switch_failed");return}
            let snap=switchSnapshot!;switchSnapshot=nil
            let confirmedUserRequest=targetTimestamp != 0
            didConfirmSource(target,targetTimestamp)
            didSelect(targetTimestamp);targetTimestamp=0
            let previous=ledger,previousDiagnosticHistory=diagnosticHistory
            self.target=nil;resetObservation();self.field=snap.field
            // AX restoration is asynchronous even after a successful source
            // switch. Preserve the verified selection until the editor observes
            // it; otherwise the next key can predict insertion at a transient
            // collapsed caret while the editor actually replaces the selection.
            if snap.selection.length==0,previous?.selection==snap.selection {
                // Keep the tracked insertion's case tolerance: an editor can
                // capitalize it after acknowledging the source switch. An empty
                // segment commits composition even if no key uses this source.
                ledger=previous;ledger?.postDeletionPrefixCount=nil
                ledger?.segments.append((source:target,keys:[]))
                diagnosticHistory=previousDiagnosticHistory;noteDiagnosticHistory(7)
            } else {
                ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location)
                selectedRange=snap.selection
                noteDiagnosticHistory(7,baseline:true)
            }
            if initialLayout != nil,target==KoreanKeyboardLayout.twoSetID,confirmedUserRequest {
                entry=Entry(field:snap.field,at:now())
            }
            awaitingSelection=true
            selectionAttempts=1;selectionRetryAt=now()+0.01
            deadline=now()+1.0;waitReason=nil;trace("editor_confirmed_switch");schedule();return
        }
        if !queued.isEmpty {
            replayNext();return
        }
        guard isReady() else{wait("waiting_for_repair");return}
        if expected == nil || matches(snap) || finishNativeBatchIfMatched(snap) {
            nativeBatch=nil;busy=false;self.transactionField=nil;finishDiagnosticRequest(1);trace("finished")
        }else{waitForMatch(snap)}
    }
    private func replayNext(){
        if let first=queued.first,entry != nil,holdFirstIfNeeded(first,alreadyQueued:true){return}
        waitReason=nil
        let saved=queued.removeFirst()
        replaySource?.userData=Self.marker
        guard let replaySource,let event=CGEvent(keyboardEventSource:replaySource,
            virtualKey:CGKeyCode(saved.getIntegerValueField(.keyboardEventKeycode)),keyDown:saved.type == .keyDown) else{queued.insert(saved,at:0);fail("allocation");return}
        event.type=saved.type;event.flags=saved.flags
        event.setIntegerValueField(.keyboardEventAutorepeat,value:saved.getIntegerValueField(.keyboardEventAutorepeat))
        event.setIntegerValueField(.eventSourceUserData,value:Self.marker)
        // A fresh delivery after an acknowledged boundary, not an old physical event.
        recordNativeBatchEdge(event)
        awaitingReplay=true;deadline=now()+1.0;send(event);schedule()
    }
    func fail(_ reason:String){
        heldStart=nil;entry=nil;resumedOriginalBatch=false
        finishDiagnosticRequest(["deadline","repair_deadline"].contains(reason) ? 2:(["focus_changed","recipient_changed"].contains(reason) ? 3:4))
        manualEdit=nil;manualEditSequence+=1

        cancelSelection();switchSnapshot=nil
        repairInFlight.removeAll()
        onsetInFlight.removeAll();onsetPendingCount=0
        repairWaitStarted=nil;waitReason=nil
        waitingForRepairBoundary=false
        generation+=1;scheduled=false;busy=false;transactionField=nil;target=nil;targetTimestamp=0;awaitingReplay=false;externalEditPending=false
        let pending=queued;queued=[];resetObservation()
        if !pending.isEmpty{retained(pending)}
        trace(reason)
    }

    private func diagnosticEnabled()->Bool {
        let generation=incidentTrace.collectionGeneration
        if generation != diagnosticGeneration {
            diagnosticGeneration=generation;diagnosticHistory=BoundaryDiagnosticHistory();diagnosticTransaction=nil
        }
        return generation>0
    }
    private func noteDiagnosticHistory(_ cause:Int,baseline:Bool=false) {
        guard diagnosticEnabled() else{return}
        diagnosticHistory.note(cause,baseline:baseline,at:now())
    }
    private func beginDiagnosticRequest(at time:Double) {
        guard diagnosticEnabled() else{return}
        finishDiagnosticRequest(4)
        diagnosticSequence=diagnosticSequence==1_000_000_000 ? 1:diagnosticSequence+1
        diagnosticTransaction=BoundaryDiagnosticTransaction(id:diagnosticSequence,started:time)
        diagnostic(diagnosticTransaction!.evidence(phase:1,reason:0,history:diagnosticHistory,at:time))
    }
    private func noteDiagnosticComparison(_ snap:Snapshot,match:TextMatch?) {
        guard diagnosticEnabled(),busy,diagnosticTransaction != nil else{return}
        let text:Int
        switch match {case .exact:text=1;case .style:text=2;case .terminalLF:text=3;case .terminalLFStyle:text=4;case nil:text=5}
        // step() already verified the transaction field. No extra field/source query.
        if let value=diagnosticTransaction?.observe(prediction:selectedRange ?? ledger?.selection,reported:snap.selection,text:text,history:diagnosticHistory,at:now()) {diagnostic(value)}
    }
    private func finishDiagnosticRequest(_ reason:Int) {
        guard diagnosticEnabled(),let transaction=diagnosticTransaction else{return}
        diagnostic(transaction.evidence(phase:3,reason:reason,history:diagnosticHistory,at:now()))
        diagnosticTransaction=nil
    }
}

// Only ranges needed for relation changes remain in this bounded, transient state.
// Encoded evidence contains fixed relations and capped ages, never the ranges.
struct BoundaryDiagnosticHistory {
    var seed=0,mutation=0,revision=0
    var seededAt:Double?,mutatedAt:Double?
    mutating func note(_ cause:Int,baseline:Bool,at time:Double) {
        revision=revision==1_000_000 ? 0:revision+1;mutation=cause;mutatedAt=time
        if baseline{seed=cause;seededAt=time}
    }
}
struct BoundaryDiagnosticTransaction {
    let id:Int,started:Double
    private var prediction:NSRange?,reported:NSRange?,previousRevision:Int?
    private var mismatchPrediction:NSRange?,mismatchReported:NSRange?,mismatchRevision:Int?
    private var predictionChanged=false,reportChanged=false
    private var resolvedAfterMismatch:Int?
    private var text=0,change=0,resolution=0,observations=0,suppressed=0,coalesced=0,emitted=0
    private var sampledAt:Double?,signature:InputIncidentTrace.BoundaryEvidence?
    init(id:Int,started:Double){self.id=id;self.started=started}
    private static func age(_ from:Double?,_ to:Double)->Int? {
        guard let from,from.isFinite,to.isFinite,to>=from else{return nil}
        return Int(min(60,to-from)*1_000_000)
    }
    private static func validRange(_ range:NSRange?)->NSRange? {
        guard let range,range.location>=0,range.length>=0,range.location != NSNotFound,
              !range.location.addingReportingOverflow(range.length).overflow else{return nil}
        return range
    }
    private static func relation(_ a:Int?,_ b:Int?)->Int {
        guard let a,let b else{return 0};return a<b ? 1:(a==b ? 2:3)
    }
    func evidence(phase:Int,reason:Int,history:BoundaryDiagnosticHistory,at time:Double)->InputIncidentTrace.BoundaryEvidence {
        let a=Self.validRange(prediction),b=Self.validRange(reported)
        return .init(transaction:id,phase:phase,reason:reason,text:text,
            start:Self.relation(a?.location,b?.location),end:Self.relation(a.map{NSMaxRange($0)},b.map{NSMaxRange($0)}),
            expected:a.map{$0.length==0 ? 1:2} ?? 0,reported:b.map{$0.length==0 ? 1:2} ?? 0,
            change:change,resolution:resolution,seed:history.seed,mutation:history.mutation,revision:history.revision,
            observations:observations,suppressed:suppressed,coalesced:coalesced,fieldRelation:observations>0 ? 1:0,
            baselineAgeMicros:Self.age(history.seededAt,time),mutationAgeMicros:Self.age(history.mutatedAt,time),
            requestAgeMicros:Self.age(started,time),sampleAgeMicros:Self.age(sampledAt,time))
    }
    mutating func observe(prediction next:NSRange?,reported actual:NSRange,text:Int,history:BoundaryDiagnosticHistory,at time:Double)->InputIncidentTrace.BoundaryEvidence? {
        let next=Self.validRange(next),actual=Self.validRange(actual)
        let p=prediction != next || previousRevision.map{$0 != history.revision} == true,r=reported != actual
        change=observations==0 ? 0:(p ? (r ? 4:3):(r ? 2:1))
        prediction=next;reported=actual;previousRevision=history.revision;self.text=text;sampledAt=time
        observations=min(1_000_000,observations+1)
        let matched=next != nil && next==actual && (1...4).contains(text)
        if let revision=mismatchRevision,resolvedAfterMismatch==nil {
            predictionChanged = predictionChanged || mismatchPrediction != next || revision != history.revision
            reportChanged = reportChanged || mismatchReported != actual
        }
        if matched {
            if mismatchRevision != nil,resolvedAfterMismatch==nil {resolvedAfterMismatch=predictionChanged ? (reportChanged ? 4:3):(reportChanged ? 2:1)}
            resolution=resolvedAfterMismatch ?? 1
        } else {
            if next != nil,actual != nil,(mismatchRevision==nil || resolvedAfterMismatch != nil) {
                mismatchPrediction=next;mismatchReported=actual;mismatchRevision=history.revision
                predictionChanged=false;reportChanged=false;resolvedAfterMismatch=nil
            }
            resolution=next != nil && actual != nil ? 5:0
        }
        let value=evidence(phase:2,reason:0,history:history,at:time)
        var key=value
        key.observations=0;key.suppressed=0;key.coalesced=0
        key.baselineAgeMicros=nil;key.mutationAgeMicros=nil;key.requestAgeMicros=nil;key.sampleAgeMicros=nil
        guard key != signature else{coalesced=min(1_000_000,coalesced+1);return nil}
        signature=key
        guard emitted<32 else{suppressed=min(1_000_000,suppressed+1);return nil}
        emitted+=1;return value
    }
}
