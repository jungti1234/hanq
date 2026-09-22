import AppKit
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        defaults.removePersistentDomain(forName: suite)
        exit(1)
    }
    checks += 1
}
let suite = "taek.in.hanq.external-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
if CommandLine.arguments.contains("--failure-check") { check(false, "intentional failure must exit 1 without SIGTRAP") }
let profiles = ExternalKeyboardProfiles(defaults: defaults)
let korean = KeyboardBinding(keyCode: 61)
let hanja = KeyboardBinding(keyCode: 62)
let profile = ExternalKeyboardProfile(korean: korean, hanja: hanja)
check(profile.valid, "Alt/Control configuration")
check(!ExternalKeyboardProfile(korean: korean, hanja: korean).valid, "duplicate key rejected")
check(!KeyboardBinding(keyCode: 57).supported, "Caps Lock excluded")
let first = ExternalKeyboardIdentity.key(vendor: 1, product: 2, transport: "USB", serial: "private-serial", location: 1, name: "Keyboard")
let replug = ExternalKeyboardIdentity.key(vendor: 1, product: 2, transport: "USB", serial: "private-serial", location: 9, name: "Keyboard")
check(first == replug && !first.contains("private-serial"), "serial identity is stable and hashed")
let port1 = ExternalKeyboardIdentity.key(vendor: 1, product: 2, transport: "USB", serial: nil, location: 1, name: "Keyboard")
let port2 = ExternalKeyboardIdentity.key(vendor: 1, product: 2, transport: "USB", serial: nil, location: 2, name: "Keyboard")
check(port1 != port2, "identical models without serial separated by port")
let anonymous1 = ExternalKeyboardIdentity.key(vendor: 1, product: 2, transport: "USB", serial: nil, location: 0, name: "Keyboard", registryID: 100)
let anonymous2 = ExternalKeyboardIdentity.key(vendor: 1, product: 2, transport: "USB", serial: nil, location: 0, name: "Keyboard", registryID: 200)
check(anonymous1 != anonymous2, "unidentifiable devices never reuse another connection's profile")
profiles.save(profile, for: first)
check(ExternalKeyboardProfiles(defaults: defaults)[first] == profile, "saved profile survives new store")
profiles.save(ExternalKeyboardProfile(korean: korean, hanja: korean), for: first)
check(profiles[first] == profile, "invalid update preserves prior settings")
defaults.set(Data("corrupt".utf8), forKey: "externalKeyboardProfiles.v1")
check(ExternalKeyboardProfiles(defaults: defaults)[first] == nil, "corrupt preferences fail closed")
let oldLeftProfile = ExternalKeyboardProfile(korean: KeyboardBinding(keyCode: 58), hanja: hanja)
defaults.set(try! JSONEncoder().encode([first: oldLeftProfile]), forKey: "externalKeyboardProfiles.v1")
check(ExternalKeyboardProfiles(defaults: defaults)[first] == nil, "legacy left-side mapping is not restored")
profiles.save(oldLeftProfile, for: first)
check(profiles[first] == profile, "left-side mapping cannot overwrite a valid profile")
for code: Int64 in [55, 58, 59, 56, 0, 49, 123, 124, 125, 126, 57, 63, 105, 107, 113, 106, 64, 79, 80, 90] {
    let binding = KeyboardBinding(keyCode: code)
    var rejected = ExternalKeyboardCapture()
    let flags = binding.modifier.map { CGEventFlags(rawValue: $0.mask | $0.aggregate.rawValue) } ?? []
    let message = rejected.receive(type: binding.modifier == nil ? .keyDown : .flagsChanged,
        key: code, flags: flags, repeated: false)
    check(message != nil && rejected.pressed == nil && rejected.korean == nil, "unintended key rejected without capture: \(code)")
}
let altFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
let ctrlFlags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
var capture = ExternalKeyboardCapture()
check(capture.receive(type: .keyDown, key: 0, flags: [], repeated: false) != nil, "typing key rejected")
_ = capture.receive(type: .flagsChanged, key: 61, flags: altFlags, repeated: false)
check(capture.korean == nil && capture.pressed == korean, "capture waits for release")
_ = capture.receive(type: .flagsChanged, key: 61, flags: [], repeated: false)
check(capture.korean == korean && capture.profile == nil, "first key alone never saved")
check(capture.receive(type: .flagsChanged, key: 61, flags: altFlags, repeated: false) != nil, "second key must differ")
_ = capture.receive(type: .flagsChanged, key: 62, flags: ctrlFlags, repeated: false)
_ = capture.receive(type: .flagsChanged, key: 62, flags: [], repeated: false)
check(capture.profile == profile, "two released keys complete capture")
var chord = ExternalKeyboardCapture()
check(chord.receive(type: .flagsChanged, key: 62, flags: ctrlFlags.union(.maskShift), repeated: false) != nil, "capture rejects chord")
var state = ExternalKeyboardKeyState()
check(state.process(binding: hanja, type: .flagsChanged, key: 62, flags: [], repeated: false, accept: true).edge == nil, "orphan up cannot trigger")
check(state.process(binding: hanja, type: .flagsChanged, key: 62, flags: ctrlFlags, repeated: false, accept: true).edge == .down, "modifier down accepted")
check(state.process(binding: hanja, type: .flagsChanged, key: 62, flags: [], repeated: false, accept: false).consume, "release consumed after disable")
let lang = KeyboardBinding(keyCode: 102)
check(state.process(binding: lang, type: .keyDown, key: 102, flags: [], repeated: false, accept: true).edge == .down, "dedicated language key down")
check(state.process(binding: lang, type: .keyDown, key: 102, flags: [], repeated: true, accept: true).edge == nil, "repeat cannot retrigger")
check(state.process(binding: lang, type: .keyUp, key: 102, flags: [], repeated: false, accept: true).edge == .up, "dedicated language key release")

