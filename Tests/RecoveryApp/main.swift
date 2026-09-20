import Foundation
import Darwin

// A permission-free fixture for the real LaunchServices relaunch path. No tap,
// NSApplication, permission API, settings or UI are created by this fixture.
PermissionRelauncher.runIfRequested()
let lockURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fixture.lock")
guard let fixtureLock = AppInstanceLock(url: lockURL) else { _exit(66) }
if CommandLine.arguments.contains("--permission-recovery") {
    InputDiagnostics.shared.record("fixture.recovered")
    withExtendedLifetime(fixtureLock) { _exit(0) }
}
let recovery = PermissionRecovery(isRecoveryLaunch: false)
recovery.prepare()
InputDiagnostics.shared.record("fixture.owner.started")
withExtendedLifetime(fixtureLock) { recovery.exitAfterPermissionLoss() }
