import AppKit
import Carbon

/// The selected two-set ID can be correct while a WebKit editor still receives
/// independent jamo. Activate the verified previous source through the system
/// input switcher only for the affected right-Command round trip.
final class SafariInputActivation {
    private static let korean = "com.apple.inputmethod.Korean.2SetKorean"
    private static let english = "com.apple.keylayout.ABC"
    private static let marker: Int64 = 0x48414E5157464958 // HanQ synthetic-event namespace

    let shortcut = MismatchActivationShortcut()
    var source = InputSourceAccess.currentID
    // The mirrored Command release can reach the session after HID flags clear.
    var modifiersReleased: () -> Bool = {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty
    }
    var layout = InputSourceAccess.currentLayoutID
    var override = InputSourceAccess.currentOverrideID
    var previousIsKorean: () -> Bool = {
        let history = UserDefaults(suiteName: "com.apple.HIToolbox")?.array(forKey: "AppleInputSourceHistory") as? [[String: Any]]
        return hasPreviousTwoSet(history)
    }
    var safari: () -> NSRunningApplication? = {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.Safari" else { return nil }
        return front
    }
    var focus: () -> AXUIElement? = { nil }
    var webEditor: (AXUIElement) -> Bool = { isWebEditor($0) }
    var now = { ProcessInfo.processInfo.systemUptime }
    var failed: (String, String) -> Void = { _, _ in }
    var usedDirectSwitch: (String) -> Void = { _ in }

    private enum Phase { case release, activation }
    private struct Attempt {
        let field: AXUIElement
        let recipient: NSRunningApplication
        var phase: Phase
        var until: Double
        let limit: Double
        var retry = false
        var clearSince: Double?
    }
    private var attempt: Attempt?
    private var outboundField: AXUIElement?
    private var confirmedOutbound = false
    private var rejected: String?
    private var missedReturn: (field: AXUIElement, until: Double)?
    // Includes modifier release, two bounded acknowledgments, and the retry lead-in.
    static let maximumDuration = 1.75
    var pendingLimit: Double? { attempt?.limit }
    var pending: Bool { attempt != nil }