_ = NSApplication.shared
let ext = ExternalKeyboardDevice(registryID: 100, identity: first, name: "External Test Keyboard", external: true)
let internalDevice = ExternalKeyboardDevice(registryID: 200, identity: "internal", name: "Built-in", external: false)
let devices = ExternalKeyboardDevices(snapshot: [100: ext, 200: internalDevice])
let controller = ExternalKeyboardController(profiles: profiles, devices: devices)
func event(_ id: Int64, _ key: Int64, _ flags: CGEventFlags = [], repeated: Bool = false) -> CGEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
    e.setIntegerValueField(CGEventField(rawValue: 87)!, value: id)
    e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    e.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
    e.flags = flags
    return e
}
func route(_ type: CGEventType, _ e: CGEvent, active: Bool = true, ko: Bool = true, hj: Bool = true) -> ExternalKeyboardController.Result {
    controller.process(type: type, event: e, active: active, koreanAllowed: ko, hanjaAllowed: hj)
}
check(devices.device(for: event(100, 61)) == ext, "sender resolves only exact registry ID")
check(devices.device(for: event(999, 61)) == nil, "unknown sender never guesses")
check(!route(.flagsChanged, event(200, 61, altFlags)).handled, "built-in retains original mapping")
let down = route(.flagsChanged, event(100, 61, altFlags))
check(down.korean && down.consume && !down.hanja, "external Alt triggers Korean on down")
check(!route(.flagsChanged, event(100, 61, altFlags)).korean, "duplicate modifier down ignored")
check(route(.flagsChanged, event(100, 61)).consume, "external Alt release consumed")
check(!route(.flagsChanged, event(100, 62, ctrlFlags)).hanja, "Hanja waits for release")
let clean = route(.keyDown, event(100, 0, ctrlFlags))
check(!clean.flags.contains(.maskControl), "consumed modifier stripped from following input")
check(route(.flagsChanged, event(100, 62)).hanja, "external Control triggers Hanja on release")
check(!route(.flagsChanged, event(100, 62)).hanja, "orphan release cannot trigger Hanja")
_ = route(.flagsChanged, event(100, 62, ctrlFlags))
check(!route(.flagsChanged, event(100, 62), active: false).hanja, "secure/inactive release cannot request edit")
check(!route(.flagsChanged, event(100, 61, altFlags), ko: false).consume, "disabled feature preserves original key")
_ = route(.flagsChanged, event(100, 61))
_ = route(.flagsChanged, event(100, 62, ctrlFlags.union(.maskCommand)))
check(!route(.flagsChanged, event(100, 62)).hanja, "Hanja rejects modified chord")
check(route(.flagsChanged, event(999, 61, altFlags)).handled, "missing sender does not apply default mapping in configured setup")
let injected = event(100, 61)
injected.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
check(devices.device(for: injected) == nil, "software event is not treated as physical device")

