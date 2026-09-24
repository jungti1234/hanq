import AppKit

// Shared state uses a bounded lock acquisition (2ms maximum requested wait).
// No AX, disk I/O, or synchronous dispatch to the main thread occurs in receive().
final class OnsetInputGate {
    static func isRecoveryMarker(_ value:Int64)->Bool {
        UInt64(bitPattern:value) >> 32 == 0x48414E51
    }
    struct Reservation { let code:UInt16;let shift:Bool;let time:Double;let sourceID:String }
    var early:Reservation?
    var hintUntil=0.0
    var hintSourceID="com.apple.inputmethod.Korean.2SetKorean"
    var hintNormal:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17]
    var hintShifted:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17]
    func configureEarly(_ allowed:Bool,sourceID:String="com.apple.inputmethod.Korean.2SetKorean",normal:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17],shifted:Set<UInt16>=[0,1,2,3,5,6,7,8,9,12,13,14,15,17]){
        lock.lock();defer{lock.unlock()}
        hintUntil=allowed ? ProcessInfo.processInfo.systemUptime+0.15:0
        hintSourceID=sourceID;hintNormal=normal;hintShifted=shifted
    }
    func reservation()->Reservation?{lock.lock();defer{lock.unlock()};return early}
    func claimEarly()->Bool {
        lock.lock();defer{lock.unlock()}
        guard !stopped,let first=early,ProcessInfo.processInfo.systemUptime-first.time<0.35 else{return false}
        early=nil;hintUntil=0;holdUntil=ProcessInfo.processInfo.systemUptime+0.8;return true
    }
    let lock=NSLock()
    var replaySeen=0
    func seenCount()->Int{lock.lock();defer{lock.unlock()};return replaySeen}
    var stopped=false
    var holdUntil:Double=0
    var heartbeat:Double=0
    var held:[CGEvent]=[]
    var passedDowns:[(CGEvent,Double)]=[]
    func recentPassedDowns()->[(CGEvent,Double)]{lock.lock();defer{lock.unlock()};return passedDowns}
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
    func cancelHold()->[CGEvent]{lock.lock();defer{lock.unlock()};holdUntil=0;early=nil;hintUntil=0;let result=held;held=[];return result}
    func finishIfEmpty()->Bool{lock.lock();defer{lock.unlock()};guard held.isEmpty else{return false};holdUntil=0;early=nil;return true}
    func poll(){
        lock.lock();defer{lock.unlock()}
        guard !stopped else{return}
        let now=ProcessInfo.processInfo.systemUptime
        if holdUntil>0 && now-heartbeat>=0.25{fail("observation_stale")}
        else if holdUntil>0 && now>=holdUntil{fail("hold_deadline")}
    }
    func stop(){lock.lock();stopped=true;holdUntil=0;early=nil;hintUntil=0;lock.unlock()}
    func healthy()->Bool{lock.lock();defer{lock.unlock()};return !stopped}
    func fail(_ reason:String){stopped=true;holdUntil=0;early=nil;hintUntil=0;DispatchQueue.main.async{self.failed?(reason)}}
    func receive(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>? {
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
        guard !stopped else{return Unmanaged.passUnretained(event)}
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput{fail("tap_disabled");return Unmanaged.passUnretained(event)}
        let now=ProcessInfo.processInfo.systemUptime
        guard holdUntil==0 || now-heartbeat<0.25 else{fail("observation_stale");return Unmanaged.passUnretained(event)}
        if holdUntil>0 {
            guard now<holdUntil else{fail("hold_deadline");return Unmanaged.passUnretained(event)}
            guard type == .keyDown || type == .keyUp || type == .flagsChanged else{fail("pointer_during_repair");return Unmanaged.passUnretained(event)}
            guard event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty else{fail("shortcut_during_repair");return Unmanaged.passUnretained(event)}
            guard held.count<128,let copy=event.copy() else{fail("buffer_limit");return Unmanaged.passUnretained(event)}
            held.append(copy);return nil
        }
        let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Shift is part of a double consonant, not a focus/shortcut change.
        // Preserve the existing hint deadline; never authorize or extend it here.
        let shiftOnlyChange=type == .flagsChanged && [56,60].contains(code)
            && event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskAlphaShift,.maskSecondaryFn]).isEmpty
        if type != .keyDown && type != .keyUp && !shiftOnlyChange {hintUntil=0}
        if !event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty {hintUntil=0}
        if type == .keyDown,now<hintUntil,event.getIntegerValueField(.keyboardEventAutorepeat)==0,
           (event.flags.contains(.maskShift) ? hintShifted:hintNormal).contains(code) {
            // Start holding subsequent events before returning this first key to the OS.
            early=Reservation(code:code,shift:event.flags.contains(.maskShift),time:now,sourceID:hintSourceID)
            hintUntil=0;holdUntil=now+0.35
        }
        if let copy=event.copy(){
            if type == .keyDown{passedDowns.append((copy,now));if passedDowns.count>8{passedDowns.removeFirst()}}
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
