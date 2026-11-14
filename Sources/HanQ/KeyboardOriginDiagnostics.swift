import Carbon
import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Only times of alphabetic down values enter the short-lived window.
struct KeyboardDeviceWindow {
    enum Status: Int { case ready = 1, permissionUnavailable, noSingleDevice, openFailed, interrupted }
    var status = Status.noSingleDevice
    var since: UInt64 = 0
    var downs: [UInt64] = []
    static let capacity = 512
    static let horizon: UInt64 = 60_000_000

    mutating func reset(_ status: Status, at time: UInt64) {
        self.status = status
        since = time
        downs.removeAll(keepingCapacity: true)
    }

    mutating func observe(_ time: UInt64, now: UInt64) {
        guard status == .ready else { return }
        guard time >= since, time <= now, now - time <= 150_000 else {
            reset(.ready, at: now)
            return
        }
        downs.removeAll { now - min($0, now) > Self.horizon }
        if downs.count == Self.capacity {
            // Overflow discards coverage as well as the oldest values.
            reset(.ready, at: now)
            return
        }
        downs.append(time)
    }
}

struct KeyboardOriginComparison {
    struct Press {
        let time: UInt64
        let sequence: Int
        let repeated: Bool
        let processReported: Bool
    }

    // Compare isolated bursts. Neighbouring matched presses on BOTH sides
    // qualify an excess. A quiet, uncalibrated device is never counted as zero.
    static func compare(_ presses: [Press], device: KeyboardDeviceWindow, now: UInt64) -> [InputIncidentTrace.KeyboardBurst] {
        guard device.status == .ready else { return [] }
        let start = max(device.since, now > KeyboardDeviceWindow.horizon ? now - KeyboardDeviceWindow.horizon : 0)
        // The device feed and the frame ring can start at different times.
        let samples = (presses.map { ($0.time, Optional($0)) } + device.downs.map { ($0, nil as Press?) })
            .filter { $0.0 >= start && $0.0 <= now }.sorted { $0.0 < $1.0 }
        var groups: [(first: UInt64, last: UInt64, presses: [Press], device: Int)] = []
        for (time, press) in samples {
            if groups.last.map({ time - $0.last > 3_000 }) ?? true {
                groups.append((time, time, [], 0))
            }
            let i = groups.count - 1
            groups[i].last = time
            if let press { groups[i].presses.append(press) } else { groups[i].device += 1 }
        }
        func settled(_ i: Int) -> Bool {
            let g = groups[i]
            return g.last - g.first <= 3_000 && now - g.last >= 200_000 && g.first - start >= 30_000
                && (i == 0 || g.first - groups[i-1].last >= 30_000)
                && (i+1 == groups.count || groups[i+1].first - g.last >= 30_000)
        }
        func anchor(_ i: Int) -> Bool {
            settled(i) && groups[i].device == 1 && groups[i].presses.count == 1 && !groups[i].presses[0].repeated
        }
        return groups.indices.compactMap { i in
            let g = groups[i]
            guard let first = g.presses.min(by: { $0.sequence < $1.sequence }) else { return nil }
            let q = g.presses.count
            var outcome = 0  // ambiguous
            if settled(i), q == g.device { outcome = 1 }
            if settled(i), q > g.device, i > 0, i+1 < groups.count,
               anchor(i-1), anchor(i+1), g.first - groups[i-1].last <= 2_000_000,
               groups[i+1].first - g.last <= 2_000_000 { outcome = 2 }
            return .init(firstSequence: first.sequence, deviceDown: g.device, quartzDown: q,
                         repeatDown: g.presses.filter(\.repeated).count,
                         reportedProcessDown: g.presses.filter(\.processReported).count, outcome: outcome)
        }
    }
}

final class KeyboardOriginDiagnostics {
    private final class Session {
        let lock = NSLock()
        var window = KeyboardDeviceWindow()
        var devices: [ObjectIdentifier: Bool] = [:]
        var stopped = false
        let enabled: () -> Bool
        init(enabled: @escaping () -> Bool) { self.enabled = enabled }

