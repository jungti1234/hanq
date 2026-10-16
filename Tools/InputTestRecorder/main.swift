import AppKit
import Darwin

struct HanQConnection {
    let source: URL
    let product: [String: Any]
    let application: NSRunningApplication
    static func discover() throws -> HanQConnection {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "taek.in.hanq").filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first, let url = app.bundleURL,
              let executable = app.executableURL,
              executable.standardizedFileURL == url.appendingPathComponent("Contents/MacOS/HanQ").standardizedFileURL else { throw RecorderError.invalidDirectory }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, app.processIdentifier], size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { throw RecorderError.invalidDirectory }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { throw RecorderError.invalidDirectory }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var offset = 4
        while offset < size && data[offset] != 0 { offset += 1 }
        while offset < size && data[offset] == 0 { offset += 1 }
        var args = [String]()
        for _ in 0..<max(0, min(Int(argc), 128)) {
            let begin = offset
            while offset < size && data[offset] != 0 { offset += 1 }
            args.append(String(decoding: data[begin..<offset], as: UTF8.self)); offset += 1
            if offset >= size { break }
        }
        guard let index = args.firstIndex(of: "--diagnose-input-incidents"), index + 1 < args.count else { throw RecorderError.invalidDirectory }
        let source = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath()
        let fd = try RecorderSession.directoryFD(source); close(fd)
        return HanQConnection(source: source, product: ["pid": app.processIdentifier, "path": url.path, "launchTime": app.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""], application: app)
    }
}

