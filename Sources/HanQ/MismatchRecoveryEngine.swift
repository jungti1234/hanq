import AppKit
import Carbon

let mismatchKoreanID="com.apple.inputmethod.Korean.2SetKorean"
struct MismatchSnapshot { let element:AXUIElement;let text:String;let selection:NSRange;var selectedText:String?=nil;var incidentAX:InputIncidentAXEvidence?=nil;var incidentWindow:AXUIElement?=nil;var incidentGeneration:Int32?=nil }
final class MismatchRecoveryEngine:NSObject {
    var sourceEvidence:MismatchSourceEvidence?
    private var deferredCandidateEpoch:Int?
    var incidentTrace=InputIncidentTrace.shared
    let detectionOnly:Bool
    init(detectionOnly:Bool=false){self.detectionOnly=detectionOnly;super.init()}
    var detectionCount=0
    func reportMismatch(_ candidate:MismatchRecoveryPlan,_ snap:MismatchSnapshot){
        detectionCount+=1
        log(detectionOnly ? "mismatch_detected_only":"mismatch_notice",["text":snap.text,"physicalKeys":candidate.replayRoman,"caret":candidate.caret,"count":detectionCount])
        plan=nil
    }
    let marker:Int64=0x48414E514155544F
    var enabled=false
    var target:NSRunningApplication?
    var followsFrontmost=false
    var activationPID:pid_t?
    func followFrontmost(event:CGEvent?=nil){
        guard followsFrontmost else{return}
        // Recovery callbacks must not perform synchronous AX requests. The
        // worker verifies actual panel/field focus before each edit and replay.
        if recovering {
            if !fastRecoveryContext(){park("frontmost_app_changed")}
            return
        }
        let front:NSRunningApplication?
        if let event {
            // Quartz already chose this event's recipient, including a
            // nonactivating panel. Discovering it again with synchronous AX
            // can stall the very input the client needs before answering AX.
            // This selects an observation target only: snapshots still prove
            // actual focus, body and selection before detection/edit/replay.
            let raw=event.getIntegerValueField(.eventTargetUnixProcessID)
            if let pid=pid_t(exactly:raw),pid>0 {
                front=InputFocusAccess.application(pid:pid,reusing:target)
            }else{
                // Some producers omit the recipient. Preserve actual-focus
                // discovery there so the first key in a new app is observable.
                front=focusAccess.currentApplication(reusing:target)
            }
        }else{front=focusAccess.currentApplication(reusing:target)}
        let next=Self.supports(front) ? front:nil
        switchTarget(to:next)
    }
    func switchTarget(to next:NSRunningApplication?){
        guard next?.processIdentifier != target?.processIdentifier else{return}
        if recovering{park("frontmost_app_changed")}
        recoveryEpoch+=1;plan=nil;planElement=nil;locked=nil;lastText=nil;heldKeys=[]
        activationPID=NSWorkspace.shared.frontmostApplication?.processIdentifier
        target=next;ax=next.map{AXUIElementCreateApplication($0.processIdentifier)}
        if let ax{AXUIElementSetMessagingTimeout(ax,0.05)}
        focusErrors=[:];focusRoute=""
        log("target_app_changed",["pid":next?.processIdentifier ?? 0,"bundleID":next?.bundleIdentifier ?? "","name":next?.localizedName ?? ""])
    }
    var ax:AXUIElement?
    var locked:AXUIElement?
    var tap:CFMachPort?
    var switchGate:MismatchSwitchGate?
    var recoverySourceID=mismatchKoreanID
    var intendedSource=mismatchKoreanID
    var pendingSources:[Int64:String]=[:]
    var pendingTimestamps:[Int64:CGEventTimestamp]=[:]
    // Queue identity must not depend on mutable CGEvent source user data.
    var bufferedIdentities:[ObjectIdentifier:Int64]=[:]
    func bufferedID(_ event:CGEvent)->Int64 { bufferedIdentities[ObjectIdentifier(event)] ?? event.getIntegerValueField(.eventSourceUserData) }
    var keyDownSources:[Int64:String]=[:]
    struct EventOrigin {let timestamp:CGEventTimestamp;let source:String?;let code:Int64;let type:CGEventType}
    private var eventOrigins:[Int64:EventOrigin]=[:]
    private var nextOrigin:Int64=0
    var willForwardEvent:(CGEventType,CGEvent)->Void = {_,_ in}
    @discardableResult func captureEventOrigin(_ type:CGEventType,_ event:CGEvent,at capturedTimestamp:CGEventTimestamp?=nil)->Int64? {
        let timestamp=capturedTimestamp ?? event.timestamp
        if recovering{observeRecoverySource(currentSource(),at:timestamp)}
        let incoming=event.getIntegerValueField(.eventSourceUserData)
        guard type == .keyDown || type == .keyUp || type == .flagsChanged,
              incoming==0 || InputDeliveryOrigin.isMarker(incoming) else{return nil}
        willForwardEvent(type,event)
        nextOrigin+=1
        let token=InputDeliveryOrigin.isMarker(incoming) ? incoming:(0x4851455600000000 | nextOrigin)
        eventOrigins[token]=EventOrigin(timestamp:timestamp,source:recovering ? intendedSource:nil,code:event.getIntegerValueField(.keyboardEventKeycode),type:type)
        if eventOrigins.count>1024 {eventOrigins=Dictionary(uniqueKeysWithValues:eventOrigins.sorted{$0.value.timestamp>$1.value.timestamp}.prefix(512).map{($0.key,$0.value)})}
        event.setIntegerValueField(.eventSourceUserData,value:token)
        return token
    }
    // Normal right Command is consumed at the main tap, so the mismatch tap
    // will never retire its origin. Take the HID boundary once, before an async
    // source selection; session retiming must not move it past following keys.
    func takeSourceSwitchTimestamp(_ type:CGEventType,_ event:CGEvent)->CGEventTimestamp {
        guard let original=origin(type,event) else{return event.timestamp}
        eventOrigins.removeValue(forKey:event.getIntegerValueField(.eventSourceUserData))
        return original.timestamp
    }
    func discardEventOrigin(_ token:Int64){eventOrigins.removeValue(forKey:token)}
    private func origin(_ type:CGEventType,_ event:CGEvent)->EventOrigin? {
        guard let value=eventOrigins[event.getIntegerValueField(.eventSourceUserData)],value.code==event.getIntegerValueField(.keyboardEventKeycode),value.type==type else{return nil}
        return value
    }
    var lastUserSourceSwitchTimestamp:CGEventTimestamp=0
    var recoverySourceBoundaries:[(timestamp:CGEventTimestamp,source:String)]=[]
    func noteUserSourceSwitch(at timestamp:CGEventTimestamp) {
        guard timestamp>0 else{return}
        lastUserSourceSwitchTimestamp=max(lastUserSourceSwitchTimestamp,timestamp)
        if !recovering{cancelDetection()}
    }
    func intendedSource(at timestamp:CGEventTimestamp)->String {
        guard timestamp>0,!recoverySourceBoundaries.isEmpty else{return intendedSource}
        return recoverySourceBoundaries.last(where:{$0.timestamp<=timestamp})?.source ?? recoverySourceID
    }
    // Caps source acknowledgement can arrive after later physical keys have
    // already been queued. Reassign only undelivered keys from the proved raw
    // boundary, keeping releases paired with their original press.
    func applyConfirmedCapsBoundary(at timestamp:CGEventTimestamp) {
        guard timestamp>0 else{return}
        for (token,value) in eventOrigins where value.type == .keyDown && value.timestamp>=timestamp {
            eventOrigins[token]=EventOrigin(timestamp:value.timestamp,source:intendedSource(at:value.timestamp),code:value.code,type:value.type)
        }
        var presses:[Int64:String]=[:]
        for event in pending {
            let id=bufferedID(event),code=event.getIntegerValueField(.keyboardEventKeycode)
            if event.type == .keyDown {
                let time=pendingTimestamps[id] ?? 0
                if time>=timestamp{pendingSources[id]=intendedSource(at:time)}
                if let source=pendingSources[id] {
                    presses[code]=source
                    if keyDownSources[code] != nil{keyDownSources[code]=source}
                }
            }else if event.type == .keyUp,let source=presses.removeValue(forKey:code) {
                pendingSources[id]=source
            }
        }
    }
    func userToggleDuringRecovery(at timestamp:CGEventTimestamp=0){
        guard recovering else{return}
        noteUserSourceSwitch(at:timestamp)
        setUserSourceIntent(toggledUserSource(intendedSource),at:timestamp)
        cancelExternalSourceSettlement();resumeDeferredSourceWork()
        log("user_source_boundary",["source":intendedSource,"afterBufferedID":nextBufferedID,"origin":"right_command"])
    }
    var runSource:CFRunLoopSource?
    var timer:Timer?
    var lastSource=""
    var englishID="com.apple.keylayout.ABC"
    var plan:MismatchRecoveryPlan?
    var planElement:AXUIElement?
    var planStart=0.0
    var verifiedDeliveryHistory:((MismatchSnapshot,Bool)->(plan:MismatchRecoveryPlan,lastKeyAt:Double)?)?
    var recovering=false
    var pending:[CGEvent]=[]
    var retained:[CGEvent]=[]
    // This deadline measures lack of confirmed progress, not total typing time.
    var recoveryDeadline=Double.greatestFiniteMagnitude
    var verifiedProgressEvents = -1
    func confirmDeliveryProgress(_ count:Int,now:Double=ProcessInfo.processInfo.systemUptime){
        guard recovering,!rollingBack,count>verifiedProgressEvents else{return}
        verifiedProgressEvents=count
        recoveryDeadline=now+2.5
        log("delivery_progress_confirmed",["postedEvents":count,"idleBudgetMs":2500])
    }
    var recoveryEpoch=0
    let traceLatency=false
    // Yield back to key delivery promptly when a busy editor cannot answer a
    // focus query during recovery. Detection, text reads and mutations retain
    // their existing timeout; a short detection timeout can lose the first mismatch.
    let focusQueryTimeout:Float=0.05
    var traceSequence=0
    var activeSnapshotID=0
    var lastCompletedSnapshotID=0
    var snapshotStage="other"
    func later(_ delay:Double,_ action:@escaping ()->Void,line:UInt=#line){
        let epoch=recoveryEpoch,scheduled=ProcessInfo.processInfo.systemUptime
        traceSequence+=1;let id=traceSequence
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak self] in
            guard let self else{return}
            let start=ProcessInfo.processInfo.systemUptime
            if self.traceLatency{self.log("callback_started",["id":id,"line":line,"scheduledUptime":scheduled,"dueUptime":scheduled+delay,"startUptime":start,"lateMs":max(0,(start-scheduled-delay)*1000),"cancelled":self.recoveryEpoch != epoch])}
            guard self.recoveryEpoch==epoch else{return}
            if self.sourceWorkPaused{self.deferRecovery(action);return}
            action()
            if self.traceLatency{self.log("callback_finished",["id":id,"line":line,"durationMs":(ProcessInfo.processInfo.systemUptime-start)*1000])}
        }
    }
    var currentPlan:MismatchRecoveryPlan?
    private var incidentShapeProbe=InputIncidentShapeProbe()
    var lastText:String?
    var lastSampleSnapshot:MismatchSnapshot?
    var unavailableReason=""
    var lastAvailability=""
    var started=0.0
    var replayCount=0
    var rollingBack=false
    var rollbackReason=""
    var stopAfterRollback=false
    var replayStarted=false
    var replayIssuedAt=0.0
    var lastRomanReplayDelayMs:Double?
    var koreanRetries=0
    var interruptedSourceRestores=0
    var nextBufferedID:Int64=0
    var postedBuffered=0
    // Deterministic failure tests inject only the OS-facing operations.
    var testSnapshot:(()->MismatchSnapshot?)?
    var testSetRange:((AXUIElement,NSRange)->AXError)?
    var testSource:(()->String)?
    var testSelectSource:((String)->OSStatus)?
    var testSelectionWritable:((AXUIElement)->Bool)?
    var testPost:((CGEvent)->Void)?
    var testPostAtTap:((CGEvent,CGEventTapLocation)->Void)?
    func currentSource()->String { testSource?() ?? InputSourceAccess.currentID() }
    let systemSwitch=MismatchSourceSwitch()
    let activationShortcut=MismatchActivationShortcut()
    var testActivationNeeded:(()->Bool)?
    var activationFallbackTried=false
    var capsSwitchEnabled:()->Bool = {false}
    var observeSourcesForTests=false
    var interactionNow:()->Double = {ProcessInfo.processInfo.systemUptime}
    var capsSourceInteraction:(actual:String,intended:String,timestamp:CGEventTimestamp,until:Double)?
    var sourceMenuPaused=false
    var sourceMenuSawPopup=false
    // A system menu can leave the editor PID on its closing key. Preserve the
    // press/release pair even if recovery resumes between those two events.
    var passedSourceMenuKeys=Set<Int64>()
    var sourceMenuPopupVisible:()->Bool = {MismatchSwitchGate.menuPopupVisible()}
    var testEventRecipient:((CGEvent)->pid_t?)?
    var sourcePauseStarted:Double?
    var pausedRecoveryActions:[()->Void]=[]
    var sourceInteractionRevision=0
    var externalSourceSettlement:(started:Double,changed:Double,changes:Int)?
    var sourceSettlementRevision=0
    var lastIntendedKorean=mismatchKoreanID
    var sourceWorkPaused:Bool {sourceMenuPaused || capsSourceInteraction != nil || externalSourceSettlement != nil}
    var ledger:MismatchReplayLedger?
    var ledgerAfterRepair:MismatchReplayLedger?
    var snapshotWaitStarted:Double?
    func chooseSource(_ id:String)->OSStatus {
        guard !detectionOnly else{return -50}
        if testSelectSource == nil,currentSource()==id{return noErr}
        guard supportsRecoverySource(id) else{return -50}
        let result=systemSwitch.request(id,valid:{[weak self] in
            guard let self,self.recovering else{return false}
            if self.testSelectSource != nil{return true}
            return self.fastRecoveryContext()
        },current:currentSource,select:testSelectSource ?? InputSourceAccess.select)
        log("system_source_requested",["target":id,"result":result,"method":"explicit_source_api"])
        return result
    }
    // Preserve the baseline for same-build A/B tests.
    var perKeyAX = false
    var testFastContext:(()->Bool)?
    func fastRecoveryContext()->Bool {
        if let testFastContext{return testFastContext()}
        if testSnapshot != nil{return true}
        return AXIsProcessTrusted() && !IsSecureEventInputEnabled() && target?.isTerminated==false &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier==activationPID
    }
    var detectionRevision=0
    var idleSnapshotRequest:Int?
    var idleSnapshotSequence=0
    var testIdleRead:((@escaping (MismatchSnapshotResult)->Void)->Void)?
    let snapshotWorker=MismatchSnapshotWorker()
    var asyncRecoveryReads = true
    var asyncRequest:(id:Int,epoch:Int,stage:String)?
    var asyncReady:(epoch:Int,stage:String,result:MismatchSnapshotResult)?
    var testAsyncRead:((@escaping (MismatchSnapshotResult)->Void)->Void)?
    func requestRecoverySnapshot(_ stage:String,retry:@escaping ()->Void) {
        if sourceWorkPaused{deferRecovery(retry);return}
        if let request=asyncRequest,request.epoch==recoveryEpoch{return}
        traceSequence+=1
        let id=traceSequence,epoch=recoveryEpoch,pid=target?.processIdentifier ?? 0
        asyncRequest=(id,epoch,stage)
        if traceLatency{log("async_snapshot_started",["id":id,"stage":stage])}
        let completion:(MismatchSnapshotResult)->Void = {[weak self] result in
            guard let self,self.recovering,self.recoveryEpoch==epoch,self.asyncRequest?.id==id else{return}
            self.asyncRequest=nil
            if self.sourceWorkPaused{self.asyncReady=nil;self.deferRecovery(retry);return}
            if self.traceLatency{self.log("async_snapshot_finished",["id":id,"stage":stage,"durationMs":result.durationMs,"focusMs":result.focusMs,"attributesMs":result.attributesMs,"deliveryDelayMs":(ProcessInfo.processInfo.systemUptime-result.completedAt)*1000,"reason":result.reason])}
            guard self.fastRecoveryContext() else{self.park(stage+"_unsafe_context");return}
            guard ProcessInfo.processInfo.systemUptime<self.recoveryDeadline else{self.park(stage+"_deadline");return}
            guard ProcessInfo.processInfo.systemUptime-result.completedAt<0.05 else{
                self.log("async_snapshot_discarded",["reason":"stale_delivery","stage":stage])
                self.later(0.001,retry);return
            }
            self.lastCompletedSnapshotID=id
            self.asyncReady=(epoch,stage,result)
            retry()
        }
        if let testAsyncRead{testAsyncRead(completion)}else{snapshotWorker.request(pid:pid,completion:completion)}
    }
    func recoverySnapshot(_ stage:String,retry:@escaping ()->Void)->MismatchSnapshot? {
        if sourceWorkPaused{deferRecovery(retry);return nil}
        let previousStage=snapshotStage;snapshotStage=stage
        defer{snapshotStage=previousStage}
        guard ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park(stage+"_deadline");return nil}
        let observed:MismatchSnapshot?
        if asyncRecoveryReads && (testSnapshot==nil || testAsyncRead != nil) {
            guard fastRecoveryContext() else{park(stage+"_unsafe_context");return nil}
            if let ready=asyncReady,ready.epoch==recoveryEpoch,ready.stage==stage {
                asyncReady=nil;unavailableReason=ready.result.reason;observed=ready.result.snapshot
            }else{
                asyncReady=nil;requestRecoverySnapshot(stage,retry:retry);return nil
            }
        }else{observed=snapshot()}
        if let snap=observed{
            snapshotWaitStarted=nil
            guard let field=planElement,CFEqual(snap.element,field) else{park(stage+"_field_changed");return nil}
            return snap
        }
        if ["target_not_frontmost","secure_input","secure_text_field","not_supported_text_field","accessibility_permission","focus_changed_during_snapshot"].contains(unavailableReason){park(stage+"_"+unavailableReason);return nil}
        let now=ProcessInfo.processInfo.systemUptime
        if snapshotWaitStarted==nil{snapshotWaitStarted=now;log("snapshot_retry_started",["stage":stage,"reason":unavailableReason])}
        guard now-(snapshotWaitStarted ?? now)<0.75,now<recoveryDeadline else{park(stage+"_snapshot_timeout");return nil}
        later(0.01,retry);return nil
    }
    func post(_ event:CGEvent,at tap:CGEventTapLocation = .cgSessionEventTap) {
        guard !detectionOnly else{return}
        // Keep queued keys on the successful final retry's route so vowels and
        // final consonants can continue its live IME composition.
        let route=tap == .cgSessionEventTap && recovering && !rollingBack && replayStarted && koreanRetries==2
            ? CGEventTapLocation.cghidEventTap:tap
        log("key_post_requested",["eventType":event.type.rawValue])
        if let testPostAtTap {testPostAtTap(event,route)}
        else if let testPost {testPost(event)}
        else {event.post(tap:route)}
    }
    private let incidentFocusProbe=InputIncidentFocusProbe()
    let focusAccess=InputFocusAccess()
    var systemAX:AXUIElement { focusAccess.system }
    var focusErrors:[String:String]=[:]
    var focusRoute=""
    var testFocusedRead:((AXUIElement)->AXUIElement?)?
    var heldKeys=Set<Int64>()
    // Key-downs delivered before recovery must not look held to the editor
    // while AX/source work queues subsequent typing.
    var deliveredHeldKeys=Set<Int64>()
    var queuedSelectAll=false
    var queuedSelectAllText:String?
    var selectAllReleases=0
    static func isSelectAll(_ event:CGEvent)->Bool {
        event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode)==0 &&
        event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift]) == .maskCommand
    }

    func attr(_ element:AXUIElement,_ name:String)->CFTypeRef?{var value:CFTypeRef?;guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else{return nil};return value}
    func focusedElement(_ application:AXUIElement,pid:pid_t)->AXUIElement? {
        focusAccess.read=testFocusedRead ?? InputFocusAccess.readFocused
        return focusAccess.focusedElement(application:application,pid:pid)
    }
    // Combo editors are admitted only by the explicit selection/source boundary.
    // They must pass all content, range, coordinate and focus checks below.
    static func supportsSnapshotRole(_ role:String,includeContent:Bool,allowComboBox:Bool)->Bool {
        ["AXTextArea","AXTextField"].contains(role) || (allowComboBox && includeContent && role=="AXComboBox")
    }
    func snapshot(includeContent:Bool=true,allowComboBox:Bool=false)->MismatchSnapshot?{
        let incidentRead=InputIncidentTrace.shared.beginRead(.mismatchAX)
        var incidentMeasured=false
        let incidentGeneration=InputIncidentTrace.shared.collectionGeneration
        var focusRead:InputIncidentFocusProbe.Read?
        let oldFocusObserver=focusAccess.observeFocus
        defer{
            focusAccess.observeFocus=oldFocusObserver
            let allowed=incidentMeasured && !["secure_input","secure_field","secure_text_field","accessibility_permission"].contains(unavailableReason)
            let focus=incidentFocusProbe.finish(allowed ? focusRead:nil,generation:incidentGeneration,path:2)
            InputIncidentTrace.shared.endRead(.mismatchAX,incidentRead,outcome:incidentMeasured ? .snapshot(unavailableReason,includesContent:includeContent):nil,focus:focus)
        }
        let queryStart=ProcessInfo.processInfo.systemUptime,previousID=activeSnapshotID
        traceSequence+=1;let id=traceSequence;activeSnapshotID=id
        if traceLatency{log("snapshot_started",["id":id,"stage":snapshotStage,"includeContent":includeContent,"uptime":queryStart])}
        defer{
            if traceLatency{log("snapshot_finished",["id":id,"stage":snapshotStage,"includeContent":includeContent,"durationMs":(ProcessInfo.processInfo.systemUptime-queryStart)*1000,"unavailableReason":unavailableReason])}
            activeSnapshotID=previousID
            lastCompletedSnapshotID=id
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
        guard focusAccess.currentPID()==target.processIdentifier else{unavailableReason="target_not_frontmost";return nil}
        guard let ax,let element=focusedElement(ax,pid:target.processIdentifier) else{unavailableReason="focused_element_unreadable";return nil}
        // Fetch one coherent attribute batch instead of four synchronous IPCs.
        let names=(includeContent ? [kAXRoleAttribute,kAXSubroleAttribute,kAXValueAttribute,kAXSelectedTextRangeAttribute] : [kAXRoleAttribute,kAXSubroleAttribute]) as CFArray
        var values:CFArray?
        let began=ProcessInfo.processInfo.systemUptime
        if traceLatency{log("attributes_query_started",["snapshotID":id,"includeContent":includeContent,"uptime":began])}
        let result=AXUIElementCopyMultipleAttributeValues(element,names,[],&values)
        let duration=(ProcessInfo.processInfo.systemUptime-began)*1000
        if traceLatency{log("attributes_query_finished",["snapshotID":id,"durationMs":duration,"result":result.rawValue])}
        if duration>5{log("snapshot_batch_latency",["ms":duration,"result":result.rawValue])}
        guard result == .success,let list=values as? [AnyObject],list.count==(includeContent ? 4:2) else{unavailableReason="attribute_batch_unreadable";return nil}
        if incidentMeasured {focusRead?.observedRole(list[0] as? String)}
        guard let role=list[0] as? String else{unavailableReason="role_unreadable";return nil}
        guard Self.supportsSnapshotRole(role,includeContent:includeContent,allowComboBox:allowComboBox) else{unavailableReason="not_supported_text_field";return nil}
        guard list[1] as? String != "AXSecureTextField" else{unavailableReason="secure_text_field";return nil}
        if !includeContent{return MismatchSnapshot(element:element,text:"",selection:NSRange(location:0,length:0))}
        guard let text=MismatchTextReader.value(element,batchValue:list[2]) else{unavailableReason="text_unreadable";return nil}
        let raw=list[3]
        guard CFGetTypeID(raw)==AXValueGetTypeID() else{unavailableReason="selection_unreadable";return nil}
        var range=CFRange();guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0,range.location+range.length<=text.utf16.count else{unavailableReason="selection_invalid";return nil}
        let selection=NSRange(location:range.location,length:range.length)
        guard let content=MismatchTextReader.read(element,value:text,selection:selection) else{unavailableReason="editor_coordinates_unverified";return nil}
        guard let after=focusedElement(ax,pid:target.processIdentifier),CFEqual(element,after) else{unavailableReason="focus_changed_during_snapshot";return nil}
        return MismatchSnapshot(element:element,text:content.text,selection:selection,selectedText:content.selectedText)
    }
    func observeAvailability(_ snap:MismatchSnapshot?){
        let availability=snap == nil ? unavailableReason : "tracking"
        if availability != lastAvailability {
            let states=["tracking","target_not_frontmost","secure_input","secure_text_field","not_supported_text_field","accessibility_permission","focused_element_unreadable","attribute_batch_unreadable","role_unreadable","text_unreadable","selection_unreadable","selection_invalid","editor_coordinates_unverified","focus_changed_during_snapshot"]
            InputDiagnostics.shared.record("mismatch.observation_state reasonCode=\(states.firstIndex(of:availability).map{$0+1} ?? 0)")
            log("tracking_state",["state":availability])
            lastAvailability=availability
        }
        guard let snap else{
            let retryable=unavailableReason=="editor_coordinates_unverified" &&
                currentSource()==(plan?.sourceID ?? recoverySourceID) && planElement != nil &&
                ProcessInfo.processInfo.systemUptime-planStart<=0.2
            if !retryable {plan=nil;heldKeys=[]}
            if retryable && plan != nil {log("candidate_read_retry",["ageMs":(ProcessInfo.processInfo.systemUptime-planStart)*1000])}
            return
        }
        if locked == nil || !CFEqual(locked!,snap.element){
            log("field_changed",["previousFieldExisted":locked != nil,"source":InputSourceAccess.currentID(),"text":snap.text,"selection":[snap.selection.location,snap.selection.length]])
            locked=snap.element;plan=nil;planElement=nil;heldKeys=[];lastText=nil
            // A new composer is a new transaction boundary. Never reuse the old field's repair range.
            lastSource=InputSourceAccess.currentID()
        }
    }
    func setRange(_ element:AXUIElement,_ range:NSRange)->AXError{guard !detectionOnly else{return .cannotComplete};if let testSetRange{return testSetRange(element,range)};var cf=CFRange(location:range.location,length:range.length);return AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&cf)!)}
    func sourceChanged(_ now:String,_ snap:MismatchSnapshot){
        guard now != lastSource else{return}
        let previous=lastSource;lastSource=now;log("source_change",["from":previous,"to":now])
        plan=nil
        if previous.hasPrefix("com.apple.keylayout."){englishID=previous}

    }
    var didStart:()->Void = {}
    var didProcessEvent:(CGEventType,CGEvent,Bool)->Void = {_,_,_ in}
    func event(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>?{
        let token=event.getIntegerValueField(.eventSourceUserData),tracked=origin(type,event) != nil
        let result=processEvent(type,event)
        didProcessEvent(type,event,result != nil)
        // Consume source intent once, but keep the original-input identity for
        // a downstream onset receipt. Quartz may retimestamp between taps.
        // Tag cleanup is deferred until the final annotated boundary.
        if tracked {eventOrigins.removeValue(forKey:token)}
        return result
    }
    // This engine repairs Korean input only. Avoid AX work for ordinary Roman
    // input, while keeping an active repair (which temporarily uses English)
    // on its full verification path.
    func skipRomanObservation(site:InputIncidentTrace.DecisionSite = .sample,event:CGEvent?=nil)->Bool {
        guard !recovering else{return false}
        let source=currentSource()
        if let evidence=sourceEvidence {
            if let saved=deferredCandidateEpoch,!evidence.retains(saved) {
                plan=nil;planElement=nil;lastSampleSnapshot=nil;deferredCandidateEpoch=nil
                incidentTrace.sourceEvidence(.rejected,evidence.diagnostic(selected:source),event:event)
            }
            if evidence.deferredSource(for:source) != nil {
                if plan != nil {deferredCandidateEpoch=evidence.epoch}
                if source.hasPrefix("com.apple.keylayout."){incidentTrace.decision(site,.romanSource,event:event)}
                // Keep only verified history/candidates. New physical keys are
                // observed by the barrier, in an explicitly deferred interval.
                incidentTrace.sourceEvidence(.deferred,evidence.diagnostic(selected:source,candidate:plan != nil),event:event)
                return true
            }
            if let saved=deferredCandidateEpoch {
                let valid=evidence.permitsHistory(saved)
                if !valid{plan=nil;planElement=nil;lastSampleSnapshot=nil}
                deferredCandidateEpoch=nil
                incidentTrace.sourceEvidence(valid ? .resumed:.rejected,evidence.diagnostic(selected:source,candidate:valid && plan != nil),event:event)
            }
            if source.hasPrefix("com.apple.keylayout.") {
                incidentTrace.sourceEvidence(.romanSkipped,evidence.diagnostic(selected:source),event:event)
            }
        }
        guard source.hasPrefix("com.apple.keylayout.") else{return false}
        incidentTrace.decision(site,.romanSource,event:event)
        plan=nil;planElement=nil;lastSampleSnapshot=nil
        lastSource=source;englishID=source
        return true
    }
    private func processEvent(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>?{
        if !recovering{sourceEvidence?.observeInteraction(type,event)}
        if type == .keyDown || type == .keyUp {log("key_received")}
        detectionRevision+=1
        if recovering{observeRecoverySource(currentSource(),at:event.timestamp)}
        let handlerStart=ProcessInfo.processInfo.systemUptime
        let beganRecovering=recovering
        defer{if traceLatency{log("event_handler_finished",["eventType":type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode),"beganRecovering":beganRecovering,"isProbeEvent":event.getIntegerValueField(.eventSourceUserData)==marker,"durationMs":(ProcessInfo.processInfo.systemUptime-handlerStart)*1000])}}
        if !OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)),event.getIntegerValueField(.eventSourceUserData) != SyntheticInputMarker.manualEdit {
            if type == .keyUp,passedSourceMenuKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil{return Unmanaged.passUnretained(event)}
            if type == .keyDown,passedSourceMenuKeys.contains(event.getIntegerValueField(.keyboardEventKeycode)){return Unmanaged.passUnretained(event)}
        }
        if enabled,!suspended,type != .tapDisabledByTimeout,type != .tapDisabledByUserInput,
           !OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)),
           event.getIntegerValueField(.eventSourceUserData) != SyntheticInputMarker.manualEdit,skipRomanObservation(site:.event,event:event){
            // Skipping Korean detection must not forget a press already passed
            // to the editor, or a later repair could delay its physical release.
            let code=event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown{heldKeys.insert(code)}
            if type == .keyUp{heldKeys.remove(code)}
            return Unmanaged.passUnretained(event)
        }
        if enabled{followFrontmost(event:event)}
        if OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)) || event.getIntegerValueField(.eventSourceUserData)==SyntheticInputMarker.manualEdit{return Unmanaged.passUnretained(event)}
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            InputDiagnostics.shared.record("mismatch.tap_disabled kind=1 type=\(type.rawValue)")
            monitorTapFailed(1)
            return Unmanaged.passUnretained(event)
        }
        guard enabled,!suspended else{return Unmanaged.passUnretained(event)}
        guard canObserve() else{
            incidentTrace.decision(.event,.observationBlocked,event:event)
            log("observation_blocked")
            if recovering{park("another_edit_started")}else{cancelDetection()}
            return Unmanaged.passUnretained(event)
        }
        let keyboard=type == .keyDown || type == .keyUp || type == .flagsChanged
        var sampled:MismatchSnapshot?
        // Observe the previous key's actual insertion before allowing the next
        // printable key through. Start the queue at the first confirmed mismatch.
        let original=origin(type,event),timestamp=original?.timestamp ?? event.timestamp
        if !recovering,timestamp>0,timestamp<=lastUserSourceSwitchTimestamp,
           type == .keyDown || type == .keyUp {
            // A normal switch can reach the main tap before older printable
            // events reach this observer. Never classify those older keys using
            // the new source or include them in a repair candidate.
            incidentTrace.decision(.event,.preSwitchKey,event:event)
            cancelDetection();return Unmanaged.passUnretained(event)
        }
        if !recovering,type == .keyDown,
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty,
           MismatchRecoveryPlan.character(UInt16(event.getIntegerValueField(.keyboardEventKeycode)),event.flags.contains(.maskShift)) != nil {
            sample(synchronous:true,beforeKey:true,followingEvent:event);sampled=lastSampleSnapshot
        }
        if recovering{
            if sourceMenuPaused {
                let popup=sourceMenuPopupVisible()
                if type == .keyDown || type == .keyUp {
                    let code=event.getIntegerValueField(.keyboardEventKeycode)
                    // Check menu ownership before interpreting a closed popup
                    // or an editor recipient as permission to buffer this key.
                    if popup || [36,53].contains(code) {
                        if type == .keyDown {
                            passedSourceMenuKeys.insert(code)
                            if [36,53].contains(code){resumeMenuAfterSelection()}
                        }
                        return Unmanaged.passUnretained(event)
                    }
                }
                if sourceMenuSawPopup,!popup{resumeSourceWork()}
            }
            if sourceMenuPaused {
                if type == .keyDown || type == .keyUp {
                    let recipient=testEventRecipient?(event) ?? pid_t(exactly:event.getIntegerValueField(.eventTargetUnixProcessID))
                    if let recipient,recipient>0,recipient==target?.processIdentifier{resumeSourceWork()}
                    else {
                        if type == .keyDown,[36,53].contains(event.getIntegerValueField(.keyboardEventKeycode)){resumeMenuAfterSelection()}
                        return Unmanaged.passUnretained(event)
                    }
                }else if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                    return Unmanaged.passUnretained(event)
                }
            }
            // Modifier notifications are state changes, not text keys. Reposting
            // source-switch generated notifications can create a feedback loop.
            if type == .flagsChanged{return Unmanaged.passUnretained(event)}
            guard ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park("recovery_deadline");return Unmanaged.passUnretained(event)}
            if perKeyAX {
                if let snap=sampled ?? snapshot(includeContent:false){
                    guard let element=planElement,CFEqual(snap.element,element) else{park("focus_changed_during_recovery");return Unmanaged.passUnretained(event)}
                }else if ["target_not_frontmost","secure_input","secure_text_field","not_supported_text_field","accessibility_permission"].contains(unavailableReason){park("unsafe_context_during_recovery");return Unmanaged.passUnretained(event)}
            }else if !fastRecoveryContext(){
                park("unsafe_context_during_recovery");return Unmanaged.passUnretained(event)
            }
            // No synchronous AX messaging in the recovery key callback. The
            // next edit/drain snapshot must still prove the original field.
            // A transient AX miss must not release newer keys ahead of the queue.
            // The asynchronous verification stage bounds the wait before any replay.
            if keyboard{
                let code=event.getIntegerValueField(.keyboardEventKeycode)
                let releaseDeliveredKey = type == .keyUp && deliveredHeldKeys.remove(code) != nil
                if releaseDeliveredKey {
                    heldKeys.remove(code)
                    // Repeats queued during the physical hold still need their
                    // own later release. Otherwise this release is not replayed.
                    if !pending.contains(where:{$0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode)==code}) {
                        keyDownSources.removeValue(forKey:code)
                        return Unmanaged.passUnretained(event)
                    }
                }
                if let copy=event.copy(){
                    copy.type=type
                    let code=event.getIntegerValueField(.keyboardEventKeycode)
                    if type == .keyDown{keyDownSources[code]=original?.source ?? intendedSource(at:timestamp)}
                    let inputSource=keyDownSources[code] ?? intendedSource
                    if type == .keyUp{keyDownSources.removeValue(forKey:code)}
                    nextBufferedID+=1;pendingSources[nextBufferedID]=inputSource;pendingTimestamps[nextBufferedID]=timestamp
                    bufferedIdentities[ObjectIdentifier(copy)]=nextBufferedID;pending.append(copy)
                    log("key_buffered",["id":nextBufferedID,"inputSource":inputSource,"eventType":type.rawValue,"eventTimestamp":String(event.timestamp),"code":event.getIntegerValueField(.keyboardEventKeycode),"flags":event.flags.rawValue])
                }else{abort("buffer_allocation_failed");return Unmanaged.passUnretained(event)}
                if pending.count>256{abort("buffer_limit")}
                return releaseDeliveredKey ? Unmanaged.passUnretained(event):nil
            }
            abort("mouse_during_recovery");return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            heldKeys.remove(event.getIntegerValueField(.keyboardEventKeycode))
            log("key_observed",["eventType":type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode),"source":InputSourceAccess.currentID(),"candidateActive":plan != nil])
            return Unmanaged.passUnretained(event)
        }
        // sample() already read this callback's pre-insertion state. No edit or
        // event delivery occurred between that read and this decision.
        let observed=sampled ?? snapshot();observeAvailability(observed)
        guard let snap=observed else{
            incidentTrace.decision(.event,.snapshotUnavailable,event:event)
            // A new untracked event breaks the exact key sequence. Sampling-only
            // outages may retry, but never silently omit a key from that sequence.
            plan=nil
            if type == .keyDown,unavailableReason != "target_not_frontmost",unavailableReason != "secure_input",unavailableReason != "accessibility_permission" {
                log("untracked_key",["code":event.getIntegerValueField(.keyboardEventKeycode),"source":InputSourceAccess.currentID(),"reason":unavailableReason])
            }
            return Unmanaged.passUnretained(event)
        }
        if keyboard{log("key_observed",["eventType":type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode),"source":InputSourceAccess.currentID(),"candidateActive":plan != nil])}
        sourceChanged(currentSource(),snap)
        if type == .keyDown{heldKeys.insert(event.getIntegerValueField(.keyboardEventKeycode))}
        if type == .keyDown{
            let disallowed=event.flags.intersection([.maskCommand,.maskControl,.maskAlternate])
            guard MismatchKeyboardLayout.supports(currentSource()),disallowed.isEmpty,
                  let candidate=MismatchRecoveryPlan.next(previous:plan,text:snap.text,selection:snap.selection,
                    code:UInt16(event.getIntegerValueField(.keyboardEventKeycode)),shift:event.flags.contains(.maskShift),sourceID:currentSource()) else{
                plan=nil;incidentTrace.decision(.event,.candidateRejectedKey,event:event);log("candidate_cancelled",["reason":"non_korean_or_non_printable_or_selection"]);return Unmanaged.passUnretained(event)
            }
            plan=candidate;planElement=snap.element;planStart=ProcessInfo.processInfo.systemUptime
            log("candidate_recorded")
            incidentTrace.decision(.event,.candidateRecorded,event:event)

            log("key",["code":event.getIntegerValueField(.keyboardEventKeycode),"roman":candidate.roman,"source":InputSourceAccess.currentID()])
        }else if !keyboard || (type == .flagsChanged && !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty){plan=nil;incidentTrace.decision(.event,.candidateCancelledNavigation,event:event);log("candidate_cancelled",["reason":"navigation_or_modifier"])}
        return Unmanaged.passUnretained(event)
    }
    func sample(synchronous:Bool=false,beforeKey:Bool=false,followingEvent:CGEvent?=nil){
        if recovering {
            observeRecoverySource(currentSource())
            if sourceMenuPaused {
                if sourceMenuPopupVisible(){sourceMenuSawPopup=true}
                else if sourceMenuSawPopup{resumeSourceWork()}
            }
            if sourceWorkPaused,let start=sourcePauseStarted,interactionNow()-start>30{park("source_interaction_timeout")}
        }
        if enabled,!suspended,skipRomanObservation(){return}
        lastSampleSnapshot=nil
        if enabled{followFrontmost(event:followingEvent)}
        guard enabled,!suspended,!recovering else{return}
        guard canObserve() else{incidentTrace.decision(.sample,.observationBlocked);cancelDetection();return}
        if !synchronous,(testSnapshot==nil || testIdleRead != nil) {
            requestIdleSnapshot();return
        }
        consumeIdleSnapshot(snapshot(),allowPrior:beforeKey)
    }
    func consumeIdleSnapshot(_ observed:MismatchSnapshot?,allowPrior:Bool=false) {
        // A queued AX reply can arrive after the source changed. Apply the same
        // preservation/safety gate before it can clear a deferred candidate.
        if enabled,!suspended,!recovering,skipRomanObservation(){return}
        observeAvailability(observed)
        guard let snap=observed else{incidentTrace.decision(.sample,.snapshotUnavailable);return}
        lastSampleSnapshot=snap
        sourceChanged(currentSource(),snap)
        if incidentTrace.enabled {
            let (identity,owner,window,epoch)=incidentTrace.fieldRegistry.identify(snap.element,owner:target?.processIdentifier ?? 0,window:snap.incidentGeneration==incidentTrace.collectionGeneration ? snap.incidentWindow:nil,generation:incidentTrace.collectionGeneration)
            var evidence=snap.incidentGeneration==incidentTrace.collectionGeneration ? (snap.incidentAX ?? InputIncidentAXEvidence()):InputIncidentAXEvidence()
            evidence.owner=owner;evidence.window=window;evidence.identityEpoch=epoch
            let change=incidentShapeProbe.observe(identity:identity,text:snap.text,selection:snap.selection,generation:incidentTrace.collectionGeneration,ax:evidence)
            incidentTrace.shape(.mismatchAX,identity:identity,count:snap.text.utf16.count,selected:snap.selection.length>0,editing:recovering,change:change)
        } else {incidentShapeProbe.reset()}
        if let known=verifiedDeliveryHistory?(snap,allowPrior),known.plan.sourceID==currentSource(),
           known.plan.codes.count>(plan?.codes.count ?? 0),
           ProcessInfo.processInfo.systemUptime-known.lastKeyAt>=0,
           ProcessInfo.processInfo.systemUptime-known.lastKeyAt<=5 {
            plan=known.plan;planElement=snap.element;planStart=known.lastKeyAt
            NSLog("입력 불일치 전달 이력 인계")
        }
        if !InputFocusAccess.sameText(lastText,snap.text){log("text",["text":snap.text,"source":InputSourceAccess.currentID(),"selection":[snap.selection.location,snap.selection.length]]);lastText=snap.text}
        guard let candidate=plan else{incidentTrace.decision(.sample,.noCandidate);return}
        if ProcessInfo.processInfo.systemUptime-planStart>5{incidentTrace.decision(.sample,.candidateExpired);log("candidate_cancelled",["reason":"timeout"]);plan=nil;return}
        let verified:MismatchRecoveryPlan?
        let detectionReason:InputIncidentTrace.RecoveryReason
        if candidate.matches(text:snap.text,selection:snap.selection) {
            verified=candidate
            detectionReason=candidate.verifiedReplacement == nil ? .romanMismatch:.verifiedReplacement
        }else if let failure=candidate.classifiedPartialFailure(text:snap.text,selection:snap.selection) {
            verified=failure.plan
            switch failure.kind {
            case .mixed:detectionReason = .mixedInsertion
            case .decomposed:detectionReason = .decomposedJamo
            case .interrupted:detectionReason = .interruptedComposition
            case .fragmented:detectionReason = .fragmentedComposition
            }
        }else{verified=nil;detectionReason = .unspecifiedMismatch}
        if let verified {
            if candidate.interruptedCompositionPlan(text:snap.text,selection:snap.selection) != nil {
                NSLog("입력 불일치 후속 조합 복구 확인")
            }
            // Exact text/range + the observed physical sequence establishes the
            // mismatch. Do not wait for all keys to be released: their up events
            // are preserved in the same ordered queue as subsequent down events.
            if detectionOnly{reportMismatch(verified,snap)}else{beginRecovery(verified,snap,reason:detectionReason)}
        }else{incidentTrace.decision(.sample,.candidateTextMismatch)}
    }
    func beginRecovery(_ candidate:MismatchRecoveryPlan,_ snap:MismatchSnapshot,reason:InputIncidentTrace.RecoveryReason = .unspecifiedMismatch){
        guard canBeginRepair() else{incidentTrace.decision(.repair,.repairBlocked);return}
        guard MismatchKeyboardLayout.supports(candidate.sourceID) else{incidentTrace.decision(.repair,.repairSourceUnsupported);return}
        guard candidate.matches(text:snap.text,selection:snap.selection) else{incidentTrace.decision(.repair,.repairTextMismatch);return}
        guard !detectionOnly else{reportMismatch(candidate,snap);return}
        recoverySourceID=candidate.sourceID
        var candidate=candidate
        candidate.captureObserved(text:snap.text)
        var writable:DarwinBoolean=false
        let canSelect=testSelectionWritable?(snap.element) ?? (AXUIElementIsAttributeSettable(snap.element,kAXSelectedTextRangeAttribute as CFString,&writable) == .success && writable.boolValue)
        guard canSelect else{incidentTrace.decision(.repair,.selectionNotWritable);reportMismatch(candidate,snap);plan=nil;log("recovery_unsupported",["reason":"selection_not_writable"]);return}
        recoveryEpoch+=1
        verifiedProgressEvents = -1
        recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        willBeginRepair()
        recovering=true;rollingBack=false;replayStarted=false;currentPlan=candidate;plan=nil;pending=[];nextBufferedID=0;postedBuffered=0
        deliveredHeldKeys=heldKeys
        intendedSource=recoverySourceID;recoverySourceBoundaries=[];pendingSources=[:];pendingTimestamps=[:];bufferedIdentities=[:];keyDownSources=Dictionary(uniqueKeysWithValues:heldKeys.map{($0,recoverySourceID)})
        clearSourceInteraction();systemSwitch.reset(currentSource());lastIntendedKorean=recoverySourceID
        koreanRetries=0;activationFallbackTried=false;interruptedSourceRestores=0;ledger=nil;ledgerAfterRepair=nil;snapshotWaitStarted=nil
        log("mismatch_confirmed",["roman":candidate.roman,"text":snap.text])
        incidentTrace.recoveryStarted(.mismatch,reason:reason)
        cycleAndReplay(candidate,snap)
        reportMismatch(candidate,snap)
    }
    func waitSource(_ id:String,remaining:Int=45,knownBoundaries:Int?=nil,knownInteraction:Int?=nil,completion:@escaping ()->Void){
        guard recovering,!rollingBack else{return}
        let boundaryCount=knownBoundaries ?? recoverySourceBoundaries.count
        let interactionRevision=knownInteraction ?? sourceInteractionRevision
        guard let _=recoverySnapshot("source_wait",retry:{[weak self] in self?.waitSource(id,remaining:remaining,knownBoundaries:boundaryCount,knownInteraction:interactionRevision,completion:completion)}) else{return}
        if !systemSwitch.busy,!activationShortcut.busy,currentSource()==id{completion();return}
        if !systemSwitch.busy,(recoverySourceBoundaries.count>boundaryCount || sourceInteractionRevision>interactionRevision) {
            // A proved user switch superseded the temporary source while its
            // AX reply was pending. Restore this known phase immediately; keep
            // the user's intent for final delivery instead of burning the wait.
            guard interruptedSourceRestores<2 else{park("source_wait_restore_exhausted");return}
            interruptedSourceRestores+=1
            guard chooseSource(id)==noErr else{park("source_wait_restore_failed");return}
            waitSource(id,remaining:remaining,knownBoundaries:recoverySourceBoundaries.count,knownInteraction:sourceInteractionRevision,completion:completion)
            return
        }
        guard remaining>0 else{log("source_switch_timeout",["wanted":id,"actual":currentSource()]);abort("source_switch_timeout");return}
        if remaining==30,!systemSwitch.busy,currentSource() != id {
            let result=chooseSource(id)
            log("source_wait_direct_fallback",["target":id,"result":result,"actual":currentSource()])
        }
        later(0.01){[weak self] in self?.waitSource(id,remaining:remaining-1,knownBoundaries:boundaryCount,knownInteraction:interactionRevision,completion:completion)}
    }
    func cycleAndReplay(_ candidate:MismatchRecoveryPlan,_ snap:MismatchSnapshot){
        if sourceWorkPaused{deferRecovery{[weak self] in self?.cycleAndReplay(candidate,snap)};return}
        let result=chooseSource(englishID);log("cycle_english",["result":result])
        guard result==noErr else{abort("english_selection_failed");return}
        waitSource(englishID){[weak self] in
            guard let self else{return}
            let selectKorean:()->Void = {[weak self] in
            guard let self,self.recovering,!self.rollingBack else{return}
            let result=self.chooseSource(recoverySourceID)
            self.log("cycle_korean",["result":result])
            guard result==noErr else{self.abort("korean_selection_failed");return}
            self.waitSource(recoverySourceID){[weak self] in
                guard let self else{return}
                // TIS can report Korean before the editor's IME is ready. A
                // first activation needs a bounded asynchronous settling interval,
                // as does a confirmed Roman retry. A failed first activation
                // can leave the client in Roman mode across later retries.
                // replaceAndReplay rechecks field, text, caret and source after
                // the wait; later also preserves source boundaries and teardown.
                self.later(0.10*Double(max(1,self.koreanRetries))){[weak self] in self?.prepareFinalActivation(candidate,snap)}
            }
            }
            // Waiting only after selecting Korean cannot give the editor an
            // opportunity to observe the intervening English activation. Keep
            // both phases asynchronous from the first repair attempt.
            self.later(0.10*Double(max(1,self.koreanRetries)),selectKorean)
        }
    }
    func replaceAndReplay(_ candidate:MismatchRecoveryPlan,_ before:MismatchSnapshot){
        guard recovering,!rollingBack else{return}
        guard let current=recoverySnapshot("pre_edit",retry:{[weak self] in self?.replaceAndReplay(candidate,before)}) else{return}
        guard CFEqual(current.element,before.element) else{abort("pre_edit_field_changed");return}
        var candidate=candidate
        if !candidate.matches(text:current.text,selection:current.selection) {
            guard currentSource()==recoverySourceID,
                  let restored=candidate.restoredKoreanPlan(text:current.text,selection:current.selection) else{
                log("pre_edit_context_failed",["source":currentSource(),"text":current.text,"selection":[current.selection.location,current.selection.length],"expectedRoman":candidate.expected ?? ""])
                abort("pre_edit_mismatch");return
            }
            log("pre_edit_korean_restored",["text":current.text,"physicalKeys":candidate.replayRoman,"pendingEvents":pending.count])
            candidate=restored;currentPlan=restored
        }
        // matches() permits editor capitalization inside the observed ASCII
        // run. Bind selection proof and rollback to that actual spelling.
        candidate.captureObserved(text:current.text);currentPlan=candidate
        guard currentSource()==recoverySourceID else{
            // A delayed source notification can arrive after waitSource's
            // successful observation and before this async snapshot completes.
            // Restore the known target, then revalidate before any edit.
            restoreInterruptedSource("pre_edit"){[weak self] in self?.replaceAndReplay(candidate,before)};return
        }
        let range=NSRange(location:candidate.caret,length:candidate.roman.utf16.count)
        guard setRange(current.element,range) == .success else{abort("selection_failed");return}
        log("selection_requested",["range":[range.location,range.length],"originalSelection":[current.selection.location,current.selection.length]])
        awaitSelection(candidate,current,range,remaining:15)
    }
    func awaitSelection(_ candidate:MismatchRecoveryPlan,_ before:MismatchSnapshot,_ range:NSRange,remaining:Int){
        guard recovering,!rollingBack else{return}
        guard let selected=recoverySnapshot("selection",retry:{[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining)}) else{return}
        guard CFEqual(selected.element,before.element) else{abort("selection_context_changed");return}
        var candidate=candidate
        if selected.text != before.text {
            guard let recaptured=candidate.recapturingASCIICase(text:selected.text) else{abort("selection_context_changed");return}
            candidate=recaptured;currentPlan=recaptured
        }
        if currentSource() != recoverySourceID {
            restoreInterruptedSource("selection"){[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining)};return
        }
        log("selection_observed",["requested":[range.location,range.length],"observed":[selected.selection.location,selected.selection.length],"remaining":remaining])
        guard selected.selection==range else{
            // Auto-capitalization/IME commits can acknowledge an AX selection
            // write and then collapse it. Reapply only after the unchanged
            // field/body proof above, twice within the original wait budget.
            if remaining==10 || remaining==5 {
                guard setRange(selected.element,range) == .success else{abort("selection_retry_failed");return}
            }
            if remaining>0{self.later(0.01){[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining-1)}}
            else{abort("selection_not_applied")}
            return
        }
        if testSnapshot==nil && testAsyncRead==nil {
            guard selected.selectedText==candidate.roman else{abort("selected_text_not_verified");return}
        }
        log("selection_overwrite_started",["range":[range.location,range.length]])
        replayCandidate(candidate)
    }
    // A source notification may arrive after the first successful observation.
    // Keep the transaction and queue intact; never repeat an edit just because
    // the source changed. The resumed stage rechecks its own text/caret proof.
    func restoreInterruptedSource(_ stage:String,targetSource:String?=nil,resume:@escaping ()->Void){
        if sourceWorkPaused{deferRecovery{[weak self] in self?.restoreInterruptedSource(stage,targetSource:targetSource,resume:resume)};return}
        let targetSource=targetSource ?? recoverySourceID
        guard interruptedSourceRestores<2,ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park(stage+"_source_restore_exhausted");return}
        if systemSwitch.busy{later(0.01){[weak self] in self?.restoreInterruptedSource(stage,targetSource:targetSource,resume:resume)};return}
        interruptedSourceRestores+=1
        log("interrupted_source_restore",["stage":stage,"source":currentSource(),"targetSource":targetSource,"intendedSource":intendedSource,"attempt":interruptedSourceRestores,"pendingEvents":pending.count])
        // This is a known target restoration, not a toggle. Another Control-
        // Space can be lost among modifier transitions or toggle the wrong way.
        let result=chooseSource(targetSource)
        log("interrupted_source_direct_selection",["target":targetSource,"result":result,"stage":stage])
        guard result==noErr else{park(stage+"_source_restore_failed");return}
        waitSource(targetSource,completion:resume)
    }
    func replayCandidate(_ candidate:MismatchRecoveryPlan){
        if koreanRetries==2 {
            replayPacedCandidate(candidate);return
        }
        replayStarted=true
        var events:[CGEvent]=[]
        for (code,shift) in candidate.codes{
            for down in [true,false]{if let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down){event.flags=shift ? .maskShift:[];events.append(event)}}
        }
        log("replay_started",["keyCount":candidate.codes.count,"pendingEvents":pending.count])
        // Verify the actual Korean result before releasing subsequent keys.
        guard events.count==candidate.codes.count*2 else{park("replay_allocation_failed");return}
        replayIssuedAt=ProcessInfo.processInfo.systemUptime
        for event in events{guard let prepared=prepareEvent(event) else{park("replay_allocation_failed");return};post(prepared)}
        awaitKorean(candidate,remaining:25)
    }
    func awaitKorean(_ candidate:MismatchRecoveryPlan,remaining:Int){
        guard recovering,!rollingBack else{return}
        guard let snap=recoverySnapshot("korean_verification",retry:{[weak self] in self?.awaitKorean(candidate,remaining:remaining)}) else{return}
        if currentSource() != recoverySourceID {
            restoreInterruptedSource("korean_verification"){[weak self] in self?.resumeKoreanAfterSourceRestore(candidate,remaining:remaining)};return
        }
        guard let korean=MismatchKeyboardLayout.render(keys:candidate.codes,sourceID:candidate.sourceID) else{park("expected_korean_unavailable");return}
        let expected=(candidate.before as NSString).replacingCharacters(in:NSRange(location:candidate.caret,length:0),with:korean)
        if snap.text==expected,snap.selection==NSRange(location:candidate.caret+korean.utf16.count,length:0){
            log("korean_result_verified",["text":snap.text])
            confirmDeliveryProgress(postedBuffered)
            if let repaired=ledgerAfterRepair{ledger=repaired;ledgerAfterRepair=nil}
            if ledger==nil{ledger=MismatchReplayLedger(before:candidate.before,caret:candidate.caret);ledger?.append(source:recoverySourceID,keys:candidate.codes)}
            drain(verifiedSnapshot:snap);return
        }
        // Selection was verified before overwrite. A complete result containing
        // exactly those Roman keys is a failed replay, not missing AX output.
        // retryKorean takes a fresh snapshot again before authorizing any edit.
        var romanCandidate=candidate
        romanCandidate.roman=candidate.replayRoman;romanCandidate.verifiedReplacement=nil
        if romanCandidate.matches(text:snap.text,selection:snap.selection){
            lastRomanReplayDelayMs=(ProcessInfo.processInfo.systemUptime-replayIssuedAt)*1000
            log("roman_replay_confirmed",["attempt":koreanRetries+1,"replayToObservationMs":lastRomanReplayDelayMs!,"remainingPolls":remaining])
            retryKorean(romanCandidate,snap);return
        }
        if let partial=romanCandidate.partialFailurePlan(text:snap.text,selection:snap.selection) {
            // Every replayed key is accounted for, including already composed
            // prefixes. A literal prior replacement is not the next result.
            // The one unused stage=2 fallback also accepts a complete, exact
            // partial rendering. Never add a direct retry or renew its budget.
            guard koreanRetries<2 || (!activationFallbackTried && activationShortcutSupported()) else{park("partial_replay_retry_exhausted");return}
            NSLog("입력 불일치 부분 조합 재시도: retries=%d",koreanRetries)
            retryKorean(partial,snap);return
        }
        guard remaining>0 else{
            log("korean_verification_failed",["text":snap.text,"selection":[snap.selection.location,snap.selection.length],"source":currentSource(),"attempt":koreanRetries+1])
            retryKorean(candidate,snap);return
        }
        self.later(0.01){[weak self] in self?.awaitKorean(candidate,remaining:remaining-1)}
    }
    func resumeKoreanAfterSourceRestore(_ candidate:MismatchRecoveryPlan,remaining:Int){
        guard recovering,!rollingBack else{return}
        guard let snap=recoverySnapshot("composition_resume",retry:{[weak self] in self?.resumeKoreanAfterSourceRestore(candidate,remaining:remaining)}) else{return}
        if currentSource()==recoverySourceID,let restored=candidate.restoredKoreanPlan(text:snap.text,selection:snap.selection) {
            guard koreanRetries<2 else{park("composition_resume_exhausted");return}
            koreanRetries+=1;currentPlan=restored;replayStarted=false
            log("composition_reopened_after_source_restore",["text":snap.text,"physicalKeys":candidate.replayRoman,"pendingEvents":pending.count])
            replaceAndReplay(restored,snap);return
        }
        var roman=candidate;roman.roman=candidate.replayRoman;roman.verifiedReplacement=nil
        if roman.matches(text:snap.text,selection:snap.selection){retryKorean(roman,snap);return}
        awaitKorean(candidate,remaining:remaining)
    }
    func retryKorean(_ candidate:MismatchRecoveryPlan,_ observed:MismatchSnapshot){
        guard recovering,!rollingBack,let field=planElement,CFEqual(observed.element,field) else{park("retry_context_not_exact_roman");return}
        guard let fresh=recoverySnapshot("retry_korean",retry:{[weak self] in self?.retryKorean(candidate,observed)}) else{return}
        guard CFEqual(fresh.element,field),fresh.text==observed.text,fresh.selection==observed.selection,
              currentSource()==recoverySourceID,candidate.matches(text:fresh.text,selection:fresh.selection) else{park("retry_context_not_exact_roman");return}
        var retry=candidate;retry.captureObserved(text:fresh.text);currentPlan=retry
        // Every replayed key is present in a proved failure rendering. Re-editing
        // this exact range cannot duplicate it; preserve the following queue.
        replayStarted=false
        // Source activation can be lost after the final pre-edit check. An
        // exact failed result is stronger evidence than a process-local TIS
        // layout snapshot. Spend the one activation fallback here if unused;
        // never extend the progress deadline or loop after that fallback fails.
        if koreanRetries==2,!activationFallbackTried,activationShortcutSupported(){
            prepareFinalActivation(retry,fresh,confirmedReplayFailure:true);return
        }
        let activationBudget=(testActivationNeeded != nil || (testSelectSource==nil && recoverySourceID==mismatchKoreanID && activationShortcut.configured)) ? 0.6:0
        let retryBudget=koreanRetries==1 ? 0.4+activationBudget+Double(candidate.codes.count)*Self.pacedReplayInterval+0.28:0.4
        guard koreanRetries<2,ProcessInfo.processInfo.systemUptime+retryBudget<recoveryDeadline else{
            log("korean_retry_exhausted",["attempts":koreanRetries+1,"pendingEvents":pending.count])
            abort("korean_retry_exhausted");return
        }
        koreanRetries+=1
        log("korean_retry",["retry":koreanRetries,"pendingEvents":pending.count,"roman":retry.roman])
        cycleAndReplay(retry,fresh)
    }
    func prepareEvent(_ saved:CGEvent)->CGEvent? {
        let event:CGEvent
        if saved.type == .keyDown || saved.type == .keyUp {
            guard let fresh=CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(saved.getIntegerValueField(.keyboardEventKeycode)),keyDown:saved.type == .keyDown) else{return nil}
            fresh.flags=saved.flags
            fresh.setIntegerValueField(.keyboardEventAutorepeat,value:saved.getIntegerValueField(.keyboardEventAutorepeat));event=fresh
        }else{return nil}
        event.setIntegerValueField(.eventSourceUserData,value:marker)
        return event
    }
    func drain(rollback:Bool=false,sourceAttempts:Int=45,verifiedSnapshot:MismatchSnapshot?=nil){
        guard recovering,rollingBack==rollback else{return}
        if sourceWorkPaused{deferRecovery{[weak self] in self?.drain(rollback:rollback,sourceAttempts:sourceAttempts)};return}
        guard ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park("delivery_deadline");return}
        guard let snap=verifiedSnapshot ?? recoverySnapshot("delivery",retry:{[weak self] in self?.drain(rollback:rollback,sourceAttempts:sourceAttempts)}) else{return}
        if systemSwitch.busy{later(0.01){[weak self] in self?.drain(rollback:rollback,sourceAttempts:sourceAttempts)};return}
        // A queued Select All is an editing boundary, not a printable key.
        // Apply its selection after the next source is ready: switching a live
        // selected composition can otherwise commit its last syllable outside
        // the selection. Earlier text is verified before reaching this boundary.
        while let first=pending.first {
            if Self.isSelectAll(first) {
                pending.removeFirst();postedBuffered+=1;selectAllReleases+=1
                queuedSelectAll=true;queuedSelectAllText=snap.text
            } else if first.type == .keyUp,first.getIntegerValueField(.keyboardEventKeycode)==0,selectAllReleases>0 {
                pending.removeFirst();postedBuffered+=1;selectAllReleases-=1
            } else {break}
        }
        // Prepare every event before removing anything from the queue.
        // A release retains its original key identity, but does not insert text.
        // Never change the input source just to deliver an old key-up.
        let nextSource=pending.first.map{event in
            event.type == .keyUp ? currentSource() : (pendingSources[bufferedID(event)] ?? recoverySourceID)
        } ?? intendedSource
        if currentSource() != nextSource {
            guard sourceAttempts>0 else{park("delivery_source_timeout");return}
            if sourceAttempts==45 {
                guard chooseSource(nextSource)==noErr else{park("delivery_source_selection_failed");return}
                log("delivery_source_requested",["source":nextSource])
            }
            if sourceAttempts==30,!systemSwitch.busy {
                let result=chooseSource(nextSource)
                log("delivery_source_direct_fallback",["target":nextSource,"result":result])
            }
            later(0.01){[weak self] in self?.drain(rollback:rollback,sourceAttempts:sourceAttempts-1)};return
        }
        if queuedSelectAll {
            guard snap.text==queuedSelectAllText else{park("select_all_context_changed");return}
            let range=NSRange(location:0,length:snap.text.utf16.count)
            if snap.selection != range {
                guard setRange(snap.element,range) == .success else{park("select_all_failed");return}
                later(0.01){[weak self] in self?.drain(rollback:rollback)};return
            }
            queuedSelectAll=false;queuedSelectAllText=nil
            ledger=MismatchReplayLedger(before:"",caret:0)
            if pending.isEmpty {ledger=nil;finishDelivery(rollback:rollback,verifiedSnapshot:snap);return}
        }
        if pending.isEmpty {
            // A source-only user boundary commits the existing ledger; it does
            // not create a new batch in its last (Korean) source. Reopening that
            // segment here would undo the requested final English source.
            if !rollback,let expected=ledger {
                guard MismatchRecoveryPlan.sameEditorText(snap.text,expected.text),snap.selection==expected.selection else{park("final_source_context_changed");return}
            }
            finishDelivery(rollback:rollback,verifiedSnapshot:snap);return
        }
        let count=pending.prefix{!Self.isSelectAll($0) && ($0.type == .keyUp || (pendingSources[bufferedID($0)] ?? recoverySourceID)==nextSource)}.count
        let group=Array(pending.prefix(count))
        var nextLedger=ledger
        var deliveredKeys:[(UInt16,Bool)]=[]
        if !rollback,let _=nextLedger {
            var keys:[(UInt16,Bool)]=[]
            for event in group where event.type == .keyDown {
                let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let shift=MismatchReplayLedger.modelShift(code:code,flags:event.flags,source:nextSource)
                guard event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty,MismatchRecoveryPlan.character(code,shift) != nil else{park("unsupported_buffered_edit");return}
                keys.append((code,shift))
            }
            deliveredKeys=keys
            nextLedger?.append(source:nextSource,keys:keys)
        }
        let prepared=group.compactMap{prepareEvent($0)}
        guard prepared.count==group.count else{if rollback{park("event_allocation_failed")}else{abort("event_allocation_failed")};return}
        let buffered=group;pending.removeFirst(count)
        for (index,event) in prepared.enumerated(){
            post(event)
            let saved=buffered[index];postedBuffered+=1
            log("buffer_event_posted",["inputSource":pendingSources[bufferedID(saved)] ?? recoverySourceID,"deliverySource":nextSource,"id":bufferedID(saved),"originTimestamp":String(saved.timestamp),"postedTimestamp":String(event.timestamp),"code":saved.getIntegerValueField(.keyboardEventKeycode),"eventType":saved.type.rawValue,"rollback":rollback])
        }
        replayCount+=prepared.count
        if !rollback,let expected=nextLedger {
            let roman=nextSource==recoverySourceID ? deliveredKeys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined():""
            // Yield after posting: an immediate synchronous AX request can reach
            // the editor before its queued key events. Verify on the next turn.
            later(0){[weak self] in self?.verifyBuffered(expected,before:snap,remaining:30,roman:roman,sourceOnly:deliveredKeys.isEmpty)}
        }else{later(0.02){[weak self] in self?.finishDelivery(rollback:rollback)}}
    }
    func verifyBuffered(_ expected:MismatchReplayLedger,before:MismatchSnapshot,remaining:Int,roman:String="",reopenComposition:Bool=false,sourceOnly:Bool=false){
        guard recovering,!rollingBack else{return}
        guard let snap=recoverySnapshot("buffer_verification",retry:{[weak self] in self?.verifyBuffered(expected,before:before,remaining:remaining,roman:roman,reopenComposition:reopenComposition,sourceOnly:sourceOnly)}) else{return}
        if traceLatency{log("buffer_verification_observed",["snapshotID":lastCompletedSnapshotID,"remaining":remaining,"postedEvents":postedBuffered,"actual":snap.text,"expected":expected.text,"selection":[snap.selection.location,snap.selection.length],"expectedSelection":[expected.selection.location,expected.selection.length],"textMatches":snap.text==expected.text,"selectionMatches":snap.selection==expected.selection])}
        if !sourceOnly,let wanted=expected.segments.last?.source,currentSource() != wanted {
            restoreInterruptedSource("buffer_verification",targetSource:wanted){[weak self] in self?.verifyBuffered(expected,before:before,remaining:remaining,roman:roman,reopenComposition:true)};return
        }
        if MismatchRecoveryPlan.sameEditorText(snap.text,expected.text),snap.selection==expected.selection {
            if reopenComposition,expected.segments.last?.source==recoverySourceID {
                log("buffer_composition_reopen",["text":snap.text,"postedEvents":postedBuffered])
                repairBufferedRoman(expected,snap);return
            }
            if snap.text != expected.text{log("editor_space_equivalence",["expected":expected.text,"actual":snap.text])}
            ledger=expected;log("buffer_text_verified",["text":snap.text,"postedEvents":postedBuffered])
            confirmDeliveryProgress(postedBuffered)
            finishDelivery(rollback:false,verifiedSnapshot:snap);return
        }
        if !roman.isEmpty,MismatchKeyboardLayout.render(roman:roman,sourceID:recoverySourceID) != roman,
           before.selection.length==0,snap.text==(before.text as NSString).replacingCharacters(in:before.selection,with:roman),
           snap.selection==NSRange(location:before.selection.location+roman.utf16.count,length:0) {
            log("buffer_roman_confirmed",["roman":roman,"text":snap.text])
            repairBufferedRoman(expected,snap);return
        }
        // Match a complete known batch across the observed ABC -> Korean boundary.
        if reopenComposition,!roman.isEmpty,before.selection.length==0,
           snap.selection.length==0,snap.selection.location>=before.selection.location,
           snap.selection.location<=snap.text.utf16.count {
            let range=NSRange(location:before.selection.location,length:snap.selection.location-before.selection.location)
            let ns=snap.text as NSString
            if ns.replacingCharacters(in:range,with:"")==before.text,
               MismatchRecoveryPlan.matchesRestoredBatch(roman:roman,inserted:ns.substring(with:range),sourceID:recoverySourceID) {
                log("buffer_committed_boundary_confirmed",["text":snap.text,"roman":roman])
                repairBufferedRoman(expected,snap);return
            }
        }
        if reopenComposition,let segment=expected.segments.last,segment.source==recoverySourceID,snap.selection.length==0 {
            let committed=expected.segments.dropLast().map{MismatchReplayLedger.render($0)}.joined()
            let start=expected.caret+committed.utf16.count
            let ns=snap.text as NSString
            if start>=0,snap.selection.location>=start,snap.selection.location<=ns.length {
                let range=NSRange(location:start,length:snap.selection.location-start)
                let base=(expected.before as NSString).replacingCharacters(in:NSRange(location:expected.caret,length:0),with:committed)
                let keys=segment.keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
                if ns.replacingCharacters(in:range,with:"")==base,
                   MismatchRecoveryPlan.matchesSourceRoundTrip(roman:keys,inserted:ns.substring(with:range),sourceID:segment.source) {
                    log("buffer_source_interval_confirmed",["physicalKeys":keys,"observed":ns.substring(with:range)])
                    repairBufferedRoman(expected,snap);return
                }
            }
        }
        if !sourceOnly,expected.segments.last?.source==recoverySourceID,
           expected.decomposedPlan(text:snap.text,selection:snap.selection) != nil {
            log("buffer_decomposed_confirmed",["postedEvents":postedBuffered,"retry":koreanRetries])
            NSLog("입력 불일치 후속 자모 확인: retries=%d",koreanRetries)
            repairBufferedRoman(expected,snap);return
        }
        if !sourceOnly,expected.segments.last?.source==recoverySourceID,
           expected.interruptedCompositionPlan(text:snap.text,selection:snap.selection) != nil {
            NSLog("입력 불일치 보관 조합 복구 확인: retries=%d",koreanRetries)
            repairBufferedRoman(expected,snap);return
        }
        guard remaining>0 else{
            log("buffer_text_failed",["expected":expected.text,"actual":snap.text,"selection":[snap.selection.location,snap.selection.length]])
            park("buffer_result_not_verified");return
        }
        later(0.01){[weak self] in self?.verifyBuffered(expected,before:before,remaining:remaining-1,roman:roman,reopenComposition:reopenComposition,sourceOnly:sourceOnly)}
    }
    func repairBufferedRoman(_ expected:MismatchReplayLedger,_ snap:MismatchSnapshot){
        guard let segment=expected.segments.last,segment.source==recoverySourceID,currentSource()==recoverySourceID,
              koreanRetries<2,ProcessInfo.processInfo.systemUptime+0.6<recoveryDeadline else{park("buffer_roman_retry_unavailable");return}
        let committed=expected.segments.dropLast().map{MismatchReplayLedger.render($0)}.joined()
        let start=expected.caret+committed.utf16.count
        let range=NSRange(location:start,length:snap.selection.location-start)
        let ns=snap.text as NSString
        guard range.length>0,start>=0,NSMaxRange(range)<=ns.length else{park("buffer_repair_range_invalid");return}
        let base=(expected.before as NSString).replacingCharacters(in:NSRange(location:expected.caret,length:0),with:committed)
        guard ns.replacingCharacters(in:range,with:"")==base else{park("buffer_repair_surroundings_changed");return}
        var repair=MismatchRecoveryPlan(before:base,caret:start,sourceID:segment.source)
        repair.codes=segment.keys;repair.roman=ns.substring(with:range);repair.verifiedReplacement=repair.roman
        ledgerAfterRepair=expected;currentPlan=repair;replayStarted=false;koreanRetries+=1
        log("buffer_repair_started",["observed":repair.roman,"physicalKeys":repair.replayRoman,"retry":koreanRetries])
        cycleAndReplay(repair,snap)
    }
    func finishDelivery(rollback:Bool,verifiedSnapshot:MismatchSnapshot?=nil){
        guard recovering,rollingBack==rollback else{return}
        if sourceWorkPaused{deferRecovery{[weak self] in self?.drain(rollback:rollback)};return}
        if !pending.isEmpty || queuedSelectAll || currentSource() != intendedSource{drain(rollback:rollback,verifiedSnapshot:verifiedSnapshot);return}
        recoveryEpoch+=1;recovering=false;rollingBack=false;currentPlan=nil;lastSource=currentSource();heldKeys=[];deliveredHeldKeys=[];queuedSelectAll=false;queuedSelectAllText=nil;selectAllReleases=0
        if !rollback,let ledger,let snap=verifiedSnapshot {
            if currentSource()==mismatchKoreanID,ledger.text==snap.text,ledger.selection==snap.selection,
               let continuation=ledger.lastTwoSetPlan() {
                plan=continuation;planElement=snap.element;planStart=ProcessInfo.processInfo.systemUptime
            }
            didVerifyReplay(ledger,snap)
        }
        log(rollback ? "rollback_finished":"recovery_finished",["bufferedEvents":nextBufferedID,"postedEvents":postedBuffered,"pendingEvents":0,"textVerified":!rollback && ledger != nil,"postingIsNotAppAcknowledgment":rollback || ledger==nil])
        if let snap=verifiedSnapshot{log("after_replay_snapshot",["text":snap.text,"source":lastSource,"selection":[snap.selection.location,snap.selection.length]])}
        if stopAfterRollback{stopAfterRollback=false;closeSession()}
    }
    func abort(_ reason:String){
        guard recovering else{return}
        if rollingBack{return}
        activationShortcut.cancel()
        recoveryEpoch+=1;asyncReady=nil
        rollingBack=true;rollbackReason=reason;plan=nil
        failureDiagnostic("abort",reason)
        log("rollback_started",["reason":reason,"originalRoman":currentPlan?.roman ?? "","pendingEvents":pending.count])
        attemptRollback(remaining:15,requested:false)
    }
    func attemptRollback(remaining:Int,requested:Bool){
        guard recovering,rollingBack else{return}
        guard let candidate=currentPlan,let field=planElement,!replayStarted else{park("rollback_context_not_intact");return}
        guard let snap=recoverySnapshot("rollback",retry:{[weak self] in self?.attemptRollback(remaining:remaining,requested:requested)}) else{return}
        guard CFEqual(snap.element,field),snap.text==candidate.expected else{park("rollback_context_not_intact");return}
        let caret=NSRange(location:candidate.caret+candidate.roman.utf16.count,length:0)
        let repairRange=NSRange(location:candidate.caret,length:candidate.roman.utf16.count)
        guard snap.selection==caret || snap.selection==repairRange else{park("rollback_unexpected_selection");return}
        if currentSource() != recoverySourceID {
            if !requested {
                guard chooseSource(recoverySourceID)==noErr else{park("rollback_source_failed");return}
            }
        }
        if snap.selection==caret,currentSource()==recoverySourceID {
            log("rollback_caret_verified",["selection":[caret.location,caret.length]])
            drain(rollback:true);return
        }
        if !requested {
            let result=setRange(field,caret)
            log("rollback_caret_requested",["selection":[caret.location,caret.length],"result":result.rawValue])
            guard result == .success else{park("rollback_caret_rejected");return}
        }
        guard remaining>0 else{park("rollback_caret_timeout");return}
        self.later(0.01){[weak self] in self?.attemptRollback(remaining:remaining-1,requested:true)}
    }
    func park(_ reason:String){
        monitorRestartAllowed=false
        failureDiagnostic("park",reason)
        clearSourceInteraction()
        // Focus/text changes cannot be undone safely. Keep the queue in memory and
        // expose it to the user, and never inject it into a different field.
        log("pending_retained",["reason":reason,"events":pending.map{["id":bufferedID($0),"eventType":Int($0.type.rawValue),"code":$0.getIntegerValueField(.keyboardEventKeycode),"flags":$0.flags.rawValue]}])
        activationShortcut.cancel();systemSwitch.cancel();snapshotWaitStarted=nil
        recoveryEpoch+=1
        retained.append(contentsOf:pending);pending=[]
        suspended=true
        didRetainInput()
        recovering=false;rollingBack=false;plan=nil;planElement=nil;currentPlan=nil;heldKeys=[];deliveredHeldKeys=[];queuedSelectAll=false;queuedSelectAllText=nil;selectAllReleases=0
        log("monitor_suspended")

        if stopAfterRollback{stopAfterRollback=false;closeSession()}
    }
    @objc func copyPending(){
        let text=(retained+pending).filter{$0.type == .keyDown}.map{event -> String in
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty,
                  let text=MismatchRecoveryPlan.character(code,event.flags.contains(.maskShift)) else{return "[keyCode:\(code)]"}
            return text
        }.joined()
        guard !text.isEmpty else{retained=[];pending=[];suspended=false;return}
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
        retained=[];pending=[];suspended=false
    }
    @objc func stop(){
        if recovering{
            stopAfterRollback=true;abort("user_stop");return
        }
        closeSession()
    }
    var canObserve:()->Bool = { true }
    var canToggleRightCommand:()->Bool = { true }
    var canBeginRepair:()->Bool = { true }
    var willBeginRepair:()->Void = {}
    var didVerifyReplay:(MismatchReplayLedger,MismatchSnapshot)->Void = {_,_ in}
    var didRetainInput:()->Void = {}
    var suspended=false
    var monitorRestartAllowed=false
    static func supports(_ app:NSRunningApplication?)->Bool {
        guard let app,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else{return false}
        return !app.isTerminated
    }
    func cancelDetection(){detectionRevision+=1;plan=nil;planElement=nil;lastSampleSnapshot=nil;heldKeys=[]}
    func failureDiagnostic(_ stage:String,_ reason:String) {
        // Only ordinal codes from fixed product reasons, never arbitrary strings.
        // Keep retired reason slots stable for existing diagnostic codes.
        let reasons=["pre_edit_mismatch","selection_failed","selection_not_applied","selected_text_not_verified","english_selection_failed","korean_selection_failed","source_switch_timeout","delete_not_verified","rollback_context_not_intact","buffer_result_not_verified","delivery_source_timeout","delivery_source_selection_failed","buffer_roman_retry_unavailable","source_menu_focus_changed","menu_source_restore_failed","caps_during_unsettled_source","menu_during_unsettled_source","final_source_context_changed","korean_retry_exhausted","recovery_deadline","paced_replay_unsafe_context","paced_replay_source_changed","paced_replay_allocation_failed","activation_context_changed","activation_boundary_changed","partial_replay_retry_exhausted"]
        let code=reason.hasSuffix("_deadline") ? 20:(reasons.firstIndex(of:reason).map{$0+1} ?? 0)
        // A recurrence can be inspected without restarting into diagnostic
        // mode. Fixed ordinal states only; no editor/text/key/clipboard data.
        NSLog("입력 불일치 복구 중단: stage=%d reason=%d retries=%d",stage=="abort" ? 1:2,code,koreanRetries)
        if stage=="abort"{InputDiagnostics.shared.record("mismatch.abort reasonCode=\(code)")}
        else if stage=="park"{InputDiagnostics.shared.record("mismatch.park reasonCode=\(code)")}
    }
    func log(_ kind:String,_ fields:@autoclosure ()->[String:Any]=[:]) {
        if InputIncidentTrace.shared.enabled {
            if let state=InputIncidentTrace.State.event(kind){InputIncidentTrace.shared.state(.mismatch,state,pending:pending.count+retained.count)}
        }
        // Deliberately never evaluate fields: they can contain typed text, keys,
        // editor identifiers or clipboard content copied from the experiment.
        if ["key_received","candidate_recorded","candidate_cancelled","field_changed","source_change","observation_blocked","user_source_boundary","mismatch_confirmed","korean_result_verified","recovery_finished","pending_retained","rollback_finished","start_failed","caps_source_wait","caps_source_confirmed","caps_source_unchanged","source_menu_paused","source_work_resumed","cycle_english","cycle_korean","selection_requested","replay_started"].contains(kind) {
            InputDiagnostics.shared.record("mismatch."+kind)
        }
    }
    func start(){
        guard !enabled,tap==nil,!suspended,retained.isEmpty,AXIsProcessTrusted() else{return}
        guard KeyboardStateMirror.shared.start() else{log("state_boundary_failed");return}
        followsFrontmost=true;target=nil;ax=nil
        let mask:CGEventMask=[CGEventType.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].reduce(0){$0 | (1 << $1.rawValue)}
        tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,event,ref in
            let owner=Unmanaged<MismatchRecoveryEngine>.fromOpaque(ref!).takeUnretainedValue()
            let incidentStart=InputIncidentTrace.shared.beginCallback(type)
            return KeyboardStateMirror.shared.preserve(type,event) {
                let began=InputIncidentTrace.shared.enabled ? ProcessInfo.processInfo.systemUptime:nil
                let result=owner.event(type,event)
                if let began{InputIncidentTrace.shared.event(.mismatch,type,event,consumed:result==nil,duration:ProcessInfo.processInfo.systemUptime-began,started:incidentStart)}
                return result
            }
        },userInfo:Unmanaged.passUnretained(self).toOpaque())
        guard let tap else{log("start_failed");return}
        runSource=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),runSource,.commonModes)
        enabled=true;recovering=false;plan=nil;locked=nil;lastText=nil;lastSource=InputSourceAccess.currentID();started=ProcessInfo.processInfo.systemUptime
        switchGate=MismatchSwitchGate(accepts:{[weak self] in
            guard let self else{return false}
            func reject(_ reason:Int)->Bool{self.switchGate?.acceptanceReason=reason;return false}
            guard self.enabled else{return reject(2)}
            guard !self.suspended else{return reject(3)}
            guard self.recovering else{return reject(4)}
            guard self.canToggleRightCommand() else{return reject(self.switchGate?.acceptanceReason == 0 ? 5:(self.switchGate?.acceptanceReason ?? 5))}
            guard !IsSecureEventInputEnabled() else{return reject(6)}
            guard self.target != nil else{return reject(7)}
            let accepted=self.fastRecoveryContext()
            self.switchGate?.acceptanceReason=accepted ? 1:8
            return accepted
        },switched:{[weak self] timestamp in self?.userToggleDuringRecovery(at:timestamp)})
        switchGate?.incidentTrace=incidentTrace
        // Capture intent in the same HID stream as the user's switch. Quartz
        // may retimestamp a delayed event before the downstream session tap.
        switchGate?.forwarded = { [weak self] type,event,timestamp in self?.captureEventOrigin(type,event,at:timestamp) }
        switchGate?.acceptsExternalSource = { [weak self] in
            guard let self else{return false}
            return self.enabled && !self.suspended && self.recovering && self.fastRecoveryContext()
        }
        switchGate?.capsChanged = { [weak self] timestamp in self?.potentialCapsSourceSwitch(at:timestamp) }
        switchGate?.menuBegan = { [weak self] timestamp in self?.beginSourceMenu(at:timestamp) }
        switchGate?.failed = { [weak self] in self?.monitorTapFailed(2) }
        guard switchGate!.start() else{closeSession();log("start_failed");return}
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in self?.sample()}
        followFrontmost();didStart()
    }
    func suspend(_ reason:String){
        if reason != "tap_disabled" {monitorRestartAllowed=false}
        let reasons=["tap_disabled","switch_gate_disabled","input_unavailable","hanq_input_stopped"]
        InputDiagnostics.shared.record("mismatch.suspend reasonCode=\(reasons.firstIndex(of:reason).map{$0+1} ?? 0)")
        if recovering || !pending.isEmpty{park(reason)}
        closeSession()
    }
    func closeSession(){
        clearSourceInteraction()
        passedSourceMenuKeys=[]
        idleSnapshotRequest=nil;detectionRevision+=1
        eventOrigins.removeAll()
        if !pending.isEmpty{retained.append(contentsOf:pending);pending=[];suspended=true;didRetainInput()}
        recoveryEpoch+=1;asyncReady=nil;asyncRequest=nil
        activationShortcut.cancel();systemSwitch.cancel();switchGate?.stop();switchGate=nil
        enabled=false;recovering=false;deliveredHeldKeys=[];queuedSelectAll=false;queuedSelectAllText=nil;selectAllReleases=0;timer?.invalidate();timer=nil;cancelDetection()
        if let tap{CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)};tap=nil
        if let runSource{CFRunLoopRemoveSource(CFRunLoopGetMain(),runSource,.commonModes);CFRunLoopSourceInvalidate(runSource)};runSource=nil
    }
}
