import AppKit
import Carbon

final class TrialTextView: NSTextView {
    var didDraw: (() -> Void)?
    override func draw(_ rect: NSRect) {
        super.draw(rect)
        didDraw?()
    }
}

// This editor owns every text event. Only the switch filter and barrier intercept
// the generated hardware positions; Cocoa and the selected macOS IME render them.
final class EditorTrial: NSObject, NSApplicationDelegate {
    let view = TrialTextView()
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
    let overlap = CommandLine.arguments.contains("--overlap-round-trip")
    let observeLayout = CommandLine.arguments.contains("--observe-round-trip")
    let control = CommandLine.arguments.contains("--observe-only")
    let keyDelayMS = CommandLine.arguments.compactMap { argument -> Int? in
        guard argument.hasPrefix("--gap-ms=") else { return nil }
        return Int(argument.dropFirst("--gap-ms=".count)).flatMap { [0,12,40,120].contains($0) ? $0 : nil }
    }.first ?? 120
    var hops = [String]()
    var overlapEdges = 0
    var firstAfterReturn: String?
    var firstDraw: String?
    var firstRequestAt: Double?, firstReceivedAt: Double?, firstEditAt: Double?, firstDrawAt: Double?
    var commitAt: Double?, decisionMS: Double?, sampleKind = "unobserved"
    var returnRequestAt: Double?
    var editObserver: NSObjectProtocol?
    let keySource = CGEventSource(stateID: .hidSystemState)
    var retained = 0
    var targets = [String]()
    var delivered = [Int64]()
    var receivedEdges = [Int]()
    var submittedEdges = [Int]()
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
                let edge = event.type == .keyDown ? key : -key
                guard self.receivedEdges.count < self.submittedEdges.count,
                      self.submittedEdges[self.receivedEdges.count] == edge else {
                    self.finish(false, "unexpected letter edge in owned editor"); return nil
                }
                self.receivedEdges.append(edge)
                if key == 15, event.type == .keyDown, self.firstRequestAt != nil, self.firstReceivedAt == nil {
                    self.firstReceivedAt = ProcessInfo.processInfo.systemUptime
                }
            }
            return event
        }
        editObserver = NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,
            object:view.textStorage, queue:nil) { [weak self] _ in
            guard let self else { return }
            guard self.knownTrialText else { self.finish(false, "unexpected text in owned editor"); return }
            guard self.firstAfterReturn == nil, let glyph = self.testSuffix() else { return }
            self.firstAfterReturn = glyph
            self.firstEditAt = ProcessInfo.processInfo.systemUptime
        }
        view.didDraw = { [weak self] in
            guard let self, self.firstDraw == nil, let glyph = self.testSuffix() else { return }
            self.firstDraw = glyph
            self.firstDrawAt = ProcessInfo.processInfo.systemUptime
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
        if overlap || observeLayout || control {
            barrier.observeSwitchCommit = { target, _, inspect in
                guard inspect else { return nil }
                let start = ProcessInfo.processInfo.systemUptime
                self.commitAt = start
                let actual = self.barrier.initialLayout?(target)
                self.decisionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.sampleKind = actual.map { String(describing: $0) } ?? "unobserved"
                return self.control ? nil : (self.overlap ? .conflicting : actual)
            }
        }
        barrier.selectRoundTripSource = { target in
            guard self.ownsField, !IsSecureEventInputEnabled() else { return -50 }
            let status = InputSourceAccess.select(target)
            if status == noErr && InputSourceAccess.currentID() == target { self.hops.append(target) }
            if target == self.abc && self.overlap && status == noErr {
                let count = self.delivered.count
                let queuedBefore = self.barrier.diagnosticCounts.queued
                for code: CGKeyCode in [15, 40, 1] { self.key(code) }
                self.overlapEdges = self.barrier.diagnosticCounts.queued - queuedBefore
                if self.delivered.count != count { self.finish(false, "letter released under ABC") }
            }
            return status
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
    var knownTrialText: Bool {
        ["", "ㄱ", "가", "간", "간x", "간xㄱ", "간x가", "간x간",
         "r", "rk", "rks", "간xr", "간xrk", "간xrks"].contains(view.string)
    }
    func testSuffix() -> String? {
        guard firstRequestAt != nil, view.string.hasPrefix("간x"), view.string.count > 2 else { return nil }
        let suffix = String(view.string.dropFirst(2))
        if suffix.hasPrefix("r") { return "r" }
        return ["ㄱ", "r", "가", "간"].contains(suffix) ? suffix : "other"
    }
    func report(_ label: String) {
        let r = view.selectedRange()
        let text = knownTrialText ? view.string.debugDescription : "<unexpected>"
        print("\(label): text=\(text) caret=\(r.location),\(r.length) marked=\(view.hasMarkedText()) source=\(InputSourceAccess.currentID())")
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
        if [15,40,1,7].contains(code) { submittedEdges.append(type == .keyDown ? Int(code) : -Int(code)) }
        event.postToPid(getpid())
    }
    func key(_ code: CGKeyCode) {
        if code == 15, firstRequestAt == nil, view.string == "간x" {
            firstRequestAt = ProcessInfo.processInfo.systemUptime
        }
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
                self.returnRequestAt = ProcessInfo.processInfo.systemUptime
                self.key(54)
                if !self.overlap { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.keyDelayMS)) { self.typeSyllable() } }
                self.wait("final 간x간 and last release", until: { !self.barrier.busy && self.hasText("간x간") && self.receivedEdges.count >= self.expectedEdges.count && self.firstDraw != nil }) {
                    let ok = self.firstEnd && self.cursorKeys.first == 123 && self.targets == [self.abc, self.korean] && self.retained == 0
                        && self.delivered == [15, 40, 1, 7, 15, 40, 1] && self.receivedEdges == self.expectedEdges
                        && InputSourceAccess.currentID() == self.korean
                    let overlappingOK = !self.overlap || (self.hops == [self.abc,self.korean] &&
                        self.overlapEdges == 6 && self.firstAfterReturn == "ㄱ")
                    let known = ["ㄱ","가","간"]
                    self.finish(ok && overlappingOK && known.contains(self.firstAfterReturn ?? "") && known.contains(self.firstDraw ?? ""),
                                "both switches and seven letter key presses")
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
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        print("round-trip source confirmations=\(hops) overlappingEdges=\(overlapEdges) firstAfterReturn=\(firstAfterReturn ?? "unobserved")")
        report("final")
        print("cursorKeys=\(cursorKeys) rangeWrites=\(rangeWrites) delivered=\(delivered) retained=\(retained) ignoreAX=\(ignoresAX)")
        print("AppKit letter edges=\(receivedEdges)")
        func ms(_ a: Double?, _ b: Double?) -> String {
            guard let a, let b else { return "missing" }
            return String(format:"%.3f", (b - a) * 1000)
        }
        print("firstKeyGapMS=\(keyDelayMS) switchToRequestMS=\(ms(returnRequestAt, firstRequestAt)) switchToReceiveMS=\(ms(returnRequestAt, firstReceivedAt))")
        print("sample=\(sampleKind) sampleMS=\(decisionMS.map { String(format:"%.3f", $0) } ?? "missing") commitToRequestMS=\(ms(commitAt, firstRequestAt)) requestToReceiveMS=\(ms(firstRequestAt, firstReceivedAt)) requestToEditMS=\(ms(firstRequestAt, firstEditAt)) requestToDrawMS=\(ms(firstRequestAt, firstDrawAt)) firstDraw=\(firstDraw ?? "unobserved")")
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
