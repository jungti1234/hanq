import AppKit
import Carbon

// Native integration fixture: controlled retained events, real product controller,
// menu action, system pasteboard and NSTextView paste. No global event tap/post.
final class CopyTrial: NSObject, NSApplicationDelegate {
    let controller = MismatchRecoveryController()
    var window: NSWindow!
    let field = NSTextView(frame: NSRect(x: 20, y: 20, width: 540, height: 150))
    var rows: [[String: Any]] = []
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let legacy = CommandLine.arguments.contains("--expect-legacy")
    @objc func copyInput() { controller.copyRetained() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "한Q 보관 입력 복사 시험"
        field.isRichText = false
        window.contentView!.addSubview(field)
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.run() }
    }
    func run() {
        let pb = NSPasteboard.general
        // Preserve all available representations in memory; never log user data.
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var lastWrite = pb.changeCount
        func check(_ ok: Bool, _ name: String) { rows.append(["check": name, "passed": ok]) }
        func event(_ code: UInt16, _ flags: CGEventFlags = [], _ down: Bool = true) -> CGEvent {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            e.flags = flags; return e
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: "보관된 입력 복사", action: #selector(copyInput), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        var posts = 0
        controller.engine.testPost = { _ in posts += 1 }
        let cases: [(String, [CGEvent], String, String)] = [
            ("digits-space-punctuation", [event(0), event(0, [], false), event(18), event(49), event(18, .maskShift), event(44, .maskShift)], "a1 !?", "a[keyCode:18][keyCode:49][keyCode:18][keyCode:44]"),
            ("shift-and-unsupported", [event(0, .maskShift), event(47), event(0, .maskCommand), event(123)], "A.[keyCode:0][keyCode:123]", "A[keyCode:47][keyCode:0][keyCode:123]"),
            ("remaining-punctuation", [event(27), event(24, .maskShift), event(33, .maskShift), event(30), event(42, .maskShift), event(41), event(39, .maskShift), event(43), event(50, .maskShift)], "-+{]|;\",~", "[keyCode:27][keyCode:24][keyCode:33][keyCode:30][keyCode:42][keyCode:41][keyCode:39][keyCode:43][keyCode:50]")
        ]
        for (name, keys, expected, old) in cases {
            controller.engine.retained = Array(keys.prefix(2))
            controller.engine.pending = Array(keys.dropFirst(2))
            controller.engine.suspended = true
            menu.performActionForItem(at: 0)
            lastWrite = pb.changeCount
            field.string = ""; field.setSelectedRange(NSRange(location: 0, length: 0)); field.paste(nil)
            let actual = field.string
            let safeActual = actual == expected || actual == old ? actual : "<unexpected clipboard content omitted>"
            rows.append(["case": name, "expected": expected, "actual": safeActual, "passed": actual == (legacy ? old : expected)])
            check(controller.engine.retained.isEmpty && controller.engine.pending.isEmpty && !controller.engine.suspended, "queue cleared after explicit copy")
        }
        controller.engine.retained = [event(18)]; controller.engine.recovering = true
        let beforeBusy = pb.changeCount
        menu.performActionForItem(at: 0)
        check(pb.changeCount == beforeBusy && controller.engine.retained.count == 1, "busy recovery refuses copy")
        controller.engine.recovering = false
        controller.engine.retained = [event(18, [], false)]; controller.engine.pending = []
        menu.performActionForItem(at: 0)
        check(pb.changeCount == lastWrite && controller.engine.retained.isEmpty, "key-up-only leaves clipboard unchanged")
        check(posts == 0, "copy never replays input")
        if pb.changeCount == lastWrite {
            pb.clearContents()
            let items = saved.map { formats -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in formats { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
            check(true, "previous clipboard restored")
        } else { check(false, "clipboard changed externally; restoration skipped") }
        let result: [String: Any] = ["legacy": legacy, "passed": rows.allSatisfy { $0["passed"] as? Bool == true }, "checks": rows]
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"), options: .atomic)
        NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let trial = CopyTrial(); app.delegate = trial
app.setActivationPolicy(.accessory); app.run()
