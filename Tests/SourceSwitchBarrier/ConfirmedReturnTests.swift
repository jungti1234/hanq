import AppKit
import Carbon

private func returnCheck(_ ok: @autoclosure () -> Bool, line: Int = #line) {
    guard ok() else { print("FAIL return regression line \(line)"); exit(1) }
}

// Separate the TIS selection, the reported layout and the editor's effective IME.
private final class ReturnEditor {
    let barrier = SourceSwitchBarrier()
    let engine = MismatchRecoveryEngine()
    let evidence = MismatchSourceEvidence()
    let field = AXUIElementCreateApplication(89001)
    var window = AXUIElementCreateApplication(89002)
    let english = "com.apple.keylayout.ABC"
    let korean = KoreanKeyboardLayout.twoSetID
    var selected = KoreanKeyboardLayout.twoSetID
    var latin = false
    var conflict = false
    var prefix: String
    var highlighted = ""
    var composition = ""
    var right: String
    var composingKeys: [(UInt16, Bool)] = []
    var writes: [NSRange] = []
    var confirmedRanges: [NSRange] = []
    var stages: [String] = []
    var retained = 0
    var time = ProcessInfo.processInfo.systemUptime - 10
    var body: String { prefix + highlighted + composition + right }
    var range: NSRange { NSRange(location: (prefix + composition).utf16.count, length: highlighted.utf16.count) }
    var stamp: UInt64 { UInt64(time * 1_000_000_000) }

    init(left: String, right: String) {
        prefix = left
        self.right = right
        let b = barrier, e = engine
        e.incidentTrace = InputIncidentTrace(secureInput: {false}, destination: nil, initiallyEnabled: false)
        b.incidentTrace = e.incidentTrace
        evidence.now = { [unowned self] in time }
        e.sourceEvidence = evidence
        b.sourceEvidence = evidence
        evidence.observe(korean)
        b.didConfirmSource = { [weak evidence] id, stamp in evidence?.didCommit(id, at: stamp) }
        e.locked = field
        e.enabled = true
        e.lastSource = korean
        e.testSource = { [unowned self] in selected }
        e.testSnapshot = { [unowned self] in snapshot() }
        e.testFastContext = { true }
        e.testSelectionWritable = { _ in true }
        e.testSelectSource = { [unowned self] id in
            commit()
            selected = id
            latin = id == english
            return noErr
        }
        e.testSetRange = { [unowned self] _, r in
            let value = body as NSString
            returnCheck(NSMaxRange(r) <= value.length)
            commit()
            writes.append(r)
            prefix = value.substring(to: r.location)
            highlighted = value.substring(with: r)
            self.right = value.substring(from: NSMaxRange(r))
            return .success
        }
        e.testPostAtTap = { [unowned self] ev, _ in insert(ev) }
        b.now = { [unowned self] in time }
        b.source = { [unowned self] in selected }
        b.initialLayout = { [unowned self] in selected != korean ? .sourceChanged : (conflict ? .conflicting : .ready) }
        b.read = { [unowned self] in .init(field: field, text: body, selection: range) }
        b.readFocus = { [unowned self] in field }
        b.fieldWindow = { [unowned self] _ in window }
        b.ready = { [weak e] in e?.recovering == false }
        b.retained = { [unowned self] in retained += $0.count }
        b.trace = { [unowned self] in stages.append($0) }
        b.select = { [unowned self] id in commit(); selected = id; latin = id == english; return noErr }
        b.send = { [unowned self] ev in
            returnCheck(!barrier.receive(ev.type, ev))
            downstream(ev)
        }
        b.didSelect = { [weak e] in e?.noteUserSourceSwitch(at: $0) }
        e.verifiedDeliveryHistory = { [weak b, weak e] snap, prior in
            b?.verifiedTwoSetHistory(snap, after: e?.lastUserSourceSwitchTimestamp ?? 0, allowPrior: prior)
        }
        e.willBeginRepair = { [weak b] in b?.noteExternalEdit() }
        e.didVerifyReplay = { [unowned self] ledger, snap in
            confirmedRanges.append(snap.selection)
            barrier.adoptVerifiedReplay(ledger, snapshot: snap)
        }
        e.didProcessEvent = { [weak b] type, ev, passed in b?.confirmDelivery(type, ev, passed: passed) }
        e.confirmsReturnedASCII = { [weak b] plan, snap, prior in
            b?.confirmsReturnedASCII(plan, snapshot: snap, beforeKey: prior) ?? false
        }
    }
    func snapshot() -> MismatchSnapshot {
        .init(element: field, text: body, selection: range, selectedText: highlighted)
    }
    func commit() {
        prefix += composition
        composingKeys.removeAll()
        composition = ""
    }
    func insert(_ ev: CGEvent) {
        guard ev.type == .keyDown else { return }
        let key = UInt16(ev.getIntegerValueField(.keyboardEventKeycode)), shift = ev.flags.contains(.maskShift)
        guard let literal = MismatchRecoveryPlan.character(key, shift) else { return }
        highlighted = ""
        if latin { prefix += literal; return }
        composingKeys.append((key, shift))
        composition = MismatchKeyboardLayout.render(keys: composingKeys, sourceID: korean)!
    }
    func downstream(_ ev: CGEvent) {
        barrier.observeBeforeOnset(ev.type, ev, waiting: false)
        if engine.event(ev.type, ev) != nil { insert(ev) }
    }
    func change(_ target: String, explicit: Bool = true) {
        time += 0.02
        evidence.request(target, at: stamp)
        returnCheck(barrier.request(target, at: stamp, rightCommand: explicit))
        for _ in 0..<6 { barrier.step() }
        returnCheck(!barrier.busy && selected == target)
        evidence.observe(target)
    }
    func key(_ ch: Character, down: Bool, timestamp: UInt64? = nil) {
        let key = Self.positions[ch]!
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: key.0, keyDown: down)!
        ev.setIntegerValueField(.eventSourceUserData, value: 0)
        ev.flags = key.1 ? .maskShift : []
        time += 0.001
        ev.timestamp = timestamp ?? stamp
        if !barrier.receive(ev.type, ev) { downstream(ev) }
    }
    static let positions: [Character:(UInt16,Bool)] = {
        var result: [Character:(UInt16,Bool)] = [:]
        for key in PhysicalLetterKeys.letters.keys.sorted() + MismatchRecoveryPlan.punctuation.keys.sorted() {
            for shift in [false,true] {
                if let ch = MismatchRecoveryPlan.character(key,shift)?.first, result[ch] == nil { result[ch] = (key,shift) }
            }
        }
        return result
    }()
    func type(_ text: String) {
        for ch in text { key(ch, down: true); key(ch, down: false) }
    }
    func waitForReceipt() {
        let until = Date().addingTimeInterval(3)
        while engine.recovering && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}

