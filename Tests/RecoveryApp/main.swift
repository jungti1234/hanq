import Foundation
import Darwin

// A permission-free fixture for the real LaunchServices relaunch path. No tap,
// NSApplication, permission API, settings or UI are created by this fixture.
PermissionRelauncher.runIfRequested()
DiagnosticStorageStartup.requireReadyIfRequested()
let lockURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fixture.lock")
guard let fixtureLock = AppInstanceLock(url: lockURL) else { _exit(66) }
if CommandLine.arguments.contains("--permission-recovery") {
    let proof = DiagnosticReadinessReceipt.make(token:DiagnosticStorageStartup.token ?? "",runID:UUID().uuidString)
    let result: [String: Any] = ["pid": Int(getpid()), "owner": Int(proof.recoveryFromPID ?? 0),
                               "arguments": Array(CommandLine.arguments.dropFirst()),
                               "directory": InputIncidentTrace.shared.destinationDirectory?.path ?? "",
                               "ready": InputIncidentTrace.shared.waitForStorageReadiness().ready]
    try! JSONSerialization.data(withJSONObject: result,options:.sortedKeys).write(to:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("recovered.json"))
    InputDiagnostics.shared.record("fixture.recovered")
    withExtendedLifetime(fixtureLock) { _exit(0) }
}
let recovery = PermissionRecovery(isRecoveryLaunch: false)
recovery.prepare()
InputDiagnostics.shared.record("fixture.owner.started")
try! Data(String(getpid()).utf8).write(to:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("owner.pid"))
withExtendedLifetime(fixtureLock) { recovery.exitAfterPermissionLoss() }
