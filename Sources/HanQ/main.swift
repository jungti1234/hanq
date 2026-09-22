import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let updater = AppUpdater()
    var updateRestricted = false
    let jamoRepair = JamoRepair()
    lazy var externalKeyboards: ExternalKeyboardController = {
        let controller = ExternalKeyboardController()
        controller.canConfigure = { [weak self] in
            guard let self else { return false }
            return self.permissionGranted && !self.updateRestricted && self.tap != nil && self.enabled
                && !self.filter.consuming && !self.optionFilter.consuming
        }
        controller.onBeginCapture = { [weak self] in self?.jamoRepair.inputDidChange() }
        return controller
    }()
    let hud = HUDController()
    let inputSource = InputSourceObserver()
    var sourceObservations = 0
    var diagnosticEventCount = 0
    var window: NSWindow!
    var permissionContent: NSView!
    var permissionTimer: Timer?
    var safetyPulseTimer: Timer?
    let inputSafety = InputSafetyWatchdog()
    let permissionRecovery = PermissionRecovery()
    lazy var freshPermission = FreshPermissionMonitor { [weak self] reason in
        NSLog("입력 안전 종료: 새 프로세스 권한 검사 (%@)", reason)
        if reason == "permission-denied" { self?.permissionRecovery.exitAfterPermissionLoss() }
        _exit(72)
    }
    var permissionGranted = false
    var pendingActivation = true
    let status = NSTextField(wrappingLabelWithString: "한영키·한자키 꺼짐")
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var optionFilter = CommandFilter(keyCode: 61, left: 0x20, right: 0x40, aggregate: .maskAlternate)
    var filter = CommandFilter()
    var enabled = false
    var koreanEnabled = false
    var hanjaEnabled = false
    var statusItem: NSStatusItem!
    let toggleItem = NSMenuItem(title: "한영키 사용", action: #selector(toggleKorean), keyEquivalent: "")
    let hanjaItem = NSMenuItem(title: "한자키 사용", action: #selector(toggleHanja), keyEquivalent: "")
    let capsItem = NSMenuItem(title: "한/A (Caps Lock) 키로 입력 소스 전환", action: #selector(toggleCaps), keyEquivalent: "")
    let hudItem = NSMenuItem(title: "입력 소스 변경 시 화면에 표시", action: #selector(toggleHUD), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    let menuStatus = NSMenuItem(title: "준비 중", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.shared.start()
        permissionRecovery.prepare()
        let preferences = UserDefaults.standard
        // Only initialize once, so disabling in macOS Settings is respected too.
        if !preferences.bool(forKey: "didInitializeLaunchAtLogin") {
            if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                do { try SMAppService.mainApp.register() }
                catch { NSLog("자동 실행 초기 설정 실패: %@", error.localizedDescription) }
            }
            let loginStatus = SMAppService.mainApp.status
            if loginStatus == .enabled || loginStatus == .requiresApproval {
                preferences.set(true, forKey: "didInitializeLaunchAtLogin")
            }
        }
        // Preserve the macOS Caps Lock setting, including on first launch.
        // Discard any pending automatic enable left by an older build.
        preferences.removeObject(forKey: "pendingInitialRomanSwitchEnable")
        UserDefaults.standard.register(defaults: ["hudEnabled": true])
        for key in ["koreanKeyEnabled", "hanjaKeyEnabled"] where UserDefaults.standard.object(forKey:key) == nil {
            UserDefaults.standard.set(true, forKey:key)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusIcon()
        let statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        capsItem.toolTip = "시스템 설정에 반영되며, 한Q를 종료해도 유지됩니다."
        menuStatus.isEnabled = false
        statusMenu.addItem(menuStatus)
        statusMenu.addItem(externalKeyboards.menuSeparator)
        statusMenu.addItem(externalKeyboards.menuItem)
        statusMenu.addItem(.separator())
        toggleItem.target = self; statusMenu.addItem(toggleItem)
        capsItem.target = self; capsItem.indentationLevel = 1; statusMenu.addItem(capsItem)
        hanjaItem.target = self; statusMenu.addItem(hanjaItem)
        statusMenu.addItem(.separator())
        hudItem.target = self; hudItem.state = UserDefaults.standard.bool(forKey: "hudEnabled") ? .on : .off
        statusMenu.addItem(hudItem)
        loginItem.target = self
        statusMenu.addItem(loginItem)
        statusMenu.addItem(updater.automaticItem)
        refreshLaunchAtLogin()
        statusMenu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "한Q 정보", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        statusMenu.addItem(aboutItem)
        statusMenu.addItem(updater.checkItem)
        statusMenu.addItem(makeFeedbackItem())
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "한Q 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let appAboutItem = NSMenuItem(title: "한Q 정보", action: #selector(showAbout), keyEquivalent: "")
        appAboutItem.target = self
        appMenu.addItem(appAboutItem)
        appMenu.addItem(makeFeedbackItem())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "한Q 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: "편집"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "한Q 시작하기"
        window.isReleasedWhenClosed = false
        buildPermissionView()
        inputSource.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.jamoRepair.inputSourceDidChange()
            self.sourceObservations += 1
            if self.permissionGranted && !self.updateRestricted && self.sourceObservations > 1 && UserDefaults.standard.bool(forKey: "hudEnabled") { self.hud.show(name: snapshot?.name) }
        }
        inputSource.start()
        window.center()
        let pulse = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.inputSafety.pulse()
            InputDiagnostics.shared.record("main.pulse tap=\(self.tap != nil) enabled=\(self.enabled) cachedAX=\(self.permissionGranted) events=\(self.diagnosticEventCount)")
        }
        safetyPulseTimer = pulse
        RunLoop.main.add(pulse, forMode: .common)
        updatePermission()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updatePermission() }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        showWindow()
        if !permissionGranted { requestAccessibility() }
        updater.onRestrictionChange = { [weak self] restricted in self?.setUpdateRestricted(restricted) }
        updater.start()
        #if HANQ_DEVELOPMENT
        showDevelopmentTestPanels()
        #endif
    }

    private func configureStatusIcon() {
        guard let button = statusItem.button,
              let iconURL = Bundle.main.url(forResource: "HanQ-MenuBar-Template", withExtension: "pdf"),
              let icon = NSImage(contentsOf: iconURL) else {
            statusItem.button?.title = "한Q"
            return
        }
        icon.isTemplate = true
        icon.size = NSSize(width: 144.0 / 112.0 * 18.0, height: 18.0)
        button.image = icon
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "한Q"
        button.setAccessibilityLabel("한Q")
    }

    func buildPermissionView() {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(panel)
        permissionContent = panel
        let badge: NSView
        if let logoURL = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png"),
           let logoImage = NSImage(contentsOf: logoURL) {
            let logo = NSImageView(image: logoImage)
            logo.imageScaling = .scaleProportionallyUpOrDown
            logo.translatesAutoresizingMaskIntoConstraints = false
            logo.setAccessibilityLabel("한Q 로고")
            NSLayoutConstraint.activate([
                logo.widthAnchor.constraint(equalToConstant: 120),
                logo.heightAnchor.constraint(equalToConstant: 120 * 704 / 920)
            ])
            badge = logo
        } else {
            let fallback = NSTextField(labelWithString: "한Q")
            fallback.font = .systemFont(ofSize: 46, weight: .bold)
            fallback.textColor = .controlAccentColor
            badge = fallback
        }
        let title = NSTextField(labelWithString: "한Q를 시작할 준비가 됐어요")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "어느 앱에서나 한영키와 한자키를 사용하려면\n손쉬운 사용 권한이 필요해요.")
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        let steps = NSTextField(wrappingLabelWithString: "시스템 설정에서 ‘한Q’ 또는 ‘HanQ’를 켜주세요.\n목록에 없다면 + 버튼으로 이 앱을 추가해주세요.")
        steps.font = .systemFont(ofSize: 13)
        steps.alignment = .center
        let button = NSButton(title: "손쉬운 사용 설정 열기", target: self, action: #selector(openAccessibility))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "허용하면 자동으로 시작할게요")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [badge, title, detail, steps, button, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            panel.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            panel.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -64)
        ])
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func openAccessibility() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func updatePermission() {
        InputDiagnostics.shared.record("main.ax.begin")
        let granted = AXIsProcessTrusted()
        InputDiagnostics.shared.record("main.ax.end granted=\(granted)")
        permissionRecovery.observePermission(granted)
        let lostPermission = permissionGranted && !granted
        if lostPermission {
            // Revocation/deletion can wedge WindowServer during tap cleanup.
            // Release the process's ports through process exit, without calling
            // back into CGEventTapEnable or AppKit termination handlers.
            NSLog("입력 안전 종료: 손쉬운 사용 권한 철회 또는 목록 삭제")
            InputDiagnostics.shared.record("exit.permissionLost")
            permissionRecovery.exitAfterPermissionLoss()
        }
        if !granted {
            if permissionGranted || tap != nil {
                NSLog("입력 감지 해제: 손쉬운 사용 권한 없음")
            }
            stopMapping()
            pendingActivation = true
            hud.hide()
        }
        permissionGranted = granted
        permissionContent.isHidden = granted
        if granted { window.orderOut(nil) }
        if granted && pendingActivation && !updateRestricted {
            let korean = UserDefaults.standard.bool(forKey: "koreanKeyEnabled")
            let hanja = UserDefaults.standard.bool(forKey: "hanjaKeyEnabled")
            if korean || hanja {
                startMapping()
                if enabled {
                    koreanEnabled = korean; hanjaEnabled = hanja
                    pendingActivation = false
                }
            } else { pendingActivation = false }
        }
        refreshStatus()
        externalKeyboards.tick()
    }

    func setUpdateRestricted(_ restricted: Bool) {
        guard updateRestricted != restricted else { return }
        updateRestricted = restricted
        if restricted {
            pendingActivation = false
            stopMapping()
            hud.hide()
        } else {
            pendingActivation = true
            updatePermission()
        }
        refreshStatus()
    }

    @objc func startMapping() {
        guard !updateRestricted else { return }
        guard !filter.consuming && !optionFilter.consuming && !externalKeyboards.consuming else { status.stringValue = "누른 한영키와 한자키를 놓은 뒤 다시 시작하세요."; return }
        guard !CGEventSource.keyState(.combinedSessionState, key: 54) && !CGEventSource.keyState(.combinedSessionState, key: 61) else {
            status.stringValue = "우측 Command와 Option을 놓은 뒤 시작하세요."; return
        }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            status.stringValue = "손쉬운 사용에서 ‘한Q’를 허용한 뒤 원하는 키를 다시 켜세요."
            return
        }
        if tap == nil {
            let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            let callback: CGEventTapCallBack = { proxy, type, event, context in
                let owner = Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue()
                owner.diagnosticEventCount += 1
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Never re-enable a tap that macOS disabled. Release the input
                    // path before doing UI or permission work on the main run loop.
                    InputDiagnostics.shared.record("tap.disabled type=\(type.rawValue)")
                    owner.enabled = false
                    owner.koreanEnabled = false
                    owner.hanjaEnabled = false
                    owner.pendingActivation = false
                    NSLog("입력 감지 중단: %u; 콜백 반환 후 해제", type.rawValue)
                    DispatchQueue.main.async {
                        owner.stopMapping()
                        owner.updatePermission()
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard owner.permissionGranted && !owner.updateRestricted else {
                    owner.enabled = false
                    DispatchQueue.main.async { owner.stopMapping() }
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == 0x454F5448 { return Unmanaged.passUnretained(event) }
                if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                    owner.jamoRepair.inputDidChange(type: type, key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                }
                let active = owner.enabled && !IsSecureEventInputEnabled()
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                let snapshot = owner.externalKeyboards.wantsInputSource(type: type, event: event)
                    ? InputSourceSnapshot.read() : nil
                let externalTarget = active && owner.koreanEnabled && snapshot != nil ? KoreanEnglishSwitch.target(for: snapshot) : nil
                let external = owner.externalKeyboards.process(type: type, event: event, active: active,
                    koreanAllowed: externalTarget != nil, hanjaAllowed: owner.hanjaEnabled)
                if external.korean, let externalTarget {
                    let selection = KoreanEnglishSwitch.select(externalTarget)
                    DispatchQueue.main.async {
                        owner.inputSource.refresh()
                        if selection != 0 { NSLog("입력 소스 전환 실패: %d", selection) }
                    }
                }
                if external.hanja {
                    owner.jamoRepair.request(allowHanja: snapshot.map {
                        $0.isKorean && $0.id.hasPrefix("com.apple.inputmethod.Korean.")
                    } == true)
                }
                if external.consume { return nil }
                event.flags = external.flags
                let legacyKey = external.handled ? Int64(-1) : key
                let target = active && !external.handled && owner.koreanEnabled && type == .flagsChanged && key == 54
                    ? KoreanEnglishSwitch.target(for: InputSourceSnapshot.read()) : nil
                let result = owner.filter.process(type: type,
                    key: legacyKey,
                    flags: event.flags, acceptNewPress: active && target != nil)
                if let edge = result.edge {
                    if edge == "right-down" {
                        if let target {
                            let result = KoreanEnglishSwitch.select(target)
                            DispatchQueue.main.async {
                                owner.inputSource.refresh()
                                if result != 0 { NSLog("입력 소스 전환 실패: %d", result) }
                            }
                        }
                    }
                    owner.refreshStatus()
                }
                let isKorean = active && !external.handled && owner.hanjaEnabled && type == .flagsChanged && key == 61
                    && InputSourceSnapshot.read().map { $0.isKorean && $0.id.hasPrefix("com.apple.inputmethod.Korean.") } == true
                let option = owner.optionFilter.process(type: type, key: legacyKey,
                    flags: result.flags, acceptNewPress: active && !external.handled && owner.hanjaEnabled && result.flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty)
                if option.edge == "right-up", active && owner.hanjaEnabled {
                    owner.jamoRepair.request(allowHanja: isKorean)
                }
                if result.consume || option.consume { return nil }
                event.flags = option.flags
                return Unmanaged.passUnretained(event)
            }
            inputSafety.arm()
            InputDiagnostics.shared.record("tap.create.begin")
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            InputDiagnostics.shared.record("tap.create.end present=\(tap != nil)")
            guard let tap else {
                inputSafety.disarm()
                status.stringValue = "감지 시작 실패 — 손쉬운 사용 권한을 확인하세요."
                return
            }
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource!, .commonModes)
            freshPermission.start()
        }
        enabled = true
        externalKeyboards.start()

        refreshStatus()
    }

    /// Fail open: remove the system hook, not just the feature flags.
    /// Called outside the tap callback. The watchdog stays armed until cleanup ends.
    func stopMapping() {
        InputDiagnostics.shared.record("tap.stop.begin present=\(tap != nil)")
        enabled = false
        koreanEnabled = false
        hanjaEnabled = false
        let oldTap = tap
        let oldSource = tapSource
        tap = nil
        tapSource = nil
        if let oldSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), oldSource, .commonModes)
            CFRunLoopSourceInvalidate(oldSource)
        }
        if let oldTap { CFMachPortInvalidate(oldTap) }
        inputSafety.disarm()
        freshPermission.stop()
        filter = CommandFilter()
        optionFilter = CommandFilter(keyCode: 61, left: 0x20, right: 0x40, aggregate: .maskAlternate)
        jamoRepair.inputDidChange()
        externalKeyboards.stop()
        InputDiagnostics.shared.record("tap.stop.end")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatus()
        refreshLaunchAtLogin()
        externalKeyboards.updateMenu()
    }
    private func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.toolTip = "로그인하면 한Q가 자동으로 시작됩니다."
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.toolTip = "시스템 설정에서 허용이 필요합니다. 클릭하면 자동 실행 등록을 해제합니다."
        default:
            loginItem.state = .off
            loginItem.toolTip = "로그인하면 한Q가 자동으로 시작되도록 설정합니다."
        }
    }
    @objc func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(true, forKey: "didInitializeLaunchAtLogin")
            default:
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "didInitializeLaunchAtLogin")
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "자동 실행 설정을 변경하지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLaunchAtLogin()
    }
    func refreshStatus() {
        status.stringValue = "한영키 \(koreanEnabled ? "켜짐" : "꺼짐") · 한자키 \(hanjaEnabled ? "켜짐" : "꺼짐")"
        if filter.consuming || optionFilter.consuming { status.stringValue += " · 누른 우측 키를 놓아주세요" }
        toggleItem.state = koreanEnabled ? .on : .off
        hanjaItem.state = hanjaEnabled ? .on : .off
        let romanEnabled = try? RomanSwitchController.isEnabled()
        capsItem.isEnabled = koreanEnabled && RomanSwitchController.isSupported && romanEnabled != nil
        capsItem.state = romanEnabled.map { $0 ? .on : .off } ?? .mixed

        if !permissionGranted {
            toggleItem.state = UserDefaults.standard.bool(forKey: "koreanKeyEnabled") ? .on : .off
            hanjaItem.state = UserDefaults.standard.bool(forKey: "hanjaKeyEnabled") ? .on : .off
        }
        toggleItem.isEnabled = permissionGranted && !updateRestricted
        hanjaItem.isEnabled = permissionGranted && !updateRestricted
        hudItem.isEnabled = permissionGranted && !updateRestricted
        menuStatus.title = permissionGranted ? status.stringValue : "손쉬운 사용 권한을 기다리고 있어요"
        if updateRestricted { menuStatus.title = "업데이트가 필요해요 · 한Q 기능 중단" }
        statusItem.button?.appearsDisabled = !koreanEnabled && !hanjaEnabled
    }
    @objc func toggleKorean() {
        guard !updateRestricted else { return }
        if !koreanEnabled { startMapping(); guard enabled else { return } }
        koreanEnabled.toggle()
        UserDefaults.standard.set(koreanEnabled, forKey: "koreanKeyEnabled")
        enabled = koreanEnabled || hanjaEnabled
        refreshStatus()
    }
    @objc func toggleHanja() {
        guard !updateRestricted else { return }
        if !hanjaEnabled { startMapping(); guard enabled else { return } }
        hanjaEnabled.toggle()
        UserDefaults.standard.set(hanjaEnabled, forKey: "hanjaKeyEnabled")
        enabled = koreanEnabled || hanjaEnabled
        refreshStatus()
    }
    @objc func toggleCaps() {
        guard koreanEnabled && RomanSwitchController.isSupported else { return }
        do {
            let enabled = try RomanSwitchController.isEnabled()
            try RomanSwitchController.setEnabled(!enabled)
            refreshStatus()
        } catch {
            refreshStatus()
            let alert = NSAlert()
            alert.messageText = "Caps Lock 설정을 변경하지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    @objc func toggleHUD() {
        let enabled = !UserDefaults.standard.bool(forKey: "hudEnabled")
        UserDefaults.standard.set(enabled, forKey: "hudEnabled")
        hudItem.state = enabled ? .on : .off
        if !enabled { hud.hide() }
    }
    private func makeFeedbackItem() -> NSMenuItem {
        let item = NSMenuItem(title: "피드백 남기기…", action: #selector(openFeedback), keyEquivalent: "")
        item.target = self
        item.toolTip = "한Q에 관한 의견을 남길 수 있는 피드백 폼을 브라우저에서 엽니다."
        return item
    }

    @objc func openFeedback() {
        guard let url = FeedbackForm.url(), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "피드백 페이지를 열 수 없어요."
            alert.informativeText = "기본 웹 브라우저를 확인한 뒤 다시 시도해 주세요."
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
    }

    @objc func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "한Q",
            .applicationVersion: info["HanQReleaseVersion"] as? String ?? "",
            .version: info["CFBundleVersion"] as? String ?? ""
        ]
        if let logoURL = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            options[.applicationIcon] = logo
        }
        if let licenseURL = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            options[.credits] = NSAttributedString(string: "라이선스", attributes: [
                .link: licenseURL,
                .font: NSFont.systemFont(ofSize: 12),
                .paragraphStyle: style
            ])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWindow() {
        guard !permissionGranted else { return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        updatePermission()
        showWindow()
        updater.showRequiredUpdate()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        updater.stop()
        permissionTimer?.invalidate()
        safetyPulseTimer?.invalidate()
        hud.hide()
        stopMapping()
    }
}

// MARK: Executable entry
PermissionRelauncher.runIfRequested()
let app = NSApplication.shared
PermissionProbe.runIfRequested()
app.setActivationPolicy(.accessory)
guard let instanceLock = AppInstanceLock() else { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.run()
