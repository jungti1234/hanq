import AppKit
import Carbon

let onsetKoreanID="com.apple.inputmethod.Korean.2SetKorean"
struct OnsetSnapshot { let element:AXUIElement;let text:String;let selection:NSRange }
final class OnsetRecoveryEngine:NSObject {
    let marker:Int64=0x48414E5100000000 | Int64(UInt32.random(in:1...UInt32.max))
    var canBeginRepair: () -> Bool = { true }
    var willBeginRepair: () -> Void = {}
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
    var lastText:String?
    var unavailableReason=""
    var lastAvailability=""
    var postedToGate=0
    var acknowledgmentWaitBegan:Double?
    var acknowledgmentClock:()->Double = { ProcessInfo.processInfo.systemUptime }
    // Bound a missing acknowledgment independently of AX availability and the
    // input hold watchdog (pauseForContext releases that hold).
    func gateAcknowledged(now:Double?=nil)->Bool {
        guard let gate else{acknowledgmentWaitBegan=nil;return true}
        guard gate.healthy() else{emergencyStop("acknowledgment_gate_unavailable");return false}
        if gate.seenCount()>=postedToGate{acknowledgmentWaitBegan=nil;return true}
        let time=now ?? acknowledgmentClock()
        guard let began=acknowledgmentWaitBegan else{acknowledgmentWaitBegan=time;return false}
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
        guard currentLayout() != nil,let snap=snapshot(),snap.selection.length==0 else{
            resumeObservedAt=nil;resumeField=nil;return
        }
        guard let field=resumeField,CFEqual(field,snap.element),let since=resumeObservedAt else{
            resumeField=snap.element;resumeObservedAt=now;return
        }
        guard now-since>=0.1 else{return}
        waitingForContext=false;resumeObservedAt=nil;resumeField=nil
        onset.cancel();currentPlan=nil;planElement=nil
        lastEditable=snap
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
    // Only an untouched, fully delivered attempt can return directly to observation.
    // cancelHold atomically collects keys arriving while AX was blocked.
    @discardableResult func abandonUneditedReservation()->Bool {
        collectHeld();pending.append(contentsOf:gate?.cancelHold() ?? [])
        guard gate?.healthy() ?? true,!recovering,!replayStarted,pending.isEmpty,prefixRemainder.isEmpty,
              retainedInput.isEmpty,gate.map({$0.seenCount()>=postedToGate}) ?? true else {
            pauseForContext("early_field_unavailable");return false
        }
        onset.cancel();currentPlan=nil;planElement=nil
        earlyObservationTime=nil;earlyObservedField=nil;earlyWaiting=false;earlyBaseline=nil
        log("early_observation_resumed")
        return true
    }
    func sampleEarly(_ observed:OnsetSnapshot?,now:Double=ProcessInfo.processInfo.systemUptime){
        guard let gate else{return}
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
            let baseline=earlyBaseline.flatMap{CFEqual($0.element,snap.element) && $0.selection.length==0 ? $0.text:nil}
            var detector=OnsetRecoveryDetector(layout:layout)
            detector.outsideKey(code:reservation.code,shift:reservation.shift,time:reservation.time,korean:true,plain:true)
            detector.entered(time:now)
            let candidate=detector.firstConsonant(time:now,text:snap.text,selection:snap.selection,previousText:baseline)
            planElement=snap.element
            if let candidate {
                log("early_candidate",["code":reservation.code,"heldMs":(now-reservation.time)*1000])
                beginRecovery(candidate,snap)
            }else{
                let caret=baseline == nil ? nil:earlyBaseline?.selection.location
                let awaiting=detector.awaitingFirstConsonant(text:snap.text,selection:snap.selection,previousText:baseline,previousCaret:caret,code:reservation.code,shift:reservation.shift)
                // Leave 50ms inside the existing 350ms gate reservation to claim
                // and release on the next 20ms observation. Never renew its deadline.
                if awaiting,now-reservation.time<0.30 {
                    if !earlyWaiting{log("early_waiting_for_text")}
                    earlyWaiting=true;return
                }
                if earlyWaiting && !awaiting{emergencyStop("early_context_changed");return}
                // Nothing can be safely selected. Keep the app's current text and only
                // forward the original follow-up events in the same field.
                guard gate.claimEarly() else{emergencyStop("early_claim_failed");return}
                recoveryEpoch+=1;recovering=true;rollingBack=false;currentPlan=nil;replayStarted=false
                recoveryBegan=now;postedBuffered=0;bufferedBase=nextBufferedID-Int64(pending.count)
                log("early_skip",["reason":"candidate_not_exact"]);drain([])
            }
            return
        }
        earlyObservationTime=nil;earlyObservedField=nil;earlyWaiting=false
        let layout=currentLayout()
        let eligible=observed==nil && unavailableReason=="not_supported_text_field" && layout != nil
        if eligible{earlyBaseline=lastEditable}
        gate.configureEarly(eligible,sourceID:layout?.sourceID ?? "",normal:Set(layout?.normal.keys.map{$0} ?? []),shifted:Set(layout?.shifted.keys.map{$0} ?? []))
        if let snap=observed {
            if lastText != snap.text{lastText=snap.text;log("text",["text":snap.text,"selection":[snap.selection.location,snap.selection.length],"source":currentSource()])}
            lastEditable=snap
        }
    }
    var replayStarted=false
    var nextBufferedID:Int64=0
    var postedBuffered=0
    // Deterministic failure tests inject only the OS-facing operations.
    var testSnapshot:(()->OnsetSnapshot?)?
    var testCanSelect:(()->Bool)?
    var testSetRange:((AXUIElement,NSRange)->AXError)?
    var testSource:(()->String)?
    var testPost:((CGEvent)->Void)?
    func currentSource()->String { testSource?() ?? InputSourceAccess.currentID() }
    @discardableResult func post(_ event:CGEvent)->Bool {
        if gate?.healthy()==false{return false}
        if testPost == nil && (!AXIsProcessTrusted() || IsSecureEventInputEnabled()){return false}
        if event.getIntegerValueField(.keyboardEventKeycode)==51 && !OnsetDeletionKey.hasDeletePayload(event){emergencyStop("unsafe_delete_payload_blocked");return false}
        if let testPost { testPost(event) } else { postedToGate+=1;event.post(tap:.cghidEventTap) };return true }
    var lastAXFailure=""
    var accessibilityRequested=false
    var lastFocusRoute=""
    let focusAccess=InputFocusAccess()
    var systemAX:AXUIElement { focusAccess.system }
    func focusedElement(_ app:AXUIElement, pid:pid_t)->AXUIElement? {
        if let element=focusAccess.focusedElement(application:app,pid:pid){return element}
        if !accessibilityRequested,focusAccess.currentPID()==pid {
            accessibilityRequested=true
            for name in ["AXManualAccessibility","AXEnhancedUserInterface"] {
                guard AXIsProcessTrusted(),focusAccess.currentPID()==pid else{break}
                _ = AXUIElementSetAttributeValue(app,name as CFString,kCFBooleanTrue)
            }
        }
        return nil
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
    func automaticTick(){
        guard enabled else{return}
        guard AXIsProcessTrusted() else{emergencyStop("permission_revoked");return}
        gate?.beat();collectHeld()
        if waitingForContext{resumeIfReady();return}
        if recovering {
            _ = gateAcknowledged()
            guard enabled,recovering else{return}
            let observed=snapshot()
            let sameField=observed.flatMap{snap in planElement.map{CFEqual(snap.element,$0)}} ?? false
            let source=currentSource()
            guard observed != nil,sameField,source==repairSourceID else{
                log("repair_context_details",["snapshotFailure":unavailableReason,"hasSnapshot":observed != nil,"sameField":sameField,"source":source,"frontmostPID":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
                if observed==nil,transientReadFailure{pauseForContext("repair_context_lost")}else{emergencyStop("repair_context_lost")};return
            }
            gate?.beat();return
        }
        sample();gate?.beat()
    }
    func snapshot()->OnsetSnapshot?{
        if let testSnapshot{return testSnapshot()}
        unavailableReason=""
        guard AXIsProcessTrusted() else{unavailableReason="accessibility_permission";return nil}
        guard !IsSecureEventInputEnabled() else{unavailableReason="secure_input";return nil}
        guard let target,!target.isTerminated,focusAccess.currentPID()==target.processIdentifier else{unavailableReason="target_not_frontmost";return nil}
        guard let ax,let element=focusedElement(ax,pid:target.processIdentifier) else{unavailableReason="focused_element_unreadable";return nil}
        guard attr(element,kAXSubroleAttribute) as? String != "AXSecureTextField" else{unavailableReason="secure_field";return nil}
        guard let role=attr(element,kAXRoleAttribute) as? String else{unavailableReason="role_unreadable";return nil}
        guard ["AXTextArea","AXTextField"].contains(role) else{unavailableReason="not_supported_text_field";return nil}
        // Respect an editor's explicit active composition; unsupported attributes
        // remain unknown, as in the original compatibility probe.
        var markedValue: CFTypeRef?
        if !recovering,AXUIElementCopyAttributeValue(element,"AXMarkedTextRange" as CFString,&markedValue) == .success,
           let markedValue,CFGetTypeID(markedValue)==AXValueGetTypeID() {
            var marked=CFRange()
            if AXValueGetValue(markedValue as! AXValue,.cfRange,&marked),marked.location>=0,marked.length>0 {
                unavailableReason="active_composition";return nil
            }
        }
        guard let text=attr(element,kAXValueAttribute) as? String else{unavailableReason="text_unreadable";return nil}
        guard let raw=attr(element,kAXSelectedTextRangeAttribute),CFGetTypeID(raw)==AXValueGetTypeID() else{unavailableReason="selection_unreadable";return nil}
        var range=CFRange();guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0,range.location+range.length<=text.utf16.count else{unavailableReason="selection_invalid";return nil}
        guard let after=focusedElement(ax,pid:target.processIdentifier),CFEqual(element,after) else{unavailableReason="focus_changed_during_snapshot";return nil}
        if target.bundleIdentifier=="com.openai.codex",text == "\n무엇이든 요청하세요",range.length==0,range.location<=1{return OnsetSnapshot(element:element,text:"",selection:NSRange(location:0,length:0))}
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
    }
    @objc func start(){
        guard !enabled else{return}
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled() else{return}
        target=focusAccess.currentApplication()
        guard let target,OnsetRecoveryController.supports(pid:target.processIdentifier) else{return}
        ax=AXUIElementCreateApplication(target.processIdentifier);AXUIElementSetMessagingTimeout(ax!,0.05)
        AXUIElementSetMessagingTimeout(systemAX,0.05);accessibilityRequested=false;lastFocusRoute="";lastAXFailure=""
        let gate=OnsetInputGate(marker:marker);self.gate=gate;postedToGate=0
        gate.deliver={[weak self,weak gate] event in guard let self,let gate,self.gate === gate,self.enabled,!self.recovering else{return};_ = self.event(event.type,event)}
        gate.failed={[weak self,weak gate] reason in guard let self,let gate,self.gate === gate else{return};self.emergencyStop(reason)}
        gate.observationNeeded={[weak self,weak gate] in
            guard let self,let gate,self.gate === gate,self.enabled else{return}
            self.requestImmediateObservation()
        }
        gate.beat();gateThread=OnsetGateThread(gate)
        enabled=true;recovering=false;lastEditable=nil;pending=[];locked=nil;lastText=nil;lastSource=InputSourceAccess.currentID()
        log("session_start",["toolVersion":"0.1.19","build":20,"mode":"first_consonant","targetPID":target.processIdentifier,"source":lastSource])
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in self?.automaticTick()}
        gateThread?.start()
        var observer:AXObserver?
        let observerResult=AXObserverCreate(target.processIdentifier,{_,_,_,ref in
            guard let ref else{return}
            Unmanaged<OnsetRecoveryEngine>.fromOpaque(ref).takeUnretainedValue().requestImmediateObservation()
        },&observer)
        if observerResult == .success,let observer{
            axObserver=observer
            CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)
        }
        log("observer_created",["result":observerResult.rawValue])

    }
    func event(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>?{
        if OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)) || event.getIntegerValueField(.eventSourceUserData)==0x454F5448{return Unmanaged.passUnretained(event)}
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput{emergencyStop("event_tap_disabled");return Unmanaged.passUnretained(event)}
        guard enabled else{return Unmanaged.passUnretained(event)}
        requestImmediateObservation()
        return Unmanaged.passUnretained(event)
    }
    func sample(){
        guard enabled,!recovering else{return}
        if currentLayout() == nil,gate?.reservation() == nil {
            gate?.configureEarly(false);onset.cancel();planElement=nil
            lastEditable=nil;earlyBaseline=nil;lastText=nil
            return
        }
        let observed=snapshot();observeAvailability(observed)
        sampleEarly(observed)
    }

