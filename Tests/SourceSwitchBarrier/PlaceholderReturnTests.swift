import AppKit

// AX shape observed in a Chromium editor. Its field value, range text and
// accessible label can all spell the prompt even when it is a typed draft.
private func promptReader(_ r: ReturnEditor, nestedDecoration: Bool = true) -> MismatchPlaceholderReader {
    let paragraph = AXUIElementCreateApplication(89100), decoration = AXUIElementCreateApplication(89101)
    let leaf = AXUIElementCreateApplication(89102)
    var reader = MismatchPlaceholderReader()
    reader.onlyChild = { [unowned r] element in
        if CFEqual(element, r.field) { return paragraph }
        if CFEqual(element, paragraph) { return r.showingPrompt && nestedDecoration ? decoration : leaf }
        return CFEqual(element, decoration) ? leaf : nil
    }
    reader.attributes = { [unowned r] element, names in
        names.map { name -> CFTypeRef? in
            switch name {
            case kAXRoleAttribute:
                if CFEqual(element, r.field) { return kAXTextAreaRole as CFString }
                return (CFEqual(element, leaf) ? kAXStaticTextRole : kAXGroupRole) as CFString
            case kAXValueAttribute: return (CFEqual(element, r.field) ? r.body + "\n" : r.body) as CFString
            case kAXWindowAttribute: return r.window
            case kAXTitleAttribute, kAXDescriptionAttribute: return r.prompt as CFString?
            case kAXSelectedTextRangeAttribute:
                var range = CFRange(location:r.range.location, length:r.range.length)
                return AXValueCreate(.cfRange, &range)
            default: return nil
            }
        }
    }
    reader.writable = { [unowned r] node, _ in CFEqual(node, paragraph) || (CFEqual(node, leaf) && !r.showingPrompt) }
    return reader
}

private func checkPlaceholderReturn() {
    let roman = "rmsep sk", hangul = "근데 나"
    for prompt in ["안내", "Type a question…", "📝 新しい質問をここに入力してください\n", "rm", "rmsep sk"] {
        for scenario in ["empty", "endOfPrompt", "draftAtStart", "draftAtEnd", "disappearingDraft"] {
            let r = ReturnEditor(left: scenario == "draftAtEnd" ? prompt : "",
                                 right: ["draftAtStart", "disappearingDraft"].contains(scenario) ? prompt : "")
            r.prompt = prompt
            let reader = promptReader(r, nestedDecoration: scenario != "endOfPrompt")
            r.barrier.inspectReturnSurface = { surface, snapshot, window, _, done in
                done(reader.confirms(surface, field:snapshot.field, window:window, text:snapshot.text, selection:snapshot.selection))
            }
            r.promptCaret = scenario == "endOfPrompt" ? prompt.utf16.count : 0
            r.engine.canBeginRepair = { false }
            r.change(r.english)
            r.conflict = true
            r.change(r.korean)
            r.latin = true
            if scenario == "disappearingDraft" { r.beforeFirstInsert = { r.right = "" } }
            r.key("r", down: true); r.key("r", down: false); r.key("m", down: true)
            r.time += 0.088
            for _ in 0..<8 { r.barrier.step() }
            r.key("m", down: false)
            r.type(String(roman.dropFirst(2)))
            let left = scenario == "draftAtEnd" ? prompt : ""
            let right = scenario == "draftAtStart" ? prompt : ""
            returnCheck(r.editableText == left + roman + right && r.writes.isEmpty)
            r.engine.canBeginRepair = { true }
            r.engine.consumeIdleSnapshot(r.snapshot())
            r.waitForReceipt()
            let recover = scenario != "disappearingDraft"
            let final = recover ? hangul : roman
            let edits = recover ? [NSRange(location: left.utf16.count, length: roman.utf16.count)] : []
            if r.editableText != left + final + right || r.writes != edits {
                print("placeholder return", scenario, prompt.debugDescription, r.editableText.debugDescription, r.writes)
            }
            returnCheck(r.editableText == left + final + right && r.writes == edits)
            returnCheck(r.range == NSRange(location: (left + final).utf16.count, length: 0))
            returnCheck(r.selected == r.korean && r.retained == 0 && r.engine.retained.isEmpty && !r.engine.recovering)
        }
    }
    print("PASS placeholder and identical typed drafts after a completed two-set return")
}

