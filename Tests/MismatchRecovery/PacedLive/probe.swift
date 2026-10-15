import AppKit
import Carbon

@main struct PacedLiveProbe {
    static func main() { exit(run()) }
    static func run() -> Int32 {
        guard (CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && ["--continue"].contains(CommandLine.arguments[2]))),
              let pid = Int32(CommandLine.arguments[1]),
              let app = NSRunningApplication(processIdentifier: pid),
              ["taek.in.hanq.paced-live-fixture"].contains(app.bundleIdentifier ?? "") else { return 2 }
        func report(_ reason: String, _ extra: [String: Any] = [:]) -> Int32 {
            var row = extra; row["reason"] = reason; row["pid"] = pid
            let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!); return reason == "completed" ? 0 : 2
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            return report("existing_permission_missing", ["ax": AXIsProcessTrusted(), "post": CGPreflightPostEventAccess()])
        }
        guard InputSourceAccess.currentID() == "com.apple.inputmethod.Korean.2SetKorean" else {
            return report("two_set_source_required")
        }
        let mirror = KeyboardStateMirror.shared
        guard mirror.start() else { return report("state_mirror_unavailable") }
        defer { mirror.stop(); Thread.sleep(forTimeInterval: 0.05) }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func focus() -> AXUIElement? {
            guard let raw = attr(root, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! AXUIElement)
        }
        func front() -> Bool {
            CFRunLoopRunInMode(.defaultMode, 0.001, false)
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        guard app.activate(options: [.activateIgnoringOtherApps]) else { return report("activation_rejected") }
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !front(), ProcessInfo.processInfo.systemUptime < activationDeadline { Thread.sleep(forTimeInterval: 0.01) }
        let settled = ProcessInfo.processInfo.systemUptime + 0.3
        while ProcessInfo.processInfo.systemUptime < settled { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        guard front(), let field = focus(),
              ["AXTextArea", "AXTextField"].contains(attr(field, kAXRoleAttribute) as? String ?? ""),
              attr(field, kAXSubroleAttribute) as? String != "AXSecureTextField",
              attr(field, kAXValueAttribute) as? String == (CommandLine.arguments.last == "--continue" ? "앞🙂간뒤":"앞🙂뒤") else { return report("blank_test_field_required") }
        guard let source = CGEventSource(stateID: .privateState) else { return report("event_source_unavailable") }
        var held: UInt16?
        defer {
            if let held, let event = CGEvent(keyboardEventSource: source, virtualKey: held, keyDown: false) {
                event.flags = []; mirror.releasePosted(event, to: app.isTerminated ? nil : pid)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        var posted = 0
        let codes:[UInt16] = CommandLine.arguments.last == "--continue" ? [40]:[15,40,1]
        for code in codes {
            for down in [true, false] {
                guard front(), !app.isTerminated,
                      !IsSecureEventInputEnabled(), CGPreflightPostEventAccess(), mirror.ready,
                      CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate]).isEmpty,
                      let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                    return report("input_context_changed", ["postedEdges": posted])
                }
                event.flags = []
                if down { held = code }
                event.post(tap: .cghidEventTap); posted += 1
                if !down { held = nil }
                Thread.sleep(forTimeInterval: 0.008)
            }
            Thread.sleep(forTimeInterval: 0.006)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3.2
        while ProcessInfo.processInfo.systemUptime < deadline { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        guard front(), let current = focus(), CFEqual(field, current),
              let value = attr(field, kAXValueAttribute) as? String else { return report("result_context_changed") }
        // Only fixed test outputs can be emitted. Never log unexpected user input.
        let safeValue = ["앞🙂뒤", "앞🙂간뒤", "앞🙂가나뒤", "앞🙂ㄱㅏㄴ뒤", "앞🙂rks뒤"].contains(value) ? value : "unexpected"
        return report("completed", ["postedEdges": posted, "value": safeValue, "utf16Count": value.utf16.count,
                                    "sourceUnchanged": InputSourceAccess.currentID() == "com.apple.inputmethod.Korean.2SetKorean"])
    }
}