    func beginRecovery(_ candidate:OnsetRecoveryPlan,_ snap:OnsetSnapshot){
        guard canBeginRepair() else{onset.cancel();emergencyStop("manual_edit_busy");return}
        var writable:DarwinBoolean=false
        let canSelect=testCanSelect?() ?? (AXUIElementIsAttributeSettable(snap.element,kAXSelectedTextRangeAttribute as CFString,&writable) == .success && writable.boolValue)
        guard canSelect else{log("recovery_unsupported",["reason":"selection_not_writable"]);emergencyStop("early_selection_not_writable");return}
        guard gate?.claimEarly() ?? true else{return}
        willBeginRepair()
        recoveryBegan=ProcessInfo.processInfo.systemUptime
        recoveryEpoch+=1
        recovering=true;rollingBack=false;replayStarted=false;currentPlan=candidate;postedBuffered=0
        bufferedBase=nextBufferedID-Int64(pending.count)
        log("repair_started",["pair":candidate.roman,"text":snap.text])
        replaceAndReplay(candidate,snap)
    }
    func replaceAndReplay(_ candidate:OnsetRecoveryPlan,_ before:OnsetSnapshot){
        guard candidate.codes.count==1 else{abort("unsupported_repair_plan");return}
        guard recovering,!rollingBack,gate?.healthy() ?? true else{return}
        guard currentSource()==repairSourceID,let current=snapshot(),CFEqual(current.element,before.element) else{abort("pre_edit_context_changed");return}
        if !candidate.matches(text:current.text,selection:current.selection) {
            log("pre_edit_changed",["expected":candidate.expected ?? "","actual":current.text,"selection":[current.selection.location,current.selection.length]])
            if skipSupersededRepair(candidate,current){return}
            abort("pre_edit_mismatch");return
        }
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
        guard candidate.codes.count==1 else{abort("unsupported_repair_plan");return}
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
        replayPair(candidate)
    }

