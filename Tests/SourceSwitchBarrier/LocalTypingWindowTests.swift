import AppKit
import Carbon

private func checkWindowBoundaries() {
    let value = String(repeating: "긴", count: 1_000) + "문단끝" as NSString
    let caret = NSRange(location: 1_000, length: 0)
    var requests: [NSRange] = []
    let nearEnd = EditorTextWindow.resolve(count: nil, selection: caret) { range in
        requests.append(range)
        guard NSMaxRange(range) <= value.length else { return (.illegalArgument, nil) }
        return (.success, value.substring(with: range))
    }
    returnCheck(nearEnd?.absoluteSelection == caret && nearEnd?.window.trailing == 0)
    returnCheck(nearEnd?.text.hasSuffix("문단끝") == true)
    returnCheck(requests.count > 1 && requests.allSatisfy { $0.location > 0 && $0.length <= 288 })

    var readCount = 0
    let oversized = NSRange(location: 0, length: EditorTextWindow.maximumSelection + 1)
    let selection = EditorTextWindow.resolve(count: value.length, selection: oversized) { _ in
        readCount += 1
        return (.success, "")
    }
    returnCheck(selection == nil && readCount == 0)
    let unavailable = EditorTextWindow.resolve(count: nil, selection: caret) { _ in
        readCount += 1
        return (.cannotComplete, nil)
    }
    returnCheck(unavailable == nil && readCount == 1)

    // Both edges split surrogate pairs. Replacing the witnessed middle must
    // preserve the original complete emoji, including their other halves.
    let full = "A😀문🙂Z"
    let bothEdges = EditorTextWindow(leading: 2, trailing: 2)
    let slice = (full as NSString).substring(with: NSRange(location: 2, length: 3))
    let original = slice.replacingOccurrences(of: "문", with: "한")
    let projected = bothEdges.expanding(original, observed: slice,
                                        selection: NSRange(location: 1, length: 0), full: full,
                                        fullSelection: NSRange(location: 3, length: 0))
    returnCheck(projected == "A😀한🙂Z")

    let context = EditorTextWindow(leading: 4, trailing: 1)
    let localCaret = NSRange(location: 1, length: 0)
    returnCheck(context.expanding("원문", observed: "내용", selection: localCaret,
                                  full: "abcd내용x", fullSelection: NSRange(location: 4, length: 0)) == nil)
    returnCheck(context.expanding("원문", observed: "내용", selection: localCaret,
                                  full: "abcd변경x", fullSelection: NSRange(location: 5, length: 0)) == nil)
}

/// The injected editor exposes the complete value only to edit and selection callbacks.
private func trackReads(_ editor: ReturnEditor) -> () -> (full: Int, bounded: Int, largest: Int) {
    var full = 0
    var bounded = 0
    var largest = 0

    func observe(_ preferred: EditorTextWindow?) -> EditorTextWindow.Observation {
        let body = editor.body as NSString
        let view = EditorTextWindow.resolve(count: body.length, selection: editor.range, preferred: preferred) { range in
            largest = max(largest, range.length)
            return (.success, body.substring(with: range))
        }
        bounded += 1
        return view!
    }
    editor.barrier.read = {
        let view = observe(editor.barrier.ledgerWindow)
        return .init(field: editor.field, text: view.text, selection: view.selection, window: view.window)
    }
    editor.engine.testObservation = {
        let view = observe(editor.engine.observationWindow)
        return .init(element: editor.field, text: view.text, selection: view.selection, observation: view.window)
    }
    editor.engine.testSnapshot = {
        full += 1
        return editor.snapshot()
    }
    editor.barrier.readForSelection = {
        full += 1
        return .init(field: editor.field, text: editor.body, selection: editor.range)
    }
    return { (full, bounded, largest) }
}

