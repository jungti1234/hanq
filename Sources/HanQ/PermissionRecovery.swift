import AppKit
import Darwin

/// Prepare the relauncher before installing an event tap. The failure path only
/// writes one nonblocking byte and exits; it never waits for LaunchServices.
final class PermissionRecovery {
    private let lock = NSLock()
    private var writer: FileHandle?
    private var helper: Process?
    private var mayRelaunch: Bool
    private var observedDenied = false

    init(isRecoveryLaunch: Bool = ProcessInfo.processInfo.arguments.contains("--permission-recovery")) {
        mayRelaunch = !isRecoveryLaunch
    }

    func prepare() {
        guard helper == nil, let executable = Bundle.main.executableURL else { return }
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--permission-relauncher", String(getpid())] + Self.diagnosticArguments
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            pipe.fileHandleForReading.closeFile()
            lock.lock()
            writer = pipe.fileHandleForWriting
            helper = process
            lock.unlock()
            InputDiagnostics.shared.record("recovery.prepared helper=\(process.processIdentifier)")
        } catch {
            InputDiagnostics.shared.record("recovery.prepare.failed")
        }
    }

    func observePermission(_ granted: Bool) {
        lock.lock()
        if !granted { observedDenied = true }
        if granted && observedDenied {
            // A recovered app can restart again after a new authorization cycle.
            // Merely launching with an inconsistent 'allowed' answer cannot loop.
            mayRelaunch = true
            observedDenied = false
        }
        lock.unlock()
    }

    @discardableResult
    func requestRelaunch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mayRelaunch, let writer else { return false }
        mayRelaunch = false
        var command: UInt8 = 0x52 // R; EOF alone never authorizes relaunch.
        return write(writer.fileDescriptor, &command, 1) == 1
    }

    func exitAfterPermissionLoss() -> Never {
        let requested = requestRelaunch()
        InputDiagnostics.shared.record("recovery.exit requested=\(requested)")
        _exit(72)
    }

    static var diagnosticArguments: [String] {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--diagnose-input"), index + 1 < args.count else { return [] }
        return ["--diagnose-input", args[index + 1]]
    }
}

enum PermissionRelauncher {
    static func runIfRequested(relaunch: @escaping () -> Void = launchApplication) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--permission-relauncher") else { return }
        guard index + 1 < args.count, let owner = Int32(args[index + 1]), owner > 1,
              getppid() == owner || getppid() == 1 else { _exit(64) }
        var requested = false
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            if count == 0 { break }
            guard count == 1, byte == 0x52, !requested else { _exit(64) }
            requested = true
            // Bounds a malformed request, owner-exit wait and launch attempt.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { _exit(75) }
        }
        guard requested else { _exit(0) }
        // EOF can precede process exit if a handle is closed explicitly.
        while getppid() == owner { usleep(10_000) }
        InputDiagnostics.shared.record("recovery.owner.exited owner=\(owner)")
        relaunch()
        _exit(0)
    }

    private static func launchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--permission-recovery"] + PermissionRecovery.diagnosticArguments
        let completed = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            InputDiagnostics.shared.record("recovery.launch success=\(error == nil)")
            completed.signal()
        }
        _ = completed.wait(timeout: .now() + 4)
    }
}

/// Helpers/probes share the bundle ID, but never acquire the UI instance lock.
/// A PID-list check would mistake a relauncher for an already-open application.
final class AppInstanceLock {
    private var descriptor: Int32 = -1

    init?(url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("taek.in.hanq.instance.lock")) {
        let candidate = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { return nil }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { close(candidate); return nil }
        descriptor = candidate
    }

    deinit { close(descriptor) }
}