        func device(_ device: IOHIDDevice, added: Bool, ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            let id = ObjectIdentifier(device)
            if added {
                let elements = IOHIDDeviceCopyMatchingElements(device, ["UsagePage": 7] as CFDictionary, 0) as? [IOHIDElement] ?? []
                let supported = Set(elements.filter {
                    let type = IOHIDElementGetType($0)
                    return type == kIOHIDElementTypeInput_Button || type == kIOHIDElementTypeInput_ScanCodes || type == kIOHIDElementTypeInput_Misc
                }.map(IOHIDElementGetUsage))
                devices[id] = ok && (4...29).allSatisfy { supported.contains(UInt32($0)) }
            } else {
                devices.removeValue(forKey: id)
            }
            window.reset(ok && devices.count == 1 && devices.values.first == true ? .ready : .noSingleDevice, at: Self.now)
        }
        static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }
        func value(_ value: IOHIDValue, ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !stopped, enabled() else { return }
            let now = Self.now
            guard ok, !IsSecureEventInputEnabled() else {
                window.reset(.interrupted, at: now)
                return
            }
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard devices.count == 1,
                  devices[ObjectIdentifier(device)] == true else { return }
            if window.status == .interrupted { window.reset(.ready, at: now); return }
            guard IOHIDElementGetUsagePage(element) == 7, (4...29).contains(IOHIDElementGetUsage(element)),
                  IOHIDValueGetIntegerValue(value) == 1 else { return }
            window.observe(KeyboardOriginDiagnostics.tickMicros(IOHIDValueGetTimeStamp(value)), now: now)
        }
    }
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private static func tickMicros(_ ticks: UInt64) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let divisor = UInt64(timebase.denom) * 1_000
        guard divisor > product.high else { return 0 }
        return divisor.dividingFullWidth(product).quotient
    }

    private let queue = DispatchQueue(label: "hanq.diagnostics.builtin-keyboard")
    private let session: Session
    private var manager: IOHIDManager?
    init(enabled: @escaping () -> Bool) { session = Session(enabled: enabled) }

    func start() {
        guard manager == nil else { return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            session.window.reset(.permissionUnavailable, at: Session.now)
            return
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        // Apple's internal physical transports. Exclude virtual keyboards and Touch Bar devices.
        let matches: [[String: Any]] = ["FIFO", "SPI", "I2C", "ADB"].map {
            ["DeviceUsagePage": 1, "DeviceUsage": 6, "Built-In": true, "Transport": $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let letterElements = (4...29).map { ["UsagePage": 7, "Usage": $0] }
        IOHIDManagerSetInputValueMatchingMultiple(m, letterElements as CFArray)
        let ctx = Unmanaged.passUnretained(session).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, result, _, d in
            guard let ctx else { return }
            Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue().device(d, added: true, ok: result == kIOReturnSuccess)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, result, _, d in
            guard let ctx else { return }
            Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue().device(d, added: false, ok: result == kIOReturnSuccess)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, result, _, v in
            guard let ctx else { return }
            Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue().value(v, ok: result == kIOReturnSuccess)
        }, ctx)
        IOHIDManagerSetDispatchQueue(m, queue)
        IOHIDManagerSetCancelHandler(m) { [session, m] in withExtendedLifetime((session, m)) {} }
        let opened = IOHIDManagerOpen(m, 0) == kIOReturnSuccess
        if !opened {
            session.stopped = true
            session.window.reset(.openFailed, at: Session.now)
        }
        IOHIDManagerActivate(m)
        if opened { manager = m } else { IOHIDManagerCancel(m) }
    }

    func stop() {
        session.lock.lock()
        session.stopped = true
        session.window.reset(.interrupted, at: Session.now)
        session.lock.unlock()
        if let manager {
            IOHIDManagerCancel(manager)
            IOHIDManagerClose(manager, 0)
            self.manager = nil
        }
    }

    func snapshot(_ frames: [InputIncidentTrace.Frame], origin: Int) -> InputIncidentTrace.KeyboardSample {
        session.lock.lock()
        let window = session.window
        let stopped = session.stopped
        session.lock.unlock()
        let now = Session.now
        guard window.status == .ready, !stopped, !IsSecureEventInputEnabled(),
              IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            return .init(status: window.status == .ready ? KeyboardDeviceWindow.Status.interrupted.rawValue : window.status.rawValue, bursts: [])
        }
        return Self.compareFrames(frames, origin: origin, window: window, now: now)
    }

    static func compareFrames(_ frames: [InputIncidentTrace.Frame], origin: Int, window: KeyboardDeviceWindow, now: UInt64) -> InputIncidentTrace.KeyboardSample {
        var presses: [KeyboardOriginComparison.Press] = []
        for f in frames where f.kind == .event && f.lane == .hid && f.edge == 1 {
            guard let e = f.eventEvidence, e.keyClass == 2 else { continue }
            let observed = UInt64(origin + e.observedAtMicros)
            guard observed >= window.since, now >= observed, now - observed <= KeyboardDeviceWindow.horizon else { continue }
            let raw = UInt64(e.timestampMicros)
            let converted = Self.tickMicros(raw * 1_000)
            let time = [raw, converted].filter { $0 <= observed + 2 }.max() ?? 0
            guard time > 0, observed - min(time, observed) <= 150_000 else {
                // An unplaceable press could change any nearby count.
                return .init(status: KeyboardDeviceWindow.Status.interrupted.rawValue, bursts: [])
            }
            presses.append(.init(time: time, sequence: f.sequence, repeated: e.autoRepeat == true,
                                 processReported: (e.creatorClass ?? 0) >= 2))
        }
        let bursts = KeyboardOriginComparison.compare(presses, device: window, now: now)
        return .init(status: window.status.rawValue, bursts: Array(bursts.suffix(256)))
    }
}
