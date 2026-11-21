import Foundation
import Darwin

let marker = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HANQ_TEST_RELAUNCH_LOG"]!)
let lockURL = marker.appendingPathExtension("lock")
PermissionRelauncher.runIfRequested { owner in
    // The real owner must have exited and released its UI-instance lock first.
    guard let acquired = AppInstanceLock(url: lockURL) else { _exit(80) }
    withExtendedLifetime(acquired) {
        try! Data("relaunched\n".utf8).write(to: marker)
        let payload: [String: Any] = ["owner": Int(owner), "arguments": PermissionRecovery.diagnosticArguments]
        try! JSONSerialization.data(withJSONObject: payload).write(to: marker.appendingPathExtension("json"))
    }
}
let mode = CommandLine.arguments.last!
if mode == "arguments-check" {
    let expected = ["--preserve-input-incidents", "/private/tmp/log path", "--diagnostic-readiness-token", "nonce",
                    "--diagnose-input", "/private/tmp/trace.log", "--trace-onset-focus", "--diagnose-onset-scene"]
    precondition(PermissionRecovery.diagnosticArguments(from: ["HanQ", "--permission-relauncher", "123"] + expected + ["--unrelated", "value"]) == expected)
    let invalid = ["--bounded-input-incidents", "/private/tmp/a", "--bounded-input-incidents", "/private/tmp/b", "--preserve-input-incidents"]
    precondition(PermissionRecovery.diagnosticArguments(from: ["HanQ"] + invalid) == invalid)
    precondition(PermissionRecovery.diagnosticArguments(from: ["HanQ", "--diagnose-input-incidents", "/private/tmp/development"]) == ["--diagnose-input-incidents", "/private/tmp/development"])
    print("PASS: relaunch forwards diagnostic paths, mode, nonce and switches without helper roles")
    exit(0)
}
if mode == "lock-check" {
    guard let acquired = AppInstanceLock(url: lockURL) else { exit(66) }
    withExtendedLifetime(acquired) { exit(0) }
}
let instanceLock = AppInstanceLock(url: lockURL)!
if mode == "duplicate" {
    let duplicate = Process()
    duplicate.executableURL = Bundle.main.executableURL
    duplicate.arguments = ["lock-check"]
    try duplicate.run()
    duplicate.waitUntilExit()
    precondition(duplicate.terminationStatus == 66)
    exit(0)
}
let recovery = PermissionRecovery(isRecoveryLaunch: mode == "loop-blocked" || mode == "reauthorized")
recovery.prepare()
if mode == "reauthorized" {
    precondition(!recovery.requestRelaunch())
    recovery.observePermission(false)
    recovery.observePermission(true)
}
if mode == "requested" || mode == "reauthorized" {
    precondition(recovery.requestRelaunch())
    precondition(!recovery.requestRelaunch(), "One request per authorization cycle")
    // A queued request must not launch while the old tap owner is alive.
    Thread.sleep(forTimeInterval: 0.25)
    precondition(!FileManager.default.fileExists(atPath: marker.path))
} else if mode == "loop-blocked" {
    recovery.observePermission(true)
    precondition(!recovery.requestRelaunch(), "Initial stale grant must not cause restart loops")
}
withExtendedLifetime(instanceLock) { _exit(0) }
