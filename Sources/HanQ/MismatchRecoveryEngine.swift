import AppKit
import Carbon

let mismatchKoreanID="com.apple.inputmethod.Korean.2SetKorean"
func mismatchSourceID()->String {
    guard let s=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),let p=TISGetInputSourceProperty(s,kTISPropertyInputSourceID) else{return "unknown"}
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func mismatchSelectSource(_ id:String)->OSStatus {
    let query=[kTISPropertyInputSourceID as String:id,kTISPropertyInputSourceIsEnabled as String:true,kTISPropertyInputSourceIsSelectCapable as String:true] as CFDictionary
    guard let list=TISCreateInputSourceList(query,false)?.takeRetainedValue() as? [TISInputSource],let s=list.first else{return -50}
    return TISSelectInputSource(s)
}
struct MismatchSnapshot { let element:AXUIElement;let text:String;let selection:NSRange;var selectedText:String?=nil }
final class MismatchRecoveryEngine:NSObject {
    let detectionOnly:Bool
    init(detectionOnly:Bool=false){self.detectionOnly=detectionOnly;super.init()}
    var detectionCount=0
    func reportMismatch(_ candidate:MismatchRecoveryPlan,_ snap:MismatchSnapshot){
        detectionCount+=1
        log(detectionOnly ? "mismatch_detected_only":"mismatch_notice",["text":snap.text,"physicalKeys":candidate.replayRoman,"caret":candidate.caret,"count":detectionCount])
        plan=nil;matchCount=0;matchingRoman=""
        statusText=detectionOnly ? "감지 전용": "복구 확인 중"
    }
    let marker:Int64=0x48414E514155544F
    var statusText="대기 중"
    var enabled=false
    var target:NSRunningApplication?
    var followsFrontmost=false
    func followFrontmost(){
        guard followsFrontmost else{return}
        let front=NSWorkspace.shared.frontmostApplication
        let next=Self.supports(front) ? front:nil
        switchTarget(to:next)
    }
    func switchTarget(to next:NSRunningApplication?){
        guard next?.processIdentifier != target?.processIdentifier else{return}
        if recovering{park("frontmost_app_changed")}
        recoveryEpoch+=1;plan=nil;planElement=nil;locked=nil;lastText=nil;heldKeys=[]
        target=next;ax=next.map{AXUIElementCreateApplication($0.processIdentifier)}
        if let ax{AXUIElementSetMessagingTimeout(ax,0.05)}
        preparationAttempts=0;nextPreparation=0;focusErrors=[:];focusRoute=""
        log("target_app_changed",["pid":next?.processIdentifier ?? 0,"bundleID":next?.bundleIdentifier ?? "","name":next?.localizedName ?? ""])
    }
    var ax:AXUIElement?
    var locked:AXUIElement?
    var tap:CFMachPort?
    var switchGate:MismatchSwitchGate?
    var recoverySourceID=mismatchKoreanID
    var intendedSource=mismatchKoreanID
    var pendingSources:[Int64:String]=[:]
    // Queue identity must not depend on mutable CGEvent source user data.
    var bufferedIdentities:[ObjectIdentifier:Int64]=[:]
    func bufferedID(_ event:CGEvent)->Int64 { bufferedIdentities[ObjectIdentifier(event)] ?? event.getIntegerValueField(.eventSourceUserData) }
    var keyDownSources:[Int64:String]=[:]
    func userToggleDuringRecovery(){
        guard recovering else{return}
        intendedSource=intendedSource==recoverySourceID ? englishID:recoverySourceID
        log("user_source_boundary",["source":intendedSource,"afterBufferedID":nextBufferedID,"origin":"right_command"])
    }
    var auditIncomplete=false
    var sessionSequence:UInt64=0
    var sessionScope=""
    var runSource:CFRunLoopSource?
    var timer:Timer?
    var lastSource=""
    var englishID="com.apple.keylayout.ABC"
    var plan:MismatchRecoveryPlan?
    var planElement:AXUIElement?
    var planStart=0.0
    var matchCount=0
    var matchingRoman=""
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
            action()
            if self.traceLatency{self.log("callback_finished",["id":id,"line":line,"durationMs":(ProcessInfo.processInfo.systemUptime-start)*1000])}
        }
    }
    var currentPlan:MismatchRecoveryPlan?
    var lastText:String?
    var lastSampleSnapshot:MismatchSnapshot?
    var unavailableReason=""
    var lastAvailability=""
    var sourceCycleStarted=false
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
    func currentSource()->String { testSource?() ?? mismatchSourceID() }
    let systemSwitch=MismatchSourceSwitch()
    var ledger:MismatchReplayLedger?
    var ledgerAfterRepair:MismatchReplayLedger?
    var snapshotWaitStarted:Double?
    func chooseSource(_ id:String)->OSStatus {
        guard !detectionOnly else{return -50}
        if let testSelectSource{return testSelectSource(id)}
        if currentSource()==id{return noErr}
        guard id==recoverySourceID || id==englishID else{return -50}
        let result=systemSwitch.request(marker:marker,valid:{[weak self] in
            guard let self,self.recovering else{return false}
            if let testSnapshot=self.testSnapshot{return testSnapshot() != nil}
            return (!IsSecureEventInputEnabled() && NSWorkspace.shared.frontmostApplication?.processIdentifier==self.target?.processIdentifier)
        },posted:{[weak self] event in
            guard let self else{return}
            var row:[String:Any]=["eventType":event.type.rawValue];row["purpose"]="source_shortcut"
            self.log("key_post_requested",row)
        })
        log("system_source_requested",["target":id,"result":result,"method":"configured_control_space"])
        return result
    }
    // Preserve the baseline for same-build A/B tests.
    var selectionOverwrite = true
    var perKeyAX = false
    var testFastContext:(()->Bool)?
    func fastRecoveryContext()->Bool {
        if let testFastContext{return testFastContext()}
        if testSnapshot != nil{return true}
        return AXIsProcessTrusted() && !IsSecureEventInputEnabled() && target?.isTerminated==false &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier==target?.processIdentifier
    }
    let snapshotWorker=MismatchSnapshotWorker()
    var asyncRecoveryReads = true
    var asyncRequest:(id:Int,epoch:Int,stage:String)?
    var asyncReady:(epoch:Int,stage:String,result:MismatchSnapshotResult)?
    var testAsyncRead:((@escaping (MismatchSnapshotResult)->Void)->Void)?
    func requestRecoverySnapshot(_ stage:String,retry:@escaping ()->Void) {
        if let request=asyncRequest,request.epoch==recoveryEpoch{return}
        traceSequence+=1
        let id=traceSequence,epoch=recoveryEpoch,pid=target?.processIdentifier ?? 0
        asyncRequest=(id,epoch,stage)
        if traceLatency{log("async_snapshot_started",["id":id,"stage":stage])}
        let completion:(MismatchSnapshotResult)->Void = {[weak self] result in
            guard let self,self.recovering,self.recoveryEpoch==epoch,self.asyncRequest?.id==id else{return}
            self.asyncRequest=nil
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
    func post(_ event:CGEvent) { guard !detectionOnly else{return};log("key_post_requested",["eventType":event.type.rawValue]);if let testPost { testPost(event) } else { event.post(tap:.cgSessionEventTap) } }
    let systemAX=AXUIElementCreateSystemWide()
    var focusErrors:[String:String]=[:]
    var focusRoute=""
    var preparationAttempts=0
    var nextPreparation=0.0
    var testFocusedRead:((AXUIElement)->AXUIElement?)?
    var heldKeys=Set<Int64>()
    func attr(_ element:AXUIElement,_ name:String)->CFTypeRef?{var value:CFTypeRef?;guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else{return nil};return value}
    func focusedElement(_ application:AXUIElement,pid:pid_t)->AXUIElement? {
        for (route,root) in [("application",application),("system",systemAX)] {
            AXUIElementSetMessagingTimeout(root,recovering ? focusQueryTimeout:0.05)
            let queryStart=ProcessInfo.processInfo.systemUptime
            if traceLatency{log("focus_query_started",["snapshotID":activeSnapshotID,"route":route,"uptime":queryStart])}
            defer{if traceLatency{log("focus_query_finished",["snapshotID":activeSnapshotID,"route":route,"durationMs":(ProcessInfo.processInfo.systemUptime-queryStart)*1000])}}
            var raw:CFTypeRef?
            let result:AXError
            if let testFocusedRead{raw=testFocusedRead(root);result=raw == nil ? .noValue:.success}
            else{result=AXUIElementCopyAttributeValue(root,kAXFocusedUIElementAttribute as CFString,&raw)}
            guard result == .success,let raw,CFGetTypeID(raw)==AXUIElementGetTypeID() else{
                let detail="\(result.rawValue):\(raw == nil ? "nil":"unexpected_type")"
                if focusErrors[route] != detail{focusErrors[route]=detail;log("focus_read_failed",["route":route,"error":detail,"targetPID":pid])}
                continue
            }
            let element=raw as! AXUIElement
            var ownerPID:pid_t=0
            guard AXUIElementGetPid(element,&ownerPID) == .success,ownerPID==pid else{continue}
            AXUIElementSetMessagingTimeout(element,0.05)
            focusErrors[route]=nil
            if focusRoute != route{focusRoute=route;log("focus_route",["route":route,"ownerPID":ownerPID])}
            return element
        }
        return nil
    }
    func snapshot(includeContent:Bool=true)->MismatchSnapshot?{
        let queryStart=ProcessInfo.processInfo.systemUptime,previousID=activeSnapshotID
        traceSequence+=1;let id=traceSequence;activeSnapshotID=id
        if traceLatency{log("snapshot_started",["id":id,"stage":snapshotStage,"includeContent":includeContent,"uptime":queryStart])}
        defer{
            if traceLatency{log("snapshot_finished",["id":id,"stage":snapshotStage,"includeContent":includeContent,"durationMs":(ProcessInfo.processInfo.systemUptime-queryStart)*1000,"unavailableReason":unavailableReason])}
            activeSnapshotID=previousID
            lastCompletedSnapshotID=id
        }
        if let testSnapshot{return testSnapshot()}
        unavailableReason=""
        guard AXIsProcessTrusted() else{unavailableReason="accessibility_permission";return nil}
        guard !IsSecureEventInputEnabled() else{unavailableReason="secure_input";return nil}
        guard let target,!target.isTerminated,NSWorkspace.shared.frontmostApplication?.processIdentifier==target.processIdentifier else{unavailableReason="target_not_frontmost";return nil}
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
        guard let role=list[0] as? String else{unavailableReason="role_unreadable";return nil}
        guard ["AXTextArea","AXTextField"].contains(role) else{unavailableReason="not_supported_text_field";return nil}
        guard list[1] as? String != "AXSecureTextField" else{unavailableReason="secure_text_field";return nil}
        if !includeContent{return MismatchSnapshot(element:element,text:"",selection:NSRange(location:0,length:0))}
        guard let text=list[2] as? String else{unavailableReason="text_unreadable";return nil}
        let raw=list[3]
        guard CFGetTypeID(raw)==AXValueGetTypeID() else{unavailableReason="selection_unreadable";return nil}
        var range=CFRange();guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0,range.location+range.length<=text.utf16.count else{unavailableReason="selection_invalid";return nil}
        let selection=NSRange(location:range.location,length:range.length)
        guard let content=MismatchTextReader.read(element,value:text,selection:selection) else{unavailableReason="editor_coordinates_unverified";return nil}
        return MismatchSnapshot(element:element,text:content.text,selection:selection,selectedText:content.selectedText)
    }
    func observeAvailability(_ snap:MismatchSnapshot?){
        let availability=snap == nil ? unavailableReason : "tracking"
        if availability != lastAvailability {
            log("tracking_state",["state":availability])
            lastAvailability=availability
        }
        guard let snap else{
            let retryable=unavailableReason=="editor_coordinates_unverified" &&
                currentSource()==(plan?.sourceID ?? recoverySourceID) && planElement != nil &&
                ProcessInfo.processInfo.systemUptime-planStart<=0.2
            if !retryable {plan=nil;heldKeys=[]}
            if retryable && plan != nil {log("candidate_read_retry",["ageMs":(ProcessInfo.processInfo.systemUptime-planStart)*1000])}
            statusText=unavailableReason == "focused_element_unreadable" ? "복구 불가 · 입력칸을 읽지 못했습니다. 현재 키는 차단하지 않습니다.":"감지 대기: " + unavailableReason
            return
        }
        if locked == nil || !CFEqual(locked!,snap.element){
            log("field_changed",["previousFieldExisted":locked != nil,"source":mismatchSourceID(),"text":snap.text,"selection":[snap.selection.location,snap.selection.length]])
            locked=snap.element;plan=nil;planElement=nil;matchCount=0;matchingRoman="";heldKeys=[];lastText=nil
            // A new composer is a new transaction boundary. Never reuse the old field's repair range.
            lastSource=mismatchSourceID()
        }
        statusText="감지 중 · " + (MismatchKeyboardLayout.supports(currentSource()) ? "한국어" : "영어/기타")
    }
    func setRange(_ element:AXUIElement,_ range:NSRange)->AXError{guard !detectionOnly else{return .cannotComplete};if let testSetRange{return testSetRange(element,range)};var cf=CFRange(location:range.location,length:range.length);return AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&cf)!)}
    let logFormatter:ISO8601DateFormatter = {
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f
    }()
    func sourceChanged(_ now:String,_ snap:MismatchSnapshot){
        guard now != lastSource else{return}
        let previous=lastSource;lastSource=now;log("source_change",["from":previous,"to":now])
        plan=nil;matchCount=0;matchingRoman=""
        if previous.hasPrefix("com.apple.keylayout."){englishID=previous}

    }
    func event(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>?{
        let handlerStart=ProcessInfo.processInfo.systemUptime
        let beganRecovering=recovering
        defer{if traceLatency{log("event_handler_finished",["eventType":type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode),"beganRecovering":beganRecovering,"isProbeEvent":event.getIntegerValueField(.eventSourceUserData)==marker,"durationMs":(ProcessInfo.processInfo.systemUptime-handlerStart)*1000])}}
        if enabled{followFrontmost()}
        if OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)) || event.getIntegerValueField(.eventSourceUserData)==0x454F5448{return Unmanaged.passUnretained(event)}
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            suspended=true
            DispatchQueue.main.async{[weak self] in self?.suspend("tap_disabled")}
            return Unmanaged.passUnretained(event)
        }
        guard enabled,!suspended else{return Unmanaged.passUnretained(event)}
        guard canObserve() else{
            if recovering{park("another_edit_started")}else{cancelDetection()}
            return Unmanaged.passUnretained(event)
        }
        let keyboard=type == .keyDown || type == .keyUp || type == .flagsChanged
        var sampled:MismatchSnapshot?
        // Observe the previous key's actual insertion before allowing the next
        // printable key through. Start the queue at the first confirmed mismatch.
        if !recovering,type == .keyDown,
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty,
           MismatchRecoveryPlan.character(UInt16(event.getIntegerValueField(.keyboardEventKeycode)),event.flags.contains(.maskShift)) != nil {
            sample();sampled=lastSampleSnapshot
        }
        if recovering{
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
                if let copy=event.copy(){
                    copy.type=type
                    let code=event.getIntegerValueField(.keyboardEventKeycode)
                    if type == .keyDown{keyDownSources[code]=intendedSource}
                    let inputSource=keyDownSources[code] ?? intendedSource
                    if type == .keyUp{keyDownSources.removeValue(forKey:code)}
                    nextBufferedID+=1;pendingSources[nextBufferedID]=inputSource
                    bufferedIdentities[ObjectIdentifier(copy)]=nextBufferedID;pending.append(copy)
                    log("key_buffered",["id":nextBufferedID,"sessionSequence":sessionSequence,"inputSource":inputSource,"eventType":type.rawValue,"eventTimestamp":String(event.timestamp),"code":event.getIntegerValueField(.keyboardEventKeycode),"flags":event.flags.rawValue])
                }else{abort("buffer_allocation_failed");return Unmanaged.passUnretained(event)}
                if pending.count>256{abort("buffer_limit")}
                return nil
            }
            abort("mouse_during_recovery");return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            heldKeys.remove(event.getIntegerValueField(.keyboardEventKeycode))
            log("key_observed",["eventType":type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode),"source":mismatchSourceID(),"candidateActive":plan != nil])
            return Unmanaged.passUnretained(event)
        }
        // sample() already read this callback's pre-insertion state. No edit or
        // event delivery occurred between that read and this decision.
        let observed=sampled ?? snapshot();observeAvailability(observed)
        guard let snap=observed else{
            // A new untracked event breaks the exact key sequence. Sampling-only
            // outages may retry, but never silently omit a key from that sequence.
            plan=nil;matchCount=0
            if type == .keyDown,unavailableReason != "target_not_frontmost",unavailableReason != "secure_input",unavailableReason != "accessibility_permission" {
                log("untracked_key",["code":event.getIntegerValueField(.keyboardEventKeycode),"source":mismatchSourceID(),"reason":unavailableReason])
            }
            return Unmanaged.passUnretained(event)
        }
        if keyboard{log("key_observed",["eventType":type.rawValue,"code":event.getIntegerValueField(.keyboardEventKeycode),"source":mismatchSourceID(),"candidateActive":plan != nil])}
        sourceChanged(currentSource(),snap)
        if type == .keyDown{heldKeys.insert(event.getIntegerValueField(.keyboardEventKeycode))}
        if type == .keyUp{heldKeys.remove(event.getIntegerValueField(.keyboardEventKeycode))}
        if type == .keyDown{
            let disallowed=event.flags.intersection([.maskCommand,.maskControl,.maskAlternate])
            guard MismatchKeyboardLayout.supports(currentSource()),disallowed.isEmpty,
                  let candidate=MismatchRecoveryPlan.next(previous:plan,text:snap.text,selection:snap.selection,
                    code:UInt16(event.getIntegerValueField(.keyboardEventKeycode)),shift:event.flags.contains(.maskShift),sourceID:currentSource()) else{
                plan=nil;matchCount=0;log("candidate_cancelled",["reason":"non_korean_or_non_printable_or_selection"]);return Unmanaged.passUnretained(event)
            }
            plan=candidate;planElement=snap.element;planStart=ProcessInfo.processInfo.systemUptime
            matchCount=0;matchingRoman=""

            log("key",["code":event.getIntegerValueField(.keyboardEventKeycode),"roman":candidate.roman,"source":mismatchSourceID()])
        }else if !keyboard || (type == .flagsChanged && !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty){plan=nil;log("candidate_cancelled",["reason":"navigation_or_modifier"])}
        return Unmanaged.passUnretained(event)
    }
    func sample(){
        lastSampleSnapshot=nil
        if enabled{followFrontmost()}
        guard enabled,!suspended,!recovering else{return}
        guard canObserve() else{cancelDetection();return}
        let observed=snapshot();observeAvailability(observed)
        guard let snap=observed else{return}
        lastSampleSnapshot=snap
        sourceChanged(currentSource(),snap)
        if lastText != snap.text{log("text",["text":snap.text,"source":mismatchSourceID(),"selection":[snap.selection.location,snap.selection.length]]);lastText=snap.text}
        guard let candidate=plan else{return}
        if ProcessInfo.processInfo.systemUptime-planStart>5{log("candidate_cancelled",["reason":"timeout"]);plan=nil;return}
        if candidate.matches(text:snap.text,selection:snap.selection){
            if matchingRoman==candidate.roman{matchCount+=1}else{matchingRoman=candidate.roman;matchCount=1}
            // Exact text/range + the observed physical sequence establishes the
            // mismatch. Do not wait for all keys to be released: their up events
            // are preserved in the same ordered queue as subsequent down events.
            if detectionOnly{reportMismatch(candidate,snap)}else{beginRecovery(candidate,snap)}
        }else{matchCount=0}
    }
    func beginRecovery(_ candidate:MismatchRecoveryPlan,_ snap:MismatchSnapshot){
        guard canBeginRepair(),MismatchKeyboardLayout.supports(candidate.sourceID),candidate.matches(text:snap.text,selection:snap.selection) else{return}
        guard !detectionOnly else{reportMismatch(candidate,snap);return}
        recoverySourceID=candidate.sourceID
        var candidate=candidate
        candidate.captureObserved(text:snap.text)
        var writable:DarwinBoolean=false
        let canSelect=testSelectionWritable?(snap.element) ?? (AXUIElementIsAttributeSettable(snap.element,kAXSelectedTextRangeAttribute as CFString,&writable) == .success && writable.boolValue)
        guard canSelect else{reportMismatch(candidate,snap);plan=nil;log("recovery_unsupported",["reason":"selection_not_writable"]);return}
        recoveryEpoch+=1
        verifiedProgressEvents = -1
        recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        willBeginRepair()
        recovering=true;rollingBack=false;replayStarted=false;currentPlan=candidate;plan=nil;pending=[];nextBufferedID=0;postedBuffered=0;sourceCycleStarted=true
        intendedSource=recoverySourceID;pendingSources=[:];bufferedIdentities=[:];keyDownSources=Dictionary(uniqueKeysWithValues:heldKeys.map{($0,recoverySourceID)})
        koreanRetries=0;interruptedSourceRestores=0;ledger=nil;ledgerAfterRepair=nil;snapshotWaitStarted=nil
        log("mismatch_confirmed",["roman":candidate.roman,"text":snap.text])
        cycleAndReplay(candidate,snap)
        reportMismatch(candidate,snap)
    }
    func waitSource(_ id:String,remaining:Int=45,completion:@escaping ()->Void){
        guard recovering,!rollingBack else{return}
        guard let _=recoverySnapshot("source_wait",retry:{[weak self] in self?.waitSource(id,remaining:remaining,completion:completion)}) else{return}
        if !systemSwitch.busy,currentSource()==id{completion();return}
        guard remaining>0 else{log("source_switch_timeout",["wanted":id,"actual":currentSource()]);abort("source_switch_timeout");return}
        if remaining==30,!systemSwitch.busy,currentSource() != id {
            let result=testSelectSource?(id) ?? mismatchSelectSource(id)
            log("source_wait_direct_fallback",["target":id,"result":result,"actual":currentSource()])
        }
        later(0.01){[weak self] in self?.waitSource(id,remaining:remaining-1,completion:completion)}
    }
    func cycleAndReplay(_ candidate:MismatchRecoveryPlan,_ snap:MismatchSnapshot){
        let result=chooseSource(englishID);log("cycle_english",["result":result])
        guard result==noErr else{abort("english_selection_failed");return}
        waitSource(englishID){[weak self] in
            guard let self else{return}
            let result=self.chooseSource(recoverySourceID);self.log("cycle_korean",["result":result])
            guard result==noErr else{self.abort("korean_selection_failed");return}
            self.waitSource(recoverySourceID){[weak self] in self?.replaceAndReplay(candidate,snap)}
        }
    }
    func replaceAndReplay(_ candidate:MismatchRecoveryPlan,_ before:MismatchSnapshot,remaining:Int=20){
        guard recovering,!rollingBack else{return}
        guard let current=recoverySnapshot("pre_edit",retry:{[weak self] in self?.replaceAndReplay(candidate,before,remaining:remaining)}) else{return}
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
        guard currentSource()==recoverySourceID else{
            log("waiting_for_korean_source",["source":mismatchSourceID(),"remaining":remaining])
            guard remaining>0 else{abort("korean_source_timeout");return}
            self.later(0.01){[weak self] in self?.replaceAndReplay(candidate,before,remaining:remaining-1)};return
        }
        let range=NSRange(location:candidate.caret,length:candidate.roman.utf16.count)
        guard setRange(current.element,range) == .success else{abort("selection_failed");return}
        log("selection_requested",["range":[range.location,range.length],"originalSelection":[current.selection.location,current.selection.length]])
        awaitSelection(candidate,current,range,remaining:15)
    }
    func awaitSelection(_ candidate:MismatchRecoveryPlan,_ before:MismatchSnapshot,_ range:NSRange,remaining:Int){
        guard recovering,!rollingBack else{return}
        guard let selected=recoverySnapshot("selection",retry:{[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining)}) else{return}
        guard CFEqual(selected.element,before.element),selected.text==before.text else{abort("selection_context_changed");return}
        if currentSource() != recoverySourceID {
            restoreInterruptedSource("selection"){[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining)};return
        }
        log("selection_observed",["requested":[range.location,range.length],"observed":[selected.selection.location,selected.selection.length],"remaining":remaining])
        guard selected.selection==range else{
            if remaining>0{self.later(0.01){[weak self] in self?.awaitSelection(candidate,before,range,remaining:remaining-1)}}
            else{abort("selection_not_applied")}
            return
        }
        if testSnapshot==nil && testAsyncRead==nil {
            guard selected.selectedText==candidate.roman else{abort("selected_text_not_verified");return}
        }
        if selectionOverwrite {
            log("selection_overwrite_started",["range":[range.location,range.length]])
            replayCandidate(candidate);return
        }
        // Some editors report AXSelectedText success without changing the text.
        // Delete only the range we have just observed, through the editor's key path.
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:true),
              let up=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:false) else{abort("delete_event_allocation_failed");return}
        for event in [down,up]{event.flags=[];event.setIntegerValueField(.eventSourceUserData,value:marker);post(event)}
        log("delete_requested",["method":"backspace","range":[range.location,range.length]])
        awaitDeletion(candidate,before.element,remaining:15)
    }
    // A source notification may arrive after the first successful observation.
    // Keep the transaction and queue intact; never repeat an edit just because
    // the source changed. The resumed stage rechecks its own text/caret proof.
    func restoreInterruptedSource(_ stage:String,targetSource:String?=nil,resume:@escaping ()->Void){
        let targetSource=targetSource ?? recoverySourceID
        guard interruptedSourceRestores<2,ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park(stage+"_source_restore_exhausted");return}
        if systemSwitch.busy{later(0.01){[weak self] in self?.restoreInterruptedSource(stage,targetSource:targetSource,resume:resume)};return}
        interruptedSourceRestores+=1
        log("interrupted_source_restore",["stage":stage,"source":currentSource(),"targetSource":targetSource,"intendedSource":intendedSource,"attempt":interruptedSourceRestores,"pendingEvents":pending.count])
        // This is a known target restoration, not a toggle. Another Control-
        // Space can be lost among modifier transitions or toggle the wrong way.
        let result=testSelectSource?(targetSource) ?? mismatchSelectSource(targetSource)
        log("interrupted_source_direct_selection",["target":targetSource,"result":result,"stage":stage])
        guard result==noErr else{park(stage+"_source_restore_failed");return}
        waitSource(targetSource,completion:resume)
    }
    func awaitDeletion(_ candidate:MismatchRecoveryPlan,_ element:AXUIElement,remaining:Int){
        guard recovering,!rollingBack else{return}
        guard let deleted=recoverySnapshot("deletion",retry:{[weak self] in self?.awaitDeletion(candidate,element,remaining:remaining)}) else{return}
        guard CFEqual(deleted.element,element) else{abort("delete_context_changed");return}
        if currentSource() != recoverySourceID {
            restoreInterruptedSource("deletion"){[weak self] in self?.awaitDeletion(candidate,element,remaining:remaining)};return
        }
        let verified=deleted.text==candidate.before && deleted.selection==NSRange(location:candidate.caret,length:0)
        log("deletion_observed",["verified":verified,"text":deleted.text,"selection":[deleted.selection.location,deleted.selection.length],"remaining":remaining])
        guard verified else{
            if remaining>0{self.later(0.01){[weak self] in self?.awaitDeletion(candidate,element,remaining:remaining-1)}}
            else{abort("delete_not_verified")}
            return
        }
        replayCandidate(candidate)
    }
    func replayCandidate(_ candidate:MismatchRecoveryPlan){
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
            drain([],verifiedSnapshot:snap);return
        }
        // Deletion was already observed before replay. A complete reappearance
        // of exactly those Roman keys is a failed replay, not missing AX output.
        // retryKorean takes a fresh snapshot again before authorizing any edit.
        var romanCandidate=candidate
        romanCandidate.roman=candidate.replayRoman;romanCandidate.verifiedReplacement=nil
        if romanCandidate.matches(text:snap.text,selection:snap.selection){
            lastRomanReplayDelayMs=(ProcessInfo.processInfo.systemUptime-replayIssuedAt)*1000
            log("roman_replay_confirmed",["attempt":koreanRetries+1,"replayToObservationMs":lastRomanReplayDelayMs!,"remainingPolls":remaining])
            retryKorean(romanCandidate,snap);return
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
        // All replayed letters are visibly present as Roman text. Re-editing this
        // exact range cannot duplicate them; keep the following input queue intact.
        replayStarted=false
        guard koreanRetries<2,ProcessInfo.processInfo.systemUptime+0.4<recoveryDeadline else{
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
    func drain(_ prefix:[CGEvent],rollback:Bool=false,sourceAttempts:Int=45,verifiedSnapshot:MismatchSnapshot?=nil){
        guard recovering,rollingBack==rollback else{return}
        guard ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park("delivery_deadline");return}
        guard let snap=verifiedSnapshot ?? recoverySnapshot("delivery",retry:{[weak self] in self?.drain(prefix,rollback:rollback,sourceAttempts:sourceAttempts)}) else{return}
        if systemSwitch.busy{later(0.01){[weak self] in self?.drain(prefix,rollback:rollback,sourceAttempts:sourceAttempts)};return}
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
            later(0.01){[weak self] in self?.drain(prefix,rollback:rollback,sourceAttempts:sourceAttempts-1)};return
        }
        let count=pending.prefix{$0.type == .keyUp || (pendingSources[bufferedID($0)] ?? recoverySourceID)==nextSource}.count
        let group=Array(pending.prefix(count))
        let all=prefix+group
        var nextLedger=ledger
        var deliveredKeys:[(UInt16,Bool)]=[]
        if !rollback,let _=nextLedger {
            var keys:[(UInt16,Bool)]=[]
            for event in all where event.type == .keyDown {
                let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode)),shift=event.flags.contains(.maskShift)
                guard event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty,MismatchRecoveryPlan.character(code,shift) != nil else{park("unsupported_buffered_edit");return}
                keys.append((code,shift))
            }
            deliveredKeys=keys
            nextLedger?.append(source:nextSource,keys:keys)
        }
        let prepared=all.compactMap{prepareEvent($0)}
        guard prepared.count==all.count else{if rollback{park("event_allocation_failed")}else{abort("event_allocation_failed")};return}
        let buffered=group;pending.removeFirst(count)
        for (index,event) in prepared.enumerated(){
            post(event)
            if index>=prefix.count {
                let saved=buffered[index-prefix.count];postedBuffered+=1
                log("buffer_event_posted",["inputSource":pendingSources[bufferedID(saved)] ?? recoverySourceID,"deliverySource":nextSource,"id":bufferedID(saved),"originTimestamp":String(saved.timestamp),"postedTimestamp":String(event.timestamp),"code":saved.getIntegerValueField(.keyboardEventKeycode),"eventType":saved.type.rawValue,"rollback":rollback])
            }
        }
        replayCount+=prepared.count
        if !rollback,let expected=nextLedger {
            let roman=nextSource==recoverySourceID ? deliveredKeys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined():""
            // Yield after posting: an immediate synchronous AX request can reach
            // the editor before its queued key events. Verify on the next turn.
            later(0){[weak self] in self?.verifyBuffered(expected,before:snap,remaining:30,roman:roman)}
        }else{later(0.02){[weak self] in self?.finishDelivery(rollback:rollback)}}
    }
    func verifyBuffered(_ expected:MismatchReplayLedger,before:MismatchSnapshot,remaining:Int,roman:String="",reopenComposition:Bool=false){
        guard recovering,!rollingBack else{return}
        guard let snap=recoverySnapshot("buffer_verification",retry:{[weak self] in self?.verifyBuffered(expected,before:before,remaining:remaining,roman:roman,reopenComposition:reopenComposition)}) else{return}
        if traceLatency{log("buffer_verification_observed",["snapshotID":lastCompletedSnapshotID,"remaining":remaining,"postedEvents":postedBuffered,"actual":snap.text,"expected":expected.text,"selection":[snap.selection.location,snap.selection.length],"expectedSelection":[expected.selection.location,expected.selection.length],"textMatches":snap.text==expected.text,"selectionMatches":snap.selection==expected.selection])}
        if let wanted=expected.segments.last?.source,currentSource() != wanted {
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
        guard remaining>0 else{
            log("buffer_text_failed",["expected":expected.text,"actual":snap.text,"selection":[snap.selection.location,snap.selection.length]])
            park("buffer_result_not_verified");return
        }
        later(0.01){[weak self] in self?.verifyBuffered(expected,before:before,remaining:remaining-1,roman:roman,reopenComposition:reopenComposition)}
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
        if !pending.isEmpty || currentSource() != intendedSource{drain([],rollback:rollback,verifiedSnapshot:verifiedSnapshot);return}
        recoveryEpoch+=1;recovering=false;rollingBack=false;currentPlan=nil;lastSource=currentSource();heldKeys=[]
        log(rollback ? "rollback_finished":"recovery_finished",["bufferedEvents":nextBufferedID,"postedEvents":postedBuffered,"pendingEvents":0,"textVerified":!rollback && ledger != nil,"postingIsNotAppAcknowledgment":rollback || ledger==nil])
        if let snap=verifiedSnapshot{log("after_replay_snapshot",["text":snap.text,"source":lastSource,"selection":[snap.selection.location,snap.selection.length]])}
        statusText=rollback ? "이번 복구 중단 · 대기 키 반환 후 감시 계속":"복구 문장 확인 완료 · 이어서 입력하세요."
        if stopAfterRollback{stopAfterRollback=false;closeSession()}
    }
    func abort(_ reason:String){
        guard recovering else{return}
        if rollingBack{return}
        recoveryEpoch+=1;asyncReady=nil
        rollingBack=true;rollbackReason=reason;plan=nil
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
            drain([],rollback:true);return
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
        // Focus/text changes cannot be undone safely. Keep the queue in memory and
        // expose it to the user, and never inject it into a different field.
        log("pending_retained",["reason":reason,"events":pending.map{["id":bufferedID($0),"eventType":Int($0.type.rawValue),"code":$0.getIntegerValueField(.keyboardEventKeycode),"flags":$0.flags.rawValue]}])
        systemSwitch.cancel();snapshotWaitStarted=nil
        recoveryEpoch+=1
        retained.append(contentsOf:pending);pending=[]
        suspended=true
        didRetainInput()
        recovering=false;rollingBack=false;plan=nil;planElement=nil;currentPlan=nil;heldKeys=[];matchCount=0
        log("monitor_suspended")
        statusText="입력 복구 중단 · 보관된 입력을 메뉴에서 확인하세요."

        if stopAfterRollback{stopAfterRollback=false;closeSession()}
    }
    @objc func copyPending(){
        let text=(retained+pending).filter{$0.type == .keyDown}.map{event -> String in
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key=MismatchRecoveryPlan.keys[code],event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty else{return "[keyCode:\(code)]"}
            return event.flags.contains(.maskShift) ? key.uppercased():key
        }.joined()
        guard !text.isEmpty else{retained=[];pending=[];suspended=false;return}
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
        statusText="보관된 입력을 복사했습니다."
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
    var didRetainInput:()->Void = {}
    var suspended=false
    static func supports(_ app:NSRunningApplication?)->Bool {
        guard let app,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else{return false}
        return !app.isTerminated
    }
    func cancelDetection(){plan=nil;planElement=nil;lastSampleSnapshot=nil;heldKeys=[];matchCount=0}
    func log(_ kind:String,_ fields:@autoclosure ()->[String:Any]=[:]) {
        // Deliberately never evaluate fields: they can contain typed text, keys,
        // editor identifiers or clipboard content copied from the experiment.
        if ["mismatch_confirmed","korean_result_verified","recovery_finished","pending_retained","rollback_finished","start_failed"].contains(kind) {
            InputDiagnostics.shared.record("mismatch."+kind)
        }
    }
    func start(){
        guard !enabled,tap==nil,!suspended,retained.isEmpty,AXIsProcessTrusted() else{return}
        followsFrontmost=true;target=nil;ax=nil
        let mask:CGEventMask=[CGEventType.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].reduce(0){$0 | (1 << $1.rawValue)}
        tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,event,ref in
            let owner=Unmanaged<MismatchRecoveryEngine>.fromOpaque(ref!).takeUnretainedValue()
            return owner.event(type,event)
        },userInfo:Unmanaged.passUnretained(self).toOpaque())
        guard let tap else{log("start_failed");return}
        runSource=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),runSource,.commonModes)
        enabled=true;recovering=false;plan=nil;locked=nil;lastText=nil;lastSource=mismatchSourceID();started=ProcessInfo.processInfo.systemUptime
        switchGate=MismatchSwitchGate(accepts:{[weak self] in
            guard let self,self.enabled,!self.suspended,self.recovering,self.canToggleRightCommand(),!IsSecureEventInputEnabled(),let target=self.target else{return false}
            return NSWorkspace.shared.frontmostApplication?.processIdentifier==target.processIdentifier
        },switched:{[weak self] in self?.userToggleDuringRecovery()})
        switchGate?.failed = { [weak self] in self?.suspended=true;self?.suspend("switch_gate_disabled") }
        guard switchGate!.start() else{closeSession();log("start_failed");return}
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in self?.sample()}
        followFrontmost()
    }
    func suspend(_ reason:String){
        if recovering || !pending.isEmpty{park(reason)}
        closeSession()
    }
    func closeSession(){
        if !pending.isEmpty{retained.append(contentsOf:pending);pending=[];suspended=true;didRetainInput()}
        recoveryEpoch+=1;asyncReady=nil;asyncRequest=nil
        systemSwitch.cancel();switchGate?.stop();switchGate=nil
        enabled=false;recovering=false;timer?.invalidate();timer=nil;cancelDetection()
        if let tap{CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)};tap=nil
        if let runSource{CFRunLoopRemoveSource(CFRunLoopGetMain(),runSource,.commonModes);CFRunLoopSourceInvalidate(runSource)};runSource=nil
    }
}
