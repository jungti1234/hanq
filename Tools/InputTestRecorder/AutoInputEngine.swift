import Foundation

struct AutoTestKey { let code: UInt16; let shift: Bool }
struct AutoTestEdge { let at: Double; let code: UInt16; let down, modifier: Bool }
struct AutoTestCase { let id: Int; let expected: String; let keys: [AutoTestKey]; let gap: Double; let overwrite: Bool }
struct AutoEditorState { let text: String; let selection: NSRange; var sourceMatches = true }

enum AutoTestFailure: String, Error {
    case cancelled, permission, secureInput, wrongApplication, targetChanged, sourceChanged
    case unreadableEditor, existingDraft, selectionNotVerified, textMismatch, emptyNotVerified, productExited
}

protocol AutoTestEditor: AnyObject {
    func check() throws
    func read() throws -> AutoEditorState
    func send(_ edge: AutoTestEdge, shifted: Bool) throws
    func selectAll() throws
    func deleteSelection() throws
    func release(_ held: Set<UInt16>)
}

struct AutoCaseResult: Codable {
    let id: Int
    let expectedSynthetic: String
    let nominalGapMilliseconds: Double
    let overwrite: Bool
    let bodyAndCaretMatched: Bool
    let pacingQualified: Bool
    let observedUTF16Length: Int
    let selectionLocation, selectionLength: Int
    let missingExpectedUTF16Indices: [Int]
    let unexpectedUTF16Units: Int
    let postedDowns, postedUps: Int
    let actualDownGapsMilliseconds: [Double]
    let scope: String
    var inputSourceMatched = true
}

enum AutoInputPlan {
    static func edges(_ keys: [AutoTestKey], gap: Double) -> [AutoTestEdge] {
        var result = [AutoTestEdge]()
        for (i, key) in keys.enumerated() {
            let start = Double(i) * gap
            let nextSame = keys.indices.dropFirst(i + 1).first { keys[$0].code == key.code }.map { Double($0) * gap - 0.001 } ?? .infinity
            if key.shift { result.append(.init(at: start - 0.0005, code: 56, down: true, modifier: true)) }
            result.append(.init(at: start, code: key.code, down: true, modifier: false))
            result.append(.init(at: min(start + 0.045, nextSame), code: key.code, down: false, modifier: false))
            if key.shift { result.append(.init(at: start + 0.001, code: 56, down: false, modifier: true)) }
        }
        return result.sorted { $0.at == $1.at ? (!$0.down && $1.down) : $0.at < $1.at }
    }
    // Only positions in our fixed expected sentence leave memory. The observed
    // editor body, hashes of it, arbitrary characters and key values are not logged.
    static func difference(expected: String, actual: String) -> ([Int], Int) {
        let a = Array(expected.utf16), b = Array(actual.utf16)
        guard a.count <= 256, b.count <= 1024 else { return (Array(a.indices), b.count) }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lengths[i][j] = a[i] == b[j] ? 1 + lengths[i + 1][j + 1] : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var i = 0, j = 0, matched = Set<Int>()
        while i < a.count && j < b.count {
            if a[i] == b[j] { matched.insert(i); i += 1; j += 1 }
            else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 } else { j += 1 }
        }
        return (a.indices.filter { !matched.contains($0) }, b.count - matched.count)
    }
    static func matches(_ state: AutoEditorState, _ expected: String) -> Bool {
        state.sourceMatches && (state.text == expected || state.text == expected + "\n") && state.selection == NSRange(location: expected.utf16.count, length: 0)
    }
}

