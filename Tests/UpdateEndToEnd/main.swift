import AppKit

final class UpdateHarness: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        let prefs = UserDefaults.standard
        if version == "1" { prefs.set("retained", forKey: "regressionMarker") }
        let retained = prefs.string(forKey: "regressionMarker") == "retained"
        let result = Bundle.main.object(forInfoDictionaryKey: "TestResultPath") as! String
        let data: [String: Any] = ["build": version, "settingRetained": retained,
                                  "path": Bundle.main.bundlePath, "pid": ProcessInfo.processInfo.processIdentifier]
        try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: result))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 190),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "한Q 업데이트 교체 테스트 — 별도 앱"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "테스트 빌드 \(version) · 설정 유지: \(retained ? "정상" : "실패")")
        let check = NSButton(title: "테스트 업데이트 확인…", target: updater.checkItem.target, action: updater.checkItem.action)
        let quit = NSButton(title: "테스트 종료", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let stack = NSStackView(views: [label, check, quit]); stack.orientation = .vertical; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)])
        let config = Bundle(path: Bundle.main.resourcePath! + "/Config.bundle")!
        let required = Bundle.main.object(forInfoDictionaryKey: "TestRequiredPolicy") as? Bool == true
        if required {
            let policyData = try! Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("required.json"))
            updater.onRestrictionChange = { restricted in
                precondition(restricted == (version == "1"), "Unexpected restriction for installed build")
                var verified = data
                verified["restricted"] = restricted
                verified["policyChecked"] = true
                try! JSONSerialization.data(withJSONObject: verified, options: [.prettyPrinted])
                    .write(to: URL(fileURLWithPath: result))
                label.stringValue = "테스트 빌드 \(version) · 필수 제한: \(restricted ? "적용" : "해제") · 설정: \(retained ? "유지" : "실패")"
            }
            // Only policy transport/HEAD availability are fixtures. Signature and build decisions use production code.
            updater.start(bundle: config, policyFetch: { _, head, reply in
                DispatchQueue.main.async { reply(head ? Data() : policyData) }; return nil
            })
        } else {
            updater.start(bundle: config, policyFetch: { _, _, reply in DispatchQueue.main.async { reply(nil) }; return nil })
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { updater.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let harness = UpdateHarness()
app.delegate = harness
app.run()