// A second keyboard holding the same side modifier must retain it.
_ = route(.flagsChanged, event(100, 62, ctrlFlags))
_ = route(.flagsChanged, event(200, 62, ctrlFlags))
check(route(.keyDown, event(200, 0, ctrlFlags)).flags.contains(.maskControl), "other keyboard same-side modifier preserved")
check(!route(.flagsChanged, event(100, 62, ctrlFlags)).hanja, "ambiguous same-side flags cannot fabricate a release")
check(route(.keyDown, event(200, 0, ctrlFlags)).flags.contains(.maskControl), "remaining physical modifier survives ambiguous release")
check(!route(.flagsChanged, event(200, 62)).hanja && !controller.consuming, "global modifier release clears stale state without firing another keyboard action")
_ = route(.flagsChanged, event(100, 61, altFlags))
devices.applySnapshot([200: internalDevice])
check(!controller.consuming, "disconnect clears held external state")
let duplicate = ExternalKeyboardDevice(registryID: 300, identity: first, name: ext.name, external: true)
devices.applySnapshot([100: ext, 300: duplicate, 200: internalDevice])
check(!devices.isUnique(ext), "ambiguous same identities rejected")
check(!route(.flagsChanged, event(100, 61, altFlags)).korean, "ambiguous device profile not applied")
let fresh = ExternalKeyboardDevice(registryID: 400, identity: "new-device", name: "New External Keyboard", external: true)
devices.applySnapshot([100: ext, 200: internalDevice, 400: fresh])
check(controller.nextUnconfiguredDevice == fresh, "only an unconfigured external device is prompted")
profiles.save(profile, for: fresh.identity)
check(controller.nextUnconfiguredDevice == nil, "completed profiles never prompt again")
let reconnected = ExternalKeyboardDevice(registryID: 500, identity: first, name: ext.name, external: true)
devices.applySnapshot([500: reconnected])
check(controller.nextUnconfiguredDevice == nil, "reconnect with new registry ID retains completed setup")
controller.stop()
check(!controller.consuming && !controller.isCapturing, "teardown clears input and capture")
print("PASS: \(checks) external keyboard identity, persistence, capture and routing checks")

if CommandLine.arguments.contains("--inventory") {
    let monitor = ExternalKeyboardDevices()
    monitor.start()
    print("Live inventory: \(monitor.devices.count) keyboard services, \(monitor.devices.values.filter(\.external).count) external")
    monitor.stop()
}

