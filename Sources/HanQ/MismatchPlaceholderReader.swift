import AppKit
import Carbon

/// Some web editors expose generated prompt text in AXValue and AXStringForRange.
/// In the empty editor its only text is a read-only decoration. Typed text,
/// including a literal copy of the prompt, belongs to the editable paragraph.
struct MismatchPlaceholderReader {
    enum Surface { case prompt, input }

    var attributes: (AXUIElement, [String]) -> [CFTypeRef?] = { element, names in
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
              let values = result as? [AnyObject] else { return [] }
        return values
    }
    var onlyChild: (AXUIElement) -> AXUIElement? = { element in
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 2, &values) == .success,
              let children = values as? [AnyObject], children.count == 1,
              CFGetTypeID(children[0]) == AXUIElementGetTypeID() else { return nil }
        let child = children[0] as! AXUIElement
        AXUIElementSetMessagingTimeout(child, 0.02)
        return child
    }
    var writable: (AXUIElement, String) -> Bool? = { element, name in
        var result: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success else { return nil }
        return result.boolValue
    }

    // A range-based snapshot can omit a final AX display newline. Compare the
    // complete text otherwise, without changing editable offsets.
    private func sameDisplay(_ value: String?, _ text: String) -> Bool {
        guard let value else { return false }
        return value.utf16.elementsEqual(text.utf16)
            || (value.utf16.last == 10 && value.utf16.dropLast().elementsEqual(text.utf16))
            || (text.utf16.last == 10 && text.utf16.dropLast().elementsEqual(value.utf16))
    }

    func confirms(_ surface: Surface, field: AXUIElement, window: AXUIElement, text: String, selection: NSRange,
                  available: () -> Bool = { true }) -> Bool {
        let context = [kAXRoleAttribute, kAXSubroleAttribute, kAXWindowAttribute, kAXValueAttribute, kAXSelectedTextRangeAttribute]
        let hints = surface == .prompt ? ["AXPlaceholderValue", kAXTitleAttribute, kAXDescriptionAttribute] : []
        func sameContext(_ values: [CFTypeRef?]) -> Bool {
            guard values.count >= context.count, let role = values[0] as? String, [kAXTextAreaRole, kAXTextFieldRole].contains(role),
                  values[1] as? String != kAXSecureTextFieldSubrole, let ownerWindow = values[2], CFEqual(ownerWindow, window),
                  sameDisplay(values[3] as? String, text), let raw = values[4], CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            var caret = CFRange()
            return AXValueGetValue(raw as! AXValue, .cfRange, &caret) && caret.location == selection.location && caret.length == 0
        }
        guard available(), !text.isEmpty, selection.length == 0 else { return false }
        let values = attributes(field, context + hints)
        guard values.count == context.count + hints.count, sameContext(values) else { return false }
        if surface == .prompt {
            let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, values.dropFirst(context.count).contains(where: {
                ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).utf16.elementsEqual(label.utf16) == true
            }) else { return false }
        }
        // Follow one bounded branch of this field only. Siblings could contain
        // real draft content. Unsupported attributes never count as read-only.
        var branch = [field]
        for _ in 0..<6 {
            guard available(), let parent = branch.last, let child = onlyChild(parent) else { return false }
            branch.append(child)
            let data = attributes(child, [kAXRoleAttribute, kAXValueAttribute])
            guard data.count == 2, let role = data[0] as? String else { return false }
            if role == kAXStaticTextRole {
                let editable = surface == .input
                guard available(), sameDisplay(data[1] as? String, text),
                      writable(child, kAXValueAttribute) == editable, writable(child, kAXSelectedTextRangeAttribute) == editable else { return false }
                // Chromium can expose the decoration directly inside an
                // editable paragraph. The leaf carrying the whole value is
                // read-only in that case too; a typed copy is writable.
                // A provider can replace the decoration with an editable leaf
                // spelling the very same text while these IPCs are in flight.
                for (ancestor, expected) in zip(branch, branch.dropFirst()) {
                    guard available(), let current = onlyChild(ancestor), CFEqual(current, expected) else { return false }
                }
                return available() && sameContext(attributes(field, context))
            }
            guard role == kAXGroupRole else { return false }
        }
        return false
    }

    private static let queue = DispatchQueue(label: "hanq.return-placeholder", qos: .userInitiated)

    static func request(_ surface: Surface, field: AXUIElement, window: AXUIElement, text: String, selection: NSRange,
                        until deadline: Double, completion: @escaping (Bool) -> Void) {
        queue.async {
            func verify() -> Bool {
                func available() -> Bool { ProcessInfo.processInfo.systemUptime < deadline && !IsSecureEventInputEnabled() }
                guard available(), let pid = InputFocusAccess.owner(of: field) else { return false }
                let app = AXUIElementCreateApplication(pid), focus = InputFocusAccess()
                AXUIElementSetMessagingTimeout(app, 0.05)
                guard let current = focus.focusedElement(application: app, pid: pid), CFEqual(current, field),
                      Self().confirms(surface, field: current, window: window, text: text, selection: selection, available: available),
                      available(), let final = focus.focusedElement(application: app, pid: pid) else { return false }
                return CFEqual(final, current) && available()
            }
            let result = verify()
            DispatchQueue.main.async { completion(result) }
        }
    }
}
