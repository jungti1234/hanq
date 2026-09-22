import AppKit
import Carbon

private final class KeyboardSetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ExternalKeyboardController: NSObject, NSWindowDelegate {
    let devices: ExternalKeyboardDevices
    let profiles: ExternalKeyboardProfiles
    let menuItem = NSMenuItem(title: "외부 키보드 설정", action: nil, keyEquivalent: "")
    let menuSeparator = NSMenuItem.separator()
    var canConfigure: () -> Bool = { false }
    var onBeginCapture: () -> Void = {}
    private var deferred = Set<String>()
    private var panel: NSPanel?
    private var selected: ExternalKeyboardDevice?
    private var capture = ExternalKeyboardCapture()
    private var setupView: ExternalKeyboardSetupView?
    private struct Presses {
        var korean = ExternalKeyboardKeyState()
        var hanja = ExternalKeyboardKeyState()
    }
    private var presses: [UInt64: Presses] = [:]
    private var physicalModifiers: [UInt64: UInt64] = [:]
    private var running = false
    // Capture owns matching releases even if the window closes or loses focus.
    private var capturedKeys: [UInt64: [Int64: KeyboardBinding]] = [:]
    var isCapturing: Bool { selected != nil }
    var consuming: Bool { !capturedKeys.isEmpty || presses.values.contains { $0.korean.consuming || $0.hanja.consuming } }

