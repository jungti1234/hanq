import Foundation

// Exercise the production monitor without installing taps or changing TCC.
// The launcher is replaceable so a hung LaunchServices call cannot stall tests.
let mode = CommandLine.arguments.last!
let launched = DispatchSemaphore(value: 0)
let terminated = DispatchSemaphore(value: 0)
let lock = NSLock()
var count = 0
var reason: String?
var directories: [URL] = []
let monitor = FreshPermissionMonitor(interval: 0.05, timeout: 0.2, launchProbe: { directory, completion in
    lock.lock()
    count += 1
    let attempt = count
    directories.append(directory)
    lock.unlock()
    launched.signal()
    if mode == "stalled-launch" {
        Thread.sleep(forTimeInterval: 1)
        return
    }
    if mode == "missing-result" || mode == "stop" { completion(nil); return }
    if mode == "launch-error" {
        completion(NSError(domain: "test", code: 1))
        return
    }
    let result = PermissionProbeResult(
        token: mode == "wrong-token" ? "another-request" : directory.lastPathComponent,
        pid: getpid(), ax: attempt == 1, post: attempt == 1)
    let data = mode == "corrupt-result" ? Data("{".utf8) : try! JSONEncoder().encode(result)
    try! data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    // A valid result wins over a delayed LaunchServices error.
    completion(mode == "result-before-error" ? NSError(domain: "test", code: 2) : nil)
}, terminate: { value in
    lock.lock()
    reason = value
    lock.unlock()
    terminated.signal()
})
monitor.start()
precondition(launched.wait(timeout: .now() + 2) == .success)
if mode == "stop" {
    monitor.stop()
    precondition(terminated.wait(timeout: .now() + 0.5) == .timedOut)
} else {
    precondition(terminated.wait(timeout: .now() + 2) == .success)
    lock.lock()
    let expected: String
    switch mode {
    case "stalled-launch", "missing-result": expected = "probe-timeout"
    case "launch-error": expected = "probe-launch"
    case "wrong-token", "corrupt-result": expected = "invalid-result"
    default:
        expected = "permission-denied"
        precondition(count == 2, "Granted result must continue monitoring")
    }
    precondition(reason == expected, "Expected \(expected), got \(String(describing: reason))")
    lock.unlock()
    monitor.stop()
}
lock.lock()
precondition(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
lock.unlock()
print("PASS: permission monitor \(mode)")