// Freeze the detector until the original batch is delivered, then perturb one
// piece of evidence at a time. The editor must never receive an AX selection.
private func checkReturnBoundaries() {
    for condition in ["window","field","prefix","suffix","caret","selection","case","wrongKey","expired","layout","mouse","source","sourceEpoch","shortcut","newSwitch"] {
        let r = ReturnEditor(left: "한", right: " 꼬리")
        let evidence = r.evidence
        r.engine.canBeginRepair = { false }
        r.change(r.english)
        r.type("Q")
        r.conflict = true
        r.change(r.korean)
        r.latin = true
        r.key("a", down:true); r.key("a", down:false)
        r.time += 0.09
        for _ in 0..<6 { r.barrier.step() }
        var plan = MismatchRecoveryPlan(before: "한Q 꼬리", caret: 2)
        _ = plan.append(code: ReturnEditor.positions["a"]!.0, shift:false)
        var snap = r.snapshot()
        returnCheck(r.barrier.confirmsReturnedASCII(plan, snapshot: snap, beforeKey: false))
        switch condition {
        case "window": r.window = AXUIElementCreateApplication(89003)
        case "field": snap = .init(element:r.window, text:r.body, selection:r.range)
        case "prefix": snap = .init(element:r.field, text:"한Ra 꼬리", selection:r.range)
        case "suffix": snap = .init(element:r.field, text:"한Qa 변경", selection:r.range)
        case "caret": snap = .init(element:r.field, text:r.body, selection:NSRange(location:2,length:0))
        case "selection": snap = .init(element:r.field, text:r.body, selection:NSRange(location:2,length:1))
        case "case": snap = .init(element:r.field, text:"한QA 꼬리", selection:r.range)
        case "wrongKey":
            plan.codes = [(ReturnEditor.positions["s"]!.0,false)]; plan.roman = "s"
            snap = .init(element:r.field, text:"한Qs 꼬리", selection:r.range)
        case "expired": r.time += 0.6
        case "layout": r.conflict = false
        case "source": r.selected = r.english
        case "sourceEpoch": evidence.interrupt()
        case "shortcut", "mouse":
            let ev = CGEvent(source:nil)!
            ev.type = condition == "mouse" ? .leftMouseDown : .keyDown
            ev.flags = .maskCommand
            _ = r.barrier.receive(ev.type,ev)
        default: _ = r.barrier.request(r.english, at:r.stamp, rightCommand:true)
        }
        returnCheck(!r.barrier.confirmsReturnedASCII(plan,snapshot:snap,beforeKey:false) && r.writes.isEmpty)
    }
    // Delayed originals keep their old source even when replay copies are retimed.
    for lateFirst in [true,false] {
        let r = ReturnEditor(left:"한",right:"")
        r.change(r.english); r.type("Q")
        r.conflict = true; r.change(r.korean); r.latin = true
        r.engine.canBeginRepair = { false }
        let stale = r.engine.lastUserSourceSwitchTimestamp - 1
        r.key("a",down:true,timestamp:lateFirst ? stale : nil)
        r.key("a",down:false)
        r.key("n",down:true,timestamp:lateFirst ? nil : stale)
        r.time += 0.09
        for _ in 0..<6 { r.barrier.step() }
        var plan = MismatchRecoveryPlan(before:"한Q",caret:2)
        for ch in "an" { _ = plan.append(code:ReturnEditor.positions[ch]!.0,shift:false) }
        returnCheck(r.body == "한Qan" && !r.barrier.confirmsReturnedASCII(plan,snapshot:r.snapshot(),beforeKey:false))
    }
    print("PASS 17 invalidated receipts, no selection writes")
}

