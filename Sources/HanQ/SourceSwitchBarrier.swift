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
    var trace:(String)->Void = {_ in}
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    private(set) var busy=false
    private var field:AXUIElement?
    private var transactionField:AXUIElement?
    private var ledger:MismatchReplayLedger?
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
        let timestamp:CGEventTimestamp
        let code:Int64
        init(_ event:CGEvent){timestamp=event.timestamp;code=event.getIntegerValueField(.keyboardEventKeycode)}
    }
    private var onsetInFlight:[OnsetDeliveryKey:CGEvent]=[:]
    /// The main tap precedes the onset gate. A key seen here may be held there,
    /// so do not predict it until that gate reports its actual delivery decision.
    func observeBeforeOnset(_ type:CGEventType,_ event:CGEvent,waiting:Bool) {
        if type == .keyDown,(waiting || !onsetInFlight.isEmpty) {
            guard onsetInFlight.count<256,let copy=event.copy() else{fail("delivery_limit");return}
            onsetInFlight[OnsetDeliveryKey(event)]=copy
            return
        }
        observe(type,event)
    }
    func confirmOnsetDelivery(_ event:CGEvent,passed:Bool) {
        guard let original=onsetInFlight.removeValue(forKey:OnsetDeliveryKey(event)) else{return}
        if passed {observe(.keyDown,original)}
    }
    private var deadline=0.0
    private var repairWaitStarted:Double?
    private var generation=0
    private var scheduled=false
    private var replaySource=CGEventSource(stateID:.privateState)

    var expected:(String,NSRange)? {
        guard let ledger else{return nil}
        return (ledger.text,selectedRange ?? ledger.selection)
    }
    func matches(_ snap:Snapshot)->Bool {
        guard let expected,snap.selection==expected.1 else{return false}
        return matchesText(snap)
    }
    func matchesText(_ snap:Snapshot)->Bool {
        guard let expected else{return false}
        if snap.text==expected.0{return true}
        // Editors may capitalize the text just typed. Accept ASCII case changes
        // only inside that tracked insertion, never changes to surrounding text,
        // a missing character, or a Korean/English layout mismatch. Do not edit it.
        guard let ledger,!ledger.segments.isEmpty,
              snap.text.utf16.count==expected.0.utf16.count else{return false}
        let insertion=NSRange(location:ledger.caret,length:ledger.insertion.utf16.count)
        let actual=snap.text as NSString, wanted=expected.0 as NSString
        guard actual.substring(to:insertion.location)==wanted.substring(to:insertion.location),
              actual.substring(from:NSMaxRange(insertion))==wanted.substring(from:NSMaxRange(insertion)) else{return false}
        func fold(_ value:String)->[UInt32] {
            value.unicodeScalars.map{(65...90).contains($0.value) ? $0.value+32:$0.value}
        }
        return fold(actual.substring(with:insertion))==fold(wanted.substring(with:insertion))
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
    func resetObservation(){field=nil;ledger=nil;selectedRange=nil;pendingSelectAll=false;selectionCommitPending=false;awaitingSelection=false;selectionAttempts=0}
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
            field=snap.field
            ledger=MismatchReplayLedger(before:(snap.text as NSString).replacingCharacters(in:snap.selection,with:""),caret:snap.selection.location)
        }
        if let selectedRange,let previous=ledger {ledger=MismatchReplayLedger(before:(previous.text as NSString).replacingCharacters(in:selectedRange,with:""),caret:selectedRange.location);self.selectedRange=nil}
        guard (ledger?.segments.reduce(0,{$0+$1.keys.count}) ?? 0)<128 else{resetObservation();return}
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
        guard [.keyDown,.keyUp,.flagsChanged].contains(type) else{fail("context_interrupted");return false}
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        let releaseDelivered = type == .keyUp && deliveredHeld.remove(code) != nil
        if releaseDelivered && !queued.contains(where:{$0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode)==code}) {return false}
        guard queued.count<256,let copy=event.copy() else{fail("buffer_limit");return false}
        queued.append(copy);schedule();return !releaseDelivered
    }
    @discardableResult func request(_ id:String,at timestamp:CGEventTimestamp=0)->Bool {
        refreshIdleField()
        if ledger == nil,let snap=read(){field=snap.field;ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location);selectedRange=snap.selection}
        guard field != nil,ledger != nil else{return false}
        if !busy { transactionField=field }
        busy=true;target=id;targetTimestamp=timestamp;deadline=now()+1.0;trace("waiting_for_editor");schedule();return true
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
            schedule();return
        }
        if repairWaitStarted != nil {repairWaitStarted=nil;deadline=now()+1}
        guard now()<deadline else{fail("deadline");return}
        guard repairInFlight.isEmpty else{schedule();return}
        guard onsetInFlight.isEmpty else{schedule();return}
        // The next replay cannot advance until the previous event reaches the
        // main tap. AX work here only delays that acknowledgment.
        guard !awaitingReplay else{schedule();return}
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
            guard let focused else{schedule();return}
            guard let transactionField,CFEqual(transactionField,focused) else{fail("focus_changed");return}
            replayNext();return
        }
        // A missing AX reply is not evidence that another field owns focus.
        // Keep later keys queued and retry within the existing deadline.
        guard let snap=read() else{schedule();return}
        guard let transactionField,CFEqual(transactionField,snap.field) else{fail("focus_changed");return}
        if externalEditPending {
            guard ready() else{schedule();return}
            ledger=MismatchReplayLedger(before:snap.text,caret:snap.selection.location)
            selectedRange=snap.selection;field=snap.field;externalEditPending=false
            trace("repair_acknowledged")
        }
        if pendingSelectAll {
            guard ready() else{schedule();return}
            if !matchesText(snap) {acknowledgeInitialBodyRemoval(snap)}
            guard matchesText(snap) else{schedule();return}
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
                schedule();return
            }
            awaitingSelection=false
        }
        if selectionCommitPending {
            if selectionCommitSnapshot == nil {
                guard matches(snap) else{schedule();return}
                selectionCommitSnapshot=snap
            }
            let result=commitSelection(selectionCommitSnapshot!)
            if result==AXError.cannotComplete.rawValue {schedule();return}
            guard result==noErr else{fail("select_all_commit_failed");return}
            selectionCommitSnapshot=nil
            selectionCommitPending=false;awaitingSelection=true
            selectionAttempts=1;selectionRetryAt=now()+0.01
            trace("select_all_committed");schedule();return
        }
        if let target {
            guard ready() else{schedule();return}
            if switchSnapshot == nil {
                guard matches(snap) else{schedule();return}
                switchSnapshot=snap
            }
            let result=select(target)
            if selectionPending(){schedule();return}
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
            deadline=now()+1.0;trace("editor_confirmed_switch");schedule();return
        }
        if !queued.isEmpty {
            replayNext();return
        }
        if ready(),expected == nil || matches(snap) {
            busy=false;self.transactionField=nil;trace("finished")
        }else{schedule()}
    }
    private func replayNext(){
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
        onsetInFlight.removeAll()
        repairWaitStarted=nil
        waitingForRepairBoundary=false
        generation+=1;scheduled=false;busy=false;transactionField=nil;target=nil;targetTimestamp=0;awaitingReplay=false;externalEditPending=false
        let pending=queued;queued=[];resetObservation()
        if !pending.isEmpty{retained(pending)}
        trace(reason)
    }
}