private func checkPlaceholderPublication() {
    let roman = "rmsep sk"
    for scenario in ["typing", "delayedPrefix", "asyncInput", "latePrompt", "layoutReady", "newWindow", "noEditableText", "lateInput"] {
        let r = ReturnEditor(left:"", right:"")
        r.prompt = scenario == "noEditableText" ? roman : "다른 길이의 안내 📝"
        let reader = promptReader(r)
        var delayed: (() -> Void)?
        r.barrier.inspectReturnSurface = { surface, snap, window, _, done in
            let confirmed = reader.confirms(surface, field:snap.field, window:window, text:snap.text, selection:snap.selection)
            if (surface == .prompt && scenario == "latePrompt") || (surface == .input && ["lateInput", "asyncInput"].contains(scenario)) {
                delayed = { done(confirmed) }
            } else { done(confirmed) }
        }
        // "typing" uses the normal pre-key detector and buffers the remaining
        // input during replay. The other cases inspect one final published run.
        r.engine.canBeginRepair = { scenario == "typing" }
        r.change(r.english); r.conflict = true; r.change(r.korean); r.latin = true
        r.key("r", down:true); r.key("r", down:false); r.key("m", down:true)
        r.time += 0.088
        for _ in 0..<8 { r.barrier.step() }
        r.key("m", down:false)
        if scenario == "latePrompt" { delayed?() }
        if scenario == "delayedPrefix" {
            r.engine.testSnapshot = { [unowned r] in .init(element:r.field, text:"r", selection:NSRange(location:1,length:0)) }
        }
        if scenario == "noEditableText" {
            // The provider still exposes only the read-only prompt, now with
            // an end caret that happens to agree with every received key.
            r.prefix = ""; r.promptCaret = roman.utf16.count
            r.engine.testPostAtTap = { _, _ in returnCheck(false) }
        }
        r.type(String(roman.dropFirst(2)))
        if scenario == "delayedPrefix" { r.engine.testSnapshot = { [unowned r] in r.snapshot() } }
        if scenario == "layoutReady" { r.conflict = false }
        if scenario == "newWindow" { r.window = AXUIElementCreateApplication(89120) }
        if scenario == "noEditableText" { r.prefix = ""; r.right = "" }
        r.engine.canBeginRepair = { true }
        r.engine.consumeIdleSnapshot(r.snapshot())
        if ["asyncInput", "lateInput"].contains(scenario) {
            if scenario == "lateInput" { r.time += MismatchSourceEvidence.confirmationSeconds + 0.01 }
            // First complete the in-flight prefix read. Only a fresh read of
            // the longer, current body can authorize its full range.
            returnCheck(delayed != nil && r.writes.isEmpty)
            for _ in 0..<2 {
                let reply = delayed; delayed = nil; reply?()
                r.engine.consumeIdleSnapshot(r.snapshot())
            }
        }
        r.waitForReceipt()
        if ["typing", "delayedPrefix", "asyncInput"].contains(scenario) {
            returnCheck(r.editableText == "근데 나" && r.range == NSRange(location:4,length:0))
            returnCheck(r.writes.count == 1 && r.writes[0].location == 0)
            if scenario == "typing" { returnCheck(r.writes[0].length < roman.utf16.count) }
        } else {
            returnCheck(r.writes.isEmpty && r.body == roman)
        }
        returnCheck(r.retained == 0 && r.engine.retained.isEmpty && r.engine.pending.isEmpty)
    }
    print("PASS incremental and delayed placeholder input, stale evidence, read-only prompt and changed context")
}

private func checkPromptStructure() {
    let editor = ReturnEditor(left:"", right:"")
    editor.prompt = "같은 문구"
    let original = promptReader(editor)
    func confirmed(_ reader: MismatchPlaceholderReader) -> Bool {
        reader.confirms(.prompt, field:editor.field, window:editor.window, text:editor.body, selection:editor.range)
    }
    returnCheck(confirmed(original))
    returnCheck(confirmed(promptReader(editor, nestedDecoration:false)))
    var unreadable = original
    unreadable.writable = { _, _ in nil }
    returnCheck(!confirmed(unreadable))
    var changedBranch = original, visits = 0
    changedBranch.onlyChild = { field in
        if CFEqual(field, editor.field) { visits += 1 }
        return visits > 1 ? nil : original.onlyChild(field)
    }
    returnCheck(!confirmed(changedBranch))
    var changedSelection = original
    changedSelection.attributes = { field, names in
        var values = original.attributes(field, names)
        if CFEqual(field, editor.field), !names.contains(kAXTitleAttribute),
           let i = names.firstIndex(of:kAXSelectedTextRangeAttribute) {
            var moved = CFRange(location:1,length:0)
            values[i] = AXValueCreate(.cfRange,&moved)
        }
        return values
    }
    returnCheck(!confirmed(changedSelection))
    editor.right = editor.prompt!
    returnCheck(!confirmed(original))
    returnCheck(!confirmed(promptReader(editor, nestedDecoration:false)))
    returnCheck(original.confirms(.input, field:editor.field, window:editor.window, text:editor.body, selection:editor.range))
}

func runPlaceholderReturnTests() {
    checkPromptStructure()
    checkPlaceholderReturn()
    checkPlaceholderPublication()
}
