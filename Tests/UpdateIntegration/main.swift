import AppKit
import CryptoKit

// Runs the production updater/policy/input teardown in an isolated bundle.
// The test never registers login items or installs a global keyboard hook.
final class Harness: NSObject, NSApplicationDelegate {
    let owner = AppDelegate()
    let updater = AppUpdater()
    var responses: [Data?] = []
    var requested = 0
    var events: [Bool] = []
    var timer: Timer?
    var step = 0
    var ticks = 0
    var interactive = CommandLine.arguments.contains("--interactive")

    func applicationDidFinishLaunching(_ notification: Notification) {
        owner.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        owner.window = NSWindow()
        owner.permissionContent = NSView()
        UserDefaults.standard.set(true, forKey: "koreanKeyEnabled")
        UserDefaults.standard.set(true, forKey: "hanjaKeyEnabled")
        let fixture = Bundle.main.resourceURL!
        responses = [try! Data(contentsOf: fixture.appendingPathComponent("required.json")), nil,
                     try! Data(contentsOf: fixture.appendingPathComponent("required.json")),
                     try! Data(contentsOf: fixture.appendingPathComponent("withdrawn.json"))]
        // Exercise cleanup of a real port/source without intercepting the keyboard.
        var context = CFMachPortContext()
        let port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil)!
        owner.tap = port
        owner.tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), owner.tapSource!, .commonModes)
        owner.enabled = true; owner.koreanEnabled = true; owner.hanjaEnabled = true
        updater.onRestrictionChange = { [weak self] restricted in
            guard let self else { return }
            self.owner.setUpdateRestricted(restricted)
            self.events.append(restricted)
        }
        updater.start(policyFetch: { [weak self] _, head, reply in
            guard let self else { return nil }
            if head { DispatchQueue.main.async { reply(Data()) }; return nil }
            self.requested += 1
            let data = self.responses.isEmpty ? nil : self.responses.removeFirst()
            DispatchQueue.main.async { reply(data) }
            return nil
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.advance() }
    }

    func advance() {
        ticks += 1
        precondition(ticks < (interactive ? 6000 : 150), "Integration test timed out")
        switch step {
        case 0:
            guard updater.requiredUpdate != nil,
                  let panel = NSApp.windows.first(where: { $0.title == "한Q 업데이트 필요" && $0.isVisible }) else { return }
            precondition(owner.updateRestricted && owner.tap == nil && !owner.enabled)
            owner.startMapping(); owner.toggleKorean(); owner.toggleHanja()
            precondition(!owner.enabled && !owner.pendingActivation)
            precondition(UserDefaults.standard.bool(forKey: "koreanKeyEnabled"))
            precondition(updater.automaticItem.title == "업데이트 자동 확인" && updater.automaticItem.toolTip == nil)
            print("PASS: signed policy shows required-update panel and blocks all input activation paths")
            fflush(stdout)
            if interactive {
                step = 10
                return
            }
            panel.close()
            precondition(owner.updateRestricted && !owner.enabled)
            updater.showRequiredUpdate()
            precondition(panel.isVisible)
            // Invoke the production recheck action; the next injected response is offline.
            NSApp.sendAction(NSSelectorFromString("recheckPolicy"), to: updater, from: nil)
            step = 1
        case 1:
            guard events.count == 2 else { return }
            precondition(!owner.updateRestricted && updater.requiredUpdate == nil)
            precondition(!NSApp.windows.contains { $0.title == "한Q 업데이트 필요" && $0.isVisible })
            print("PASS: closing panel cannot bypass restriction; offline recheck releases it")
            NSApp.sendAction(NSSelectorFromString("recheckPolicy"), to: updater, from: nil)
            step = 2
        case 2:
            guard events.count == 3 else { return }
            precondition(owner.updateRestricted)
            NSApp.sendAction(NSSelectorFromString("recheckPolicy"), to: updater, from: nil)
            step = 3
        case 3:
            guard events.count == 4 else { return }
            precondition(events == [true, false, true, false] && !owner.updateRestricted)
            print("PASS: renewed requirement and signed withdrawal restore the expected state")
            finish()
        case 10:
            // In interactive mode the operator clicks the real recheck button.
            guard events.count == 2 else { return }
            precondition(!owner.updateRestricted && updater.requiredUpdate == nil)
            print("PASS: interactive offline recheck dismissed panel and released restriction")
            finish()
        default: break
        }
    }
    func finish() {
        timer?.invalidate(); updater.stop()
        NSStatusBar.system.removeStatusItem(owner.statusItem)
        fflush(stdout)
        if interactive {
            // Leave a visible result instead of racing a UI inspector with process exit.
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            result.title = "한Q 정책 테스트 완료"
            result.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "정책 재확인과 오프라인 제한 해제 확인 완료")
            let quit = NSButton(title: "테스트 종료", target: NSApp, action: #selector(NSApplication.terminate(_:)))
            let stack = NSStackView(views: [label, quit]); stack.orientation = .vertical; stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false; result.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: result.contentView!.centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: result.contentView!.centerYAnchor)])
            result.center(); result.makeKeyAndOrderFront(nil)
        } else { NSApp.terminate(nil) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let harness = Harness()
app.delegate = harness
app.run()