    init(profiles: ExternalKeyboardProfiles = ExternalKeyboardProfiles(), devices: ExternalKeyboardDevices = ExternalKeyboardDevices()) {
        self.devices = devices
        self.profiles = profiles
        super.init()
        devices.onChange = { [weak self] in self?.devicesChanged() }
        updateMenu()
    }
    func start() {
        running = true
        devices.start()
    }
    func stop() {
        running = false
        cancelCapture()
        presses.removeAll(); physicalModifiers.removeAll(); capturedKeys.removeAll()
        devices.stop()
        updateMenu()
    }
    /// Called by the existing permission timer; no additional periodic HID polling.
    func tick() {
        guard running else { return }
        if selected != nil && (!canConfigure() || IsSecureEventInputEnabled()) { cancelCapture() }
        guard selected == nil, canConfigure(), !consuming, !IsSecureEventInputEnabled(), NSApp.modalWindow == nil else { return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty else { return }
        guard let device = nextUnconfiguredDevice else { return }
        show(device)
    }
    var nextUnconfiguredDevice: ExternalKeyboardDevice? {
        devices.devices.values.sorted(by: { $0.registryID < $1.registryID }).first {
            $0.external && devices.isUnique($0) && profiles[$0.identity] == nil && !deferred.contains($0.identity)
        }
    }
    private func devicesChanged() {
        presses = presses.filter { devices.devices[$0.key] != nil }
        capturedKeys = capturedKeys.filter { devices.devices[$0.key] != nil }
        physicalModifiers = physicalModifiers.filter { devices.devices[$0.key] != nil }
        if let selected, devices.devices[selected.registryID] != selected || !devices.isUnique(selected) { cancelCapture() }
        updateMenu()
        // UI is deferred to tick(), outside registry callbacks and input callbacks.
    }
    func updateMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in devices.devices.values.filter({ $0.external }).sorted(by: { $0.name < $1.name }) {
            let suffix = profiles[device.identity] == nil ? "설정하기…" : "다시 설정…"
            let item = NSMenuItem(title: "\(device.name) · \(suffix)", action: #selector(configure(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = NSNumber(value: device.registryID)
            item.isEnabled = devices.isUnique(device) && canConfigure() && !consuming
            if !devices.isUnique(device) { item.title = "\(device.name) · 같은 기기를 구분할 수 없음" }
            menu.addItem(item)
        }
        let hidden = menu.items.isEmpty
        menuItem.isHidden = hidden
        menuSeparator.isHidden = hidden
        menuItem.submenu = menu
    }
    @objc private func configure(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSNumber, let device = devices.devices[id.uint64Value],
              devices.isUnique(device), canConfigure(), !consuming, !IsSecureEventInputEnabled() else { return }
        if selected == device, let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        cancelCapture()
        show(device)
    }
    private func show(_ device: ExternalKeyboardDevice) {
        // Do not capture the release of a key pressed before the window opened.
        guard !(0...127).contains(where: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }) else { return }
        selected = device
        capture = ExternalKeyboardCapture()
        deferred.insert(device.identity)
        onBeginCapture()
        let panel = KeyboardSetupPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 410),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "한Q - 외부 키보드 설정"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let view = ExternalKeyboardSetupView(deviceName: device.name, target: self,
            later: #selector(deferSetup), restart: #selector(restartCapture), save: #selector(save))
        setupView = view
        panel.contentView = view
        self.panel = panel
        refreshCapture()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func refreshCapture(message: String? = nil) {
        guard let view = setupView else { return }
        let completed = capture.profile != nil
        view.step.stringValue = completed ? "설정할 키를 확인하고 저장해주세요." :
            capture.pressed != nil ? "누른 키를 놓아주세요." :
            capture.korean == nil ? "한영키로 사용할 키를 눌러주세요." : "한자키로 사용할 키를 눌러주세요."
        view.progress.stringValue = completed ? "완료" : capture.korean == nil ? "1 / 2" : "2 / 2"
        view.korean.update(index: 1, key: capture.korean, active: capture.korean == nil,
            waitingForRelease: capture.pressed != nil)
        view.hanja.update(index: 2, key: capture.hanja, active: capture.korean != nil && !completed,
            waitingForRelease: capture.pressed != nil)
        view.hint.stringValue = message ?? "사용할 키를 하나씩 누르고 놓아주세요.\n저장한 키는 한Q가 켜져 있을 때 전용 키로 사용돼요."
        view.saveButton.isEnabled = completed
    }

    @objc private func restartCapture() {
        guard capture.pressed == nil, capturedKeys.isEmpty else { return }
        capture = ExternalKeyboardCapture(); refreshCapture()
    }
    @objc private func deferSetup() {
        guard let panel, panel.attachedSheet == nil else { return }
        capture.cancelPendingPress()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "키 설정을 나중에 할까요?"
        alert.informativeText = "외부 키보드의 키 설정을 완료하지 않으면 한영키·한자키가 올바르게 작동하지 않을 수 있어요. 나중에 메뉴의 ‘외부 키보드 설정’에서 다시 설정할 수 있어요."
        alert.addButton(withTitle: "설정 계속하기")
        alert.addButton(withTitle: "나중에 설정하기")
        alert.beginSheetModal(for: panel) { [weak self, weak panel] response in
            guard let self, let panel, self.panel === panel else { return }
            if response == .alertSecondButtonReturn {
                self.cancelCapture()
            } else {
                panel.makeKeyAndOrderFront(nil)
                self.refreshCapture()
            }
        }
    }
    @objc private func save() {
        guard let selected, devices.devices[selected.registryID] == selected,
              devices.isUnique(selected), canConfigure(), !IsSecureEventInputEnabled(),
              capturedKeys.isEmpty, let profile = capture.profile else { return }
        profiles.save(profile, for: selected.identity)
        presses.removeValue(forKey: selected.registryID)
        cancelCapture()
        updateMenu()
    }
    func windowDidResignKey(_ notification: Notification) {
        // Keep completed steps, but never complete a press released in another app.
        capture.cancelPendingPress()
        refreshCapture(message: "이 창을 다시 클릭하면 키 설정을 이어갈 수 있어요.")
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshCapture() }
    func windowWillClose(_ notification: Notification) { cancelCapture() }
    func cancelCapture() {
        selected = nil; capture = ExternalKeyboardCapture()
        let oldPanel = panel
        panel = nil
        setupView = nil
        oldPanel?.delegate = nil
        if let sheet = oldPanel?.attachedSheet {
            oldPanel?.endSheet(sheet, returnCode: .abort)
            sheet.orderOut(nil)
        }
        oldPanel?.orderOut(nil)
    }

    struct Result {
        var handled = false
        var consume = false
        var flags: CGEventFlags
        var korean = false
        var hanja = false
    }
    func wantsInputSource(type: CGEventType, event: CGEvent) -> Bool {
        guard panel?.isKeyWindow != true, panel?.attachedSheet == nil, let device = devices.device(for: event), device.external,
              let profile = profiles[device.identity] else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        return profile.korean.matches(type: type, key: key) || profile.hanja.matches(type: type, key: key)
    }

    /// No persistence, registry enumeration, or window creation in the event tap.
    func process(type: CGEventType, event: CGEvent, active: Bool,
                 koreanAllowed: Bool, hanjaAllowed: Bool) -> Result {
        var result = Result(flags: event.flags)
        let keyboardEvent = type == .keyDown || type == .keyUp || type == .flagsChanged
        let device = keyboardEvent ? devices.device(for: event) : nil
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let binding = KeyboardBinding(keyCode: key)
        if let device, type == .flagsChanged, let modifier = binding.modifier {
            var flags = physicalModifiers[device.registryID] ?? 0
            if event.flags.rawValue & modifier.mask != 0 { flags |= modifier.mask } else { flags &= ~modifier.mask }
            physicalModifiers[device.registryID] = flags
        }
        var capturedRelease = false
        if let device, let held = capturedKeys[device.registryID]?[key], held.matches(type: type, key: key) {
            capturedRelease = true
            if !held.isDown(type: type, flags: event.flags) {
                capturedKeys[device.registryID]?.removeValue(forKey: key)
                if capturedKeys[device.registryID]?.isEmpty == true { capturedKeys.removeValue(forKey: device.registryID) }
            }
        }
        for keys in capturedKeys.values {
            for binding in keys.values { result.flags = binding.removingModifier(from: result.flags) }
        }
        if let selected, panel?.isKeyWindow == true || panel?.attachedSheet != nil {
            // Suppress HanQ actions only while setup has focus. Only the
            // selected device can be captured, and only while our window has focus.
            result.handled = true
            result.consume = capturedRelease
            guard active, !IsSecureEventInputEnabled(), panel?.attachedSheet == nil, panel?.isKeyWindow == true, keyboardEvent else { return result }
            guard device == selected else {
                if device == nil {
                    DispatchQueue.main.async { [weak self] in
                        guard self?.selected != nil else { return }
                        self?.refreshCapture(message: "이 입력이 어느 키보드에서 왔는지 확인하지 못했어요. ‘나중에’를 누르면 기본 키로 사용할 수 있어요.")
                    }
                }
                return result
            }
            if binding.matches(type: type, key: key), binding.isDown(type: type, flags: event.flags) {
                capturedKeys[selected.registryID, default: [:]][key] = binding
            }
            let message = capture.receive(type: type, key: key, flags: event.flags,
                repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            result.consume = true
            DispatchQueue.main.async { [weak self] in if self?.selected != nil { self?.refreshCapture(message: message) } }
            return result
        }
        if capturedRelease { result.handled = true; result.consume = true; return result }
        if let device, device.external, devices.isUnique(device), let profile = profiles[device.identity] {
            result.handled = true
            var state = presses[device.registryID] ?? Presses()
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let korean = state.korean.process(binding: profile.korean, type: type, key: key,
                flags: event.flags, repeated: repeated, accept: active && koreanAllowed)
            let otherFlags = profile.hanja.removingModifier(from: event.flags)
            let hanja = state.hanja.process(binding: profile.hanja, type: type, key: key,
                flags: event.flags, repeated: repeated,
                accept: active && hanjaAllowed && otherFlags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty)
            presses[device.registryID] = state
            result.consume = korean.consume || hanja.consume
            result.korean = active && koreanAllowed && korean.edge == .down
            result.hanja = active && hanjaAllowed && hanja.edge == .up
            for (binding, consumed) in [(profile.korean, korean.consume), (profile.hanja, hanja.consume)] where consumed {
                let alsoHeld = binding.modifier.map { modifier in
                    physicalModifiers.contains { $0.key != device.registryID && $0.value & modifier.mask != 0 }
                } ?? false
                if !alsoHeld { result.flags = binding.removingModifier(from: result.flags) }
            }
        } else if keyboardEvent, device == nil, devices.devices.values.contains(where: { $0.external && profiles[$0.identity] != nil }) {
            // If the private sender field disappears, fail open instead of applying
            // another keyboard's profile or silently triggering the default keys.
            result.handled = true
        }
        // Global flags cannot always identify which same-side key was released
        // when two keyboards hold it. Once that bit is globally up, clear any
        // stale state without attributing the other keyboard's release to an action.
        for id in Array(physicalModifiers.keys) { physicalModifiers[id]! &= event.flags.rawValue }
        for id in Array(presses.keys) {
            guard let device = devices.devices[id], let profile = profiles[device.identity] else { continue }
            if let modifier = profile.korean.modifier, event.flags.rawValue & modifier.mask == 0 {
                presses[id]?.korean = ExternalKeyboardKeyState()
            }
            if let modifier = profile.hanja.modifier, event.flags.rawValue & modifier.mask == 0 {
                presses[id]?.hanja = ExternalKeyboardKeyState()
            }
        }
        // Modifier flags accompany events from other keyboards and the mouse too.
        for (id, state) in presses {
            guard let source = devices.devices[id], let profile = profiles[source.identity] else { continue }
            for (binding, held) in [(profile.korean, state.korean.consuming), (profile.hanja, state.hanja.consuming)] where held {
                guard let modifier = binding.modifier else { continue }
                let alsoHeld = physicalModifiers.contains { $0.key != id && $0.value & modifier.mask != 0 }
                if !alsoHeld { result.flags = binding.removingModifier(from: result.flags) }
            }
        }
        return result
    }
}
