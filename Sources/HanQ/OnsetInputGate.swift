import AppKit

// Shared state uses a bounded lock acquisition (2ms maximum requested wait).
// No AX, disk I/O, or synchronous dispatch to the main thread occurs in receive().
final class OnsetInputGate {
    static func isRecoveryMarker(_ value:Int64)->Bool {
        UInt64(bitPattern:value) >> 32 == 0x48414E51
    }
    struct Reservation { let code:UInt16;let shift:Bool;let time:Double;let sourceID:String }
    struct PassedInput {
        let first:Reservation
        var baselineRevision:Int?
        var revision=1
        var keys:[(UInt16,Bool)]
        var pressed:Set<UInt16>
    }
    private(set) var reentryTraceEnabled=false
    private var reentryFrames:[OnsetReentryDiagnostics.Frame]=[]
    private var reentryDropped=0
    private var reentrySequence=0
    private var reentryInputSequence=0
    private var reentryHintReason:OnsetReentryDiagnostics.Reason?
    func enableReentryTrace(){
        lock.lock();defer{lock.unlock()}
        reentryFrames.reserveCapacity(256);reentryTraceEnabled=true
    }
    // Called under the existing gate lock. No event value or input source is retained.
    private func traceReentry(_ stage:OnsetReentryDiagnostics.Stage,_ reason:OnsetReentryDiagnostics.Reason,now:Double?=nil){
        guard reentryTraceEnabled else{return}
        let time=now ?? ProcessInfo.processInfo.systemUptime
        reentrySequence+=1
        guard reentryFrames.count<256 else{reentryDropped+=1;return}
        reentryFrames.append(.init(sequence:reentrySequence,inputSequence:reentryInputSequence,decisionMonoNs:UInt64(time*1_000_000_000),stage:stage,reason:reason,
            hintMs:hintUntil>time ? Int((hintUntil-time)*1000):0,early:early != nil,expired:expiredEarly,
            holdMs:holdUntil>time ? Int((holdUntil-time)*1000):0,historyKeys:passedInput?.keys.count ?? 0,held:held.count))
    }
    func takeReentryTrace()->([OnsetReentryDiagnostics.Frame],Int){
        guard reentryTraceEnabled else{return ([],0)}
        lock.lock();defer{lock.unlock()}
        let frames=reentryFrames;let dropped=reentryDropped
        reentryFrames=[];reentryDropped=0
        return (frames,dropped)
    }
    private var passedBaselineRevision:Int?
    private var passedBaselineSource=""
    // A known field permits observation only. It never reserves or holds input.
    func configurePassedBaseline(_ revision:Int?,sourceID:String=""){
        lock.lock();defer{lock.unlock()}
        passedBaselineRevision=revision;passedBaselineSource=sourceID
    }
    private var passedInput:PassedInput?
    func passedObservation()->PassedInput? {
        lock.lock();defer{lock.unlock()}
        if let p=passedInput,ProcessInfo.processInfo.systemUptime-p.first.time>=2{traceReentry(.history,.history_expired);passedInput=nil}
        return stopped ? nil:passedInput
    }
    func discardPassed(reason:OnsetReentryDiagnostics.Reason = .cancelled){lock.lock();if passedInput != nil{traceReentry(.history,reason)};passedInput=nil;lock.unlock()}
    func claimPassed(_ observed:PassedInput)->Bool {
        lock.lock();defer{lock.unlock()}
        guard !stopped,early==nil,holdUntil==0,held.isEmpty,
              let current=passedInput,current.first.time==observed.first.time,
              current.revision==observed.revision,current.pressed.isEmpty,
              current.keys.count>=2,ProcessInfo.processInfo.systemUptime-current.first.time<2 else{traceReentry(.claim,.claim_rejected);return false}
        traceReentry(.claim,.claim_accepted)
        passedInput=nil;deferred=nil;hintUntil=0
        heartbeat=ProcessInfo.processInfo.systemUptime;holdUntil=heartbeat+0.8
        return true
    }
    // Under lock, observe only keys actually passed to the application. Never
    // retain these events or treat the record itself as permission to edit.
    private func observePassed(_ type:CGEventType,_ event:CGEvent){
        guard var p=passedInput else{return}
        let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard ProcessInfo.processInfo.systemUptime-p.first.time<2,
              type == .keyDown || type == .keyUp,
              event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskAlphaShift,.maskSecondaryFn]).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat)==0,
              (PhysicalLetterKeys.letters[code] != nil || code==49) else{traceReentry(.history,.history_invalid);passedInput=nil;return}
        if type == .keyDown {
            guard p.keys.count<16,!p.pressed.contains(code) else{traceReentry(.history,.history_limit);passedInput=nil;return}
            p.keys.append((code,event.flags.contains(.maskShift)));p.pressed.insert(code)
        }else{
            guard p.pressed.remove(code) != nil else{traceReentry(.history,.history_release_invalid);passedInput=nil;return}
        }
        p.revision+=1;passedInput=p
    }
    var early:Reservation?
    // Expiration must be acknowledged on the main thread before another hint.
    // An empty gate does not imply an empty engine-side pending queue.
    var expiredEarly=false
    private var deferred:Reservation?
    private var deferredReleasePending=false
    func deferredReservation()->Reservation? {
        lock.lock();defer{lock.unlock()}
        if let first=deferred,ProcessInfo.processInfo.systemUptime-first.time>=2{deferred=nil}
        return stopped ? nil:deferred
    }
    func discardDeferred(){lock.lock();if passedInput != nil{traceReentry(.history,.cancelled)};deferred=nil;passedInput=nil;lock.unlock()}
    func claimDeferred(_ first:Reservation)->Bool {
        lock.lock();defer{lock.unlock()}
        guard !stopped,early==nil,holdUntil==0,held.isEmpty,
              deferred?.time==first.time,ProcessInfo.processInfo.systemUptime-first.time<2 else{return false}
        deferred=nil;passedInput=nil;hintUntil=0;heartbeat=ProcessInfo.processInfo.systemUptime;holdUntil=heartbeat+0.8
        return true
    }
    // Any event passed after the first release invalidates a late observation.
    private func observeDeferredPass(_ type:CGEventType,_ event:CGEvent){
        guard let first=deferred else{return}
        if deferredReleasePending,type == .keyUp,event.getIntegerValueField(.keyboardEventKeycode)==Int64(first.code),
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty {
            deferredReleasePending=false
        }else{deferred=nil}
    }
    var earlyReleasePending=false
    var observationNeeded:(()->Void)?
    func takeEarlyExpiration()->Bool {
        lock.lock();defer{lock.unlock()}
        let expired=expiredEarly;expiredEarly=false;return expired
    }
    // Called only under lock. No editing/replay has begun while early is present.
    func expireOrFail(_ reason:String){
        guard early != nil,held.isEmpty else{fail(reason);return}
        deferred=early;deferredReleasePending=earlyReleasePending
        early=nil;earlyReleasePending=false;holdUntil=0;hintUntil=0;expiredEarly=true
        DispatchQueue.main.async{self.observationNeeded?()}
    }
    var hintUntil=0.0
    var hintSourceID="com.apple.inputmethod.Korean.2SetKorean"
    var hintNormal:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17]
    var hintShifted:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17]
    func configureEarly(_ allowed:Bool,sourceID:String="com.apple.inputmethod.Korean.2SetKorean",normal:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17],shifted:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17]){
        lock.lock();defer{lock.unlock()}
        hintUntil=allowed && !expiredEarly && !stopped ? ProcessInfo.processInfo.systemUptime+0.15:0
        if reentryTraceEnabled {
            let reason:OnsetReentryDiagnostics.Reason=stopped ? .stopped:(expiredEarly ? .expiration_unacknowledged:(allowed ? .ready:.not_outside))
            if reason != reentryHintReason{traceReentry(.hint,reason);reentryHintReason=reason}
        }
        hintSourceID=sourceID;hintNormal=normal;hintShifted=shifted
    }
    func reservation()->Reservation?{lock.lock();defer{lock.unlock()};return early}
    func claimEarly()->Bool {
        lock.lock();defer{lock.unlock()}
        guard !stopped,let first=early,ProcessInfo.processInfo.systemUptime-first.time<0.35 else{traceReentry(.claim,.claim_rejected);return false}
        traceReentry(.claim,.claim_accepted);early=nil;passedInput=nil;hintUntil=0;holdUntil=ProcessInfo.processInfo.systemUptime+0.8;return true
    }
    let lock=NSLock()
    var replaySeen=0
    func seenCount()->Int{lock.lock();defer{lock.unlock()};return replaySeen}
    private var diagnosticFailure="none"
    func diagnosticState()->String {
        lock.lock();defer{lock.unlock()}
        let now=ProcessInfo.processInfo.systemUptime
        return "gateStopped=\(stopped) gateFailure=\(OnsetSafetyDiagnostics.reason(diagnosticFailure)) gateHeld=\(held.count) gateSeen=\(replaySeen) heartbeatAgeMs=\(Int(max(0,now-heartbeat)*1000)) holdRemainingMs=\(holdUntil>0 ? Int((holdUntil-now)*1000):0)"
    }
    var stopped=false
    var holdUntil:Double=0
    var heartbeat:Double=0
    var held:[CGEvent]=[]
    let marker:Int64
    var deliver:((CGEvent)->Void)?
    var failed:((String)->Void)?
    init(marker:Int64){self.marker=marker}
    func beat(){lock.lock();heartbeat=ProcessInfo.processInfo.systemUptime;lock.unlock()}
    func begin()->Bool {
        lock.lock();defer{lock.unlock()}
        guard !stopped,held.isEmpty else{return false}
        holdUntil=ProcessInfo.processInfo.systemUptime+0.8
        return true
    }
    func take()->[CGEvent]{lock.lock();defer{lock.unlock()};let result=held;held=[];return result}
    func cancelHold(preserveUnclaimed:Bool=false)->[CGEvent]{lock.lock();defer{lock.unlock()};
        if preserveUnclaimed,held.isEmpty,let first=early{deferred=first;deferredReleasePending=earlyReleasePending}
        else if !preserveUnclaimed || !held.isEmpty{deferred=nil}
        holdUntil=0;early=nil;hintUntil=0;let result=held;held=[];return result}
    func finishIfEmpty()->Bool{lock.lock();defer{lock.unlock()};guard held.isEmpty else{return false};holdUntil=0;early=nil;traceReentry(.finish,.empty_finished);return true}
    func poll(){
        lock.lock();defer{lock.unlock()}
        guard !stopped else{return}
        let now=ProcessInfo.processInfo.systemUptime
        if holdUntil>0 && now-heartbeat>=0.25{expireOrFail("observation_stale")}
        else if holdUntil>0 && now>=holdUntil{expireOrFail("hold_deadline")}
    }
    func stop(){lock.lock();stopped=true;holdUntil=0;early=nil;deferred=nil;passedInput=nil;hintUntil=0;lock.unlock()}
    func hasActiveReplayHold()->Bool {
        lock.lock();defer{lock.unlock()}
        let now=ProcessInfo.processInfo.systemUptime
        return !stopped && early == nil && holdUntil>now && now-heartbeat<0.25
    }
    func healthy()->Bool{lock.lock();defer{lock.unlock()};return !stopped}
    func fail(_ reason:String){diagnosticFailure=reason;stopped=true;holdUntil=0;early=nil;deferred=nil;passedInput=nil;hintUntil=0;DispatchQueue.main.async{self.failed?(reason)}}
    var didProcessPhysicalKey:((CGEvent,Bool)->Void)?
    func receive(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>? {
        let result=processEvent(type,event)
        if type == .keyDown,!Self.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)),
           didProcessPhysicalKey != nil,let copy=event.copy() {
            let passed=result != nil
            DispatchQueue.main.async{self.didProcessPhysicalKey?(copy,passed)}
        }
        return result
    }
    private func processEvent(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>? {
        // A main-thread heartbeat/take can briefly own this lock. A single failed
        // try is normal contention, not an unhealthy gate. Never wait indefinitely.
        guard lock.try() || lock.lock(before:Date(timeIntervalSinceNow:0.002)) else{
            DispatchQueue.main.async{self.stop();self.failed?("gate_lock_timeout")}
            return Unmanaged.passUnretained(event)
        }
        defer{lock.unlock()}
        if event.getIntegerValueField(.eventSourceUserData)==marker{
            replaySeen+=1
            return Unmanaged.passUnretained(event)
        }
        // Old-session replay must pass, but cannot acknowledge this session or
        // be captured again as physical input.
        if Self.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)){return Unmanaged.passUnretained(event)}
        if event.getIntegerValueField(.eventSourceUserData)==0x454F5448{return Unmanaged.passUnretained(event)}
        guard !stopped else{if type == .keyDown{traceReentry(.key,.stopped)};return Unmanaged.passUnretained(event)}
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput{fail("tap_disabled");return Unmanaged.passUnretained(event)}
        let now=ProcessInfo.processInfo.systemUptime
        if reentryTraceEnabled,type == .keyDown{reentryInputSequence+=1}
        if holdUntil>0 && now-heartbeat>=0.25{expireOrFail("observation_stale");observeDeferredPass(type,event);observePassed(type,event);return Unmanaged.passUnretained(event)}
        if holdUntil>0 {
            guard now<holdUntil else{expireOrFail("hold_deadline");observeDeferredPass(type,event);observePassed(type,event);return Unmanaged.passUnretained(event)}
            guard type == .keyDown || type == .keyUp || type == .flagsChanged else{fail("pointer_during_repair");return Unmanaged.passUnretained(event)}
            guard event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty else{fail("shortcut_during_repair");return Unmanaged.passUnretained(event)}
            // The original first down already went to the editor. Its release
            // can follow it before a repair is claimed; never bypass queued input.
            if let first=early,earlyReleasePending,type == .keyUp,
               UInt16(event.getIntegerValueField(.keyboardEventKeycode))==first.code {
                earlyReleasePending=false;observePassed(type,event);return Unmanaged.passUnretained(event)
            }
            // Until a verified repair claims this reservation, following input
            // belongs to the editor. Never quarantine keys for an unknown field.
            if early != nil {
                early=nil;earlyReleasePending=false;holdUntil=0;hintUntil=0
                deferred=nil;expiredEarly=true;observePassed(type,event)
                if type == .keyDown{traceReentry(.key,.unclaimed_followup,now:now)}
                DispatchQueue.main.async{self.observationNeeded?()}
                return Unmanaged.passUnretained(event)
            }
            earlyReleasePending=false
            guard held.count<128,let copy=event.copy() else{fail("buffer_limit");return Unmanaged.passUnretained(event)}
            held.append(copy);if type == .keyDown{traceReentry(.key,.hold_active,now:now)};return nil
        }
        observeDeferredPass(type,event);observePassed(type,event)
        let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Shift is part of a double consonant, not a focus/shortcut change.
        // Preserve the existing hint deadline; never authorize or extend it here.
        let shiftOnlyChange=type == .flagsChanged && [56,60].contains(code)
            && event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskAlphaShift,.maskSecondaryFn]).isEmpty
        if type != .keyDown && type != .keyUp && !shiftOnlyChange {hintUntil=0}
        if !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty {hintUntil=0}
        var observedPassed=false
        if type == .keyDown,passedInput==nil,let revision=passedBaselineRevision,
           passedBaselineSource=="com.apple.inputmethod.Korean.2SetKorean",
           event.getIntegerValueField(.keyboardEventAutorepeat)==0,
           event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskAlphaShift,.maskSecondaryFn]).isEmpty,
           (event.flags.contains(.maskShift) ? hintShifted:hintNormal).contains(code),now>=hintUntil {
            passedInput=PassedInput(first:Reservation(code:code,shift:event.flags.contains(.maskShift),time:now,sourceID:passedBaselineSource),keys:[(code,event.flags.contains(.maskShift))],pressed:[code])
            passedInput?.baselineRevision=revision;observedPassed=true
        }
        if type == .keyDown,now<hintUntil,event.getIntegerValueField(.keyboardEventAutorepeat)==0,
           (event.flags.contains(.maskShift) ? hintShifted:hintNormal).contains(code) {
            // Observe the first key. Only an atomic claim after AX validation may hold later input.
            early=Reservation(code:code,shift:event.flags.contains(.maskShift),time:now,sourceID:hintSourceID)
            if hintSourceID=="com.apple.inputmethod.Korean.2SetKorean",let first=early {
                passedInput=PassedInput(first:first,keys:[(code,event.flags.contains(.maskShift))],pressed:[code])
            }else{passedInput=nil}
            deferred=nil;earlyReleasePending=true;hintUntil=0;holdUntil=now+0.35
            traceReentry(.key,.reserved,now:now)
        }else if type == .keyDown {
            traceReentry(.key,observedPassed ? .observed_passed:(hintUntil==0 ? .hint_missing:(now>=hintUntil ? .hint_elapsed:.not_eligible)),now:now)
        }
        if let copy=event.copy(){
            DispatchQueue.main.async{self.deliver?(copy)}
        }
        return Unmanaged.passUnretained(event)
    }
}

final class OnsetGateThread {
    let gate:OnsetInputGate
    var thread:Thread?
    init(_ gate:OnsetInputGate){self.gate=gate}
    func start(){
        let worker=Thread{[self] in
            let mask:CGEventMask=[CGEventType.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].reduce(0){$0 | (1 << $1.rawValue)}
            guard let tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,event,ref in
                Unmanaged<OnsetInputGate>.fromOpaque(ref!).takeUnretainedValue().receive(type,event)
            },userInfo:Unmanaged.passUnretained(gate).toOpaque()) else{
                gate.stop();DispatchQueue.main.async{self.gate.failed?("tap_create_failed")};return
            }
            let source=CFMachPortCreateRunLoopSource(nil,tap,0)!
            CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.commonModes)
            CGEvent.tapEnable(tap:tap,enable:true)
            while gate.healthy(){
                RunLoop.current.run(until:Date().addingTimeInterval(0.025))
                if !AXIsProcessTrusted(){gate.stop();DispatchQueue.main.async{self.gate.failed?("permission_revoked")}}
                gate.poll()
            }
            CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),source,.commonModes)
        }
        worker.name="HanQ bounded input gate";thread=worker;worker.start()
    }
}
