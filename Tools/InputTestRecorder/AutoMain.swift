import AppKit
import Darwin

final class AutoInputApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "준비 상태를 확인하세요.")
    let detail = NSTextField(wrappingLabelWithString: "")
    var startButton: NSButton!, stopButton: NSButton!
    let queue = DispatchQueue(label: "hanq.user-started-input-test", qos: .userInitiated)
    var running = false, countdown: Timer?, remaining = 0, folder: URL?
    var editor: UserStartedChatGPTEditor?
    var attempt: RecorderSession?
    var product: NSRunningApplication?
    var monitors = [Any]()
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu(); menu.addItem(item); item.submenu = submenu
        submenu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 680, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ChatGPT 자동 입력 시험"; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "ChatGPT 자동 입력 시험"); title.font = .boldSystemFont(ofSize: 23)
        let intro = NSTextField(wrappingLabelWithString: "시작을 누른 뒤 8초 안에 현재 ChatGPT의 빈 입력창을 클릭하세요.\n두벌식 5문장·3속도로 총100회 입력합니다. 약 3분 동안 본문·커서·입력 소스와 삭제/덮어쓰기를 확인합니다.")
        let rules = NSTextField(wrappingLabelWithString: "시험 중 키보드·마우스를 사용하지 마세요. Escape로 중단할 수 있습니다.\n기존 초안이 있으면 시작하지 않습니다. 메시지를 전송하지 않으며, 첫 불일치에서 멈춥니다. 마지막 시험 초안은 확인할 수 있게 남깁니다.")
        let privacy = NSTextField(wrappingLabelWithString: "고정 시험 문장·일치 여부·빠진 예상 위치·처리 시각을 저장합니다.\n실제 본문·클립보드는 저장하지 않습니다. 속도가 맞지 않은 회차는 별도 표시합니다."); privacy.textColor = .secondaryLabelColor
        startButton = button("자동 시험 시작", #selector(start)); stopButton = button("중단", #selector(stop)); stopButton.isEnabled = false
        let row = NSStackView(views: [startButton, stopButton, button("권한 설정", #selector(permissions)), button("결과 폴더", #selector(reveal))]); row.spacing = 10
        let stack = NSStackView(views: [title, intro, row, status, rules, detail, privacy]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        for label in [title, intro, status, rules, detail, privacy] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        status.stringValue = UserStartedChatGPTEditor.permissions() ? "권한 준비됨 · ChatGPT 빈 초안을 준비하세요." : "이 자동 시험 앱의 손쉬운 사용·키 전송 권한이 필요합니다."
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func permissions() {
        guard !running else { return }; UserStartedChatGPTEditor.requestPermissions()
        status.stringValue = "이 앱의 권한을 허용한 뒤 자동 시험 시작을 누르세요."
    }
    func update() { startButton.isEnabled = !running; stopButton.isEnabled = running }
    @objc func start() {
        guard !running else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--self-test") else { status.stringValue = "자체 UI 확인 모드 · 실제 앱 제어는 비활성화돼 있습니다."; return }
        guard UserStartedChatGPTEditor.permissions() else { status.stringValue = "먼저 ‘권한 설정’에서 이 앱의 권한을 허용하세요."; return }
        do {
            let context = try AutoHanQContext.discover()
            product = context.application
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HanQ Input Test Recorder/Automatic", isDirectory: true)
            var product = context.product; product["automaticInputTest"] = true
            let session = try RecorderSession(source: context.source, outputRoot: root, product: product); attempt = session; folder = session.directory
            let plan: [[String: Any]] = AutoInputPlan.cases().map { ["id": $0.id, "expectedSynthetic": $0.expected, "expectedDowns": $0.keys.count, "nominalGapMilliseconds": $0.gap * 1000, "overwrite": $0.overwrite] }
            try RecorderSession.writeJSON(["schema": 2, "mode": "user-started-automatic", "toolBundle": Bundle.main.bundleIdentifier ?? "", "toolBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "target": UserStartedChatGPTEditor.targetBundle, "planID": AutoInputPlan.identifier, "casesPlanned": AutoInputPlan.caseCount, "casePlan": plan, "typedTextCollected": false, "clipboardCollected": false, "sendReturn": false], to: session.directory.appendingPathComponent("auto-run.json"))
        } catch { status.stringValue = "한Q 진단 연결·결과 저장 준비를 확인할 수 없어 시작하지 않았습니다."; return }
        running = true; remaining = 8; update(); tick()
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick() {
        if remaining > 0 { status.stringValue = "\(remaining)초 뒤 시작 · ChatGPT의 빈 입력창을 클릭하세요."; remaining -= 1; return }
        countdown?.invalidate(); countdown = nil
        do {
            let value = try UserStartedChatGPTEditor(); value.product = product; editor = value
            let hanqPID = NSRunningApplication.runningApplications(withBundleIdentifier: "taek.in.hanq").first?.processIdentifier
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak value] event in
                let cg = event.cgEvent
                if cg?.getIntegerValueField(.eventSourceUserData) == UserStartedChatGPTEditor.marker { return }
                let pid = cg?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
                if pid == Int64(getpid()) || (hanqPID != nil && pid == Int64(hanqPID!)) { return }
                value?.cancel()
            }) { monitors.append(monitor) }
            else { throw AutoTestFailure.permission }
            guard let session = attempt else { throw AutoTestFailure.cancelled }; attempt = nil
            status.stringValue = "시험 중 · Escape로 중단"; queue.async { self.run(value, session: session) }
        } catch { finishPending(outcome: outcome(error), message: "시작 중단: \(reason(error))", extra: errorDetails(error)) }
    }
    func outcome(_ error: Error) -> String { error is AutoAXFailure ? "ax_read_failure" : ((error as? AutoTestFailure)?.rawValue ?? "recorder_error") }
    func errorDetails(_ error: Error) -> [String: Any] {
        if let ax = error as? AutoAXFailure { return ["axAttribute": ax.attribute, "axErrorCode": ax.code] }
        return [:]
    }
    func reason(_ error: Error) -> String {
        if error is AutoAXFailure { return "입력창 접근이 실패했습니다. 손쉬운 사용 권한과 선택한 입력창을 확인하세요." }
        guard let failure = error as? AutoTestFailure else { return "기록 저장 또는 연결 오류" }
        switch failure {
        case .existingDraft: return "빈 초안이 아니어서 입력하지 않았습니다."
        case .wrongApplication: return "현재 ChatGPT가 전면이 아니거나 대상이 바뀌었습니다."
        case .sourceChanged: return "두벌식이 아니거나 입력기가 바뀌었습니다."
        case .unreadableEditor: return "입력창 본문·커서를 읽을 수 없습니다."
        case .permission: return "권한 또는 입력 감시 준비를 확인할 수 없습니다."
        case .textMismatch: return "입력 결과가 예상 문장·커서와 다릅니다. 초안을 그대로 남겼습니다."
        case .cancelled: return "사용자 입력 또는 중단 요청을 감지했습니다."
        case .productExited: return "시험 중 한Q가 종료돼 중단했습니다."
        default: return "입력창·선택·보안 상태가 달라져 중단했습니다."
        }
    }
    func run(_ target: UserStartedChatGPTEditor, session: RecorderSession) {
        var results = [AutoCaseResult]()
        var outcome = "completed"
        var message = ""
        var accessError: [String: Any] = [:]
        do {
            let value = session
            try RecorderSession.writeJSON(["schema": 1, "targetPID": target.application.processIdentifier, "targetLaunchTime": target.application.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? "", "bundle": UserStartedChatGPTEditor.targetBundle], to: value.directory.appendingPathComponent("auto-target.json"))
            let engine = AutoInputEngine(editor: target, scope: "user-started-chatgpt", onBegin: { item in
                try RecorderSession.writeJSON(["id": item.id, "expectedSynthetic": item.expected, "nominalGapMilliseconds": item.gap * 1000, "overwrite": item.overwrite, "uptime": ProcessInfo.processInfo.systemUptime], to: value.directory.appendingPathComponent(String(format: "auto-attempt-%03d.json", item.id)))
            }, onAbort: { item, downs, ups, reason in
                try RecorderSession.writeJSON(["id": item.id, "postedDowns": downs, "postedUps": ups, "reason": reason, "uptime": ProcessInfo.processInfo.systemUptime], to: value.directory.appendingPathComponent("auto-interruption.json"))
            }) { result in
                guard UserStartedChatGPTEditor.permissions() else { throw AutoTestFailure.permission }
                let data = try JSONEncoder().encode(result)
                var row = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                row["finishedUptime"] = ProcessInfo.processInfo.systemUptime
                try RecorderSession.writeJSON(row, to: value.directory.appendingPathComponent(String(format: "auto-case-%03d.json", result.id)))
                results.append(result); try value.collect(scenario: "ordinary")
                DispatchQueue.main.async { self.status.stringValue = "\(result.id)/\(AutoInputPlan.caseCount) · \(result.bodyAndCaretMatched ? "본문·커서 일치" : "불일치") · \(Int(result.nominalGapMilliseconds))ms" }
            }
            try engine.run(AutoInputPlan.cases())
            message = "\(AutoInputPlan.caseCount)회 종료 · 본문·커서 일치 \(results.filter { $0.bodyAndCaretMatched }.count)건 · 속도 미충족 \(results.filter { !$0.pacingQualified }.count)건"
        } catch { outcome = self.outcome(error); accessError = errorDetails(error); message = reason(error) }
        do {
                // Include phase-1 incident files without posting more input.
                Thread.sleep(forTimeInterval: 1.1); try session.finish(scenario: "ordinary")
                var final: [String: Any] = ["schema": 1, "outcome": outcome, "cases": results.count, "bodyAndCaretMatches": results.filter { $0.bodyAndCaretMatched }.count, "pacingUnqualified": results.filter { !$0.pacingQualified }.count, "userStarted": true, "actualTextStored": false]
                final.merge(accessError) { original, _ in original }
                try RecorderSession.writeJSON(final, to: session.directory.appendingPathComponent("auto-result.json"))
        } catch { message += " · 일부 기록 저장에 실패했습니다." }
        DispatchQueue.main.async { self.complete(message) }
    }
    func finishPending(outcome: String, message: String, extra: [String: Any] = [:]) {
        countdown?.invalidate(); countdown = nil
        let session = attempt; attempt = nil
        queue.async {
            var note = message
            do {
                try session?.finish(scenario: "ordinary")
                if let session {
                    var final: [String: Any] = ["schema": 1, "outcome": outcome, "cases": 0, "bodyAndCaretMatches": 0, "pacingUnqualified": 0, "userStarted": true, "actualTextStored": false]
                    final.merge(extra) { original, _ in original }; try RecorderSession.writeJSON(final, to: session.directory.appendingPathComponent("auto-result.json"))
                }
            } catch { note += " · 일부 기록 저장에 실패했습니다." }
            let finalNote = note; DispatchQueue.main.async { self.complete(finalNote) }
        }
    }
    func complete(_ message: String) {
        countdown?.invalidate(); countdown = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }; monitors.removeAll()
        editor = nil; running = false; update(); status.stringValue = message
        let saved = folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("auto-result.json").path) } ?? false
        detail.stringValue = saved ? "결과를 저장했습니다. 불일치가 있었다면 한Q의 ‘진단 및 로그 → 방금 발생한 문제 기록’으로 추가 진단을 남길 수 있습니다." : "시험 준비 또는 저장이 끝나지 않았습니다. 기존 초안을 지우지 않으며 폴더에 일부 기록이 있을 수 있습니다."
        if saved { NSApp.requestUserAttention(.informationalRequest) }
    }
    @objc func stop() { editor?.cancel(); if countdown != nil { finishPending(outcome: "cancelled", message: "시작 전에 중단했습니다.") } }
    @objc func reveal() { if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard running else { return .terminateNow }
        stop(); if !running { return .terminateNow }
        status.stringValue = "중단·저장 중입니다. 저장이 끝난 뒤 종료하세요."; return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { window.makeKeyAndOrderFront(nil); sender.activate(ignoringOtherApps: true); return true }
}

@main enum AutoInputTestMain {
    static func main() { let app = NSApplication.shared; app.setActivationPolicy(.regular); let delegate = AutoInputApp(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } }
}