func runConfirmedReturnTests(firstLeft: String = "기존 내용을 그대로 둔 ", firstPair: (String,String) = ("문제인가 싶어서", "answpdlsrk tlvdjtj")) {
    let words = [("문제인가","answpdlsrk"), ("입력","dlqfur"), ("한글","gksrmf"), ("확인","ghkrdls"),
                 ("바로","qkfh"), ("그래서","rmfotj"), ("끝까지","RmxRkwl"), ("있어","dlTdj")]
    let leads = [("한","gks"), ("지금","wlrma"), ("다시","ektl"), ("문장","answkd")]
    let literals = ["Q","API","Mix","Z2","aBC","UTF8","v1.2","XYZ"]
    let sides = ["","앞쪽 ","📝 ","이전 문단\n"]
    var seed: UInt64 = 7265
    func pick<T>(_ values: [T]) -> T {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return values[Int((seed >> 32) % UInt64(values.count))]
    }
    checkReturnBoundaries()
    var verified = 0, untouched = 0
    for i in 0..<33 {
        let lead = i == 0 ? leads[0] : pick(leads), en = i == 0 ? "Q" : pick(literals)
        let pair = i == 0 ? firstPair : pick(words)
        let left = i == 0 ? firstLeft : pick(sides)
        let right = i == 0 ? "" : pick([""," 뒤"," 🌏","\n다음 문단"])
        for mode in ["broken","normal","nativeConflict","nonCommand"] {
            let r = ReturnEditor(left: left, right: right)
            r.type(lead.1); r.change(r.english); r.type(en)
            let protected = left + lead.0 + en
            returnCheck(r.body == protected + right)
            r.conflict = mode != "normal"
            r.change(r.korean, explicit: mode != "nonCommand")
            r.latin = mode == "broken" || mode == "nonCommand"
            r.time += 0.22
            let keys = Array(pair.1)
            r.key(keys[0], down:true); r.key(keys[0], down:false); r.key(keys[1], down:true)
            r.time += 0.087
            for _ in 0..<8 { r.barrier.step() }
            r.key(keys[1], down:false)
            for ch in keys.dropFirst(2) { r.key(ch, down:true); r.key(ch, down:false) }
            if !r.engine.recovering { r.engine.consumeIdleSnapshot(r.snapshot()) }
            r.waitForReceipt()
            let suffix = mode == "nonCommand" ? pair.1 : pair.0
            let ok = r.body.utf16.elementsEqual((protected + suffix + right).utf16)
                && r.range == NSRange(location:(protected + suffix).utf16.count,length:0)
            if !ok || i == 0 {
                print("case=\(i) mode=\(mode) text=\(r.body) caret=\(r.range) reason=\(r.engine.rollbackReason) stages=\(r.stages.suffix(12)) detections=\(r.engine.detectionCount) selections=\(r.writes) verified=\(r.confirmedRanges.count) retained=\(r.engine.retained.count) pass=\(ok)")
            }
            returnCheck(ok && r.retained == 0 && r.engine.retained.isEmpty && r.engine.pending.isEmpty && !r.engine.suspended && !r.engine.recovering)
            if mode == "broken" || mode == "nativeConflict" || mode == "nonCommand" {
                returnCheck(r.stages.contains("initial_original_resumed") && r.stages.contains("initial_transport_completed"))
            }
            if mode == "broken" {
                returnCheck(r.writes.count == 1 && r.writes[0].location == protected.utf16.count && r.writes[0].length > 0 && r.confirmedRanges.count == 1)
                verified += 1
            } else { returnCheck(r.writes.isEmpty && r.confirmedRanges.isEmpty); untouched += 1 }
        }
    }
    print("PASS exact body, caret, selection boundary and queues: repairs=\(verified) untouched=\(untouched) seed=7265")
}