if CommandLine.arguments.contains("--ui") {
    NSApp.setActivationPolicy(.regular)
    NSApp.finishLaunching()
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
    }
    devices.applySnapshot([100: ext, 200: internalDevice])
    controller.canConfigure = { true }
    controller.updateMenu()
    controller.menuItem.submenu!.performActionForItem(at: 0)
    pump(0.5)
    guard let window = NSApp.windows.first(where: { $0.title == "한Q - 외부 키보드 설정" && $0.isVisible }) else {
        FileHandle.standardError.write(Data("FAIL: setup panel must open from menu\n".utf8))
        defaults.removePersistentDomain(forName: suite)
        exit(1)
    }
    window.makeKey()
    check(window.isKeyWindow, "capture panel has keyboard focus")
    func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let content = window.contentView!
    content.layoutSubtreeIfNeeded()
    if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/hanq/external-keyboard-setup.png"))
    }
    if CommandLine.arguments.contains("--preview") {
        print("PREVIEW: setup window ready")
        fflush(stdout)
        pump(45)
    }
    let save = buttons(content).first(where: { $0.title == "저장" })!
    check(!save.isEnabled, "save starts disabled")
    _ = route(.flagsChanged, event(200, 62, ctrlFlags))
    check(!save.isEnabled, "another keyboard cannot register")
    // Reconfigure: first Control for Korean, then Alt for Hanja.
    _ = route(.flagsChanged, event(100, 62, ctrlFlags))
    _ = route(.flagsChanged, event(100, 62))
    buttons(content).first(where: { $0.title == "나중에" })!.performClick(nil)
    pump(0.2)
    let blocked = route(.flagsChanged, event(100, 61, altFlags))
    _ = route(.flagsChanged, event(100, 61))
    pump(0.1)
    check(blocked.handled && !blocked.korean && !blocked.hanja && !save.isEnabled, "confirmation prevents capture and HanQ actions")
    buttons(window.attachedSheet!.contentView!).first(where: { $0.title == "설정 계속하기" })!.performClick(nil)
    pump(0.3)
    let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
        styleMask: [.titled], backing: .buffered, defer: false)
    otherWindow.makeKeyAndOrderFront(nil)
    pump(0.1)
    check(!window.isKeyWindow && window.isVisible && controller.isCapturing, "outside focus keeps setup visible and preserves progress")
    check((window as? NSPanel)?.hidesOnDeactivate == false && !window.styleMask.contains(.closable), "setup neither hides on app deactivation nor offers implicit close")
    _ = route(.flagsChanged, event(100, 61, altFlags))
    _ = route(.flagsChanged, event(100, 61))
    pump(0.1)
    check(!save.isEnabled, "background input cannot register second key")
    window.makeKeyAndOrderFront(nil)
    otherWindow.orderOut(nil)
    _ = route(.flagsChanged, event(100, 61, altFlags))
    _ = route(.flagsChanged, event(100, 61))
    pump(0.1)
    check(save.isEnabled, "two captured releases enable save")
    save.performClick(nil)
    check(!controller.isCapturing && profiles[first] == ExternalKeyboardProfile(korean: hanja, hanja: korean), "save applies complete profile and closes panel")
    controller.updateMenu()
    controller.menuItem.submenu!.performActionForItem(at: 0)
    NSApp.windows.first(where: { $0.title == "한Q - 외부 키보드 설정" && $0.isVisible })!.makeKey()
    _ = route(.flagsChanged, event(100, 62, ctrlFlags))
    let setup = NSApp.windows.first(where: { $0.title == "한Q - 외부 키보드 설정" && $0.isVisible })!
    buttons(setup.contentView!).first(where: { $0.title == "나중에" })!.performClick(nil)
    pump(0.2)
    check(setup.attachedSheet != nil && controller.isCapturing, "Later requests confirmation before closing")
    buttons(setup.attachedSheet!.contentView!).first(where: { $0.title == "설정 계속하기" })!.performClick(nil)
    pump(0.3)
    check(setup.isVisible && setup.attachedSheet == nil && controller.isCapturing, "Continue returns to setup")
    buttons(setup.contentView!).first(where: { $0.title == "나중에" })!.performClick(nil)
    pump(0.2)
    buttons(setup.attachedSheet!.contentView!).first(where: { $0.title == "나중에 설정하기" })!.performClick(nil)
    pump(0.3)
    check(!setup.isVisible && !controller.isCapturing, "confirmed Later explicitly dismisses setup")
    check(controller.consuming, "closing capture owns already swallowed press")
    let release = route(.flagsChanged, event(100, 62))
    check(release.consume && !release.hanja && !release.korean && !controller.consuming, "release after closing capture is swallowed without action")
    controller.updateMenu()
    controller.menuItem.submenu!.performActionForItem(at: 0)
    check(controller.isCapturing, "manual reconfiguration remains available")
    let finalSetup = NSApp.windows.first(where: { $0.title == "한Q - 외부 키보드 설정" && $0.isVisible })!
    buttons(finalSetup.contentView!).first(where: { $0.title == "나중에" })!.performClick(nil)
    pump(0.2)
    devices.applySnapshot([200: internalDevice])
    pump(0.3)
    check(!controller.isCapturing && finalSetup.attachedSheet == nil, "disconnect closes setup and pending confirmation")
    controller.stop()
    print("PASS: native setup panel, two-stage capture, Save, cancel and disconnect (\(checks) total checks)")
}
