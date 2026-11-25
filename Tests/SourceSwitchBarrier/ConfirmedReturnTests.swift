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
    let korean: String
    var selected: String
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

    init(left: String, right: String, sourceID: String = KoreanKeyboardLayout.twoSetID) {
        korean = sourceID
        selected = sourceID
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
        b.initialLayout = { [unowned self] target in selected != target ? .sourceChanged : (conflict ? .conflicting : .ready) }
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
    func change(_ target: String, explicit: Bool = true, afterCommit: (() -> Void)? = nil) {
        time += 0.02
        evidence.request(target, at: stamp)
        returnCheck(barrier.request(target, at: stamp, rightCommand: explicit))
        barrier.step()
        if let afterCommit {
            returnCheck(barrier.busy && selected == target)
            afterCommit()
        }
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

// Q is released before the Korean switch, but Shift can change while
// the right Command used for the switch is still physically held.
private func checkShiftAcrossReturn() {
    let command = CommandFilter()
    let right = CGEventFlags(rawValue: command.rightDeviceMask).union(.maskCommand)
    let left = CGEventFlags(rawValue: command.leftDeviceMask).union(.maskCommand)
    let cases: [(CGKeyCode, CGEventFlags, Bool, Bool, Bool)] = [
        // Shift key, flags at its edge, queued during the switch, Latin output, should repair.
        (56, right, true, true, true), (60, right, false, true, true),
        (56, right, true, false, false), (56, left, true, true, false),
        (56, right.union(left), true, true, false),
        (60, right.union(.maskControl), true, true, false),
        (56, right.union(.maskAlternate), true, true, false)
    ]
    for (code, flags, queued, latin, repair) in cases {
        let r = ReturnEditor(left: "한", right: " 뒤")
        r.change(r.english)
        r.type("Q")
        r.conflict = true
        func shiftEdge() {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
            ev.type = .flagsChanged
            ev.flags = flags
            ev.timestamp = r.stamp
            let consumed = r.barrier.receive(.flagsChanged, ev)
            returnCheck(consumed == queued)
            if !consumed { r.downstream(ev) }
        }
        r.change(r.korean, afterCommit: queued ? shiftEdge : nil)
        if !queued { shiftEdge() }
        r.latin = latin
        let release = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: false)!
        release.type = .flagsChanged
        release.flags = []
        returnCheck(!r.barrier.receive(.flagsChanged, release))
        r.time += 0.16
        r.type("f")
        r.time += 0.09
        for _ in 0..<8 { r.barrier.step() }
        r.engine.consumeIdleSnapshot(r.snapshot())
        r.waitForReceipt()
        r.type("kd dj")
        r.engine.consumeIdleSnapshot(r.snapshot())
        r.waitForReceipt()
        let expected = repair || !latin ? "한Q랑 어 뒤" : "한Qfkd dj 뒤"
        let ok = r.body == expected && r.range.location == (expected as NSString).length - 2
            && r.range.length == 0 && r.writes == (repair ? [NSRange(location: 2, length: 1)] : [])
            && r.retained == 0 && r.engine.retained.isEmpty && r.engine.pending.isEmpty
        if !ok { print("Shift across return", code, flags.rawValue, queued, r.body, r.writes, r.stages) }
        returnCheck(ok)
    }
    print("PASS Shift across the return switch, exact suffix recovery and shortcut guards")
}

private func checkMultilineHangulToEnglish() {
    let paragraph = "첫 문단🙂\n\n두 번째 문단을 쓰고, 아무튼 "
    let suffix = " 남은 본문"
    let r = ReturnEditor(left: paragraph, right: suffix)
    let selector = SelectionPreservingSourceSwitch()
    selector.allowed = { true }
    selector.focus = { r.field }
    selector.editable = { _ in true }
    selector.currentSource = { r.selected }
    selector.now = { r.time }
    selector.text = { _ in r.body + "\n" }
    selector.range = { _ in CFRange(location: r.range.location, length: r.range.length) }
    selector.caretText = { _, raw, selected in
        let text = r.body as NSString
        let caret = NSRange(location: selected.location, length: selected.length)
        return MismatchTextReader.resolve(value: raw, selection: caret) { range in
            NSMaxRange(range) <= text.length ? text.substring(with: range) : nil
        }
    }
    selector.postCommit = { _, key in
        returnCheck(key == 123)
        let previous = NSRange(location: r.range.location - 1, length: 0)
        return r.engine.testSetRange?(r.field, previous) == .success
    }
    selector.setRange = { _, range in
        r.engine.testSetRange?(r.field, NSRange(location: range.location, length: range.length)) == .success
    }
    selector.selectSource = r.barrier.select
    r.barrier.select = { selector.select($0, asynchronous: true) }
    r.barrier.selectAfterTypedHangul = { target, snapshot in
        let proof = SelectionPreservingSourceSwitch.TypedCaret(field: snapshot.field, text: snapshot.text, offset: snapshot.selection.location)
        return selector.select(target, asynchronous: true, typedCaret: proof)
    }
    r.barrier.selectionPending = { selector.isPending }
    r.type("gks")
    r.change(r.english)
    r.type("Q")
    let end = (paragraph + "한").utf16.count
    returnCheck(r.body == paragraph + "한Q" + suffix)
    returnCheck(r.range == NSRange(location: end + 1, length: 0))
    returnCheck(r.writes == [NSRange(location: end - 1, length: 0), NSRange(location: end, length: 0)])
    returnCheck(r.retained == 0 && r.selected == r.english)
    print("PASS multiline editor: composed Hangul, right Command, Shift+Q and suffix")
}

private func checkMissingOutboundSyllable() {
    // This editor temporarily hides an active syllable on direct deactivation.
    // Both callbacks run through the normal request and queued-delivery path.
    for guarded in [false,true] {
        let r=ReturnEditor(left:"오래 입력한 뒤에도 ",right:" 다음 문단")
        var hidden="", commits=0
        r.barrier.select={ id in
            if id==r.english {hidden=r.composition;r.composition="";r.composingKeys=[]}
            else if !hidden.isEmpty {r.prefix+=hidden;hidden=""}
            r.commit();r.selected=id;r.latin=id==r.english;return noErr
        }
        if guarded {
            r.barrier.selectAfterTypedHangul={ id,snap in
                returnCheck(snap.text==r.body && snap.selection==r.range && id==r.english)
                r.commit();commits+=1
                return r.barrier.select(id)
            }
        }
        r.type("gks");r.evidence.request(r.english,at:r.stamp)
        returnCheck(r.barrier.request(r.english,at:r.stamp,rightCommand:true))
        r.barrier.step()
        if guarded {
            for _ in 0..<6 {r.barrier.step()}
            r.type("Q");r.change(r.korean);r.type("dptj")
            returnCheck(commits==1 && hidden.isEmpty && r.body=="오래 입력한 뒤에도 한Q에서 다음 문단" &&
                        r.range.location=="오래 입력한 뒤에도 한Q에서".utf16.count && r.writes.isEmpty && r.retained==0)
        } else {returnCheck(hidden=="한" && r.body=="오래 입력한 뒤에도  다음 문단")}
    }

    for mode in ["nativeRestores","remainsMissing","differentField","differentWindow","expired","changedSuffix","wrongGap","pendingQ","noUserReturn"] {
        let r=ReturnEditor(left:"🙂 앞 ",right:" 뒤")
        r.type("gks")
        r.change(r.english);r.type("Q")
        let complete=r.body
        r.prefix="🙂 앞 Q"
        switch mode {
        case "changedSuffix":r.right=" 끝"
        case "wrongGap":r.prefix="🙂 한Q"
        case "pendingQ":r.prefix="🙂 앞 한"
        case "expired":r.time+=3.1
        case "differentWindow":r.window=AXUIElementCreateApplication(89009)
        case "differentField":r.barrier.read={.init(field:r.window,text:r.body,selection:r.range)}
        default:break
        }
        r.barrier.select={ id in
            r.commit();r.selected=id;r.latin=id==r.english
            if mode=="nativeRestores" {r.prefix="🙂 앞 한Q"}
            return noErr
        }
        r.evidence.request(r.korean,at:r.stamp)
        returnCheck(r.barrier.request(r.korean,at:r.stamp,rightCommand:mode != "noUserReturn"))
        for _ in 0..<5 {r.barrier.step()}
        let shouldSwitch=["nativeRestores","remainsMissing"].contains(mode)
        returnCheck((r.selected==r.korean)==shouldSwitch && r.writes.isEmpty)
        if shouldSwitch {
            r.type("dptj")
            let desired=mode=="nativeRestores" ? "🙂 앞 한Q에서 뒤":"🙂 앞 Q에서 뒤"
            returnCheck(r.body==desired && r.range.location==desired.utf16.count-2 && r.retained==0)
        } else {returnCheck(r.body != complete)}
    }
    let r=ReturnEditor(left:"문장 중간 한",right:" 다음 문단")
    r.change(r.english);r.type("Q");r.conflict=true;r.change(r.korean)
    r.type("f");r.time+=0.09
    for _ in 0..<8 {r.barrier.step()}
    r.type("kd");r.change(r.english)
    returnCheck(r.body=="문장 중간 한Q랑 다음 문단" && r.writes.isEmpty)
    print("PASS missing outbound syllable, native reinsertion, context guards and composed-onset continuation")
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
    checkMultilineHangulToEnglish()
    checkMissingOutboundSyllable()
    checkShiftAcrossReturn()
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


func checkLayoutReturn(_ id: String) -> Bool {
    let word: String
    switch id {
    case KoreanKeyboardLayout.twoSetID: word = "rks"
    case KoreanKeyboardLayout.threeSetID, KoreanKeyboardLayout.threeSet390ID: word = "kfs"
    default: word = "gan"
    }
    let next = String(word.prefix(2))
    var passed = true
    func record(_ name: String, _ ok: Bool) {
        print("MATRIX \(id) \(name) \(ok ? "PASS" : "FAIL")")
        passed = passed && ok
    }
    var mixed = MismatchRecoveryPlan(before: "앞뒤", caret: 1, sourceID: id)
    for ch in word + "Q" {
        let key = ReturnEditor.positions[ch]!
        _ = mixed.append(code: key.0, shift: key.1)
    }
    record("mixed-spelling", mixed.matchesMixedInputBeforeSwitch(text: "앞간Q뒤", selection: NSRange(location: 3, length: 0)))
    let e = MismatchRecoveryEngine()
    e.recoverySourceID = id; e.testSource = { id }
    e.testActivationNeeded = { true }
    e.activationShortcut.configuration = { (49, .maskControl) }
    record("configured-activation", e.activationShortcutSupported())
    for mode in ["native", "conflict-but-correct", "wrong-ascii"] {
        let r = ReturnEditor(left: "🙂", right: "뒤", sourceID: id)
        r.type(word); r.change(r.english); r.type("Q")
        r.conflict = mode != "native"; r.change(id); r.latin = mode == "wrong-ascii"
        let keys = Array(word)
        r.key(keys[0], down:true); r.key(keys[0], down:false); r.key(keys[1], down:true)
        r.time += 0.09
        for _ in 0..<8 { r.barrier.step() }
        r.key(keys[1], down:false); r.type(String(keys.dropFirst(2)))
        if !r.engine.recovering { r.engine.consumeIdleSnapshot(r.snapshot()) }
        r.waitForReceipt()
        r.type(next); r.waitForReceipt()
        let repaired = r.confirmedRanges.count == 1 && r.writes.count == 1 && r.writes[0].location == 4
        let ok = r.body == "🙂간Q간가뒤" && r.range == NSRange(location: 6, length: 0)
            && (mode == "wrong-ascii" ? repaired : r.writes.isEmpty && r.confirmedRanges.isEmpty)
            && r.engine.retained.isEmpty && r.engine.pending.isEmpty && !r.engine.suspended
        record(mode, ok)
        if !ok { print("FIXTURE", r.body, r.range, r.writes, r.stages.suffix(6)) }
    }
    // Each target owns its receipt, even when the next source is also Korean.
    let guarded = ReturnEditor(left: "간", right: "뒤", sourceID: id)
    guarded.engine.canBeginRepair = { false }
    guarded.change(guarded.english); guarded.type("Q")
    guarded.conflict = true; guarded.change(id); guarded.latin = true
    let first = word.first!
    guarded.type(String(first)); guarded.time += 0.09
    for _ in 0..<6 { guarded.barrier.step() }
    var evidence = MismatchRecoveryPlan(before: "간Q뒤", caret: 2, sourceID: id)
    let firstKey = ReturnEditor.positions[first]!
    _ = evidence.append(code: firstKey.0, shift: firstKey.1)
    let snap = guarded.snapshot()
    record("original-receipt", guarded.barrier.confirmsReturnedASCII(evidence, snapshot: snap, beforeKey: false))
    for other in KoreanKeyboardLayout.supportedIDs where other != id {
        var foreign = evidence
        foreign.sourceID = other
        guarded.selected = id
        let rejectedPlan = !guarded.barrier.confirmsReturnedASCII(foreign, snapshot: snap, beforeKey: false)
        guarded.selected = other
        record("different-layout-"+other, rejectedPlan && !guarded.barrier.confirmsReturnedASCII(evidence, snapshot: snap, beforeKey: false))
    }

    var history = MismatchReplayLedger(before: "🙂뒤", caret: 2)
    let pair = next.map { ReturnEditor.positions[$0]! }
    for _ in 0..<64 { history.append(source: id, keys: pair) }
    var compacted = history.compactedForObservation()
    compacted?.append(source: id, keys: pair)
    record("long-history", compacted?.text == "🙂" + String(repeating: "가", count: 65) + "뒤"
        && compacted?.selection == NSRange(location: 67, length: 0))

    // Check native ASCII (including Roman-layout letters) while the TIS layout is
    // reporting ABC. A literal that this IME normally produces must pass through.
    let literals = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*1234567890.,;"
    var literalCount = 0
    for ch in literals {
        guard let key = ReturnEditor.positions[ch],
              MismatchKeyboardLayout.output(code:key.0,shift:key.1,sourceID:id) == ch else { continue }
        let r = ReturnEditor(left:"한",right:"",sourceID:id)
        r.change(r.english); r.type("Q"); r.conflict = true; r.change(id)
        r.type(String(ch))
        r.engine.consumeIdleSnapshot(r.snapshot())
        record("native-literal-\(ch)", r.body == "한Q" + String(ch) && r.writes.isEmpty
            && !r.engine.recovering && !r.stages.contains("initial_layout_wait"))
        literalCount += 1
    }
    record("native-literal-coverage",literalCount > 0)

    // Sample a reproducible range of mixed prefixes and verified Korean input,
    // without relying on the product renderer for the expected Hangul.
    var samples = [("가",String(word.prefix(2))), ("간",word)]
    switch id {
    case KoreanKeyboardLayout.twoSetID: samples += [("한글","gksrmf"),("가나다","rkskek")]
    case KoreanKeyboardLayout.threeSetID: samples += [("안","jfs"),("2ᆱᆭ","KFS"),("ᇂᆻᆸ","123")]
    case KoreanKeyboardLayout.threeSet390ID: samples += [("안","jfs"),("5ᆩᆭ","KFS"),("ᇂᆻᆸ","123")]
    case KoreanKeyboardLayout.gongjinID: samples += [("ㅐ","ae"),("하늘","haneul"),("한국","hangug")]
    default: samples += [("ㅏㅓ","ae"),("하너ㅜㄹ","haneul"),("한국","hangug")]
    }
    let englishTokens = ["API","Q","v1.2","AbC","Wi-Fi","7bit"]
    var seed: UInt64 = 447
    for trial in 0..<24 {
        func index(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(count))
        }
        let first = samples[index(samples.count)], token = englishTokens[index(englishTokens.count)]
        let last = samples[index(samples.count)], left = ["🙂","첫 ",""][index(3)]
        let r = ReturnEditor(left:left,right:" 끝",sourceID:id)
        r.type(first.1); r.change(r.english); r.type(token); r.change(id); r.type(last.1)
        r.engine.consumeIdleSnapshot(r.snapshot()); r.waitForReceipt()
        let target = left + first.0 + token + last.0
        record("mixed-\(trial)",r.body == target + " 끝" && r.range == NSRange(location: target.utf16.count,length:0) && r.writes.isEmpty && r.engine.retained.isEmpty)
    }


    let preserved = returnedQueueChecks(id, word: word)
    return passed && preserved
}

private func returnedQueueChecks(_ id: String, word: String) -> Bool {
    var passed = true
    let keys = Array(word)
    for mode in ["recover", "retain", "english-only", "mixed-queue"] {
        let r = ReturnEditor(left: "간", right: "뒤", sourceID: id)
        let engine = r.engine
        var attempts = 0
        var shortcutRequests = 0
        engine.testActivationNeeded = { true }
        engine.activationShortcut.canPost = { true }
        engine.activationShortcut.modifiersClear = { true }
        engine.activationShortcut.configuration = { mode == "recover" ? (49, .maskControl) : nil }
        engine.activationShortcut.releasePosted = { _,_ in }
        engine.activationShortcut.post = { ev in
            if ev.type == .keyDown {
                shortcutRequests += 1
                r.commit(); r.selected = id; r.latin = false
            }
        }
        engine.testSelectSource = { requested in
            r.commit(); r.selected = requested; r.latin = true
            if requested == id { attempts += 1 }
            return noErr
        }
        r.change(r.english); r.type("Q")
        r.conflict = true; r.change(id); r.latin = true; r.time += 0.22
        r.type(String(keys[0])); r.key(keys[1],down:true)
        r.time += 0.087
        for _ in 0..<8 { r.barrier.step() }
        r.key(keys[1],down:false)
        if !engine.recovering { engine.consumeIdleSnapshot(r.snapshot()) }
        guard engine.recovering else { print("MATRIX \(id) \(mode) FAIL no recovery"); passed=false; continue }
        let koreanTail = String(keys[2]) + String(keys.prefix(2))
        if mode != "english-only" { r.type(koreanTail) }
        let switchToEnglish = mode == "english-only" || mode == "mixed-queue"
        if switchToEnglish { engine.userToggleDuringRecovery(at:r.stamp); r.type("AbC") }
        func edges(_ events: [CGEvent]) -> [[Int]] {
            events.map { [$0.type == .keyDown ? 1 : 0, Int($0.getIntegerValueField(.keyboardEventKeycode)), $0.flags.contains(.maskShift) ? 1 : 0] }
        }
        let original = edges(engine.pending)
        let raw = String(keys.prefix(2))
        r.waitForReceipt()
        let expectPark = mode == "retain" || mode == "mixed-queue"
        let body = mode == "recover" ? "간Q간가뒤" : "간Q" + raw + (mode == "english-only" ? "AbC" : "") + "뒤"
        let ok = r.body == body && r.range == NSRange(location: body.utf16.count - 1, length: 0)
            && !engine.recovering && engine.pending.isEmpty && engine.suspended == expectPark
            && r.selected == (switchToEnglish ? r.english : id)
            && shortcutRequests == (mode == "recover" ? 1 : 0)
            && (mode != "recover" || attempts == 1)
            && (expectPark ? !original.isEmpty && edges(engine.retained) == original : engine.retained.isEmpty)
        print("MATRIX \(id) \(mode) \(ok ? "PASS" : "FAIL")")
        if !ok { print("QUEUE",body,r.body,attempts,shortcutRequests,engine.rollbackReason,original.count,engine.retained.count,r.range) }
        passed = passed && ok
    }
    return passed
}