func runLocalTypingWindowTests() {
    checkWindowBoundaries()
    let fixtures: [String: [String: String]]
    if let path = ProcessInfo.processInfo.environment["HANQ_TYPING_FIXTURE"] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        fixtures = try! JSONDecoder().decode([String: [String: String]].self, from: data)
    } else {
        fixtures = [
            "menu": ["before": String(repeating: "첫 문단과 기존 내용\n", count: 36) + "마지막 문장 ㅋㅋ",
                     "after": "\n\n 다음 줄, test\n\n"],
            "withoutTail": ["before": "기존 문장 ㅋㅋ", "after": ""],
            "mac": ["before": String(repeating: "긴 메모 🙂 ", count: 64),
                    "after": "메모앱에서 " + String(repeating: "기존 문장 ", count: 32)],
        ]
    }
    for (name, fixture) in fixtures {
        let left = fixture["before"]!
        let tail = fixture["after"]!
        if name == "mac" {
            let editor = ReturnEditor(left: left, right: tail)
            let reads = trackReads(editor)
            editor.type("aor")
            returnCheck(editor.body == left + "맥" + tail && reads().full == 0)

            var keys: [CGKeyCode] = []
            let selector = SelectionPreservingSourceSwitch()
            selector.focus = { editor.field }
            selector.allowed = { true }
            selector.editable = { _ in true }
            selector.currentSource = { editor.selected }
            selector.now = { editor.time }
            selector.text = { _ in editor.body }
            selector.range = { _ in .init(location: editor.range.location, length: 0) }
            selector.caretText = { _, _, _ in editor.body }
            selector.postCommit = { _, key in
                keys.append(key)
                editor.commit()
                let body = editor.body as NSString
                let offset = editor.range.location + (key == 123 ? -1 : 1)
                editor.prefix = body.substring(to: offset)
                editor.right = body.substring(from: offset)
                return true
            }
            // The editor acknowledges an AX selection write without moving the caret.
            selector.setRange = { _, _ in true }
            selector.selectSource = editor.barrier.select
            editor.barrier.selectAfterTypedHangul = { id, local in
                if selector.isPending { return selector.select(id, asynchronous: true) }
                let full = editor.barrier.readForSelection!()!
                returnCheck(local.window.expanding(local.text, observed: local.text, selection: local.selection,
                                                   full: full.text, fullSelection: full.selection) != nil)
                let caret = SelectionPreservingSourceSwitch.TypedCaret(field: editor.field, text: full.text,
                                                                      offset: full.selection.location)
                return selector.select(id, asynchronous: true, typedCaret: caret)
            }
            editor.barrier.selectionPending = { selector.isPending }
            editor.change(editor.english)
            editor.type("OS")

            returnCheck(editor.body == left + "맥OS" + tail)
            returnCheck(editor.range == NSRange(location: left.utf16.count + 3, length: 0))
            returnCheck(keys == [123, 124] && reads().full == 1)
            returnCheck(editor.retained == 0 && editor.engine.retained.isEmpty)
        } else {
            let editor = ReturnEditor(left: left + "\n", right: tail)
            let reads = trackReads(editor)
            editor.change(editor.english)
            editor.type("menu11")
            // The editor updates another paragraph while the typed token and caret still match.
            editor.right = tail.replacingOccurrences(of: ",", with: "，")
            let preserved = editor.right
            editor.change(editor.korean)
            editor.type("eh")

            let prefix = left + "\nmenu11도"
            returnCheck(editor.body == prefix + preserved)
            returnCheck(editor.range == NSRange(location: prefix.utf16.count, length: 0))
            returnCheck(reads().full == 0 && reads().bounded > 0 && reads().largest <= 288)
            returnCheck(editor.writes.isEmpty && editor.retained == 0 && editor.engine.retained.isEmpty)
        }
    }

    let left = String(repeating: "기존 문단과 🙂 ", count: 150)
    let right = String(repeating: " 반복 문맥 ", count: 130)
    let editor = ReturnEditor(left: left, right: right)
    let reads = trackReads(editor)
    // The first occurrence is user content. Only the new run has input history.
    editor.prefix += "rks "
    editor.latin = true
    editor.engine.canBeginRepair = { false }
    editor.type("rks")
    editor.engine.canBeginRepair = { true }
    for _ in 0..<7 { editor.engine.sample(synchronous: true) }
    editor.waitForReceipt()

    returnCheck(editor.body == left + "rks 간" + right)
    returnCheck(editor.range.location == (left + "rks 간").utf16.count)
    returnCheck(reads().full > 0 && reads().largest <= 288)
    returnCheck(editor.writes.allSatisfy { $0.location >= left.utf16.count + 4 })
    print("PASS bounded typing, unknown count, surrogate edges, multiline switching, middle caret and absolute repairs")
}
