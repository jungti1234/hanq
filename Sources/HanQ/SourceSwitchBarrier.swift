import AppKit
import Carbon

/// Keep a user source boundary behind text already submitted to the editor.
/// The ledger is evidence for ordering, never a replacement for editor text.
final class SourceSwitchBarrier {
    struct Snapshot { let field:AXUIElement; let text:String; let selection:NSRange }
    static let marker:Int64 = 0x4851535749544348
    var read:()->Snapshot? = {nil}
    var readFocus:(()->AXUIElement?)?
    var source:()->String = InputSourceAccess.currentID
    var ready:()->Bool = {true}
    var select:(String)->OSStatus = InputSourceAccess.select
    var selectionPending:()->Bool = {false}
    var cancelSelection:()->Void = {}
    private var switchSnapshot:Snapshot?
    private var selectionCommitSnapshot:Snapshot?
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
    private var selectionCommitPending=false
    private var awaitingSelection=false
    private var selectionAttempts=0
    private var selectionRetryAt=0.0
    var applySelection:(AXUIElement,NSRange)->Bool = { field,range in
        var value=CFRange(location:range.location,length:range.length)
        guard let raw=AXValueCreate(.cfRange,&value) else{return false}
        return AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,raw) == .success
    }
    var commitSelection:(Snapshot)->OSStatus = {_ in noErr}
    private var queued:[CGEvent]=[]
    private var deliveredHeld:Set<Int64>=[]
    private var target:String?
    private var targetTimestamp:CGEventTimestamp=0
    private var awaitingReplay=false
    private var externalEditPending=false
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
    var diagnosticCounts:(queued:Int,awaitingOnset:Int) {(queued.count,onsetPendingCount)}
    /// The main tap precedes the onset gate. A key seen here may be held there,
    /// so do not predict it until that gate reports its actual delivery decision.
    func observeBeforeOnset(_ type:CGEventType,_ event:CGEvent,waiting:Bool) {
        if type == .keyDown,(waiting || !onsetInFlight.isEmpty) {
            guard onsetPendingCount<256,let copy=event.copy() else{fail("delivery_limit");return}
            onsetInFlight[OnsetDeliveryKey(event),default:[]].append(copy)
            onsetPendingCount+=1
            trace("onset_delivery_waiting")
            return
        }
        observe(type,event)
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
        guard let expected,snap.selection==expected.1 else{return false}
        return matchesText(snap)
    }
    private enum TextMatch {case exact,style,terminalLF,terminalLFStyle}
    private func textMatch(_ snap:Snapshot,_ ledger:MismatchReplayLedger,allowEmptyInsertion:Bool=false)->TextMatch? {
        let predicted=ledger.text
        if snap.text==predicted{return .exact}
        guard !ledger.segments.isEmpty,allowEmptyInsertion || !ledger.insertion.isEmpty else{return nil}
        var wanted=predicted as NSString
        var removedLF=false
        // An empty final web paragraph can expose one AX-only LF, then omit it
        // on typing. Only that original suffix after the insertion may disappear.
        let before=ledger.before as NSString
        if snap.text.utf16.count+1==wanted.length,ledger.caret==before.length-1,
           ledger.caret>=0,before.substring(from:ledger.caret)=="\n" {
            wanted=wanted.substring(to:wanted.length-1) as NSString;removedLF=true
        }
        guard snap.text.utf16.count==wanted.length else{return nil}
        let insertion=NSRange(location:ledger.caret,length:ledger.insertion.utf16.count)
        let actual=snap.text as NSString
        guard NSMaxRange(insertion)<=wanted.length else{return nil}
        guard actual.substring(to:insertion.location)==wanted.substring(to:insertion.location),
              actual.substring(from:NSMaxRange(insertion))==wanted.substring(from:NSMaxRange(insertion)) else{return nil}
        func fold(_ value:String)->[UInt32] {
            value.unicodeScalars.map{(65...90).contains($0.value) ? $0.value+32:($0.value==160 ? 32:$0.value)}
        }
        let actualInsertion=actual.substring(with:insertion),wantedInsertion=wanted.substring(with:insertion)
        guard fold(actualInsertion)==fold(wantedInsertion) else{return nil}
        if removedLF{return actualInsertion==wantedInsertion ? .terminalLF:.terminalLFStyle}
        return .style
    }
    func matchesText(_ snap:Snapshot)->Bool {
        guard let ledger else{return false};return textMatch(snap,ledger) != nil
    }
    private func noteTextMatch(_ snap:Snapshot) {
        guard let ledger,let match=textMatch(snap,ledger) else{return}
        mismatchedSnapshot=nil
        if pendingSelectAll,(match == .terminalLF || match == .terminalLFStyle),
           selectedRange==NSRange(location:0,length:ledger.text.utf16.count) {
            selectedRange=NSRange(location:0,length:snap.text.utf16.count)
        }
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
        trace("select_all_initial_body_removed")
    }
    /// A source request also provides an explicit boundary. Only accept an
    /// initial body disappearing at offset zero when all observed keys account
    /// for the complete current text and its end caret. This proves delivery
    /// without treating arbitrary editor changes as a new baseline.
    private func acknowledgeSourceInitialBodyRemoval(_ snap:Snapshot) {
        guard target != nil,switchSnapshot == nil,!pendingSelectAll,
              !awaitingSelection,!selectionCommitPending,
              let field,CFEqual(field,snap.field),let previous=ledger,
              previous.caret==0,!previous.before.isEmpty,!previous.insertion.isEmpty else{return}
        var acknowledged=MismatchReplayLedger(before:"",caret:0)
        acknowledged.segments=previous.segments
        guard textMatch(snap,acknowledged) != nil,
              snap.selection==acknowledged.selection,!isPendingTextPrefix(snap) else{return}
        ledger=acknowledged;selectedRange=nil;mismatchedSnapshot=nil
        trace("source_initial_body_removed")
    }
    func resetObservation(){field=nil;ledger=nil;priorKeyLedger=nil;deletionHistory=nil;mismatchedSnapshot=nil;lastTextMatch=nil;lastKeyAt=0;priorKeyAt=0;historyStarted=0;selectedRange=nil;pendingSelectAll=false;selectionCommitPending=false;awaitingSelection=false;selectionAttempts=0}
    // Backspace can remove one component of live Hangul rather than commit the
    // remaining syllable. Reuse only our observed key prefix, after the editor
    // proves its entire text and caret. Never decompose existing editor text.
    private func restoreDeletionHistory(_ snap:Snapshot) {
        guard let saved=deletionHistory else{return}
        deletionHistory=nil
        guard CFEqual(saved.field,snap.field),
              let last=saved.ledger.segments.last,last.source==source() else{return}
        func adopt(_ candidate:MismatchReplayLedger)->Bool {
            guard textMatch(snap,candidate) != nil,candidate.selection==snap.selection else{return false}
            field=snap.field;ledger=candidate;historyStarted=saved.started;return true
        }
        if adopt(saved.ledger){return}
        // Deleting the last medial can leave the initial detached from the
        // preceding committed syllable (이거 -> 이ㄱ, never 익). Try boundaries
        // only between keys we observed; accept solely the exact editor result.
        guard last.keys.count>1 else{return}
        for split in stride(from:last.keys.count-1,through:1,by:-1) {
            var candidate=saved.ledger
            candidate.segments[candidate.segments.count-1].keys=Array(last.keys.prefix(split))
            candidate.segments.append((source:last.source,keys:Array(last.keys.dropFirst(split))))
            if adopt(candidate){return}
        }
    }
    // The main tap records accepted keys before the mismatch tap reads their
    // pre-insertion snapshot. Offer either complete ledger, never inferred text.
    func verifiedTwoSetHistory(_ snap:MismatchSnapshot,after boundary:CGEventTimestamp,allowPrior:Bool=false)->(plan:MismatchRecoveryPlan,lastKeyAt:Double)? {
        guard !busy,ready(),!externalEditPending,selectedRange==nil,
              let field,CFEqual(field,snap.element),source()==mismatchKoreanID,
              historyStarted>boundary else{return nil}
        let histories=allowPrior ? [(ledger,lastKeyAt),(priorKeyLedger,priorKeyAt)]:[(ledger,lastKeyAt)]
        for (candidate,at) in histories {
            guard let candidate,now()-at>=0,now()-at<=5,
                  let plan=candidate.lastTwoSetPlan() else{continue}
            let normal=candidate.text==snap.text && candidate.selection==snap.selection
            guard normal || plan.matches(text:snap.text,selection:snap.selection) ||
                plan.partialFailurePlan(text:snap.text,selection:snap.selection) != nil else{continue}
            return (plan,at)
        }
        return nil
    }
    /// The onset engine has selected its exact replacement on this field.
    /// Seed prediction before posting, then observe each posted event once.
    /// This is not editor acknowledgment: selection/switch still requires the
    /// resulting full text and caret, and ready() must wait for replay delivery.
    func beginOnsetReplay(field:AXUIElement,before:String,caret:Int) {
        guard !busy,caret>=0,caret<=before.utf16.count else{return}
        resetObservation()
        self.field=field;ledger=MismatchReplayLedger(before:before,caret:caret)
    }
    /// A completed boundary leaves prediction history for the next key. A new
    /// focused field must start its own history before that key is submitted.
    /// Never rebase an active transaction or treat a missing reply as a move.
    private func refreshIdleField() {
        guard !busy,ready(),let field else{return}
        let focused:AXUIElement?
        if let readFocus {focused=readFocus()} else{focused=read()?.field}
        guard let focused,!CFEqual(field,focused) else{return}
        resetObservation()
        trace("observation_field_changed")
    }
    /// A repair owns its replay and acknowledges the final editor state itself.
    /// Its marked events must not leave our pre-repair prediction alive.
    func noteExternalEdit() {
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
        guard replay.text==snapshot.text,replay.selection==snapshot.selection else{return}
        guard transactionField == nil || CFEqual(transactionField!,snapshot.element) else{return}
        field=snapshot.element;ledger=replay;selectedRange=nil;externalEditPending=false
        priorKeyLedger=nil;lastKeyAt=now();historyStarted=MismatchRecoveryEngine.sourceEventTime()
        trace("repair_history_adopted")
    }
    func observe(_ type:CGEventType,_ event:CGEvent) {
        let heldCode=event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {deliveredHeld.insert(heldCode)}
        if type == .keyUp {deliveredHeld.remove(heldCode)}
        if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type){resetObservation();return}
        guard type == .keyDown else{return}
        if externalEditPending {
            guard ready() else{
                if repairInFlight.count<256 {repairInFlight.insert(DeliveryKey(event))}
                return
            }
            externalEditPending=false
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
            if ledger == nil,let snap=read(){field=snap.field;ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location)}
            selectedRange=ledger.map{NSRange(location:0,length:$0.text.utf16.count)}
            pendingSelectAll=selectedRange != nil
            selectionCommitPending=pendingSelectAll
            selectionAttempts=0
            if pendingSelectAll,let field {
                if !busy{transactionField=field}
                busy=true;deadline=now()+1;trace("waiting_for_select_all");schedule()
            }
            return
        }
        guard flags.isEmpty,let code=UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)),
              MismatchRecoveryPlan.character(code,event.flags.contains(.maskShift)) != nil else{resetObservation();return}
        let id=source()
        guard id.hasPrefix("com.apple.keylayout." ) || MismatchKeyboardLayout.supports(id) else{resetObservation();return}
        refreshIdleField()
        if ledger == nil {
            guard let snap=read(),snap.selection.location>=0,snap.selection.length>=0,
                  NSMaxRange(snap.selection)<=snap.text.utf16.count else{return}
            restoreDeletionHistory(snap)
            if ledger == nil {
                field=snap.field
                ledger=MismatchReplayLedger(before:(snap.text as NSString).replacingCharacters(in:snap.selection,with:""),caret:snap.selection.location)
                historyStarted=event.timestamp
            }
        }
        if let selectedRange,let previous=ledger {ledger=MismatchReplayLedger(before:(previous.text as NSString).replacingCharacters(in:selectedRange,with:""),caret:selectedRange.location);self.selectedRange=nil}
        guard (ledger?.segments.reduce(0,{$0+$1.keys.count}) ?? 0)<128 else{resetObservation();return}
        priorKeyLedger=ledger;priorKeyAt=lastKeyAt;lastKeyAt=now()
        ledger?.append(source:id,keys:[(code,event.flags.contains(.maskShift))])

    }
    /// Reserve the edit boundary in the HID stream, before a later right
    /// Command can be consumed by the repair's source gate. Queue the original
    /// events at the normal session tap, preserving its single delivery path.
    func beginRepairBoundary(_ type:CGEventType,_ event:CGEvent) {
        if !busy,externalEditPending,!ready(),type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode)==0,
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift]) == .maskCommand {
            // Let the repair verify its current text before beginning a new
            // editing command. Keep the whole shortcut and its following keys
            // in the same ordered path used outside a repair.
            busy=true;waitingForRepairBoundary=true;deadline=now()+1
            trace("select_all_waiting_for_repair");schedule()
        }
    }
    /// Called before the normal key filters. Only our own one-at-a-time replay bypasses the queue.
    func receive(_ type:CGEventType,_ event:CGEvent)->Bool {
        if event.getIntegerValueField(.eventSourceUserData)==Self.marker {
            event.setIntegerValueField(.eventSourceUserData,value:0)
            awaitingReplay=false;schedule();return false
        }
        beginRepairBoundary(type,event)
        guard busy else{return false}
        if type == .keyDown,target != nil,switchSnapshot == nil,
           !pendingSelectAll,!awaitingSelection,!selectionCommitPending,
           ready(),repairInFlight.isEmpty,onsetInFlight.isEmpty,!awaitingReplay,
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
    @discardableResult func request(_ id:String,at timestamp:CGEventTimestamp=0)->Bool {
        refreshIdleField()
        if ledger == nil,let snap=read(){field=snap.field;ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location);selectedRange=snap.selection}
        guard field != nil,ledger != nil else{return false}
        if !busy { transactionField=field }
        busy=true;target=id;targetTimestamp=timestamp;deadline=now()+1.0;waitReason=nil;lastTextMatch=nil;trace("waiting_for_editor");schedule();return true
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
        guard busy,!scheduled else{return};scheduled=true
        let token=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+0.002){[weak self] in
            guard let self,self.generation==token else{return}
            self.scheduled=false;self.step()
        }
    }
    func step(){
        guard busy else{return}
        // A repair has its own bounded edit/verification transaction. Do not
        // expire our editor-ack deadline or compete with its AX reads meanwhile.
        if !ready() {
            if repairWaitStarted == nil {repairWaitStarted=now()}
            guard now()-repairWaitStarted!<3 else{fail("repair_deadline");return}
            wait("waiting_for_repair");return
        }
        if repairWaitStarted != nil {repairWaitStarted=nil;deadline=now()+1}
        guard now()<deadline else{fail("deadline");return}
        guard repairInFlight.isEmpty else{wait("waiting_for_repair_receipt");return}
        guard onsetInFlight.isEmpty else{wait("waiting_for_onset_receipt");return}
        // The next replay cannot advance until the previous event reaches the
        // main tap. AX work here only delays that acknowledgment.
        guard !awaitingReplay else{wait("waiting_for_replay_receipt");return}
        if waitingForRepairBoundary {
            guard !externalEditPending,let field,ledger != nil else{fail("repair_not_verified");return}
            if transactionField == nil {transactionField=field}
            waitingForRepairBoundary=false
        }
        if target == nil,!pendingSelectAll,!awaitingSelection,!selectionCommitPending,
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
            guard ready() else{wait("waiting_for_repair");return}
            ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location)
            selectedRange=snap.selection;field=snap.field;externalEditPending=false
            trace("repair_acknowledged")
        }
        if !matchesText(snap) {acknowledgeSourceInitialBodyRemoval(snap)}
        noteTextMatch(snap)
        if pendingSelectAll {
            guard ready() else{wait("waiting_for_repair");return}
            if !matchesText(snap) {acknowledgeInitialBodyRemoval(snap)}
            guard matchesText(snap) else{waitForMatch(snap);return}
            guard let selectedRange else{schedule();return}
            if snap.selection != selectedRange {
                guard applySelection(snap.field,selectedRange) else{fail("select_all_failed");return}
                // Keep subsequent editing keys behind the selection acknowledgment.
                pendingSelectAll=false;awaitingSelection=true
                selectionAttempts=1;selectionRetryAt=now()+0.01
                trace("select_all_applied");schedule();return
            }
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
        if selectionCommitPending {
            if selectionCommitSnapshot == nil {
                guard matches(snap) else{waitForMatch(snap);return}
                selectionCommitSnapshot=snap
            }
            let result=commitSelection(selectionCommitSnapshot!)
            if result==AXError.cannotComplete.rawValue {wait("waiting_for_selection_commit");return}
            guard result==noErr else{fail("select_all_commit_failed");return}
            selectionCommitSnapshot=nil
            selectionCommitPending=false;awaitingSelection=true
            selectionAttempts=1;selectionRetryAt=now()+0.01
            trace("select_all_committed");schedule();return
        }
        if let target {
            guard ready() else{wait("waiting_for_repair");return}
            if switchSnapshot == nil {
                guard matches(snap) else{waitForMatch(snap);return}
                switchSnapshot=snap
            }
            let result=select(target)
            if selectionPending(){wait("waiting_for_source_commit");return}
            guard result==noErr,source()==target else{fail("switch_failed");return}
            let snap=switchSnapshot!;switchSnapshot=nil
            didSelect(targetTimestamp);targetTimestamp=0
            let previous=ledger
            self.target=nil;resetObservation();self.field=snap.field
            // AX restoration is asynchronous even after a successful source
            // switch. Preserve the verified selection until the editor observes
            // it; otherwise the next key can predict insertion at a transient
            // collapsed caret while the editor actually replaces the selection.
            if snap.selection.length==0,previous?.selection==snap.selection {
                // Keep the tracked insertion's case tolerance: an editor can
                // capitalize it after acknowledging the source switch. An empty
                // segment commits composition even if no key uses this source.
                ledger=previous;ledger?.segments.append((source:target,keys:[]))
            } else {
                ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location)
                selectedRange=snap.selection
            }
            awaitingSelection=true
            selectionAttempts=1;selectionRetryAt=now()+0.01
            deadline=now()+1.0;waitReason=nil;trace("editor_confirmed_switch");schedule();return
        }
        if !queued.isEmpty {
            replayNext();return
        }
        guard ready() else{wait("waiting_for_repair");return}
        if expected == nil || matches(snap) {
            busy=false;self.transactionField=nil;trace("finished")
        }else{waitForMatch(snap)}
    }
    private func replayNext(){
        waitReason=nil
        let saved=queued.removeFirst()
        replaySource?.userData=Self.marker
        guard let replaySource,let event=CGEvent(keyboardEventSource:replaySource,
            virtualKey:CGKeyCode(saved.getIntegerValueField(.keyboardEventKeycode)),keyDown:saved.type == .keyDown) else{queued.insert(saved,at:0);fail("allocation");return}
        event.type=saved.type;event.flags=saved.flags
        event.setIntegerValueField(.keyboardEventAutorepeat,value:saved.getIntegerValueField(.keyboardEventAutorepeat))
        event.setIntegerValueField(.eventSourceUserData,value:Self.marker)
        // A fresh delivery after an acknowledged boundary, not an old physical event.
        awaitingReplay=true;deadline=now()+1.0;send(event);schedule()
    }
    func fail(_ reason:String){

        cancelSelection();switchSnapshot=nil;selectionCommitSnapshot=nil
        repairInFlight.removeAll()
        onsetInFlight.removeAll();onsetPendingCount=0
        repairWaitStarted=nil;waitReason=nil
        waitingForRepairBoundary=false
        generation+=1;scheduled=false;busy=false;transactionField=nil;target=nil;targetTimestamp=0;awaitingReplay=false;externalEditPending=false
        let pending=queued;queued=[];resetObservation()
        if !pending.isEmpty{retained(pending)}
        trace(reason)
    }
}
