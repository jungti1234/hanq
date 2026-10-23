import AppKit
import Carbon

/// Preserve the OS-chosen recipient of ordinary input across a delayed session
/// tap. Quartz can rewrite timestamps and route a returned event to a newly
/// active app; neither the timestamp nor setting the target PID pins delivery.
/// No AX work or text replay. A redirected press retains ownership of its
/// repeats and release until the matching release or teardown.
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
    var diagnosticEvent:((CGEventType,CGEvent,Bool)->Void)?
    var diagnosticReceive:((CGEventType,CGEvent,()->Unmanaged<CGEvent>?)->Unmanaged<CGEvent>?)?
    private let lock=NSLock()
    private var entries:[Int64:Origin]=[:]
    private var next:UInt64=0
    private let session=UInt64(UInt16.random(in:1...UInt16.max)) << 32
    private var active=false
    private var port:CFMachPort?
    private var thread:Thread?
    private struct Press:Hashable {
        let code:Int64;let sourcePID:Int64;let device:Int64
        init(_ event:CGEvent) {
            code=event.getIntegerValueField(.keyboardEventKeycode)
            sourcePID=event.getIntegerValueField(.eventSourceUnixProcessID)
            device=CGEventField(rawValue:87).map{event.getIntegerValueField($0)} ?? 0
        }
    }
    private struct Recipient {let pid:pid_t;let alive:()->Bool;let tag:Int64}
    private var routedPresses:[Press:Recipient]=[:]
    var frontPID:()->pid_t? = {NSWorkspace.shared.frontmostApplication?.processIdentifier}
    var targetPID:(CGEvent)->pid_t? = {
        let value=$0.getIntegerValueField(.eventTargetUnixProcessID)
        return value>0 ? pid_t(exactly:value):nil
    }
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    var canSend:()->Bool = {AXIsProcessTrusted() && !IsSecureEventInputEnabled()}
    var send:(CGEvent,pid_t)->Void = {$0.postToPid($1)}
    var recipientLifetime:(pid_t)->(()->Bool)? = {pid in
        guard let app=NSRunningApplication(processIdentifier:pid),!app.isTerminated else{return nil}
        return { !app.isTerminated }
    }

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
    func forgetMirroredRelease(_ type:CGEventType,_ event:CGEvent) {
        guard type == .keyUp,KeyboardStateMirror.isMarker(event.getIntegerValueField(.eventSourceUserData)) else{return}
        lock.lock();routedPresses.removeValue(forKey:Press(event));lock.unlock()
    }
    /// A later consumer must not swallow the release of a press already sent
    /// to another app. Resolve that ownership at HID before the recovery gates.
    func receive(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>? {
        guard isActive,canSend(),type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.eventSourceUserData)==0,let front=frontPID(),
              targetPID(event)==front else{capture(type,event);return Unmanaged.passUnretained(event)}
        let press=Press(event)
        lock.lock();let held=routedPresses[press];lock.unlock()
        if let held,!held.alive() {
            lock.lock();routedPresses.removeValue(forKey:press);lock.unlock()
        }
        if let held,held.alive(),held.pid != front,let copy=event.copy() {
            if type == .keyUp {lock.lock();routedPresses.removeValue(forKey:press);lock.unlock()}
            copy.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x4852000000000000|session))
            copy.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(held.pid))
            // Quartz drops native autorepeat records for a background PID.
            // Preserve each repeated press as an ordinary targeted key-down.
            if type == .keyDown {copy.setIntegerValueField(.keyboardEventAutorepeat,value:0)}
            send(copy,held.pid);return nil
        }
        capture(type,event);return Unmanaged.passUnretained(event)
    }
    /// Consume once at the main tap, before any potentially slow application work.
    /// Keep the returned value on the stack for the final check before returning.
    func take(_ type:CGEventType,_ event:CGEvent)->Origin? {
        let token=event.getIntegerValueField(.eventSourceUserData)
        guard Self.isMarker(token) else{return nil}
        lock.lock();let origin=entries.removeValue(forKey:token);lock.unlock()
        if origin == nil,type == .keyDown,event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            lock.lock();let held=routedPresses[Press(event)];lock.unlock()
            if let held,held.tag==token,held.alive() {
                return Origin(pid:held.pid,code:event.getIntegerValueField(.keyboardEventKeycode),type:type,
                              sourcePID:event.getIntegerValueField(.eventSourceUnixProcessID),capturedAt:now())
            }
        }
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
        guard isActive,canSend(),let origin,!origin.delivered,let front=frontPID() else{return false}
        let press=Press(event)
        lock.lock()
        let tagged=routedPresses.first{$0.value.tag==event.getIntegerValueField(.eventSourceUserData)}
        let identity=tagged?.key ?? press
        let held=routedPresses[identity]
        if event.type == .keyUp {routedPresses.removeValue(forKey:identity)}
        lock.unlock()
        if let held,!held.alive() {return false}
        let destination=held?.pid ?? origin.pid
        guard front != destination || origin.pid != destination,
              let copy=event.copy(),let alive=held?.alive ?? recipientLifetime(destination) else{return false}
        if event.type == .keyDown {
            lock.lock();let room=routedPresses[press] != nil || routedPresses.count<256;lock.unlock()
            guard room else{return false}
        }
        origin.delivered=true
        if event.type == .keyDown {
            lock.lock();routedPresses[identity]=Recipient(pid:destination,alive:alive,tag:held?.tag ?? event.getIntegerValueField(.eventSourceUserData));lock.unlock()
        }
        copy.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(destination))
        if event.type == .keyDown {copy.setIntegerValueField(.keyboardEventAutorepeat,value:0)}
        send(copy,destination)
        return true
    }
    func start() {
        guard KeyboardStateMirror.shared.start() else{return}
        lock.lock()
        guard !active,thread==nil else{lock.unlock();return}
        active=true;lock.unlock()
        let worker=Thread{[self] in
            let mask=(CGEventMask(1)<<CGEventType.keyDown.rawValue)|(CGEventMask(1)<<CGEventType.keyUp.rawValue)
            guard let tap=CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.defaultTap,
                eventsOfInterest:mask,callback:{_,type,event,ref in
                    let owner=Unmanaged<InputDeliveryOrigin>.fromOpaque(ref!).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {owner.stop()}
                    else {
                        owner.forgetMirroredRelease(type,event)
                        return KeyboardStateMirror.shared.preserve(type,event) {
                            if let measured=owner.diagnosticReceive{return measured(type,event){owner.receive(type,event)}}
                            let result=owner.receive(type,event)
                            owner.diagnosticEvent?(type,event,result==nil)
                            return result
                        }
                    }
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
        lock.lock();active=false;entries.removeAll();routedPresses.removeAll();lock.unlock()
    }
    // Deterministic tests exercise ownership and single-consumption without a tap.
    func beginTesting(){lock.lock();active=true;lock.unlock()}
}
