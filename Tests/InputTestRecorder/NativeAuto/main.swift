import AppKit
import Carbon

final class NativeEditor: AutoTestEditor {
    let window: NSWindow
    let field: NSTextView
    init(window: NSWindow, field: NSTextView) { self.window = window; self.field = field }
    func check() throws {
        guard NSApp.isActive, window.isKeyWindow, window.firstResponder === field else { throw AutoTestFailure.targetChanged }
    }
    func read() throws -> AutoEditorState { try check(); return .init(text: field.string, selection: field.selectedRange()) }
    func send(_ edge: AutoTestEdge, shifted: Bool) throws {
        try check()
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: edge.code, keyDown: edge.down) else { throw AutoTestFailure.cancelled }
        event.flags = shifted ? CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02) : []
        if edge.modifier { event.type = .flagsChanged }
        guard let native = NSEvent(cgEvent: event) else { throw AutoTestFailure.cancelled }
        if edge.modifier { field.flagsChanged(with: native) }
        else if edge.down { field.keyDown(with: native) } else { field.keyUp(with: native) }
    }
    func selectAll() throws { try check(); field.selectAll(nil) }
    func deleteSelection() throws { try check(); field.deleteBackward(nil) }
    func release(_ held: Set<UInt16>) { /* Owned local events do not change global key state. */ }
}
final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!, field: NSTextView!
    var original: TISInputSource?
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    func applicationDidFinishLaunching(_ notification: Notification) {
        original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: "com.apple.inputmethod.Korean.2SetKorean"] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        guard let source = list.first, TISSelectInputSource(source) == noErr else { finish("source_unavailable", []); return }
        window = NSWindow(contentRect: NSRect(x: 160, y: 250, width: 720, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Owned native IME automatic-engine test"
        field = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 300)); field.isAutomaticTextReplacementEnabled = false; field.isAutomaticSpellingCorrectionEnabled = false; field.isAutomaticQuoteSubstitutionEnabled = false; field.isAutomaticDashSubstitutionEnabled = false
        window.contentView = field; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.run() }
    }
    func run() {
        let adapter = NativeEditor(window: window, field: field); var rows = [AutoCaseResult]()
        do {
            let engine = AutoInputEngine(editor: adapter, scope: "owned-native-local-ime", pause: { seconds in
                CFRunLoopRunInMode(.defaultMode, max(seconds, 0.0001), false)
            }) { result in rows.append(result); print("case", result.id, result.bodyAndCaretMatched, result.pacingQualified); fflush(stdout) }
            try engine.run(AutoInputPlan.cases()); finish("completed", rows)
        } catch { finish((error as? AutoTestFailure)?.rawValue ?? "error", rows) }
    }
    func finish(_ reason: String, _ rows: [AutoCaseResult]) {
        field?.inputContext?.discardMarkedText(); let restored = original.map { TISSelectInputSource($0) == noErr } ?? false
        let encoded = try! JSONEncoder().encode(rows); let cases = try! JSONSerialization.jsonObject(with: encoded)
        let result: [String: Any] = ["reason": reason, "cases": cases, "restored": restored, "globalKeys": false, "chatgptTested": false]
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        NSApp.terminate(nil)
    }
}
guard CommandLine.arguments.count == 2 else { exit(2) }
let app = NSApplication.shared; app.setActivationPolicy(.regular); let fixture = Fixture(); app.delegate = fixture; app.run()
