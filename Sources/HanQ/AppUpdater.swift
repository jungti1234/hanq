import AppKit
import Sparkle

final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var policy: UpdatePolicyClient?
    private var observations: [NSKeyValueObservation] = []
    private var panel: NSPanel?
    private var reasonLabel: NSTextField?
    private var policyUpdateButton: NSButton?
    private var recheckButton: NSButton?
    private(set) var requiredUpdate: UpdatePolicy.Rule?
    var onRestrictionChange: ((Bool) -> Void)?
    let checkItem = NSMenuItem(title: "업데이트 확인…", action: nil, keyEquivalent: "")
    let automaticItem = NSMenuItem(title: "업데이트 자동 확인", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        checkItem.target = self; checkItem.action = #selector(checkForUpdates)
        automaticItem.target = self; automaticItem.action = #selector(toggleAutomaticChecks)
        refreshMenus()
    }

    func start(bundle: Bundle = .main, policyFetch: UpdatePolicyClient.Fetch? = nil) {
        guard controller == nil,
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let keyString = bundle.object(forInfoDictionaryKey: "HanQPolicyPublicKey") as? String,
              let key = Data(base64Encoded: keyString), key.count == 32,
              let policyURL = bundle.object(forInfoDictionaryKey: "HanQPolicyURL") as? String,
              let url = URL(string: policyURL), url.scheme == "https",
              let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(buildString) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do { try controller.updater.start() }
        catch { NSLog("업데이트 초기화 실패: %@", error.localizedDescription); return }
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.refreshMenus() },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.refreshMenus() }
        ]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let release = bundle.object(forInfoDictionaryKey: "HanQReleaseVersion") as? String ?? ""
        let client = UpdatePolicyClient(url: url, key: key, context: .init(build: build,
            channel: release.contains("-beta.") ? "beta" : "stable", architecture: "arm64",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            fetch: policyFetch ?? { UpdatePolicyRequest(url: $0, head: $1, completion: $2) })
        client.onChange = { [weak self] rule in self?.apply(rule) }
        client.onCheckingChange = { [weak self] in self?.refreshMenus() }
        policy = client
        client.check()
        refreshMenus()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let release = Bundle.main.object(forInfoDictionaryKey: "HanQReleaseVersion") as? String ?? ""
        return release.contains("-beta.") ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        policy?.check()
    }

    @objc private func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates, policy?.isChecking != true else { return }
        policy?.check { [weak self] in
            guard let self, self.controller?.updater.canCheckForUpdates == true else { return }
            self.controller?.checkForUpdates(nil)
        }
    }

    @objc private func toggleAutomaticChecks() {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
        refreshMenus()
    }

    private func refreshMenus() {
        let available = controller?.updater.canCheckForUpdates == true
        checkItem.isEnabled = available && policy?.isChecking != true
        checkItem.toolTip = controller == nil ? "업데이트 배포 설정을 준비 중입니다." : nil
        automaticItem.isEnabled = controller != nil
        automaticItem.state = controller?.updater.automaticallyChecksForUpdates == true ? .on : .off
        policyUpdateButton?.isEnabled = checkItem.isEnabled
        recheckButton?.isEnabled = policy?.isChecking != true
    }

    private func apply(_ rule: UpdatePolicy.Rule?) {
        let changed = requiredUpdate != rule
        requiredUpdate = rule
        onRestrictionChange?(rule != nil)
        guard let rule else { panel?.orderOut(nil); return }
        reasonLabel?.stringValue = "\(rule.reason)\n\n\(rule.targetVersion) (빌드 \(rule.targetBuild)) 이상으로 업데이트해야 한Q를 사용할 수 있습니다."
        if changed { showRequiredUpdate() }
    }

    func showRequiredUpdate() {
        guard let rule = requiredUpdate else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: 270),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "한Q 업데이트 필요"
            panel.isReleasedWhenClosed = false
            let title = NSTextField(labelWithString: "계속 사용하려면 업데이트해 주세요")
            title.font = .boldSystemFont(ofSize: 18)
            let reason = NSTextField(wrappingLabelWithString: "")
            reasonLabel = reason
            let update = NSButton(title: "업데이트…", target: self, action: #selector(checkForUpdates))
            let recheck = NSButton(title: "정책 다시 확인", target: self, action: #selector(recheckPolicy))
            let download = NSButton(title: "설치 파일 열기", target: self, action: #selector(openDownload))
            let quit = NSButton(title: "종료", target: NSApp, action: #selector(NSApplication.terminate(_:)))
            policyUpdateButton = update; recheckButton = recheck
            let buttons = NSStackView(views: [update, recheck, download, quit])
            buttons.spacing = 10
            let stack = NSStackView(views: [title, reason, buttons])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 24
            stack.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
                stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
            ])
            self.panel = panel
            panel.center()
        }
        reasonLabel?.stringValue = "\(rule.reason)\n\n\(rule.targetVersion) (빌드 \(rule.targetBuild)) 이상으로 업데이트해야 한Q를 사용할 수 있습니다."
        refreshMenus()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func recheckPolicy() { policy?.check() }
    @objc private func openDownload() {
        if let url = requiredUpdate?.downloadURL { NSWorkspace.shared.open(url) }
    }
    func stop() { policy?.stop(); panel?.orderOut(nil) }
}
