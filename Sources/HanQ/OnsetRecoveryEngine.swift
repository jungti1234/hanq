import AppKit
import Carbon

let onsetKoreanID="com.apple.inputmethod.Korean.2SetKorean"
struct OnsetSnapshot { let element:AXUIElement;let text:String;let selection:NSRange }
final class OnsetRecoveryEngine:NSObject {
    let marker:Int64=0x48414E5100000000 | Int64(UInt32.random(in:1...UInt32.max))
    var canBeginRepair: () -> Bool = { true }
    var willBeginRepair: () -> Void = {}
    var willReplay: (AXUIElement,String,Int) -> Void = {_,_,_ in}
    var didPostReplayEvent: (CGEvent) -> Void = {_ in}
    var didProcessPhysicalKey:(CGEvent,Bool)->Void = {_,_ in}
    var didStop:(()->Void)?
    var enabled=false
    var target:NSRunningApplication?
    var ax:AXUIElement?
    var locked:AXUIElement?
    var axObserver:AXObserver?
    var observedField:AXUIElement?
    var updateQueued=false
    func requestImmediateObservation(){
        guard enabled,!updateQueued else{return};updateQueued=true
        DispatchQueue.main.async{[weak self] in
            guard let self else{return};self.updateQueued=false;self.automaticTick()
        }
    }
    func observeFieldChanges(_ field:AXUIElement){
        guard let axObserver else{return}
        if let old=observedField,CFEqual(old,field){return}
        if let old=observedField {
            for name in [kAXValueChangedNotification,kAXSelectedTextChangedNotification]{AXObserverRemoveNotification(axObserver,old,name as CFString)}
        }
        observedField=field
        for name in [kAXValueChangedNotification,kAXSelectedTextChangedNotification]{
            let result=AXObserverAddNotification(axObserver,field,name as CFString,Unmanaged.passUnretained(self).toOpaque())
            log("observation_subscription",["notification":name,"result":result.rawValue])
        }
    }
    var gate:OnsetInputGate?
    var gateThread:OnsetGateThread?
    var lastEditable:OnsetSnapshot?
    var timer:Timer?
    var lastSource=""
    var onset=OnsetRecoveryDetector()
    var planElement:AXUIElement?
    var recovering=false
    var pending:[CGEvent]=[]
    var currentPlan:OnsetRecoveryPlan?
    private var incidentShapeProbe=InputIncidentShapeProbe()
    var lastText:String?
    var unavailableReason=""
    var lastAvailability=""
    var postedToGate=0
    var acknowledgmentWaitBegan:Double?
    // Each real transmission retains its own deadline. New transmissions must
    // not prolong an older event's deadline or inherit a completed event's wait.
    var unacknowledgedPosts:[(sequence:Int,time:Double)]=[]
    func recordPostedEvent(){
        postedToGate+=1
        unacknowledgedPosts.append((postedToGate,acknowledgmentClock()))
    }
    var acknowledgmentClock:()->Double = { ProcessInfo.processInfo.systemUptime }
    // Bound a missing acknowledgment independently of AX availability and the
    // input hold watchdog (pauseForContext releases that hold).
    func traceSafety(_ stage:OnsetSafetyDiagnostics.Stage,reason:String="none") {
        InputDiagnostics.shared.record("onset.safety stage=\(stage.rawValue) reason=\(OnsetSafetyDiagnostics.reason(reason)) pending=\(pending.count) retained=\(retainedInput.count) prefix=\(prefixRemainder.count) posted=\(postedToGate) waitMs=\(acknowledgmentWaitBegan.map{Int(max(0,acknowledgmentClock()-$0)*1000)} ?? 0) recovering=\(recovering) waiting=\(waitingForContext) \(gate?.diagnosticState() ?? "gate=none")")
    }
    // Values describe the already evaluated decision; diagnostics perform no AX read.
    func traceDeliveryContext(hasSnapshot:Bool,hasPlanField:Bool,sameField:Bool,sameSource:Bool?) {
        InputDiagnostics.shared.record("onset.deliveryContext snapshot=\(hasSnapshot) planField=\(hasPlanField) sameField=\(sameField) sameSource=\(sameSource.map{String($0)} ?? "unchecked") readFailure=\(OnsetSafetyDiagnostics.readFailure(unavailableReason)) replayStarted=\(replayStarted) rollingBack=\(rollingBack) pending=\(pending.count)")
    }
    func gateAcknowledged(now:Double?=nil)->Bool {
        guard let gate else{acknowledgmentWaitBegan=nil;return true}
        guard gate.healthy() else{emergencyStop("acknowledgment_gate_unavailable");return false}
        let seen=gate.seenCount()
        unacknowledgedPosts.removeAll{$0.sequence<=seen}
        if seen>=postedToGate{if acknowledgmentWaitBegan != nil{traceSafety(.ackReady)};acknowledgmentWaitBegan=nil;return true}
        let time=now ?? acknowledgmentClock()
        if let oldest=unacknowledgedPosts.first {
            if acknowledgmentWaitBegan != oldest.time {
                acknowledgmentWaitBegan=oldest.time;traceSafety(.ackWait)
            }
        }
        // Explicit counter-only test doubles and restored legacy state retain
        // the original bounded wait; real posts always have an issue time.
        guard let began=acknowledgmentWaitBegan else{acknowledgmentWaitBegan=time;traceSafety(.ackWait);return false}
        if time-began>=0.25{emergencyStop("replay_acknowledgment_timeout")}
        return false
    }
    var rollingBack=false
    var rollbackReason=""
    var stopAfterRollback=false
    var prefixRemainder:[CGEvent]=[]
    var lastPrefixObservation=""
    var waitingForContext=false
    var resumeObservedAt:Double?
    var resumeField:AXUIElement?
    var retainedInput:[CGEvent]=[]
    var recoveryEpoch=0
    var transientReadFailure:Bool {
        ["not_supported_text_field","role_unreadable","focused_element_unreadable","text_unreadable","selection_unreadable","selection_invalid"].contains(unavailableReason)
    }
    func scheduleRecovery(_ delay:Double=0,_ action:@escaping ()->Void){
        let epoch=recoveryEpoch
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak self] in
            guard let self,self.recoveryEpoch==epoch else{return};action()
        }
    }
    func pauseForContext(_ reason:String){
        traceSafety(.pause,reason:reason)
        guard !stopAfterRollback,gate?.healthy() ?? true else{parkTerminal(reason);return}
        recoveryEpoch+=1
        retainPrefixRemainder();collectHeld()
        pending.append(contentsOf:gate?.cancelHold() ?? [])
        retainedInput.append(contentsOf:pending);pending=[]
        recovering=false;rollingBack=false;waitingForContext=true
        resumeObservedAt=nil;resumeField=nil;currentPlan=nil;onset.cancel()
        lastEditable=nil
        log("repair_paused",["reason":reason,"retainedEvents":retainedInput.count])
    }
    func resumeIfReady(now:Double=ProcessInfo.processInfo.systemUptime){
        guard enabled,waitingForContext else{return}
        guard gateAcknowledged(now:now) else{resumeObservedAt=nil;resumeField=nil;return}
        observePassedIdentity()
        refreshAcknowledgedPassedBaseline()
        guard currentLayout() != nil,let snap=snapshot(),snap.selection.length==0 else{
            resumeObservedAt=nil;resumeField=nil;return
        }
        guard let field=resumeField,CFEqual(field,snap.element),let since=resumeObservedAt else{
            resumeField=snap.element;resumeObservedAt=now;return
        }
        guard now-since>=0.1 else{return}
        waitingForContext=false;resumeObservedAt=nil;resumeField=nil
        onset.cancel();currentPlan=nil;planElement=nil
        // All posted events are acknowledged above. Only an empty delivery
        // state may stop carrying the previous replay into a new observation.
        if pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty {
            replayStarted=false
        }
        lastEditable=snap;publishPassedBaseline(snap)
        traceSafety(.resume)
        log("repair_resumed",["retainedEvents":retainedInput.count])
    }
    func retainPrefixRemainder(){
        let rest=prefixRemainder;prefixRemainder=[]
        for event in rest{nextBufferedID+=1;event.setIntegerValueField(.eventSourceUserData,value:nextBufferedID)}
        pending.insert(contentsOf:rest,at:0)
    }
    var repairSourceID=onsetKoreanID
    var cachedLayoutID=""
    var cachedLayout:OnsetKeyboardLayout?
    func currentLayout()->OnsetKeyboardLayout? {
        let id=currentSource()
        if id != cachedLayoutID{cachedLayoutID=id;cachedLayout=OnsetKeyboardLayout.load(sourceID:id)}
        return cachedLayout
    }
    var earlyBaseline:OnsetSnapshot?
    var earlyObservationTime:Double?
    var earlyObservedField:AXUIElement?
    var earlyWaiting=false
    var bufferedBase:Int64=0
    var deferredTime:Double?
    var deferredBaseline:OnsetSnapshot?
    var deferredField:AXUIElement?
    var passedTime:Double?
    var passedBaseline:OnsetSnapshot?
    var passedField:AXUIElement?
    func cancelDeferredObservation(){gate?.discardDeferred();deferredTime=nil;deferredBaseline=nil;deferredField=nil;passedTime=nil;passedBaseline=nil;passedField=nil}
    var publishedPassedBaselines:[(revision:Int,snapshot:OnsetSnapshot)]=[]
    var publishedPassedRevision=0
    func publishPassedBaseline(_ snap:OnsetSnapshot?){
        guard enabled,!recovering,pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty,
              let layout=currentLayout(),let snap,snap.selection.length==0 else{gate?.configurePassedBaseline(nil);return}
        if let last=publishedPassedBaselines.last,CFEqual(last.snapshot.element,snap.element),InputFocusAccess.sameText(last.snapshot.text,snap.text),last.snapshot.selection==snap.selection {
            gate?.configurePassedBaseline(last.revision,sourceID:layout.sourceID);return
        }
        publishedPassedRevision+=1
        publishedPassedBaselines.append((publishedPassedRevision,snap))
        // The current and previous publication cover a gate/main-thread race.
        // Once observed, an active sequence has its own anchored snapshot below.
        if publishedPassedBaselines.count>2{publishedPassedBaselines.removeFirst()}
        gate?.configurePassedBaseline(publishedPassedRevision,sourceID:layout.sourceID)
    }
    // A focus pause may hide the original field from snapshot(). Refresh only
    // its read-only baseline after every issued event has crossed the gate.
    func refreshAcknowledgedPassedBaseline(){
        guard enabled,!recovering,!rollingBack,pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty,
              gate?.healthy() ?? true,gate.map({$0.seenCount()>=postedToGate}) ?? true,
              currentSource()==repairSourceID,let field=planElement,let snap=originalSnapshot(field),snap.selection.length==0 else{return}
        lastEditable=snap;publishPassedBaseline(snap)
    }
    func observePassedIdentity(){
        guard let p=gate?.passedObservation(),passedTime != p.first.time else{return}
        passedTime=p.first.time
        if let revision=p.baselineRevision {
            guard let baseline=publishedPassedBaselines.first(where:{$0.revision==revision})?.snapshot else{
                gate?.discardPassed(reason:.baseline_missing);passedBaseline=nil;passedField=nil;return
            }
            passedBaseline=baseline;passedField=baseline.element
        }else{passedBaseline=earlyBaseline;passedField=earlyObservedField}
    }
    func samplePassed(_ snap:OnsetSnapshot?)->Bool {
        guard let gate,let p=gate.passedObservation(),p.keys.count>=2 else{return false}
        guard canBeginRepair(),currentSource()==p.first.sourceID,currentLayout() != nil,
              pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty,!replayStarted,
              gate.seenCount()>=postedToGate else{traceReentryObservation("history_guard_failed",hasSnapshot:snap != nil);gate.discardPassed(reason:.guard_failed);return false}
        guard let snap else{if !transientReadFailure{gate.discardPassed()};return true}
        if let field=passedField,!CFEqual(field,snap.element){traceReentryObservation("history_field_changed",hasSnapshot:true);gate.discardPassed(reason:.field_changed);return false}
        passedField=snap.element
        if let observed=observedEmptyEntry(snap,before:p.first.time) ?? observedDraftEntry(snap,before:p.first.time) {
            passedBaseline=observed
        }
        let baseline=passedBaseline.flatMap{CFEqual($0.element,snap.element) && $0.selection.length==0 ? $0:nil}
        let allowObservedReplay=OnsetFocusHandoff.supports(testTargetBundleID?() ?? target?.bundleIdentifier)
            && baseline != nil && baseline!.selection.location==baseline!.text.utf16.count
        if allowObservedReplay,Self.awaitingEmptyEntryPublication(baseline,current:snap){return true}
        switch OnsetLateSequenceDetector.inspect(keys:p.keys,before:baseline?.text ?? "",caret:baseline?.selection.location ?? 0,text:snap.text,selection:snap.selection,sourceID:p.first.sourceID,allowObservedReplay:allowObservedReplay) {
        case .waiting:traceReentryObservation("history_wait",hasSnapshot:true);return true
        case .complete:traceReentryObservation("history_complete",hasSnapshot:true);gate.discardPassed(reason:.already_composed);return false
        case .rejected:traceReentryObservation("history_rejected",hasSnapshot:true);gate.discardPassed(reason:.detector_rejected);return false
        case .candidate(let candidate):
            traceReentryObservation("history_candidate",hasSnapshot:true)
            if candidate.isObservedReplay {guard p.pressed.isEmpty else{return true}}
            else {guard p.pressed.isEmpty || p.onlyFinalPlainSpaceDown else{return true}}
            planElement=snap.element;repairSourceID=p.first.sourceID
            beginRecovery(candidate,snap,passed:p);return true
        }
    }
    // Called before an ordinary event leaves the main tap. The tail gate's
    // atomic claim rejects any event that already passed during the AX read.
    func observeDeferredBeforeInput(_ type:CGEventType,_ event:CGEvent){
        guard enabled,!recovering,!waitingForContext,(gate?.reservation() != nil || gate?.deferredReservation() != nil || gate?.passedObservation() != nil) else{return}
        if type == .flagsChanged,[56,60].contains(UInt16(event.getIntegerValueField(.keyboardEventKeycode))),
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskAlphaShift,.maskSecondaryFn]).isEmpty {return}
        guard (type == .keyDown || type == .keyUp),
              event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty else{cancelDeferredObservation();return}
        if gate?.reservation()==nil,gate?.deferredReservation()==nil,gate?.passedObservation()?.baselineRevision != nil {
            requestImmediateObservation();return
        }
        sample()
    }
    func sampleDeferred(_ snap:OnsetSnapshot?)->Bool {
        guard let gate,let first=gate.deferredReservation() else{return false}
        guard canBeginRepair(),currentSource()==first.sourceID,let layout=currentLayout(),
              pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty,!replayStarted,
              gate.seenCount()>=postedToGate else{cancelDeferredObservation();return false}
        guard let snap else{
            if !transientReadFailure{cancelDeferredObservation()}
            return true
        }
        if let field=deferredField,!CFEqual(field,snap.element){cancelDeferredObservation();return false}
        if let prior=outsideObservation.baseline(for:snap.element,before:first.time){deferredBaseline=prior}
        let emptyEntry=observedEmptyEntry(snap,before:first.time)
        let prior=emptyEntry ?? observedDraftEntry(snap,before:first.time) ?? deferredBaseline
        guard let baseline=Self.firstConsonantBaseline(prior,current:snap,observedEmptyEntry:emptyEntry != nil) else {
            observeUnclaimedOnset(first,snap);return true
        }
        // The late path relaxes only publication time, never the exact text,
        // caret, physical key, input source or no-following-input requirements.
        var detector=OnsetRecoveryDetector(layout:layout)
        let time=ProcessInfo.processInfo.systemUptime
        detector.outsideKey(code:first.code,shift:first.shift,time:time,korean:true,plain:true)
        detector.entered(time:time)
        guard let candidate=detector.firstConsonant(time:time,text:snap.text,selection:snap.selection,previousText:baseline) else {
            if Self.awaitingEmptyEntryPublication(emptyEntry,current:snap) || detector.awaitingFirstConsonant(text:snap.text,selection:snap.selection,previousText:baseline,
                previousCaret:prior?.selection.location,code:first.code,shift:first.shift) {
                deferredField=snap.element;return true
            }
            cancelDeferredObservation();return false
        }
        planElement=snap.element;repairSourceID=first.sourceID
        beginRecovery(candidate,snap,deferred:first)
        return true
    }
    // Only an untouched, fully delivered attempt can return directly to observation.
    // cancelHold atomically collects keys arriving while AX was blocked.
    @discardableResult func abandonUneditedReservation()->Bool {
        let first=gate?.reservation() ?? gate?.deferredReservation()
        if deferredTime != first?.time {deferredTime=first?.time;deferredBaseline=earlyBaseline;deferredField=earlyObservedField}
        collectHeld();pending.append(contentsOf:gate?.cancelHold(preserveUnclaimed:true) ?? [])
        guard gate?.healthy() ?? true,!recovering,!replayStarted,pending.isEmpty,prefixRemainder.isEmpty,
              retainedInput.isEmpty,gate.map({$0.seenCount()>=postedToGate}) ?? true else {
            pauseForContext("early_field_unavailable");return false
        }
        onset.cancel();currentPlan=nil;planElement=nil
        earlyObservationTime=nil;earlyObservedField=nil;earlyWaiting=false;earlyBaseline=nil
        log("early_observation_resumed")
        return true
    }
    func observeUnclaimedOnset(_ first:OnsetInputGate.Reservation,_ snap:OnsetSnapshot){
        guard pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty,!replayStarted,
              gate?.observeUnclaimed(first)==true else{abandonUneditedReservation();return}
        // A new field or its first isolated character cannot distinguish live
        // IME composition from a detached onset. Observe the whole passed word
        // without sending a cursor command or quarantining subsequent keys.
        passedTime=first.time;passedBaseline=nil;passedField=snap.element
        deferredTime=nil;deferredBaseline=nil;deferredField=nil
        earlyObservationTime=nil;earlyObservedField=nil;earlyWaiting=false;earlyBaseline=nil
        onset.cancel();currentPlan=nil;planElement=nil
        traceReentryObservation("early_skip",hasSnapshot:true)
        lastEditable=snap;publishPassedBaseline(snap)
        _ = samplePassed(snap)
    }
    // Match observed content transitions, independent of application identity.
    func observedEmptyEntry(_ current:OnsetSnapshot,before time:Double)->OnsetSnapshot? {
        guard OnsetFocusHandoff.supports(testTargetBundleID?() ?? target?.bundleIdentifier) else{return nil}
        return focusHandoff.emptyEntryBaseline(for:current.element,before:time)
    }
    func observedDraftEntry(_ current:OnsetSnapshot,before time:Double)->OnsetSnapshot? {
        guard OnsetFocusHandoff.supports(testTargetBundleID?() ?? target?.bundleIdentifier) else{return nil}
        return focusHandoff.draftEntryBaseline(for:current.element,before:time)
    }
    // A focused editor can still publish its pre-key empty representation.
    // Keep reading without claiming the gate; later original input still passes.
    static func awaitingEmptyEntryPublication(_ previous:OnsetSnapshot?,current:OnsetSnapshot)->Bool {
        guard let previous,CFEqual(previous.element,current.element),previous.text.isEmpty,
              previous.selection==NSRange(location:0,length:0),current.selection.length==0 else{return false}
        if current.text=="\n" {return current.selection.location==0 || current.selection.location==1}
        return current.selection.location==0 && (current.text.isEmpty || OnsetFocusHandoff.knownCodexPlaceholder(current.text))
    }
    static func firstConsonantBaseline(_ previous:OnsetSnapshot?,current:OnsetSnapshot,observedEmptyEntry:Bool=false)->String? {
        // Restore the released empty-composer path only with an independently
        // observed pre-key empty field. A placeholder observation is normalized
        // to empty; it is never restored as user text. The detector still proves
        // the original consonant/source/caret and commits composition first.
        if current.text.utf16.count == 1,current.selection == NSRange(location:1,length:0),current.text != previous?.text {
            guard observedEmptyEntry,let previous,CFEqual(previous.element,current.element),previous.text.isEmpty,previous.selection==NSRange(location:0,length:0) else{return nil}
            return ""
        }
        guard let previous,CFEqual(previous.element,current.element),previous.selection.length == 0 else{return nil}
        let length=previous.text.utf16.count
        if length>0,
           current.selection == NSRange(location:length+2,length:0),
           current.text.utf16.count == length+2,current.text.hasPrefix(previous.text+" ") {
            return previous.text+" "
        }
        return previous.text
    }
    let focusHandoff=OnsetFocusHandoff()
    var focusLayoutWindow:AXUIElement?
    // Explicit temporary diagnosis only. Observe existing decisions on the
    // main run loop; never write files or issue additional AX reads in a key
    // callback. The deadline is shared across rebound engines in one process.
    private static let focusTraceDeadline=ProcessInfo.processInfo.systemUptime+120
    private static var focusTraceLines=0
    private let focusTraceRequested=ProcessInfo.processInfo.arguments.contains("--trace-onset-focus")
    private var focusTraceNext=0.0,focusTracePrevious=""
    private var focusKeySerial=0,focusKeyStage=0
    private var firstFocusDecisionRecorded=false
    private lazy var sceneProbe=OnsetFocusHandoff()
    private var sceneProbeFinished=false,sceneProbeBegan=0.0
    private let sceneProbeRequested=ProcessInfo.processInfo.arguments.contains("--diagnose-onset-scene")
    func observeSceneProbe(){
        guard sceneProbeRequested,InputDiagnostics.shared.isEnabled,!sceneProbeFinished,enabled,
              !recovering,!waitingForContext,pending.isEmpty,retainedInput.isEmpty,
              canBeginRepair(),AXIsProcessTrusted(),!IsSecureEventInputEnabled(),
              let target,target.bundleIdentifier=="com.openai.codex",!target.isTerminated,let ax,
              focusAccess.currentPID()==target.processIdentifier,
              let raw=attr(ax,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else{return}
        let time=ProcessInfo.processInfo.systemUptime
        if sceneProbeBegan==0{sceneProbeBegan=time;sceneProbe.nodeLimit=16384;sceneProbe.diagnosticsEnabled=true}
        if time-sceneProbeBegan>10{sceneProbeFinished=true;InputDiagnostics.shared.record("onset.scene_probe deadline=1 \(sceneProbe.diagnosticState)");return}
        sceneProbe.advance(window:raw as! AXUIElement)
        if sceneProbe.sceneCompleted{
            sceneProbeFinished=true
            InputDiagnostics.shared.record("onset.scene_probe deadline=0 overProductionLimit=\(sceneProbe.sceneVisited>2048 || sceneProbe.sceneClipped ? 1:0) \(sceneProbe.diagnosticState)")
        }
    }
    private var focusKeyDecisions:[(Int,Int,Int)]=[]
    func flushFocusHandoffDiagnostics(){
        guard focusTraceRequested,InputDiagnostics.shared.isEnabled,
              Self.focusTraceLines<1024 else{return}
        let time=ProcessInfo.processInfo.systemUptime
        guard time<Self.focusTraceDeadline,time>=focusTraceNext else{return}
        focusTraceNext=time+0.25
        let state="scope=\(OnsetFocusHandoff.supports(target?.bundleIdentifier) ? 1:0) reason=\(InputIncidentTrace.ReadOutcome.snapshot(unavailableReason).rawValue) enabled=\(enabled ? 1:0) recovering=\(recovering ? 1:0) waiting=\(waitingForContext ? 1:0) pending=\(pending.count) retained=\(retainedInput.count) \(focusHandoff.diagnosticState)"
        if state != focusTracePrevious {
            focusTracePrevious=state;Self.focusTraceLines+=1
            InputDiagnostics.shared.record("onset.focus_idle \(state)")
        }
        for (sequence,stage,outcome) in focusKeyDecisions where Self.focusTraceLines<1024 {
            Self.focusTraceLines+=1
            InputDiagnostics.shared.record("onset.focus_key sequence=\(sequence) stage=\(stage) outcome=\(outcome)")
        }
        focusKeyDecisions.removeAll(keepingCapacity:true)
    }
    // Only a proved empty, unique composer may receive this first-key focus
    // handoff. It never consumes the key or enters the text-replacement path.
    func prepareFocusForFirstInput(_ type:CGEventType,_ event:CGEvent){
        let traceKey=focusTraceRequested && InputDiagnostics.shared.isEnabled && type == .keyDown
            && ProcessInfo.processInfo.systemUptime<Self.focusTraceDeadline
        if type == .keyDown{focusKeyStage=1}
        let recordDecision=type == .keyDown && InputIncidentTrace.shared.enabled && !firstFocusDecisionRecorded
            && OnsetFocusHandoff.supports(target?.bundleIdentifier)
            && PhysicalLetterKeys.printableCodes.contains(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            && event.getIntegerValueField(.keyboardEventKeycode) != 49
            && event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty
            && (unavailableReason=="not_supported_text_field" || lastEditable==nil || focusHandoff.candidate != nil)
        defer{
            if recordDecision{
                firstFocusDecisionRecorded=true
                let state:InputIncidentTrace.State
                if focusKeyStage==3{state = .focusConfirmed}
                else if focusKeyStage==2 && focusHandoff.lastOutcome == .unconfirmed{state = .focusRequestUnconfirmed}
                else if focusKeyStage==11 && focusHandoff.sceneClipped{state = .focusSceneClipped}
                else if focusKeyStage==11 && focusHandoff.sceneEditorCount>1{state = .focusMultipleEditors}
                else if focusKeyStage==11 && focusHandoff.sceneScanning{state = .focusSceneScanning}
                else if focusKeyStage==11{state = .focusCandidateUnavailable}
                else{state = .focusGuardRejected}
                InputIncidentTrace.shared.focusHandoffObservation(state)
            }
        }
        if traceKey{focusKeySerial+=1}
        defer{if traceKey,focusKeyDecisions.count<16{focusKeyDecisions.append((focusKeySerial,focusKeyStage,focusHandoff.lastOutcome.rawValue))}}
        if [.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].contains(type)
            || (type == .keyDown && !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty){firstFocusDecisionRecorded=false;focusHandoff.invalidateEmptyEntries();focusHandoff.reset();return}
        guard type == .keyDown,enabled,!recovering,!waitingForContext,!replayStarted,
              pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty else{return}
        focusKeyStage=10
        guard let target,!target.isTerminated,OnsetFocusHandoff.supports(target.bundleIdentifier) else{return}
        focusKeyStage=11
        guard let ax,focusHandoff.candidate != nil else{return}
        focusKeyStage=12
        guard canBeginRepair() else{return}
        focusKeyStage=13
        guard let gate,gate.healthy(),!gate.hasActiveReplayHold(),gate.reservation()==nil,
              gate.deferredReservation()==nil,gate.passedObservation()==nil else{return}
        focusKeyStage=14
        guard let layout=currentLayout() else{return}
        focusKeyStage=2
        AXUIElementSetMessagingTimeout(focusAccess.system,0.003)
        defer{AXUIElementSetMessagingTimeout(focusAccess.system,0.05)}
        guard focusHandoff.prepare(type,event,application:ax,pid:target.processIdentifier,
              sourceID:layout.sourceID,currentSource:currentSource,
              normal:Set(layout.normal.keys),shifted:Set(layout.shifted.keys),systemFocus:{[self] in
                  guard let actual=focusAccess.focusedElement(application:ax,pid:target.processIdentifier),
                        focusAccess.lastRoute==1 || event.getIntegerValueField(.eventTargetUnixProcessID)==Int64(target.processIdentifier) else{return nil}
                  return actual
              }) else{return}
        focusKeyStage=3
        // Let the normal main/mismatch/boundary observers see this untouched
        // first key on the now-focused field. No early hold is needed.
        gate.configureEarly(false,sourceID:layout.sourceID,normal:Set(layout.normal.keys),shifted:Set(layout.shifted.keys))
        gate.configurePassedBaseline(nil);cancelDeferredObservation();onset.cancel()
        earlyBaseline=nil;lastEditable=nil
        log("first_input_focus_confirmed")
    }
    func observeFocusHandoff(){
        guard testSnapshot==nil,let target,!target.isTerminated,
              OnsetFocusHandoff.supports(target.bundleIdentifier),let ax,
              canBeginRepair(),focusAccess.currentPID()==target.processIdentifier,
              let raw=attr(ax,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID(),
              let outside=focusAccess.focusedElement(application:ax,pid:target.processIdentifier) else{return}
        let window=raw as! AXUIElement
        if let observer=axObserver,focusLayoutWindow.map({!CFEqual($0,window)}) ?? true {
            if let old=focusLayoutWindow{AXObserverRemoveNotification(observer,old,kAXLayoutChangedNotification as CFString)}
            let status=AXObserverAddNotification(observer,window,kAXLayoutChangedNotification as CFString,Unmanaged.passUnretained(self).toOpaque())
            focusHandoff.sceneCacheEnabled=status == .success
            focusLayoutWindow=window
        }
        focusHandoff.advance(window:window,outside:outside)
    }
    let outsideObservation=OnsetOutsideObservation()
    func observeOutsideEditors(){
        guard testSnapshot == nil else{return}
        guard let ax,let target,focusAccess.currentPID()==target.processIdentifier else{return}
        guard let window=attr(ax,kAXFocusedWindowAttribute),CFGetTypeID(window)==AXUIElementGetTypeID() else{return}
        outsideObservation.advance(root:window as! AXUIElement,focused:focusAccess.focusedElement(application:ax,pid:target.processIdentifier))
    }
    func sampleEarly(_ observed:OnsetSnapshot?,now:Double=ProcessInfo.processInfo.systemUptime){
        guard let gate else{return}
        observePassedIdentity()
        if gate.takeEarlyExpiration() {
            guard abandonUneditedReservation() else{return}
        }
        guard canBeginRepair() else{gate.configureEarly(false);if gate.reservation() != nil{emergencyStop("manual_edit_busy")};return}
        if let reservation=gate.reservation() {
            if earlyObservationTime != reservation.time {
                earlyObservationTime=reservation.time;earlyObservedField=nil;earlyWaiting=false
            }
            guard currentSource()==reservation.sourceID,let layout=currentLayout() else{emergencyStop("early_source_changed");return}
            repairSourceID=reservation.sourceID
            guard let snap=observed else{
                if !transientReadFailure || now-reservation.time>=0.15 {
                    if transientReadFailure { abandonUneditedReservation() }
                    else { emergencyStop("early_field_unavailable") }
                }
                return
            }
            guard snap.selection.length==0 else{emergencyStop("early_selection_changed");return}
            if let field=earlyObservedField,!CFEqual(field,snap.element){emergencyStop("early_field_changed");return}
            earlyObservedField=snap.element
            if let prior=outsideObservation.baseline(for:snap.element,before:reservation.time){earlyBaseline=prior}
            let emptyEntry=observedEmptyEntry(snap,before:reservation.time)
            let prior=emptyEntry ?? observedDraftEntry(snap,before:reservation.time) ?? earlyBaseline
            guard let baseline=Self.firstConsonantBaseline(prior,current:snap,observedEmptyEntry:emptyEntry != nil) else {
                observeUnclaimedOnset(reservation,snap);return
            }
            var detector=OnsetRecoveryDetector(layout:layout)
            detector.outsideKey(code:reservation.code,shift:reservation.shift,time:reservation.time,korean:true,plain:true)
            detector.entered(time:now)
            let candidate=detector.firstConsonant(time:now,text:snap.text,selection:snap.selection,previousText:baseline)
            planElement=snap.element
            if let candidate {
                traceReentryObservation("early_candidate",hasSnapshot:true)
                log("early_candidate",["code":reservation.code,"heldMs":(now-reservation.time)*1000])
                beginRecovery(candidate,snap)
            }else{
                let caret=prior?.selection.location
                let awaiting=Self.awaitingEmptyEntryPublication(emptyEntry,current:snap) || detector.awaitingFirstConsonant(text:snap.text,selection:snap.selection,previousText:baseline,previousCaret:caret,code:reservation.code,shift:reservation.shift)
                // Leave 50ms inside the existing 350ms gate reservation to claim
                // and release on the next 20ms observation. Never renew its deadline.
                if awaiting,now-reservation.time<0.30 {
                    if !earlyWaiting{traceReentryObservation("early_wait",hasSnapshot:true);log("early_waiting_for_text")}
                    earlyWaiting=true;return
                }
                if earlyWaiting && !awaiting{emergencyStop("early_context_changed");return}
                // Nothing can be safely selected. Keep the app's current text and only
                // forward the original follow-up events in the same field.
                traceReentryObservation("early_skip",hasSnapshot:true);log("early_skip",["reason":"candidate_not_exact"])
                guard abandonUneditedReservation() else{return}
                lastEditable=snap;publishPassedBaseline(snap)
                _ = samplePassed(snap)
            }
            return
        }
        if sampleDeferred(observed){return}
        if samplePassed(observed){return}
        earlyObservationTime=nil;earlyObservedField=nil;earlyWaiting=false
        let layout=currentLayout()
        let eligible=observed==nil && unavailableReason=="not_supported_text_field" && layout != nil
        if eligible {
            earlyBaseline=lastEditable
            if OnsetFocusHandoff.supports(target?.bundleIdentifier){observeFocusHandoff()}
            else{observeOutsideEditors()}
        }
        else if let observed{focusHandoff.enteredEditor(observed.element,text:observed.text,selection:observed.selection)}
        gate.configureEarly(eligible,sourceID:layout?.sourceID ?? "",normal:Set(layout?.normal.keys.map{$0} ?? []),shifted:Set(layout?.shifted.keys.map{$0} ?? []))
        if let snap=observed {
            if !InputFocusAccess.sameText(lastText,snap.text){lastText=snap.text;log("text",["text":snap.text,"selection":[snap.selection.location,snap.selection.length],"source":currentSource()])}
            lastEditable=snap
        }
        publishPassedBaseline(lastEditable)
    }
    var replayStarted=false
    var nextBufferedID:Int64=0
    var postedBuffered=0
    // Deterministic failure tests inject only the OS-facing operations.
    var testSnapshot:(()->OnsetSnapshot?)?
    var testCanSelect:(()->Bool)?
    var testCanReplaceText:(()->Bool)?
    var testTargetBundleID:(()->String?)?
    var testReplaceText:((AXUIElement,String)->AXError)?
    var testOriginalSnapshot:((AXUIElement)->OnsetSnapshot?)?
    var testSetRange:((AXUIElement,NSRange)->AXError)?
    // Detached-text test doubles have no IME composition to commit. Real clients
    // use the cursor-key path and must acknowledge it through their text/caret.
    var testCommitComposition:((AXUIElement)->Bool)?
    var testPostCompositionCommit:((AXUIElement,CGEvent)->Bool)?
    var testSource:(()->String)?
    var testPost:((CGEvent)->Void)?
    func currentSource()->String { testSource?() ?? InputSourceAccess.currentID() }
    @discardableResult func post(_ event:CGEvent)->Bool {
        if gate?.healthy()==false{return false}
        if testPost == nil && (!AXIsProcessTrusted() || IsSecureEventInputEnabled()){return false}
        if event.getIntegerValueField(.keyboardEventKeycode)==51 && !OnsetDeletionKey.hasDeletePayload(event){emergencyStop("unsafe_delete_payload_blocked");return false}
        if let testPost { testPost(event) } else { recordPostedEvent();event.post(tap:.cghidEventTap) }
        if replayStarted,!rollingBack,currentPlan?.supportsReplay == true {didPostReplayEvent(event)}
        return true }
    var lastAXFailure=""
    var accessibilityActivation=OnsetAccessibilityActivation()
    var accessibilityClock:()->Double={ProcessInfo.processInfo.systemUptime}
    var testAccessibilityReady:(()->Bool)?
    var testAccessibilityTarget:(()->pid_t?)?
    var testAccessibilityRequest:((AXUIElement,String)->AXError)?
    var lastFocusRoute=""
    private let incidentFocusProbe=InputIncidentFocusProbe()
    let focusAccess=InputFocusAccess()
    var systemAX:AXUIElement { focusAccess.system }
    func focusedElement(_ app:AXUIElement, pid:pid_t)->AXUIElement? {
        if let element=focusAccess.focusedElement(application:app,pid:pid){
            accessibilityActivation.available(now:accessibilityClock());return element
        }
        accessibilityActivation.missing(now:accessibilityClock())
        return nil
    }
    func serviceFocusAccessibility(){
        // No activation writes while input is held, a replay is outstanding,
        // or another edit owns the input. A snapshot can also be requested by
        // the main key tap; it only records failure and never services this.
        let now=accessibilityClock()
        guard accessibilityActivation.due(now:now),let ax else{return}
        let pid:pid_t
        if let testAccessibilityTarget {
            guard let testPID=testAccessibilityTarget(),testPID>0 else{return};pid=testPID
        }else {
            guard let target,!target.isTerminated,target.processIdentifier>0 else{return};pid=target.processIdentifier
        }
        func ready()->Bool {
            guard enabled,!recovering,!waitingForContext,!replayStarted,
                  pending.isEmpty,retainedInput.isEmpty,prefixRemainder.isEmpty,
                  unacknowledgedPosts.isEmpty,(gate?.seenCount() ?? 0)>=postedToGate,
                  gate?.reservation()==nil,gate?.deferredReservation()==nil,gate?.passedObservation()==nil,
                  canBeginRepair(),(testAccessibilityReady?() ?? (AXIsProcessTrusted() && !IsSecureEventInputEnabled())) else{return false}
            return focusAccess.currentPID()==pid
        }
        guard ready() else{return}
        for attribute in accessibilityActivation.begin(now:now) {
            guard ready() else{break}
            let result=testAccessibilityRequest?(ax,attribute.name) ?? AXUIElementSetAttributeValue(ax,attribute.name as CFString,kCFBooleanTrue)
            let outcome:OnsetAccessibilityActivation.Result
            switch result {
            case .success:outcome = .enabled
            case .attributeUnsupported,.notImplemented,.illegalArgument:outcome = .unsupported
            default:outcome = .retryable
            }
            accessibilityActivation.completed(attribute,result:outcome)
        }
        // Setting an AX attribute does not establish focus or an editable
        // snapshot. Only a later normal, fully validated read can do that.
    }
    func attr(_ element:AXUIElement,_ name:String)->CFTypeRef?{
        var value:CFTypeRef?
        let result=AXUIElementCopyAttributeValue(element,name as CFString,&value)
        if result != .success {
            let detail="\(name):\(result.rawValue)"
            if detail != lastAXFailure{lastAXFailure=detail;log("ax_read_failed",["attribute":name,"errorCode":result.rawValue,"targetPID":target?.processIdentifier ?? -1])}
            return nil
        }
        return value
    }
    func emergencyStop(_ reason:String){
        traceSafety(.stop,reason:reason)
        guard enabled || recovering || waitingForContext else{return}
        recoveryEpoch+=1;waitingForContext=false
        retainPrefixRemainder()
        gate?.stop();collectHeld()
        enabled=false;recovering=false;rollingBack=false;onset.cancel()
        // Detach before logging or making any further accessibility calls.
        timer?.invalidate();timer=nil
        log("safety_stop",["reason":reason,"retainedEvents":pending.count])
        closeSession();didStop?()
    }
    func collectHeld(){
        for event in gate?.take() ?? [] {
            nextBufferedID+=1;event.setIntegerValueField(.eventSourceUserData,value:nextBufferedID);pending.append(event)
            log("key_buffered",["id":nextBufferedID,"eventType":event.type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode)])
        }
    }
    // A temporary content read failure is not a transaction boundary. Keep the
    // existing hold and queue; never extend its deadline or post without a new
    // complete snapshot of the original field and source.
    func canAwaitReplaySnapshot()->Bool {
        guard recovering,replayStarted,!rollingBack,planElement != nil,currentPlan != nil,
              ["text_unreadable","selection_unreadable","selection_invalid"].contains(unavailableReason),
              let gate,currentSource()==repairSourceID else{return false}
        gate.poll()
        return gate.hasActiveReplayHold()
    }
    func flushReentryTrace(){
        guard InputDiagnostics.shared.isEnabled,let gate else{return}
        let (frames,dropped)=gate.takeReentryTrace()
        for frame in frames{InputDiagnostics.shared.record(frame.line)}
        if dropped>0{InputDiagnostics.shared.record("onset.reentry_dropped count=\(dropped)")}
    }
    var lastReentryObservation=""
    func traceReentryObservation(_ reason:String,hasSnapshot:Bool){
        guard InputDiagnostics.shared.isEnabled else{return}
        let state="reason=\(OnsetReentryDiagnostics.engineReason(reason)) snapshot=\(hasSnapshot) baseline=\(earlyBaseline != nil) passedBaseline=\(passedBaseline != nil) replayStarted=\(replayStarted) recovering=\(recovering) waiting=\(waitingForContext) pending=\(pending.count) retained=\(retainedInput.count)"
        guard state != lastReentryObservation else{return};lastReentryObservation=state
        InputDiagnostics.shared.record("onset.reentry_engine decisionMonoNs=\(DispatchTime.now().uptimeNanoseconds) \(state)")
    }
    func automaticTick(){
        defer{flushReentryTrace();flushFocusHandoffDiagnostics();observeSceneProbe()}
        guard enabled else{return}
        guard AXIsProcessTrusted() else{emergencyStop("permission_revoked");return}
        gate?.beat();collectHeld()
        if waitingForContext{resumeIfReady();return}
        if recovering {
            if committedReplacementAwaiting {verifyCommittedReplacement();return}
            if finishQuietConfirmedDelivery(){return}
            _ = gateAcknowledged()
            guard enabled,recovering else{return}
            let observed=snapshot()
            let sameField=observed.flatMap{snap in planElement.map{CFEqual(snap.element,$0)}} ?? false
            let source=currentSource()
            guard observed != nil,sameField,source==repairSourceID else{
                log("repair_context_details",["snapshotFailure":unavailableReason,"hasSnapshot":observed != nil,"sameField":sameField,"source":source,"frontmostPID":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
                if observed==nil,canAwaitReplaySnapshot(){return}
                if observed==nil,transientReadFailure{pauseForContext("repair_context_lost")}else{emergencyStop("repair_context_lost")};return
            }
            gate?.beat();return
        }
        sample();gate?.beat()
        serviceFocusAccessibility()
        gate?.beat()
    }
    func snapshot()->OnsetSnapshot?{
        let incidentRead=InputIncidentTrace.shared.beginRead(.onsetAX)
        var incidentMeasured=false
        let incidentGeneration=InputIncidentTrace.shared.collectionGeneration
        var focusRead:InputIncidentFocusProbe.Read?
        let oldFocusObserver=focusAccess.observeFocus
        defer{
            focusAccess.observeFocus=oldFocusObserver
            let allowed=incidentMeasured && !["secure_input","secure_field","secure_text_field","accessibility_permission"].contains(unavailableReason)
            let focus=incidentFocusProbe.finish(allowed ? focusRead:nil,generation:incidentGeneration,path:1)
            InputIncidentTrace.shared.endRead(.onsetAX,incidentRead,outcome:incidentMeasured ? .snapshot(unavailableReason):nil,focus:focus)
        }
        if let testSnapshot{return testSnapshot()}
        unavailableReason="";incidentMeasured=incidentRead != nil
        guard AXIsProcessTrusted() else{unavailableReason="accessibility_permission";return nil}
        guard !IsSecureEventInputEnabled() else{unavailableReason="secure_input";return nil}
        guard let target,!target.isTerminated else{unavailableReason="target_not_frontmost";return nil}
        if incidentMeasured {
            focusRead=InputIncidentFocusProbe.Read(target:target.processIdentifier)
            focusAccess.observeFocus={element,owner,route in focusRead?.observe(element,owner:owner,route:route)}
        }
        // focusedElement proves the owner itself. A separate currentPID read
        // immediately before it duplicated the same system-wide AX request.
        guard let ax,let element=focusedElement(ax,pid:target.processIdentifier) else{
            unavailableReason=focusAccess.lastOwner==target.processIdentifier ? "focused_element_unreadable":"target_not_frontmost";return nil
        }
        let context=InputFocusAccess.attributes(element,[kAXSubroleAttribute,kAXRoleAttribute]+(recovering ? []:["AXMarkedTextRange"]))
        if incidentMeasured {focusRead?.observedRole(context[1] as? String)}
        guard context[0] as? String != "AXSecureTextField" else{unavailableReason="secure_field";return nil}
        guard let role=context[1] as? String else{unavailableReason="role_unreadable";return nil}
        guard OnsetEditableRole.supports(role) else{unavailableReason="not_supported_text_field";return nil}
        // Respect an editor's explicit active composition; unsupported attributes
        // remain unknown, as in the original compatibility probe.
        if !recovering,let markedValue=context[2],CFGetTypeID(markedValue)==AXValueGetTypeID() {
            var marked=CFRange()
            if AXValueGetValue(markedValue as! AXValue,.cfRange,&marked),marked.location>=0,marked.length>0 {
                unavailableReason="active_composition";return nil
            }
        }
        let content=InputFocusAccess.attributes(element,[kAXValueAttribute,kAXSelectedTextRangeAttribute])
        guard let text=content[0] as? String else{unavailableReason="text_unreadable";return nil}
        guard let raw=content[1],CFGetTypeID(raw)==AXValueGetTypeID() else{unavailableReason="selection_unreadable";return nil}
        var range=CFRange();guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0,range.location+range.length<=text.utf16.count else{unavailableReason="selection_invalid";return nil}
        guard let after=focusedElement(ax,pid:target.processIdentifier),CFEqual(element,after) else{unavailableReason="focus_changed_during_snapshot";return nil}
        if InputIncidentTrace.shared.enabled {
            let trace=InputIncidentTrace.shared
            let (identity,owner,window,epoch)=trace.fieldRegistry.identify(element,owner:target.processIdentifier,window:nil,generation:trace.collectionGeneration)
            var evidence=InputIncidentAXEvidence();evidence.owner=owner;evidence.window=window;evidence.identityEpoch=epoch;evidence.route=focusAccess.lastRoute
            let change=incidentShapeProbe.observe(identity:identity,text:text,selection:NSRange(location:range.location,length:range.length),generation:trace.collectionGeneration,ax:evidence)
            trace.shape(.onsetAX,identity:identity,count:text.utf16.count,selected:range.length>0,editing:recovering,change:change)
        } else {incidentShapeProbe.reset()}
        return OnsetSnapshot(element:element,text:text,selection:NSRange(location:range.location,length:range.length))
    }
    func observeAvailability(_ snap:OnsetSnapshot?){
        let availability=snap == nil ? unavailableReason : "tracking"
        if availability != lastAvailability {
            log("tracking_state",["state":availability])
            lastAvailability=availability
        }
        guard let snap else{return}
        observeFieldChanges(snap.element)
        if locked == nil || !CFEqual(locked!,snap.element){
            log("field_changed",["previousFieldExisted":locked != nil,"source":InputSourceAccess.currentID(),"text":snap.text,"selection":[snap.selection.location,snap.selection.length]])
            locked=snap.element;planElement=nil;lastText=nil
            // A new composer is a new transaction boundary. Never reuse the old field's repair range.
            lastSource=InputSourceAccess.currentID()
        }
    }
    func setRange(_ element:AXUIElement,_ range:NSRange)->AXError{guard gate?.healthy() ?? true else{return .cannotComplete};if let testSetRange{return testSetRange(element,range)};var cf=CFRange(location:range.location,length:range.length);return AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&cf)!)}
    // Deliberately discard all probe payloads: they can contain user text and keys.
    func log(_ kind:String,_ fields:@autoclosure ()->[String:Any]=[:]) {
        InputDiagnostics.shared.record("onset.\(kind)")
        if InputIncidentTrace.shared.enabled {
            if let state=InputIncidentTrace.State.event(kind){InputIncidentTrace.shared.state(.onset,state,pending:pending.count+retainedInput.count)}
        }
    }
    @objc func start(){
        guard !enabled else{return}
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled() else{return}
        target=focusAccess.currentApplication()
        guard let target,OnsetRecoveryController.supports(pid:target.processIdentifier) else{return}
        ax=AXUIElementCreateApplication(target.processIdentifier);AXUIElementSetMessagingTimeout(ax!,0.05)
        AXUIElementSetMessagingTimeout(systemAX,0.05);accessibilityActivation=OnsetAccessibilityActivation();lastFocusRoute="";lastAXFailure=""
        let gate=OnsetInputGate(marker:marker);if InputDiagnostics.shared.isEnabled{gate.enableReentryTrace()};self.gate=gate;postedToGate=0;unacknowledgedPosts=[];acknowledgmentWaitBegan=nil
        if InputIncidentTrace.shared.enabled {
            gate.diagnosticEvent={type,event,consumed,duration,started in InputIncidentTrace.shared.event(.onset,type,event,consumed:consumed,duration:duration,started:started)}
        }
        gate.didProcessPhysicalKey = { [weak self] event,passed in self?.didProcessPhysicalKey(event,passed) }
        gate.deliver={[weak self,weak gate] event in guard let self,let gate,self.gate === gate,self.enabled,!self.recovering else{return};_ = self.event(event.type,event)}
        gate.failed={[weak self,weak gate] reason in guard let self,let gate,self.gate === gate else{return};self.emergencyStop(reason)}
        gate.observationNeeded={[weak self,weak gate] in
            guard let self,let gate,self.gate === gate,self.enabled else{return}
            self.requestImmediateObservation()
        }
        focusHandoff.diagnosticsEnabled=focusTraceRequested && InputDiagnostics.shared.isEnabled
        focusHandoff.beginDiagnosticObservation()
        if focusTraceRequested,InputDiagnostics.shared.isEnabled{focusKeyDecisions.reserveCapacity(16)}
        gate.beat();gateThread=OnsetGateThread(gate)
        enabled=true;recovering=false;lastEditable=nil;pending=[];locked=nil;lastText=nil;lastSource=InputSourceAccess.currentID();focusHandoff.reset();focusLayoutWindow=nil;focusHandoff.sceneCacheEnabled=false
        log("session_start",["toolVersion":"0.1.19","build":20,"mode":"first_consonant","targetPID":target.processIdentifier,"source":lastSource])
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in self?.automaticTick()}
        gateThread?.start()
        var observer:AXObserver?
        let observerResult=AXObserverCreate(target.processIdentifier,{_,_,notification,ref in
            guard let ref else{return}
            let engine=Unmanaged<OnsetRecoveryEngine>.fromOpaque(ref).takeUnretainedValue()
            if CFEqual(notification,kAXLayoutChangedNotification as CFString){engine.focusHandoff.reset()}
            engine.requestImmediateObservation()
        },&observer)
        if observerResult == .success,let observer{
            axObserver=observer
            CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)
        }
        log("observer_created",["result":observerResult.rawValue])

    }
    func event(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>?{
        if OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)) || event.getIntegerValueField(.eventSourceUserData)==SyntheticInputMarker.manualEdit{return Unmanaged.passUnretained(event)}
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput{emergencyStop("event_tap_disabled");return Unmanaged.passUnretained(event)}
        guard enabled else{return Unmanaged.passUnretained(event)}
        requestImmediateObservation()
        return Unmanaged.passUnretained(event)
    }
    func sample(){
        guard enabled,!recovering else{return}
        if currentLayout() == nil,gate?.reservation() == nil {
            cancelDeferredObservation()
            gate?.configurePassedBaseline(nil)
            gate?.configureEarly(false);onset.cancel();planElement=nil
            lastEditable=nil;earlyBaseline=nil;lastText=nil;outsideObservation.reset()
            return
        }
        let observed=snapshot();traceReentryObservation(observed == nil ? unavailableReason:"tracking",hasSnapshot:observed != nil);observeAvailability(observed)
        sampleEarly(observed)
    }

    func beginRecovery(_ candidate:OnsetRecoveryPlan,_ snap:OnsetSnapshot,deferred:OnsetInputGate.Reservation?=nil,passed:OnsetInputGate.PassedInput?=nil){
        guard canBeginRepair() else{onset.cancel();emergencyStop("manual_edit_busy");return}
        if candidate.isObservedReplay {
            guard OnsetFocusHandoff.supports(testTargetBundleID?() ?? target?.bundleIdentifier),
                  let passed,passed.pressed.isEmpty,passed.keys.count==candidate.codes.count,
                  zip(passed.keys,candidate.codes).allSatisfy({$0.0==$0.1}),
                  currentSource()==passed.first.sourceID else{return}
        }
        if candidate.replayedText != nil {
            guard candidate.isCommittedLate,canReplaceCommittedText(snap.element) else{gate?.discardPassed();log("committed_replacement_unsupported");return}
        }
        var writable:DarwinBoolean=false
        let canSelect=testCanSelect?() ?? (AXUIElementIsAttributeSettable(snap.element,kAXSelectedTextRangeAttribute as CFString,&writable) == .success && writable.boolValue)
        guard canSelect else{log("recovery_unsupported",["reason":"selection_not_writable"]);emergencyStop("early_selection_not_writable");return}
        let claimed=passed.map{gate?.claimPassed($0) ?? false} ?? deferred.map{gate?.claimDeferred($0) ?? false} ?? (gate?.claimEarly() ?? true)
        guard claimed else{return}
        if deferred != nil{log("deferred_candidate")}
        if passed != nil{log("passed_sequence_candidate")}
        willBeginRepair()
        recoveryBegan=ProcessInfo.processInfo.systemUptime
        recoveryEpoch+=1
        recovering=true;rollingBack=false;replayStarted=false;deliveryPrefixConfirmed=false;replayCommitCaret=nil;committedReplacementAwaiting=false;committedCaretRestoring=false;currentPlan=candidate;postedBuffered=0
        bufferedBase=nextBufferedID-Int64(pending.count)
        traceSafety(.started)
        log("repair_started",["pair":candidate.roman,"text":snap.text])
        InputIncidentTrace.shared.recoveryStarted(.onset,reason:candidate.isCommittedLate ? .committedLateSequence:(candidate.codes.count>1 ? .lateSequence:.firstConsonant))
        replaceAndReplay(candidate,snap)
    }
    func replaceAndReplay(_ candidate:OnsetRecoveryPlan,_ before:OnsetSnapshot){
        guard candidate.supportsReplay || candidate.isCommittedLate else{abort("unsupported_repair_plan");return}
        guard recovering,!rollingBack,gate?.healthy() ?? true else{return}
        guard currentSource()==repairSourceID,let current=snapshot(),CFEqual(current.element,before.element) else{abort("pre_edit_context_changed");return}
        if !candidate.matches(text:current.text,selection:current.selection) {
            log("pre_edit_changed",["expected":candidate.expected ?? "","actual":current.text,"selection":[current.selection.location,current.selection.length]])
            if skipSupersededRepair(candidate,current){return}
            abort("pre_edit_mismatch");return
        }
        if candidate.supportsReplay {
            commitConsonantComposition(candidate,current)
            return
        }
        requestRepairSelection(candidate,current)
    }
    func requestRepairSelection(_ candidate:OnsetRecoveryPlan,_ current:OnsetSnapshot){
        let range=NSRange(location:candidate.caret,length:candidate.roman.utf16.count)
        selectionRequestAt=ProcessInfo.processInfo.systemUptime;selectionRetried=false
        guard setRange(current.element,range) == .success else{abort("selection_failed");return}
        log("selection_requested",["range":[range.location,range.length],"originalSelection":[current.selection.location,current.selection.length]])
        awaitSelection(candidate,current,range,remaining:75)
    }
    // An in-flight next syllable can make this repair obsolete before any key is posted.
    // Preserve the current caret/composition and release held input, without disabling monitoring.
    func skipSupersededRepair(_ candidate:OnsetRecoveryPlan,_ snap:OnsetSnapshot)->Bool {
        guard recovering,!rollingBack,!replayStarted,
              currentSource()==repairSourceID,let field=planElement,CFEqual(field,snap.element),
              let expected=candidate.expected else{return false}
        let original=expected as NSString,actual=snap.text as NSString
        let end=candidate.caret+candidate.roman.utf16.count
        let added=actual.length-original.length
        guard end>=0,end<=original.length,added>0,
              snap.selection==NSRange(location:end+added,length:0),
              actual.substring(to:end)==original.substring(to:end),
              actual.substring(from:end+added)==original.substring(from:end) else{return false}
        onset.cancel()
        log("repair_skipped_following_input",["addedUTF16":added])
        drain([])
        return true
    }
    func awaitSelection(_ candidate:OnsetRecoveryPlan,_ before:OnsetSnapshot,_ range:NSRange,remaining:Int){
        guard candidate.supportsReplay || candidate.isCommittedLate else{abort("unsupported_repair_plan");return}
        guard recovering,!rollingBack,gate?.healthy() ?? true else{return}
        guard currentSource()==repairSourceID else{abort("selection_source_changed");return}
        guard let selected=snapshot() else{
            // AX can briefly expose an intermediate role or inconsistent value/range.
            // Retry only within the original selection deadline; never use a cached field to edit.
            let transient=["not_supported_text_field","role_unreadable","focused_element_unreadable","text_unreadable","selection_unreadable","selection_invalid"].contains(unavailableReason)
            if transient,remaining>0,ProcessInfo.processInfo.systemUptime-selectionRequestAt<0.12 {
                log("selection_read_retry",["reason":unavailableReason,"remaining":remaining])
                scheduleRecovery(0.002){[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining-1)}
                return
            }
            log("selection_context_failed",["reason":unavailableReason]);abort("selection_context_changed");return
        }
        guard CFEqual(selected.element,before.element) else{abort("selection_field_changed");return}
        if selected.text != before.text {
            log("selection_text_changed",["expected":before.text,"actual":selected.text,"selection":[selected.selection.location,selected.selection.length]])
            if skipSupersededRepair(candidate,selected){return}
            abort("selection_context_changed");return
        }
        log("selection_observed",["requested":[range.location,range.length],"observed":[selected.selection.location,selected.selection.length],"remaining":remaining])
        guard selected.selection==range else{
            let elapsed=ProcessInfo.processInfo.systemUptime-selectionRequestAt
            guard elapsed<0.12 else{abort("selection_deadline");return}
            if !selectionRetried,elapsed>=0.03,selected.selection==before.selection {
                selectionRetried=true
                let result=setRange(selected.element,range)
                log("selection_retried",["result":result.rawValue,"elapsedMs":elapsed*1000])
                guard result == .success else{abort("selection_retry_rejected");return}
            }
            if remaining>0{scheduleRecovery(0.002){[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining-1)}}
            else{abort("selection_not_applied")}
            return
        }
        log("selected_replacement_started")
        if candidate.isCommittedLate {replaceCommitted(candidate,selected);return}
        replayPair(candidate)
    }

    var replayCommitCaret:NSRange?
    var deliveryPrefixConfirmed=false
    var committedReplacementAwaiting=false
    var committedReplacementDeadline=0.0
    var committedCaretRestoring=false
    var committedCaretRestoreDeadline=0.0
    var recoveryBegan=0.0
    var selectionRequestAt=0.0
    var selectionRetried=false

    func replayPair(_ candidate:OnsetRecoveryPlan){
        guard candidate.supportsReplay else{abort("unsupported_repair_plan");return}
        if let field=planElement {willReplay(field,candidate.before,candidate.caret)}
        replayStarted=true;deliveryPrefixConfirmed=false;prefixRemainder=[];lastPrefixObservation=""
        var events:[CGEvent]=[]
        for (code,shift) in candidate.codes{
            for down in [true,false]{if let event=CGEvent(keyboardEventSource:CGEventSource(stateID:.hidSystemState),virtualKey:code,keyDown:down){event.flags=shift ? .maskShift:[];events.append(event)}}
        }
        log("replay_started",["keyCount":candidate.codes.count,"pendingEvents":pending.count])
        // Replay to the IME, not a committed Hangul string, so the next consonant can join it.
        drain(events)
    }
    func prepareEvent(_ saved:CGEvent)->CGEvent? {
        let event:CGEvent
        if saved.type == .keyDown || saved.type == .keyUp {
            let code=CGKeyCode(saved.getIntegerValueField(.keyboardEventKeycode))
            guard let fresh=(code==51 ? OnsetDeletionKey.make(down:saved.type == .keyDown,marker:marker):CGEvent(keyboardEventSource:CGEventSource(stateID:.hidSystemState),virtualKey:code,keyDown:saved.type == .keyDown)) else{return nil}
            fresh.flags=saved.flags
            fresh.setIntegerValueField(.keyboardEventAutorepeat,value:saved.getIntegerValueField(.keyboardEventAutorepeat));event=fresh
        }else if saved.type == .flagsChanged {
            // Setting eventSourceUserData on a copied flagsChanged event does not
            // replace its source tag. Tag the source before creating the replay,
            // otherwise the gate can capture its own Shift release repeatedly.
            guard let source=CGEventSource(stateID:.hidSystemState) else{return nil}
            source.userData=marker
            guard let fresh=CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(saved.getIntegerValueField(.keyboardEventKeycode)),keyDown:false) else{return nil}
            fresh.type = .flagsChanged;fresh.flags=saved.flags;event=fresh
        }else{guard let copy=saved.copy() else{return nil};event=copy}
        event.setIntegerValueField(.eventSourceUserData,value:marker)
        return event
    }
    func awaitPrefix(deadline:Double,rollback:Bool){
        guard recovering,rollingBack==rollback,gate?.healthy() ?? true else{return}
        collectHeld()
        guard let candidate=currentPlan,let expected=candidate.expected,let snap=snapshot(),let field=planElement,CFEqual(snap.element,field),currentSource()==repairSourceID else{park("prefix_confirmation_context_lost");return}
        let observation="\(snap.text)|\(snap.selection)|\(gate?.seenCount() ?? -1)"
        if observation != lastPrefixObservation {
            lastPrefixObservation=observation
            log("prefix_observed",["actual":snap.text,"expected":expected,"selection":[snap.selection.location,snap.selection.length],"gateSeen":gate?.seenCount() ?? -1,"postedToGate":postedToGate])
        }
        let joined=candidate.observedReplayText ?? candidate.replayedText
        let caret=NSRange(location:candidate.caret+(joined ?? candidate.roman).utf16.count,length:0)
        let replacementReady=snap.selection==caret && (gate.map{$0.seenCount()>=postedToGate} ?? true)
        let acceptable=(joined.map{[$0]} ?? ([candidate.roman]+candidate.onsetVariants)).map{
            (candidate.before as NSString).replacingCharacters(in:NSRange(location:candidate.caret,length:0),with:$0)
        }
        if acceptable.contains(snap.text) && replacementReady {
            log("prefix_visible",["text":snap.text]);deliveryPrefixConfirmed=true
            drain([],rollback:rollback)
            return
        }
        guard ProcessInfo.processInfo.systemUptime<deadline else{park("prefix_not_visible");return}
        scheduleRecovery(0.002){[weak self] in self?.awaitPrefix(deadline:deadline,rollback:rollback)}
    }
    func drain(_ prefix:[CGEvent],rollback:Bool=false){
        guard recovering,rollingBack==rollback,gate?.healthy() ?? true else{return}
        collectHeld()
        if prefix.isEmpty,!rollback,finishQuietConfirmedDelivery(){return}
        let deliverySnapshot=snapshot()
        let deliveryField=planElement
        let sameField=deliverySnapshot.flatMap{snap in deliveryField.map{CFEqual(snap.element,$0)}} ?? false
        // Preserve the original short circuit: source is read only for the same field.
        let sameSource:Bool?=sameField ? currentSource()==repairSourceID : nil
        guard deliverySnapshot != nil,deliveryField != nil,sameField,sameSource == true else{
            traceDeliveryContext(hasSnapshot:deliverySnapshot != nil,hasPlanField:deliveryField != nil,sameField:sameField,sameSource:sameSource)
            if deliverySnapshot==nil,!rollback,canAwaitReplaySnapshot(){
                scheduleRecovery(0.002){[weak self] in self?.drain(prefix,rollback:false)};return
            }
            if rollback{park("rollback_delivery_context_changed")}else{abort("replay_target_changed")};return
        }
        // Replace the selection with the consonant first; observe it before the vowel.
        // Context was checked above; real keys remain in OnsetInputGate until drain resumes.
        if !prefix.isEmpty {
            let events=prefix.compactMap{prepareEvent($0)}
            guard events.count==prefix.count else{abort("event_allocation_failed");return}
            for (index,event) in events.enumerated(){
                prefixRemainder=Array(events.dropFirst(index))
                guard post(event) else{park("prefix_post_rejected");return}
            }
            prefixRemainder=[]
            log("prefix_posted",["events":events.count,"mode":"ordered_burst"])
            scheduleRecovery{[weak self] in self?.awaitPrefix(deadline:ProcessInfo.processInfo.systemUptime+0.15,rollback:rollback)}
            return
        }
        // Remove only the event being posted; later physical keys remain in the queue.
        if let saved=pending.first {
            guard let event=prepareEvent(saved) else{if rollback{park("event_allocation_failed")}else{abort("event_allocation_failed")};return}
            guard post(event) else{park("buffer_post_rejected");return}
            pending.removeFirst()
            postedBuffered+=1
            traceSafety(.posted)
            log("buffer_event_posted",["id":saved.getIntegerValueField(.eventSourceUserData),"code":saved.getIntegerValueField(.keyboardEventKeycode),"eventType":saved.type.rawValue,"rollback":rollback])
            scheduleRecovery(0.001){[weak self] in self?.drain([],rollback:rollback)}
            return
        }
        scheduleRecovery{[weak self] in self?.completeReplayDelivery(rollback:rollback)}
    }
    // Prefix visibility has already been proved. With no keys left to issue,
    // waiting for/closing delivery needs no current-focus check or AX read.
    func finishQuietConfirmedDelivery()->Bool {
        guard recovering,!rollingBack,deliveryPrefixConfirmed,prefixRemainder.isEmpty,gate?.healthy() ?? true else{return false}
        collectHeld()
        guard pending.isEmpty else{return false}
        scheduleRecovery{[weak self] in self?.completeReplayDelivery(rollback:false)}
        return true
    }
    func completeReplayDelivery(rollback:Bool){
        guard recovering,rollingBack==rollback else{return}
        collectHeld()
        if !pending.isEmpty{drain([],rollback:rollback);return}
        if !gateAcknowledged() {
            guard enabled,recovering else{return}
            scheduleRecovery(0.002){[weak self] in self?.completeReplayDelivery(rollback:rollback)};return
        }
        if gate?.finishIfEmpty()==false{drain([],rollback:rollback);return}
        recovering=false;rollingBack=false;replayStarted=false;currentPlan=nil;lastSource=currentSource()
        log(rollback ? "rollback_finished" : "recovery_finished",["bufferedEvents":nextBufferedID-bufferedBase,"postedEvents":postedBuffered,"pendingEvents":0,"postingIsNotAppAcknowledgment":true,"recoveryMs":(ProcessInfo.processInfo.systemUptime-recoveryBegan)*1000])
        if let snap=snapshot(){lastEditable=snap;publishPassedBaseline(snap);log("after_replay_snapshot",["text":snap.text,"source":lastSource,"selection":[snap.selection.location,snap.selection.length]])}
        else{refreshAcknowledgedPassedBaseline()}
        if rollback{
            gate?.stop();enabled=false;didStop?()
        }
        if stopAfterRollback{stopAfterRollback=false;closeSession()}
    }
    func abort(_ reason:String){
        guard recovering else{return}
        if let candidate=currentPlan,candidate.isCommittedLate,!replayStarted {cancelCommittedSelection(candidate);return}
        if rollingBack{return}
        rollingBack=true;rollbackReason=reason
        log("rollback_started",["reason":reason,"originalRoman":currentPlan?.roman ?? "","pendingEvents":pending.count])
        attemptRollback(remaining:15,requested:false)
    }
    func attemptRollback(remaining:Int,requested:Bool){
        guard recovering,rollingBack else{return}
        guard let candidate=currentPlan,let field=planElement,let snap=snapshot(),CFEqual(snap.element,field),snap.text==candidate.expected,!replayStarted else{park("rollback_context_not_intact");return}
        let caret=NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0)
        let repairRange=NSRange(location:candidate.caret,length:candidate.roman.utf16.count)
        let committedCaret=candidate.isObservedReplay && gate?.healthy()==true && replayCommitCaret==snap.selection
        guard snap.selection==caret || snap.selection==repairRange || committedCaret else{park("rollback_unexpected_selection");return}
        guard currentSource()==repairSourceID else{park("rollback_source_changed");return}
        if snap.selection==caret,currentSource()==repairSourceID {
            log("rollback_caret_verified",["selection":[caret.location,caret.length]])
            drain([],rollback:true);return
        }
        if !requested {
            let result=setRange(field,caret)
            log("rollback_caret_requested",["selection":[caret.location,caret.length],"result":result.rawValue])
            guard result == .success else{park("rollback_caret_rejected");return}
        }
        guard remaining>0 else{park("rollback_caret_timeout");return}
        scheduleRecovery(0.01){[weak self] in self?.attemptRollback(remaining:remaining-1,requested:true)}
    }
    func park(_ reason:String){
        if reason=="rollback_context_not_intact",rollbackReason=="selection_context_changed",transientReadFailure {
            pauseForContext(reason);return
        }
        parkTerminal(reason)
    }
    func parkTerminal(_ reason:String){
        traceSafety(.parked,reason:reason)
        retainPrefixRemainder()
        gate?.stop();collectHeld()
        // Keep uncertain input in memory; never inject it into a different field.
        log("pending_retained",["reason":reason,"events":pending.map{["id":$0.getIntegerValueField(.eventSourceUserData),"eventType":Int($0.type.rawValue),"code":$0.getIntegerValueField(.keyboardEventKeycode),"flags":$0.flags.rawValue]}])
        recovering=false;rollingBack=false;enabled=false;didStop?()
        if stopAfterRollback{stopAfterRollback=false;closeSession()}
    }
    @objc func stop(){
        if recovering{
            stopAfterRollback=true;abort("user_stop");return
        }
        closeSession()
    }
    func closeSession(){
        traceSafety(.sessionEnd)
        recoveryEpoch+=1;waitingForContext=false
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(axObserver),.commonModes)
        }
        axObserver=nil;observedField=nil;updateQueued=false
        gate?.stop();collectHeld();flushReentryTrace()
        enabled=false;timer?.invalidate();timer=nil
        log("session_end",["undeliveredEvents":pending.count+retainedInput.count])
    }
}