    var recoveryBegan=0.0
    var selectionRequestAt=0.0
    var selectionRetried=false

    func replayPair(_ candidate:OnsetRecoveryPlan){
        replayStarted=true;prefixRemainder=[];lastPrefixObservation=""
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
        let caret=NSRange(location:candidate.caret+(expected.utf16.count-candidate.before.utf16.count),length:0)
        let replacementReady=snap.selection==caret && (gate.map{$0.seenCount()>=postedToGate} ?? true)
        let acceptable=([candidate.roman]+candidate.onsetVariants).map{
            (candidate.before as NSString).replacingCharacters(in:NSRange(location:candidate.caret,length:0),with:$0)
        }
        if acceptable.contains(snap.text) && replacementReady {
            log("prefix_visible",["text":snap.text])
            drain([],rollback:rollback)
            return
        }
        guard ProcessInfo.processInfo.systemUptime<deadline else{park("prefix_not_visible");return}
        scheduleRecovery(0.002){[weak self] in self?.awaitPrefix(deadline:deadline,rollback:rollback)}
    }
    func drain(_ prefix:[CGEvent],rollback:Bool=false){
        guard recovering,rollingBack==rollback,gate?.healthy() ?? true else{return}
        collectHeld()
        guard let snap=snapshot(),let field=planElement,CFEqual(snap.element,field),currentSource()==repairSourceID else{
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
            log("buffer_event_posted",["id":saved.getIntegerValueField(.eventSourceUserData),"code":saved.getIntegerValueField(.keyboardEventKeycode),"eventType":saved.type.rawValue,"rollback":rollback])
            scheduleRecovery(0.001){[weak self] in self?.drain([],rollback:rollback)}
            return
        }
        scheduleRecovery{[weak self] in
            guard let self,self.recovering,self.rollingBack==rollback else{return}
            self.collectHeld()
            if !self.pending.isEmpty{self.drain([],rollback:rollback);return}
            if !self.gateAcknowledged() {
                guard self.enabled,self.recovering else{return}
                self.scheduleRecovery(0.002){[weak self] in self?.drain([],rollback:rollback)};return
            }
            if self.gate?.finishIfEmpty()==false{self.drain([],rollback:rollback);return}
            self.recovering=false;self.rollingBack=false;self.replayStarted=false;self.currentPlan=nil;self.lastSource=self.currentSource()
            self.log(rollback ? "rollback_finished" : "recovery_finished",["bufferedEvents":self.nextBufferedID-self.bufferedBase,"postedEvents":self.postedBuffered,"pendingEvents":0,"postingIsNotAppAcknowledgment":true,"recoveryMs":(ProcessInfo.processInfo.systemUptime-self.recoveryBegan)*1000])
            if let snap=self.snapshot(){self.log("after_replay_snapshot",["text":snap.text,"source":self.lastSource,"selection":[snap.selection.location,snap.selection.length]])}
            if rollback{
                self.gate?.stop();self.enabled=false;self.didStop?()
            }
            if self.stopAfterRollback{self.stopAfterRollback=false;self.closeSession()}
        }
    }
    func abort(_ reason:String){
        guard recovering else{return}
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
        guard snap.selection==caret || snap.selection==repairRange else{park("rollback_unexpected_selection");return}
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
        recoveryEpoch+=1;waitingForContext=false
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(axObserver),.commonModes)
        }
        axObserver=nil;observedField=nil;updateQueued=false
        gate?.stop();collectHeld()
        enabled=false;timer?.invalidate();timer=nil
        log("session_end",["undeliveredEvents":pending.count+retainedInput.count])
    }
}
