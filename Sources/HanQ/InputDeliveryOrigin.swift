import AppKit
import Carbon

/// Preserve the OS-chosen recipient of ordinary input across a delayed session
/// tap. Quartz can rewrite timestamps and route a returned event to a newly
/// active app; neither the timestamp nor setting the target PID pins delivery.
/// This gate does no AX work and never queues, suppresses, or replays input.
final class InputDeliveryOrigin {
    final class Origin {
        let pid:pid_t
        let code:Int64
        let type:CGEventType
        let sourcePID:Int64
        let capturedAt:Double
        var delivered=false
        init(pid:pid_t,code:Int64,type:CGEventType,sourcePID:Int64,capturedAt:Double){
            self.pid=pid;self.code=code;self.type=type;self.sourcePID=sourcePID;self.capturedAt=capturedAt
        }
    }
    static func isMarker(_ value:Int64)->Bool {
        UInt64(bitPattern:value) >> 48 == 0x4852
    }
    private let lock=NSLock()
    private var entries:[Int64:Origin]=[:]
    private var next:UInt64=0
    private let session=UInt64(UInt16.random(in:1...UInt16.max)) << 32
    private var active=false
    private var port:CFMachPort?
    private var thread:Thread?
    var frontPID:()->pid_t? = {NSWorkspace.shared.frontmostApplication?.processIdentifier}
    var targetPID:(CGEvent)->pid_t? = {
        let value=$0.getIntegerValueField(.eventTargetUnixProcessID)
        return value>0 ? pid_t(exactly:value):nil
    }
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    var canSend:()->Bool = {AXIsProcessTrusted() && !IsSecureEventInputEnabled()}
    var send:(CGEvent,pid_t)->Void = {$0.postToPid($1)}

    func capture(_ type:CGEventType,_ event:CGEvent) {
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.eventSourceUserData)==0,
              let front=frontPID(),front>0,
              targetPID(event)==front else{return}
        // A non-activating panel may own keyboard focus while another app is
        // frontmost. Leave that path unchanged; do not guess its owner with AX.
        guard lock.try() || lock.lock(before:Date(timeIntervalSinceNow:0.002)) else{return}
        defer{lock.unlock()}
        guard active else{return}
        let time=now()
        if entries.count>=1024 {entries=entries.filter{time-$0.value.capturedAt<2}}
        guard entries.count<1024 else{return}
        next+=1
        let token=Int64(bitPattern:0x4852000000000000 | session | (next & 0xffffffff))
        entries[token]=Origin(pid:front,code:event.getIntegerValueField(.keyboardEventKeycode),type:type,
                              sourcePID:event.getIntegerValueField(.eventSourceUnixProcessID),capturedAt:time)
        event.setIntegerValueField(.eventSourceUserData,value:token)
    }
    /// Consume once at the main tap, before any potentially slow application work.
    /// Keep the returned value on the stack for the final check before returning.
    func take(_ type:CGEventType,_ event:CGEvent)->Origin? {
        let token=event.getIntegerValueField(.eventSourceUserData)
        guard Self.isMarker(token) else{return nil}
        lock.lock();let origin=entries.removeValue(forKey:token);lock.unlock()
        guard let origin,origin.type==type,
              origin.code==event.getIntegerValueField(.keyboardEventKeycode),
              origin.sourcePID==event.getIntegerValueField(.eventSourceUnixProcessID),
              targetPID(event)==origin.pid,
              now()-origin.capturedAt<2 else{return nil}
        return origin
    }
    /// Only original, unconsumed input is eligible. Never send a repair or guess
    /// a field, change focus/source, or retry a post whose delivery is uncertain.
    func forwardIfMoved(_ event:CGEvent,origin:Origin?)->Bool {
        guard isActive,canSend(),let origin,!origin.delivered,let front=frontPID(),front != origin.pid else{return false}
        origin.delivered=true
        send(event,origin.pid)
        return true
    }
    func start() {
        lock.lock()
        guard !active,thread==nil else{lock.unlock();return}
        active=true;lock.unlock()
        let worker=Thread{[self] in
            let mask=(CGEventMask(1)<<CGEventType.keyDown.rawValue)|(CGEventMask(1)<<CGEventType.keyUp.rawValue)
            guard let tap=CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.defaultTap,
                eventsOfInterest:mask,callback:{_,type,event,ref in
                    let owner=Unmanaged<InputDeliveryOrigin>.fromOpaque(ref!).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {owner.stop()}
                    else{owner.capture(type,event)}
                    return Unmanaged.passUnretained(event)
                },userInfo:Unmanaged.passUnretained(self).toOpaque()) else{stop();return}
            let source=CFMachPortCreateRunLoopSource(nil,tap,0)!
            lock.lock();port=tap;let running=active;lock.unlock()
            if running {
                CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.commonModes)
                while isActive {RunLoop.current.run(until:Date().addingTimeInterval(0.025))}
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(),source,.commonModes)
            }
            CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)
            lock.lock();port=nil;lock.unlock()
        }
        worker.name="HanQ input origin";thread=worker;worker.start()
    }
    var isActive:Bool {lock.lock();defer{lock.unlock()};return active}
    func stop() {
        lock.lock();active=false;entries.removeAll();lock.unlock()
    }
    // Deterministic tests exercise ownership and single-consumption without a tap.
    func beginTesting(){lock.lock();active=true;lock.unlock()}
}
