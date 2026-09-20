import Foundation
import Darwin

/// A stuck main run loop must not retain a system-wide input hook indefinitely.
/// This queue never calls TCC, AppKit or WindowServer. Expiry exits without running
/// AppKit termination handlers, which could be stuck in the same system call.
final class InputSafetyWatchdog {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "taek.in.hanq.input-safety")
    private var timer: DispatchSourceTimer?
    private var lastPulse: UInt64?
    private let timeoutNanoseconds: UInt64
    private let terminate: () -> Void

    init(timeout: TimeInterval = 2, terminate: @escaping () -> Void = { _exit(70) }) {
        timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        self.terminate = terminate
    }

    func arm() {
        lock.lock()
        lastPulse = DispatchTime.now().uptimeNanoseconds
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
        lock.unlock()
    }

    func pulse() {
        lock.lock()
        if lastPulse != nil { lastPulse = DispatchTime.now().uptimeNanoseconds }
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        lastPulse = nil
        lock.unlock()
    }

    private func check() {
        lock.lock()
        let expired = lastPulse.map { DispatchTime.now().uptimeNanoseconds - $0 >= timeoutNanoseconds } ?? false
        if expired { lastPulse = nil }
        lock.unlock()
        if expired { terminate() }
    }

    deinit { timer?.cancel() }
}
