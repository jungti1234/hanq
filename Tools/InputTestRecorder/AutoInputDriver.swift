import AppKit
import ApplicationServices
import Carbon

struct AutoAXFailure: Error {
    let attribute: String
    let code: Int
}

// This adapter is constructed only after a human presses Start and selects the
// empty composer. Merely launching the app never reads or controls ChatGPT.
final class UserStartedChatGPTEditor: AutoTestEditor {
    static let targetBundle = "com.openai.codex"
    static let marker: Int64 = 0x4851545445535401
    let application: NSRunningApplication
    let accessibility: AXUIElement
    let field: AXUIElement
    private let eventSource = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var cancelled = false
    private let originalSource: String
    var product: NSRunningApplication?
    static func sourceID() -> String {
        if !Thread.isMainThread { return DispatchQueue.main.sync { sourceID() } }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    static func frontApplication() -> NSRunningApplication? {
        if Thread.isMainThread { return NSWorkspace.shared.frontmostApplication }
        return DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
    }
    static func permissions() -> Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    static func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        _ = CGRequestPostEventAccess()
    }
    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success, let value else { throw AutoAXFailure(attribute: name, code: Int(result.rawValue)) }
        return value
    }
    init() throws {
        guard !ProcessInfo.processInfo.arguments.contains("--self-test") else { throw AutoTestFailure.cancelled }
        guard Self.permissions() else { throw AutoTestFailure.permission }
        guard !IsSecureEventInputEnabled() else { throw AutoTestFailure.secureInput }
        guard let app = Self.frontApplication(), app.bundleIdentifier == Self.targetBundle, !app.isTerminated else { throw AutoTestFailure.wrongApplication }
        application = app; accessibility = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(accessibility, 0.06)
        let value = try Self.attribute(accessibility, kAXFocusedUIElementAttribute)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw AutoTestFailure.unreadableEditor }
        field = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.06)
        let role = try Self.attribute(field, kAXRoleAttribute) as? String
        guard role == kAXTextAreaRole else { throw AutoTestFailure.unreadableEditor }
        originalSource = Self.sourceID()
        guard originalSource == "com.apple.inputmethod.Korean.2SetKorean" else { throw AutoTestFailure.sourceChanged }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stop = cancelled; lock.unlock()
        guard !stop else { throw AutoTestFailure.cancelled }
        guard !CGEventSource.keyState(.combinedSessionState, key: 53) else { throw AutoTestFailure.cancelled }
        guard product?.isTerminated != true else { throw AutoTestFailure.productExited }
        guard !application.isTerminated, application.bundleIdentifier == Self.targetBundle,
              Self.frontApplication()?.processIdentifier == application.processIdentifier else { throw AutoTestFailure.wrongApplication }
        guard !IsSecureEventInputEnabled() else { throw AutoTestFailure.secureInput }
    }
    private func sameFocus() throws {
        let current = try Self.attribute(accessibility, kAXFocusedUIElementAttribute)
        guard CFGetTypeID(current) == AXUIElementGetTypeID(), CFEqual(current, field) else { throw AutoTestFailure.targetChanged }
    }
    func read() throws -> AutoEditorState {
        try check(); try sameFocus()
        guard let text = try Self.attribute(field, kAXValueAttribute) as? String, text.utf16.count <= 1024 else { throw AutoTestFailure.unreadableEditor }
        let selected = try Self.attribute(field, kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(selected) == AXValueGetTypeID() else { throw AutoTestFailure.unreadableEditor }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(selected, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { throw AutoTestFailure.unreadableEditor }
        // A legitimate HanQ repair may briefly select another source. Let the
        // bounded result wait observe restoration instead of cancelling it.
        return AutoEditorState(text: text, selection: NSRange(location: range.location, length: range.length), sourceMatches: Self.sourceID() == originalSource)
    }
    private func post(_ code: UInt16, down: Bool, flags: CGEventFlags = [], modifier: Bool = false) throws {
        try check()
        if down && !modifier { try sameFocus() }
        guard let source = eventSource, let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw AutoTestFailure.permission }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        // HanQ assigns its own delivery-origin token only to untagged input.
        // Keep ordinary test presses untagged and identify our process via its
        // actual creator PID in the observation monitor, never as hardware/HanQ.
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        event.post(tap: .cghidEventTap)
    }
    func send(_ edge: AutoTestEdge, shifted: Bool) throws {
        // No Return, keypad Enter, Tab, navigation or arbitrary key API is
        // exposed to the plan. The scheduled keys come from fixed sentences.
        guard ![UInt16(36), 76, 48].contains(edge.code) else { throw AutoTestFailure.cancelled }
        let shift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
        try post(edge.code, down: edge.down, flags: shifted ? shift : [], modifier: edge.modifier)
    }
    func selectAll() throws {
        try check(); try sameFocus()
        try post(0, down: true, flags: [.maskCommand])
        do { Thread.sleep(forTimeInterval: 0.012); try post(0, down: false) }
        catch { release([0]); throw error }
    }
    func deleteSelection() throws {
        try post(51, down: true)
        do { Thread.sleep(forTimeInterval: 0.012); try post(51, down: false) }
        catch { release([51]); throw error }
    }
    func release(_ held: Set<UInt16>) {
        // Release-only cleanup cannot type into another application. Original
        // presses remain owned by the original receiver after cancellation.
        for code in held.sorted() {
            guard !application.isTerminated else { return }
            guard let source = eventSource, let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            if code == 56 { event.type = .flagsChanged }
            event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.postToPid(application.processIdentifier)
        }
    }
}
