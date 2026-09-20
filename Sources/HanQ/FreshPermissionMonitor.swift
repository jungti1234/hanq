import AppKit
import ApplicationServices

/// Each answer comes from a new LaunchServices instance of the same signed app.
/// A child launched directly by Process can inherit its launcher's TCC identity.
final class FreshPermissionMonitor {
    typealias LaunchProbe = (URL, @escaping (Error?) -> Void) -> Void
    private let queue = DispatchQueue(label: "taek.in.hanq.fresh-permission")
    private let launchQueue = DispatchQueue(label: "taek.in.hanq.permission-launch")
    private let terminate: (String) -> Void
    private let launchProbe: LaunchProbe
    private let interval: UInt64
    private let timeout: UInt64
    private var timer: DispatchSourceTimer?
    private var pending: (directory: URL, started: UInt64)?
    private var nextCheck: UInt64 = 0
    private var active = false
    private var notification: NSObjectProtocol?

    init(interval: TimeInterval = 1, timeout: TimeInterval = 2,
         launchProbe: @escaping LaunchProbe = FreshPermissionMonitor.launchProbe,
         terminate: @escaping (String) -> Void) {
        precondition(interval > 0 && timeout > 0)
        self.interval = UInt64(interval * 1_000_000_000)
        self.timeout = UInt64(timeout * 1_000_000_000)
        self.launchProbe = launchProbe
        self.terminate = terminate
    }

    func start() {
        queue.async { [self] in
            guard !active else { return }
            active = true
            nextCheck = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
        // This notification is an optimization, not the sole detector: it can
        // concern another app and may be absent on future macOS versions.
        if notification == nil {
            notification = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in
                    InputDiagnostics.shared.record("fresh.notification")
                    self?.nextCheck = 0
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            active = false
            timer?.cancel()
            timer = nil
            cleanup()
        }
        if let notification { DistributedNotificationCenter.default().removeObserver(notification) }
        notification = nil
    }

    private func cleanup() {
        if let pending { try? FileManager.default.removeItem(at: pending.directory) }
        pending = nil
    }

    private func fail(_ reason: String) {
        active = false
        timer?.cancel()
        timer = nil
        cleanup()
        InputDiagnostics.shared.record("fresh.exit reason=\(reason)")
        terminate(reason)
    }

    private func tick() {
        guard active else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let pending {
            guard now - pending.started < timeout else { fail("probe-timeout"); return }
            let resultURL = pending.directory.appendingPathComponent("result.json")
            if let data = try? Data(contentsOf: resultURL) {
                guard let result = try? JSONDecoder().decode(PermissionProbeResult.self, from: data),
                      result.token == pending.directory.lastPathComponent else {
                    fail("invalid-result"); return
                }
                let ax = result.ax.map { String($0) } ?? "skipped"
                InputDiagnostics.shared.record("fresh.result pid=\(result.pid) ax=\(ax) post=\(result.post) elapsedMS=\((now - pending.started) / 1_000_000)")
                cleanup()
                guard result.post && result.ax == true else { fail("permission-denied"); return }
                nextCheck = now + interval
            }
            return
        }
        guard now >= nextCheck else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hanq-permission-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { fail("probe-directory"); return }
        pending = (directory, now)
        InputDiagnostics.shared.record("fresh.launch token=\(directory.lastPathComponent)")
        launchQueue.async { [weak self] in
            self?.launchProbe(directory) { [weak self] error in
                guard error != nil else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.active, self.pending?.directory == directory else { return }
                    // Very short-lived probes may finish before LaunchServices replies.
                    if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.json").path) {
                        self.fail("probe-launch")
                    }
                }
            }
        }
    }

    private static func launchProbe(directory: URL, completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--permission-probe", directory.path]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            completion(error)
        }
    }
}

struct PermissionProbeResult: Codable {
    let token: String
    let pid: Int32
    let ax: Bool?
    let post: Bool
}

enum PermissionProbe {
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--permission-probe") else { return }
        guard index + 1 < arguments.count else { _exit(64) }
        let directory = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              directory.lastPathComponent.hasPrefix("hanq-permission-") else { _exit(64) }
        // A probe never creates a tap, shows permission prompts, or edits settings.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(71) }
        // Avoid an AX request when event posting is already denied. On this OS,
        // querying AX from a new process can register a deleted app as disabled.
        let post = CGPreflightPostEventAccess()
        let result = PermissionProbeResult(token: directory.lastPathComponent, pid: getpid(),
                                          ax: post ? AXIsProcessTrusted() : nil, post: post)
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
            _exit(0)
        } catch { _exit(74) }
    }
}
