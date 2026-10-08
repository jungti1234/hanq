import AppKit

/// Keyboard focus can belong to a non-activating panel (for example Spotlight),
/// while NSWorkspace still reports the application underneath it as frontmost.
/// Never fall back to that application's remembered field when system focus
/// positively identifies another process.
final class InputFocusAccess {
    let system = AXUIElementCreateSystemWide()
    var read: (AXUIElement) -> AXUIElement? = InputFocusAccess.readFocused
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    init() { AXUIElementSetMessagingTimeout(system, 0.05) }

    static func readFocused(_ root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func owner(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    func currentPID() -> pid_t? {
        if let element = read(system) { return Self.owner(of: element) }
        return frontmostPID()
    }

    func currentApplication() -> NSRunningApplication? {
        currentPID().flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    func focusedElement(application: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let element = read(system) {
            guard Self.owner(of: element) == pid else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            return element
        }
        // Some editors expose focus only on the application AX root. This
        // fallback is valid only for the actual frontmost application.
        guard frontmostPID() == pid, let element = read(application),
              Self.owner(of: element) == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }
}
