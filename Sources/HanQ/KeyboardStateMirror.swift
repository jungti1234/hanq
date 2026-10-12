import AppKit
import Carbon

/// Let suppressed keyboard edges update Quartz before dropping them at the
/// annotated boundary. No second app delivery and no invented key release.
final class KeyboardStateMirror {
    static let shared = KeyboardStateMirror()
    let marker = Int64(bitPattern: 0x48414B5300000000 | UInt64(UInt32.random(in: 1...UInt32.max)))
    static func isMarker(_ value: Int64) -> Bool { UInt64(bitPattern: value) >> 32 == 0x48414B53 }
    private let lock = NSLock()
    private var accepting = false
    private var pending = 0
    private var thread: Thread?
    private var port: CFMachPort?
    private var stopAt = 0.0
    private let stateSource = CGEventSource(stateID: .privateState)
    var failed: (() -> Void)?

    init() { stateSource?.userData = marker }

    static func keyboard(_ type: CGEventType) -> Bool {
        type == .keyDown || type == .keyUp || type == .flagsChanged
    }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return accepting }

    @discardableResult func start() -> Bool {
        lock.lock()
        if accepting { lock.unlock(); return true }
        guard thread == nil else { lock.unlock(); return false }
        lock.unlock()
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(0) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, ref in
                let owner = Unmanaged<KeyboardStateMirror>.fromOpaque(ref!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.stop(); DispatchQueue.main.async { owner.failed?() }
                    return Unmanaged.passUnretained(event)
                }
                return owner.receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let worker = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            while running { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            lock.lock(); port = nil; thread = nil; lock.unlock()
        }
        worker.name = "HanQ keyboard state boundary"
        lock.lock(); port = tap; accepting = true; pending = 0; thread = worker; lock.unlock()
        worker.start()
        return true
    }
    private var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting || (pending > 0 && ProcessInfo.processInfo.systemUptime < stopAt)
    }
    func stop() {
        lock.lock(); accepting = false; stopAt = ProcessInfo.processInfo.systemUptime + 1; lock.unlock()
    }
    /// Acquire before invoking a consumer so teardown drains callbacks already
    /// in flight. A stopped boundary never runs an input-consuming handler.
    func preserve(_ type: CGEventType, _ event: CGEvent,
                  process: () -> Unmanaged<CGEvent>?) -> Unmanaged<CGEvent>? {
        guard Self.keyboard(type) else { return process() }
        if Self.isMarker(event.getIntegerValueField(.eventSourceUserData)) { return Unmanaged.passUnretained(event) }
        lock.lock()
        guard accepting else { lock.unlock(); return Unmanaged.passUnretained(event) }
        pending += 1; lock.unlock()
        let flags = event.flags
        if let result = process() {
            complete(); return result
        }
        guard let stateSource,let state=CGEvent(keyboardEventSource:stateSource,
            virtualKey:CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),keyDown:event.type == .keyDown) else {
            complete();return nil
        }
        // A separately posted PID copy can share the original event's backing
        // record. Replace it with a fresh state-only record, never return that
        // original to the global delivery stream after direct dispatch.
        state.type=event.type;state.flags=flags
        state.setIntegerValueField(.eventSourceUserData,value:marker)
        return Unmanaged.passRetained(state)
    }
    func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Self.keyboard(type), event.getIntegerValueField(.eventSourceUserData) == marker else {
            return Unmanaged.passUnretained(event)
        }
        complete(); return nil
    }
    private func complete() { lock.lock(); pending = max(0, pending - 1); lock.unlock() }
    /// Cleanup only edges a test producer actually posted. The targeted release
    /// balances its app; this tagged HID copy updates state without app delivery.
    func releasePosted(_ event: CGEvent, to pid: pid_t?) {
        guard ready, let stateSource,
              let state = CGEvent(keyboardEventSource: stateSource,
                  virtualKey: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), keyDown: false) else { return }
        state.type = event.type
        state.flags = event.flags
        lock.lock()
        guard accepting else { lock.unlock(); return }
        pending += 1; lock.unlock()
        if let pid {
            event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
            event.postToPid(pid)
        }
        state.setIntegerValueField(.eventSourceUserData, value: marker)
        state.post(tap: .cghidEventTap)
    }
    func beginTesting() { lock.lock(); accepting = true; lock.unlock() }
}