    static func hasPreviousTwoSet(_ history: [[String: Any]]?) -> Bool {
        guard let history, history.count >= 2 else { return false }
        return history[0]["InputSourceKind"] as? String == "Keyboard Layout" &&
            history[0]["KeyboardLayout Name"] as? String == "ABC" &&
            history[1]["InputSourceKind"] as? String == "Input Mode" &&
            history[1]["Input Mode"] as? String == korean
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func canWriteValue(_ element: AXUIElement) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable) == .success && writable.boolValue
    }

    static func isWebEditor(_ field: AXUIElement,
                            read: (AXUIElement, String) -> CFTypeRef? = attribute,
                            canWriteValue: (AXUIElement) -> Bool = canWriteValue) -> Bool {
        guard let role = read(field, kAXRoleAttribute) as? String,
              read(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
        if role == kAXComboBoxRole {
            // A web combo may be a read-only list. Only a writable text value
            // and a text selection belong to an editable combo.
            guard read(field, kAXEnabledAttribute) as? Bool == true,
                  canWriteValue(field),
                  let selection = read(field, kAXSelectedTextRangeAttribute),
                  CFGetTypeID(selection) == AXValueGetTypeID(),
                  AXValueGetType(selection as! AXValue) == .cfRange else { return false }
        } else if role != kAXTextFieldRole && role != kAXTextAreaRole {
            return false
        }
        var node = field
        for _ in 0..<16 {
            guard let parent = read(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
            if read(node, kAXRoleAttribute) as? String == "AXWebArea" { return true }
        }
        return false
    }

    func committed(_ id: String) {
        missedReturn = nil
        confirmedOutbound = outboundField != nil && id == Self.english
        if !confirmedOutbound { outboundField = nil }
    }

    func observed(_ id: String) {
        if id != Self.english { missedReturn = nil }
        if confirmedOutbound && id != Self.english {
            outboundField = nil
            confirmedOutbound = false
        }
    }

    private func issue(_ attempt: Attempt) -> String? {
        if !shortcut.canPost() { return "input_unavailable" }
        guard safari()?.processIdentifier == attempt.recipient.processIdentifier,
              let current = focus(), CFEqual(current, attempt.field) else { return "field_changed" }
        let id = source()
        if id == Self.english {
            // The OS can update its history before the TIS current-source
            // query converges. Only the previous-source lookup preceding our
            // Space down authorizes the switch. Afterwards verify its target.
            return shortcut.switchKeyPosted || previousIsKorean() ? nil : "previous_source_changed"
        }
        return (attempt.phase == .activation || attempt.retry) && id == Self.korean ? nil : "source_changed"
    }

    func cancel(_ reason: String) {
        outboundField = nil
        confirmedOutbound = false
        // The outer barrier reports switch_failed immediately after our own
        // terminal miss. Keep only that short-lived, same-field evidence.
        if reason != "switch_failed" || attempt != nil { missedReturn = nil }
        guard let attempt else { return }
        self.attempt = nil
        let stage = attempt.retry ? "safariActivationRetry" : (attempt.phase == .release ? "safariModifierRelease" : "safariInputActivation")
        failed(stage, rejected ?? reason)
        rejected = nil
        shortcut.cancel()
    }

    /// nil leaves the established direct-selection path in charge. A pending
    /// attempt belongs to the editor barrier, which keeps new keys in order.
    func select(_ target: String, field: AXUIElement) -> OSStatus? {
        guard target == Self.korean else {
            if pending { cancel("source_changed"); return -50 }
            missedReturn = nil
            confirmedOutbound = false
            outboundField = target == Self.english && safari() != nil && source() == Self.korean ? field : nil
            return nil
        }
        if attempt == nil {
            let missed = missedReturn.flatMap { now() < $0.until ? $0.field : nil }
            let previous = outboundField ?? missed
            outboundField = nil
            let wasConfirmed = confirmedOutbound || missed != nil
            missedReturn = nil
            confirmedOutbound = false
            guard let app = safari() else { return nil }
            let directReason: String?
            if previous == nil { directReason = "outbound_not_observed" }
            else if !wasConfirmed { directReason = "round_trip_unconfirmed" }
            else if previous.map({ CFEqual($0, field) }) != true { directReason = "field_changed" }
            else if source() != Self.english { directReason = "source_changed" }
            else if layout() != Self.english { directReason = "abc_layout_unconfirmed" }
            else if override() != nil { directReason = "layout_override_present" }
            else if !shortcut.configured { directReason = "shortcut_unavailable" }
            else if !shortcut.canPost() { directReason = "input_unavailable" }
            else if !previousIsKorean() { directReason = "previous_source_changed" }
            else if !webEditor(field) { directReason = "web_editor_unconfirmed" }
            else if focus().map({ CFEqual($0, field) }) != true { directReason = "field_changed" }
            else { directReason = nil }
            if let directReason {
                usedDirectSwitch(directReason)
                return nil
            }
            let began = now()
            attempt = Attempt(field: field, recipient: app, phase: .release, until: began + 0.75,
                              limit: began + Self.maximumDuration)
        }
        guard var active = attempt else { return nil }
        if let reason = rejected ?? issue(active) {
            cancel(reason)
            return -50
        }
        switch active.phase {
        case .release:
            if active.retry && source() == Self.korean {
                attempt = nil
                return noErr
            }
            let time = now()
            guard shortcut.modifiersClear(), modifiersReleased() else {
                active.clearSince = nil
                attempt = active
                if time >= active.until { cancel("modifier_release_timeout"); return -50 }
                return noErr
            }
            // Allow the released Command to settle before introducing Control.
            // Restart this interval on any intervening modifier.
            if active.clearSince == nil {
                active.clearSince = time
                attempt = active
            }
            guard time - (active.clearSince ?? time) >= 0.025 else { return noErr }
            // After a missed chord, sample the history and target again before
            // arming the next one. A late first switch must never toggle back.
            guard previousIsKorean() else { cancel("previous_source_changed"); return -50 }
            active.phase = .activation
            active.until = now() + 0.42
            attempt = active
            let status = shortcut.request(marker: Self.marker, recipient: active.recipient) { [weak self] in
                guard let self, let current = self.attempt else { return false }
                if current.retry && !self.shortcut.switchKeyPosted && self.source() == Self.korean {
                    return false
                }
                self.rejected = self.issue(current)
                return self.rejected == nil
            }
            if status != noErr { cancel("shortcut_unavailable"); return -50 }
            return noErr
        case .activation:
            if !shortcut.busy && source() == target {
                self.attempt = nil
                return noErr
            }
            guard now() >= active.until else { return noErr }
            // Repeating a previous-source shortcut is safe only while the
            // first one has fully released and ABC still precedes two-set.
            guard !shortcut.busy && shortcut.switchKeyPosted else { cancel("source_switch_timeout"); return -50 }
            guard source() == Self.english else { cancel("source_changed"); return -50 }
            guard layout() == Self.english else { cancel("abc_layout_unconfirmed"); return -50 }
            guard override() == nil else { cancel("layout_override_present"); return -50 }
            guard previousIsKorean() else { cancel("previous_source_changed"); return -50 }
            if active.retry {
                cancel("source_switch_timeout")
                missedReturn = (active.field, now() + 1.5)
                return -50
            }
            failed("safariInputActivation", "source_switch_timeout")
            shortcut.cancel()
            active.phase = .release
            active.retry = true
            active.clearSince = nil
            active.until = now() + 0.10
            attempt = active
            return noErr
        }
    }
}
