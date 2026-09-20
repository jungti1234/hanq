import ApplicationServices
import Foundation
import Darwin

/// Opt-in incident tracing. No text, keycodes, clipboard or AX content is logged.
/// Independent probes let us distinguish a stuck main loop from stale permission
/// answers. They are measurements only and do not change permission policy.
final class InputDiagnostics {
    static let shared = InputDiagnostics()
    private let descriptor: Int32
    private var timers: [DispatchSourceTimer] = []

    private init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--diagnose-input"), index + 1 < args.count {
            descriptor = open(args[index + 1], O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        } else { descriptor = -1 }
    }

    func record(_ message: String) {
        guard descriptor >= 0 else { return }
        let line = "\(Date().timeIntervalSince1970) mono=\(DispatchTime.now().uptimeNanoseconds) pid=\(getpid()) \(message)\n"
        line.withCString { pointer in _ = write(descriptor, pointer, strlen(pointer)) }
    }

    func start() {
        guard descriptor >= 0, timers.isEmpty else { return }
        record("diagnostics.start")
        for (name, probe) in [("ax", { AXIsProcessTrusted() }), ("post", { CGPreflightPostEventAccess() })] {
            let queue = DispatchQueue(label: "taek.in.hanq.diagnostics.\(name)")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                self?.record("probe.\(name).begin")
                let result = probe()
                self?.record("probe.\(name).end granted=\(result)")
            }
            timers.append(timer)
            timer.resume()
        }
    }

    deinit {
        timers.forEach { $0.cancel() }
        if descriptor >= 0 { close(descriptor) }
    }
}