final class AutoInputEngine {
    let editor: AutoTestEditor
    let clock: () -> Double
    let pause: (Double) -> Void
    let save: (AutoCaseResult) throws -> Void
    let onBegin: (AutoTestCase) throws -> Void
    let onAbort: (AutoTestCase, Int, Int, String) throws -> Void
    let scope: String
    var completed = 0
    init(editor: AutoTestEditor, scope: String, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, pause: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }, onBegin: @escaping (AutoTestCase) throws -> Void = { _ in }, onAbort: @escaping (AutoTestCase, Int, Int, String) throws -> Void = { _, _, _, _ in }, save: @escaping (AutoCaseResult) throws -> Void) {
        self.editor = editor; self.scope = scope; self.clock = clock; self.pause = pause; self.save = save; self.onBegin = onBegin; self.onAbort = onAbort
    }
    func stable(_ expected: String, timeout: Double) throws -> AutoEditorState {
        let end = clock() + timeout
        var stableSince: Double?
        var last = AutoEditorState(text: "", selection: NSRange(location: 0, length: 0))
        while clock() < end {
            try editor.check(); last = try editor.read()
            if AutoInputPlan.matches(last, expected) {
                if stableSince == nil { stableSince = clock() }
                if clock() - stableSince! >= 0.2 { return last }
            } else { stableSince = nil }
            pause(0.02)
        }
        return last
    }
    func selectOwned(_ expected: String) throws {
        guard AutoInputPlan.matches(try editor.read(), expected) else { throw AutoTestFailure.targetChanged }
        try editor.selectAll()
        let end = clock() + 1
        while clock() < end {
            try editor.check(); let state = try editor.read()
            if (state.text == expected || state.text == expected + "\n") && state.selection.location == 0 &&
                [expected.utf16.count, state.text.utf16.count].contains(state.selection.length) { return }
            pause(0.02)
        }
        throw AutoTestFailure.selectionNotVerified
    }
    func run(_ cases: [AutoTestCase]) throws {
        try editor.check()
        let initial = try stable("", timeout: 0.6)
        guard AutoInputPlan.matches(initial, "") else { throw AutoTestFailure.existingDraft }
        var owned = ""
        for item in cases {
            try onBegin(item)
            if !owned.isEmpty {
                try selectOwned(owned)
                if !item.overwrite {
                    try editor.deleteSelection()
                    guard AutoInputPlan.matches(try stable("", timeout: 2), "") else { throw AutoTestFailure.emptyNotVerified }
                }
            } else { guard AutoInputPlan.matches(try editor.read(), "") else { throw AutoTestFailure.targetChanged } }
            var held = Set<UInt16>(), downs = [Double](), upCount = 0
            do {
                let began = clock(); var last = -Double.infinity
                for edge in AutoInputPlan.edges(item.keys, gap: item.gap) {
                    while clock() - began < edge.at || clock() - last < 0.004 { try editor.check(); pause(0.0005) }
                    try editor.check()
                    let shifted = edge.modifier ? edge.down : held.contains(56)
                    try editor.send(edge, shifted: shifted)
                    if edge.down { held.insert(edge.code) } else { held.remove(edge.code) }
                    if !edge.modifier { if edge.down { downs.append(clock()) } else { upCount += 1 } }
                    last = clock()
                }
            } catch { editor.release(held); try onAbort(item, downs.count, upCount, (error as? AutoTestFailure)?.rawValue ?? "adapter_error"); throw error }
            editor.release(held)
            let state: AutoEditorState
            do { state = try stable(item.expected, timeout: 5) }
            catch { try onAbort(item, downs.count, upCount, (error as? AutoTestFailure)?.rawValue ?? "adapter_error"); throw error }
            let matched = AutoInputPlan.matches(state, item.expected)
            let observed = state.text.hasSuffix("\n") ? String(state.text.dropLast()) : state.text
            let diff = AutoInputPlan.difference(expected: item.expected, actual: observed)
            let gaps = zip(downs.dropFirst(), downs).map { ($0 - $1) * 1000 }
            let sorted = gaps.sorted(), p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
            let result = AutoCaseResult(id: item.id, expectedSynthetic: item.expected, nominalGapMilliseconds: item.gap * 1000, overwrite: item.overwrite, bodyAndCaretMatched: matched, pacingQualified: p95 <= item.gap * 2000 + 4, observedUTF16Length: observed.utf16.count, selectionLocation: state.selection.location, selectionLength: state.selection.length, missingExpectedUTF16Indices: diff.0, unexpectedUTF16Units: diff.1, postedDowns: downs.count, postedUps: upCount, actualDownGapsMilliseconds: gaps, scope: scope, inputSourceMatched: state.sourceMatches)
            try save(result); completed += 1
            guard state.sourceMatches else { throw AutoTestFailure.sourceChanged }
            guard matched else { throw AutoTestFailure.textMismatch }
            owned = item.expected; pause(0.15)
        }
    }
}
