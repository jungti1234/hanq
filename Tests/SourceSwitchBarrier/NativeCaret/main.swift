import AppKit
import Carbon

// This editor owns every text event. Only the switch filter and barrier intercept
// the generated hardware positions; Cocoa and the selected macOS IME render them.
final class EditorTrial: NSObject, NSApplicationDelegate {
    let view = NSTextView()
    let window = NSWindow(contentRect: NSRect(x: 180, y: 200, width: 430, height: 110),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let field = AXUIElementCreateApplication(getpid())
    let selector = SelectionPreservingSourceSwitch()
    let barrier = SourceSwitchBarrier()
    var filter = CommandFilter()
    let korean = KoreanKeyboardLayout.twoSetID
    let abc = "com.apple.keylayout.ABC"
    let previousApp = NSWorkspace.shared.frontmostApplication
    let original = InputSourceAccess.currentID()
    let ignoresAX = CommandLine.arguments.contains("--ignore-ax-write")
    let keySource = CGEventSource(stateID: .hidSystemState)
    var retained = 0
    var targets = [String]()
    var delivered = [Int64]()
    var receivedEdges = [Int]()
    var eventMonitor: Any?
    let expectedEdges = [15, -15, 40, -40, 1, -1, 7, -7, 15, -15, 40, -40, 1, -1]
    var cursorKeys = [CGKeyCode]()
    var rangeWrites = 0
    var firstEnd = false
    var finished = false
    var ownsField: Bool { NSApp.isActive && window.isKeyWindow && window.firstResponder === view }

    func applicationDidFinishLaunching(_ note: Notification) {
        view.isRichText = false
        window.title = "한Q 커서 복원 입력 시험"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let key = Int(event.keyCode)
            if self.ownsField, [15, 40, 1, 7].contains(key) {
                self.receivedEdges.append(event.type == .keyDown ? key : -key)
            }
            return event
        }
        configureSwitch()
        wait("own editor", until: { self.ownsField }) {
            guard InputSourceAccess.select(self.korean) == noErr else { self.finish(false, "enable two-set"); return }
            self.wait("two-set", until: { InputSourceAccess.currentID() == self.korean }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.typeSyllable(); self.firstSwitch() }
            }
        }
    }

    func configureSwitch() {
        barrier.incidentTrace = InputIncidentTrace(secureInput: { false }, destination: nil, initiallyEnabled: false)
        barrier.read = { self.ownsField ? .init(field: self.field, text: self.view.string, selection: self.view.selectedRange()) : nil }
        barrier.readFocus = { self.ownsField ? self.field : nil }
        barrier.send = { self.route($0) }
        barrier.retained = { self.retained += $0.count }
        barrier.select = { self.selector.select($0, asynchronous: true) }
        barrier.selectAfterTypedHangul = { target, snap in
            self.selector.select(target, asynchronous: true, typedCaret: .init(field: snap.field, text: snap.text, offset: snap.selection.location))
        }
        barrier.selectionPending = { self.selector.isPending }
        barrier.cancelSelection = { _ in self.selector.cancelPending() }
        barrier.initialLayout = { target in
            let source = InputSourceAccess.currentID()
            return SourceSwitchBarrier.classifyInitialLayout(first: source, layout: InputSourceAccess.currentLayoutID(),
                override: InputSourceAccess.currentOverrideID(), last: InputSourceAccess.currentID(), target: target)
        }
        selector.allowed = { self.ownsField && !IsSecureEventInputEnabled() }
        selector.focus = { self.ownsField ? self.field : nil }
        selector.editable = { _ in self.ownsField }
        selector.text = { _ in self.view.string }
        selector.range = { _ in
            let r = self.view.selectedRange()
            return CFRange(location: r.location, length: r.length)
        }
        selector.caretText = { _, _, _ in self.view.string }
        selector.setRange = { _, range in
            self.rangeWrites += 1
            if !self.ignoresAX { self.view.setSelectedRange(NSRange(location: range.location, length: range.length)) }
            return true
        }
        let nativePost = selector.postCommit
        selector.postCommit = { field, key in
            guard self.ownsField, CFEqual(field, self.field) else { return false }
            self.cursorKeys.append(key)
            return nativePost(field, key)
        }
        selector.selectSource = { target in
            guard self.ownsField else { return -50 }
            if target == self.abc { self.firstEnd = self.hasText("간") }
            self.targets.append(target)
            self.report("select \(target)")
            return InputSourceAccess.select(target)
        }
        selector.trace = { stage in self.report("selector \(stage.rawValue)") }
    }

    func hasText(_ value: String) -> Bool {
        view.string == value && view.selectedRange() == NSRange(location: value.utf16.count, length: 0)
    }
    func report(_ label: String) {
        let r = view.selectedRange()
        print("\(label): text=\(view.string.debugDescription) caret=\(r.location),\(r.length) marked=\(view.hasMarkedText()) source=\(InputSourceAccess.currentID())")
    }
    func route(_ event: CGEvent) {
        guard !finished, ownsField else { finish(false, "lost editor before delivery"); return }
        let type = event.type, code = event.getIntegerValueField(.keyboardEventKeycode)
        if barrier.receive(type, event) { return }
        let result = filter.process(type: type, key: code, flags: event.flags, acceptNewPress: true)
        if result.edge == "right-down" {
            let target = InputSourceAccess.currentID() == korean ? abc : korean
            if let (body, caret) = barrier.expected {
                print("right Command: expected=\(body.debugDescription) caret=\(caret) timestamp=\(event.timestamp)")
            }
            guard barrier.request(target, at: event.timestamp, rightCommand: true) else { finish(false, "switch request"); return }
        }
        if result.consume { return }
        barrier.observeBeforeOnset(type, event, waiting: false)
        guard type == .keyDown || type == .keyUp else { return }
        if type == .keyDown { delivered.append(code) }
        event.flags = result.flags
        event.postToPid(getpid())
    }
    func key(_ code: CGKeyCode) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down) else { finish(false, "allocate key"); return }
            // Quartz assigns a timestamp during delivery. The fixture routes these
            // positions through the product's callback before posting its output.
            event.timestamp = MismatchRecoveryEngine.sourceEventTime()
            event.flags = []
            if code == 54 {
                event.type = .flagsChanged
                event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10) : []
            }
            route(event)
        }
    }
    func typeSyllable() {
        for (index, code) in [CGKeyCode(15), 40, 1].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(index * 38)) { self.key(code) }
        }
    }
    func firstSwitch() {
        wait("initial 간", until: { self.hasText("간") }) {
            self.report("before first right Command")
            self.key(54)
            self.key(7)
            self.wait("간x after first switch", until: { !self.barrier.busy && self.hasText("간x") }) {
                self.report("after x")
                self.key(54)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.typeSyllable() }
                self.wait("final 간x간 and last release", until: { !self.barrier.busy && self.hasText("간x간") && self.receivedEdges.count >= self.expectedEdges.count }) {
                    let ok = self.firstEnd && self.cursorKeys.first == 123 && self.targets == [self.abc, self.korean] && self.retained == 0
                        && self.delivered == [15, 40, 1, 7, 15, 40, 1] && self.receivedEdges == self.expectedEdges
                        && InputSourceAccess.currentID() == self.korean
                    self.finish(ok, "both switches and seven letter key presses")
                }
            }
        }
    }
    func wait(_ label: String, until condition: @escaping () -> Bool, then next: @escaping () -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.8
        func poll() {
            guard !finished else { return }
            if condition() { next() }
            else if retained != 0 || ProcessInfo.processInfo.systemUptime >= deadline { finish(false, label) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: poll) }
        }
        poll()
    }
    func finish(_ ok: Bool, _ reason: String) {
        guard !finished else { return }
        finished = true
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        report("final")
        print("cursorKeys=\(cursorKeys) rangeWrites=\(rangeWrites) delivered=\(delivered) retained=\(retained) ignoreAX=\(ignoresAX)")
        print("AppKit letter edges=\(receivedEdges)")
        let restored = InputSourceAccess.currentID() == original || (NSApp.isActive && InputSourceAccess.select(original) == noErr && InputSourceAccess.currentID() == original)
        if NSApp.isActive { previousApp?.activate(options: []) }
        print("\(ok && restored ? "PASS" : "FAIL") \(reason), original source restored=\(restored)")
        fflush(stdout)
        exit(ok && restored ? 0 : 1)
    }
}

guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled() else { fputs("Keyboard event posting unavailable\n", stderr); exit(2) }
let app = NSApplication.shared
let trial = EditorTrial()
app.setActivationPolicy(.regular)
app.delegate = trial
app.run()
