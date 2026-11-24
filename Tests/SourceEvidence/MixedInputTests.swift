import AppKit
import Carbon

func runMixedInputTests() {
    // Run the product's normal key observation, detection and source barrier
    // against a separate editor model. No key is posted to macOS.
    func verifySwitch(_ ko: String, prefix: (String, String), suffix: (String, String), missedFirstSwitch: Bool) {
        print("SWITCH", ko, prefix.1, missedFirstSwitch ? "first unobserved" : "first observed"); fflush(stdout)
        let engine = MismatchRecoveryEngine(), barrier = SourceSwitchBarrier()
        let sourceEvidence = MismatchSourceEvidence()
        var selected = ko, editorSource = ko, stamp: UInt64 = 100
        var editor = MismatchReplayLedger(before: "앞🙂뒤", caret: 3)
        var requested: [String] = []
        var received: [(UInt16, Bool)] = []
        var originalEvents = 0
        func snapshot() -> MismatchSnapshot {
            .init(element: field, text: editor.text, selection: editor.selection)
        }
        func unexpectedEdit(_ operation: String) { check(false, "unexpected \(operation) for \(ko) at \(editor.text)") }
        engine.enabled = true
        engine.testFastContext = { true }
        engine.locked = field
        engine.lastSource = ko
        engine.testSource = { selected }
        engine.testSnapshot = { snapshot() }
        engine.testSelectionWritable = { _ in true }
        engine.testSelectSource = { _ in unexpectedEdit("source edit"); return -50 }
        engine.testSetRange = { _,_ in unexpectedEdit("selection edit"); return .cannotComplete }
        engine.testPost = { _ in unexpectedEdit("post") }
        engine.testPostAtTap = { _,_ in unexpectedEdit("post at tap") }
        engine.sourceEvidence = sourceEvidence
        barrier.sourceEvidence = sourceEvidence
        barrier.read = { .init(field: field, text: editor.text, selection: editor.selection) }
        barrier.readFocus = { field }
        barrier.source = { selected }
        barrier.send = { _ in unexpectedEdit("barrier replay") }
        barrier.retained = { _ in unexpectedEdit("barrier retain") }
        barrier.select = { id in
            selected = id
            editorSource = id
            requested.append(id)
            return noErr
        }
        barrier.didConfirmSource = { id, time in sourceEvidence.didCommit(id, at: time) }
        barrier.didSelect = { time in engine.noteUserSourceSwitch(at: time) }
        engine.verifiedDeliveryHistory = { snap, prior in
            barrier.verifiedTwoSetHistory(snap, after: engine.lastUserSourceSwitchTimestamp, allowPrior: prior)
        }
        func switchTo(_ target: String) {
            stamp += 1
            sourceEvidence.request(target, at: stamp)
            check(barrier.request(target, at: stamp, rightCommand: true), "request accepted")
            barrier.step()
            check(requested.last == target && selected == target, "visible mixed text cannot strand the next switch")
            barrier.step()
            sourceEvidence.observe(target)
        }
        func send(_ code: UInt16, shifted: Bool, down: Bool) {
            stamp += 1
            let e = key(code, stamp)
            e.type = down ? .keyDown : .keyUp
            e.flags = shifted ? .maskShift : []
            check(!barrier.receive(e.type, e), "native event can go to its original editor")
            barrier.observe(e.type, e)
            check(engine.event(e.type, e) != nil && !engine.recovering, "original press/release passed")
            originalEvents += 1
            if down {
                received.append((code, shifted))
                editor.append(source: editorSource, keys: [(code, shifted)])
            }
            engine.consumeIdleSnapshot(snapshot())
        }
        func typeLetters(_ letters: String) {
            for letter in letters {
                let code = PhysicalLetterKeys.letters.first { $0.value == String(letter).lowercased() }!.key
                send(code, shifted: letter.isUppercase, down: true)
                send(code, shifted: letter.isUppercase, down: false)
            }
        }
        typeLetters(prefix.0)
        if missedFirstSwitch {
            // The editor accepted English but the observer still saw Korean.
            editorSource = en
        } else {
            switchTo(en)
        }
        send(12, shifted: true, down: true)
        check(editor.text == "앞🙂" + prefix.1 + "Q뒤", "editor has correct uppercase Q")
        if missedFirstSwitch {
            send(12, shifted: true, down: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            engine.consumeIdleSnapshot(snapshot())
            check(!engine.recovering, "settled mixed text must not start a repair")
            selected = en  // current source seen when the next switch is requested
        }
        switchTo(ko)
        if !missedFirstSwitch { send(12, shifted: true, down: false) }
        typeLetters(suffix.0)
        let physical = received.compactMap { MismatchRecoveryPlan.character($0.0, $0.1) }.joined()
        check(physical == prefix.0 + "Q" + suffix.0 && originalEvents == received.count * 2, "each original key and release passed once")
        check(requested == (missedFirstSwitch ? [ko] : [en, ko]), "only explicit requests changed the source")
        let expected = "앞🙂" + prefix.1 + "Q" + suffix.1
        check(editor.text == expected + "뒤" && editor.selection == NSRange(location: expected.utf16.count, length: 0), "complete text and UTF-16 caret match")
        check(engine.pending.isEmpty && engine.retained.isEmpty && !barrier.busy, "no pending transaction or lost input")
    }

    let mixedCases = [
        (KoreanKeyboardLayout.twoSetID, ("gks","한"), ("answpdlsrk","문제인가")),
        (KoreanKeyboardLayout.threeSetID, ("kfs","간"), ("jf","아")),
        (KoreanKeyboardLayout.threeSet390ID, ("kfs","간"), ("jf","아")),
        (KoreanKeyboardLayout.gongjinID, ("gan","간"), ("haneul","하늘")),
        (KoreanKeyboardLayout.hncID, ("gan","간"), ("haneul","하너ㅜㄹ")),
        (KoreanKeyboardLayout.twoSetID, ("r","ㄱ"), ("rk","가")),
        (KoreanKeyboardLayout.threeSetID, ("KFS","2ᆱᆭ"), ("kf","가")),
        (KoreanKeyboardLayout.threeSet390ID, ("KFS","5ᆩᆭ"), ("kf","가")),
        (KoreanKeyboardLayout.gongjinID, ("ae","ㅐ"), ("ga","가")),
        (KoreanKeyboardLayout.hncID, ("ae","ㅏㅓ"), ("ga","가"))
    ]
    for (id,prefix,suffix) in mixedCases {
        for missed in [false, true] { verifySwitch(id, prefix: prefix, suffix: suffix, missedFirstSwitch: missed) }
    }

    // Exercise a long elapsed candidate and the fragmented matcher after more
    // Korean text arrives. The barrier can hand either history back to idle.
    for (tail, latin, following) in [("Q", "Q", ""), ("w", "w", ""), ("Ab", "Ab", "ans")] {
        let head = String(repeating: "gks", count: 18) + "gk"
        var history = MismatchRecoveryPlan(before: "앞🙂뒤", caret: 3)
        for letter in head + tail + following {
            let code = PhysicalLetterKeys.letters.first { $0.value == String(letter).lowercased() }!.key
            _ = history.append(code: code, shift: letter.isUppercase)
        }
        let insertion = MismatchKeyboardLayout.render(roman: head, sourceID: ko)! + latin +
            MismatchKeyboardLayout.render(roman: following, sourceID: ko)!
        let snap = MismatchSnapshot(element: field, text: "앞🙂" + insertion + "뒤",
                                    selection: NSRange(location: 3 + insertion.utf16.count, length: 0))
        let engine = MismatchRecoveryEngine(detectionOnly: true)
        engine.enabled = true; engine.locked = field; engine.lastSource = ko
        engine.testSource = { ko }; engine.testSnapshot = { snap }
        let observedAt = ProcessInfo.processInfo.systemUptime
        engine.verifiedDeliveryHistory = { _,_ in (history, observedAt) }
        check(history.classifiedPartialFailure(text: snap.text, selection: snap.selection) != nil, "positive shape control")
        engine.consumeIdleSnapshot(snap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        engine.consumeIdleSnapshot(snap)
        check(engine.detectionCount == 0, "persistent mixed text never becomes an idle repair via history handoff")
    }

    func mixedPlan(_ keys: String, before: String = "") -> MismatchRecoveryPlan {
        var plan = MismatchRecoveryPlan(before: before, caret: before.utf16.count)
        for key in keys {
            let shift = key.isUppercase
            let letter = PhysicalLetterKeys.letters.first { $0.value == key.lowercased() }?.key
            let punctuation = MismatchRecoveryPlan.punctuation.first { $0.value.0 == String(key) }?.key
            _ = plan.append(code: (letter ?? punctuation)!, shift: shift)
        }
        return plan
    }
    for token in ["A1", "A-B", "Open Source", "A9/B"] {
        let text = "가" + token
        let plan = mixedPlan("rk" + token)
        let caret = NSRange(location: text.utf16.count, length: 0)
        check(plan.matchesMixedInputBeforeSwitch(text: text, selection: caret), "complete literal token permits requested switch")
        check(!plan.matchesMixedInputBeforeSwitch(text: text.lowercased(), selection: caret), "case change cannot authorize a switch")
    }
    check(mixedPlan("b", before: "ㄱQa").hasAmbiguousLatinInput("b"), "jamo mixed token remains protected after the capital")
    check(!mixedPlan("k", before: "ㄱ").hasAmbiguousLatinInput("k"), "plain failed vowel remains eligible for existing jamo repairs")
    check(mixedPlan("i", before: "값ap").hasAmbiguousLatinInput("i"), "tracking within api cannot replace its final letter")
    check(mixedPlan("F", before: "한q" + String(repeating: "0", count: 385)).hasAmbiguousLatinInput("F"), "a long numeric interval cannot authorize rewriting only its tail")
    check(mixedPlan("W", before: "한Wi-Fi A1 ").hasAmbiguousLatinInput("W"), "continued mixed phrase survives a space")
    check(!mixedPlan("i", before: "값. ").hasAmbiguousLatinInput("i"), "a prior sentence does not block a new candidate")
    let longKeys = String(repeating: "rk", count: 65)
    let longText = String(repeating: "가", count: 65)
    let sourcePlan = mixedPlan(longKeys)
    var ledger = MismatchReplayLedger(before: "🙂", caret: 2)
    ledger.append(source: ko, keys: Array(sourcePlan.codes.prefix(128)))
    if var compacted = ledger.compactedForObservation() {
        compacted.append(source: ko, keys: Array(sourcePlan.codes.dropFirst(128)))
        check(compacted.text == "🙂" + longText, "long word preserves composition and the key after rollover")
    } else { check(false, "long two-set history can roll over") }

    var plan = MismatchRecoveryPlan(before: "앞🙂뒤", caret: 3)
    for code: UInt16 in [5, 40, 1] { _ = plan.append(code: code, shift: false) }
    _ = plan.append(code: 12, shift: true)
    let caret = NSRange(location: 5, length: 0)
    for text in ["앞🙂한뒤", "앞🙂한q뒤", "앞🙂한A뒤", "앞🙂한QQ뒤", "앞🙂한Q끝"] {
        check(!plan.matchesMixedInputBeforeSwitch(text: text, selection: caret), "missing/changed/surplus key or surroundings cannot acknowledge delivery")
    }
    for invalid in [NSRange(location: 4, length: 0), NSRange(location: 5, length: 1)] {
        check(!plan.matchesMixedInputBeforeSwitch(text: "앞🙂한Q뒤", selection: invalid), "caret and selection required")
    }
}