final class RecorderApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "한Q 진단 연결을 확인하세요.")
    let detail = NSTextField(wrappingLabelWithString: "")
    let scenario = NSPopUpButton()
    var startButton: NSButton!, stopButton: NSButton!, trialButton: NSButton!, normalButton: NSButton!, lossButton: NSButton!
    let queue = DispatchQueue(label: "hanq.input-test-recorder", qos: .utility)
    var session: RecorderSession?, connection: HanQConnection?, timer: Timer?, lastFolder: URL?
    var active = false, stopping = false, productEnded = false
    var scenarioID: String { ["ordinary", "reentry", "append", "overwrite", "switch"][max(0, scenario.indexOfSelectedItem)] }
    var outputRoot: URL {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--output-root"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HanQ Input Test Recorder/Sessions", isDirectory: true)
    }
    func button(_ title: String, _ selector: Selector) -> NSButton { NSButton(title: title, target: self, action: selector) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 660, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ChatGPT 입력 진단 기록"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "ChatGPT 입력 진단 기록"); title.font = .boldSystemFont(ofSize: 22)
        let intro = NSTextField(wrappingLabelWithString: "시험 대상은 현재 대화용 ChatGPT 앱입니다.\nChatGPT에서 직접 입력하세요. 이 앱은 입력하거나 전송하지 않습니다.")
        let instructions = NSTextField(wrappingLabelWithString: "누락이 보이면 한Q 메뉴의 ‘방금 입력 누락 기록’을 누르세요.\n이 앱이 이후 저장되는 처리 진단을 자동으로 모읍니다. ‘누락 관찰’은 관찰 시각만 표시합니다.")
        let privacy = NSTextField(wrappingLabelWithString: "입력 본문·누른 키·클립보드는 수집하지 않습니다.\n저장 결과는 사용자 관찰과 한Q 처리 기록이며, ChatGPT 수신을 자동 판정하지 않습니다."); privacy.textColor = .secondaryLabelColor
        scenario.addItems(withTitles: ["평소 입력", "입력창 재진입", "기존 문장 뒤 이어 쓰기", "선택 후 덮어쓰기", "한영 전환 뒤 입력"])
        scenario.target = self; scenario.action = #selector(scenarioChanged)
        startButton = button("기록 시작", #selector(start)); stopButton = button("기록 종료", #selector(stop))
        trialButton = button("구간 시작 표시", #selector(trial)); normalButton = button("정상 관찰", #selector(normal)); lossButton = button("누락 관찰", #selector(loss))
        let row = NSStackView(views: [startButton, stopButton, button("다시 연결", #selector(reconnect)), button("기록 폴더", #selector(reveal))]); row.spacing = 8
        let observations = NSStackView(views: [trialButton, normalButton, lossButton]); observations.spacing = 8
        let stack = NSStackView(views: [title, intro, status, scenario, row, observations, instructions, detail, privacy]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        for label in [title, intro, status, instructions, detail, privacy] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateButtons(); reconnect(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func updateButtons() {
        startButton.isEnabled = !active && connection != nil
        stopButton.isEnabled = active && !stopping
        for b in [trialButton, normalButton, lossButton] { b?.isEnabled = active && !stopping }
        scenario.isEnabled = !stopping
    }
    @objc func reconnect() {
        guard !active else { return }
        do { connection = try HanQConnection.discover(); status.stringValue = "실행 중인 한Q · 진단 연결됨"; detail.stringValue = "기록 시작 후 생성되는 진단만 저장합니다. 기존 기록과 구분됩니다." }
        catch { connection = nil; status.stringValue = "진단 모드로 실행 중인 한Q에 연결할 수 없습니다."; detail.stringValue = "한Q 진단 실행을 준비한 뒤 ‘다시 연결’을 누르세요. 앱과 입력기 설정은 바꾸지 않습니다." }
        updateButtons()
    }
    @objc func start() {
        guard !active else { return }; reconnect(); guard let connection else { return }
        active = true; productEnded = false; updateButtons(); let root = outputRoot
        queue.async {
            do {
                var product = connection.product; product["recorderSelfTest"] = ProcessInfo.processInfo.arguments.contains("--self-test")
                let value = try RecorderSession(source: connection.source, outputRoot: root, product: product); self.session = value
                DispatchQueue.main.async { self.lastFolder = value.directory; self.status.stringValue = "기록 중 · ChatGPT에서 직접 입력하세요."; self.detail.stringValue = "저장된 진단 0건 · 관찰 표시 0건"; self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() } }
            } catch { DispatchQueue.main.async { self.active = false; self.status.stringValue = "기록을 시작하지 못했습니다."; self.detail.stringValue = error.localizedDescription; self.updateButtons() } }
        }
    }
    func fail(_ error: Error) { DispatchQueue.main.async { self.detail.stringValue = error.localizedDescription } }
    func poll() {
        let id = scenarioID
        if connection?.application.isTerminated == true && active && !stopping {
            productEnded = true
            queue.async { do { try self.session?.record("product_exited", scenario: id) } catch { self.fail(error) } }
            stop(); return
        }
        queue.async {
            guard let session = self.session else { return }
            do { try session.collect(scenario: id); let text = "저장된 진단 \(session.copied)건 · 관찰 표시 \(session.observations)건 · 제외된 파일 \(session.rejected)건"; DispatchQueue.main.async { self.detail.stringValue = text } }
            catch { self.fail(error) }
        }
    }
    func observe(_ kind: String) {
        guard active, !stopping else { return }; let id = scenarioID
        queue.async { do { try self.session?.record(kind, scenario: id) } catch { self.fail(error) } }; poll()
    }
    @objc func scenarioChanged() { if active { observe("trial_started") } }
    @objc func trial() { observe("trial_started") }
    @objc func normal() { observe("observed_normal") }
    @objc func loss() { observe("observed_loss"); detail.stringValue = "관찰 시각을 표시했습니다. 한Q 메뉴의 ‘방금 입력 누락 기록’도 눌러 직전 진단을 남기세요." }
    @objc func stop() {
        guard active, !stopping else { return }; stopping = true; timer?.invalidate(); updateButtons(); status.stringValue = "마지막 진단을 저장하는 중…"; let id = scenarioID, exited = productEnded
        queue.asyncAfter(deadline: .now() + 2) {
            var complete = false
            do { try self.session?.finish(scenario: id); complete = self.session?.collectionWarning == nil && self.session != nil } catch { self.fail(error) }; self.session = nil
            let message = complete ? (exited ? "한Q 종료 감지 · 기록을 종료하고 저장했습니다." : "기록 종료 · 폴더에 저장했습니다.") : "기록 종료 · 수집이 불완전합니다. 폴더의 기록을 확인하세요."
            DispatchQueue.main.async { self.active = false; self.stopping = false; self.status.stringValue = message; self.updateButtons() }
        }
    }
    @objc func reveal() { if let lastFolder { NSWorkspace.shared.activateFileViewerSelecting([lastFolder]) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard active else { return .terminateNow }
        timer?.invalidate(); let id = scenarioID
        queue.asyncAfter(deadline: .now() + (active ? 2 : 0)) { do { try self.session?.finish(scenario: id) } catch { }; DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); sender.activate(ignoringOtherApps: true); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = RecorderApp(); application.delegate = delegate; application.run()
