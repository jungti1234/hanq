import AppKit
import Carbon

/// Some editors commit marked Korean text over the entire selection when TIS
/// deactivates the IME. Collapse the selection for that commit, then restore it.
/// Commit through the editor's cursor key path; never rewrite text or guess a marked range.
final class SelectionPreservingSourceSwitch {
    enum Stage: String {
        case begin, unsupportedSource, permission, missingFocus, unsupportedField
        case missingText, missingSelection, emptySelection, invalidSelection, deadline
        case changedSource, changedContext, collapseFailed, collapsed, switched
        case restoreSkipped, restored, restoreFailed, commitPosted, commitUnconfirmed
    }
    private let commitSource=CGEventSource(stateID:.privateState)
    private let caretSource=CGEventSource(stateID:.hidSystemState)
    var postCommit: (AXUIElement,CGKeyCode) -> Bool = { _,_ in false }
    var trace: (Stage) -> Void = { _ in }
    private let system = AXUIElementCreateSystemWide()
    var currentSource: () -> String = InputSourceAccess.currentID
    var selectSource: (String) -> OSStatus = InputSourceAccess.select
    var allowed: () -> Bool = { AXIsProcessTrusted() && !IsSecureEventInputEnabled() }
    var focus: () -> AXUIElement? = { nil }
    var text: (AXUIElement) -> String? = { attribute($0, kAXValueAttribute) as? String }
    var range: (AXUIElement) -> CFRange? = { element in
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &result) ? result : nil
    }
    static func supportsEditableRole(_ role:String?)->Bool {
        role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }
    var editable: (AXUIElement) -> Bool = { element in
        let role = attribute(element, kAXRoleAttribute) as? String
        guard supportsEditableRole(role),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
    }
    var setRange: (AXUIElement, CFRange) -> Bool = { element, requested in
        var requested = requested
        guard let value = AXValueCreate(.cfRange, &requested) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init() {
        postCommit = { [weak self] element,key in
            guard let self, let source=self.pendingCaretCommand ? self.caretSource : self.commitSource,CGPreflightPostEventAccess() else{return false}
            var pid:pid_t=0
            guard AXUIElementGetPid(element,&pid) == .success,pid>0,
                  let down=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:true),
                  let up=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:false) else{return false}
            for event in [down,up] {
                event.flags=[];event.setIntegerValueField(.eventSourceUserData,value:0x48414E514155544F)
                event.postToPid(pid)
            }
            return true
        }
        // Bound each AX request in both the asynchronous barrier path and the
        // synchronous fallback. A cursor commit is posted once, then verified;
        // neither path sleeps or pumps the run loop.
        AXUIElementSetMessagingTimeout(system, 0.01)
        let system = self.system
        focus = {
            guard let value = Self.attribute(system, kAXFocusedUIElementAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.01)
            return element
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func equal(_ lhs: CFRange?, _ rhs: CFRange) -> Bool {
        lhs?.location == rhs.location && lhs?.length == rhs.length
    }

    static func valid(_ range: CFRange, length: Int) -> Bool {
        range.location >= 0 && range.length > 0 && range.location <= length && range.length <= length - range.location
    }

    struct TypedCaret {
        let field: AXUIElement
        let text: String
        let offset: Int
    }
    // The barrier proves text in AXStringForRange coordinates. AXValue may
    // include paragraph separators that the editor's selection offsets omit.
    var caretText: (AXUIElement, String, CFRange) -> String? = { element, value, caret in
        MismatchTextReader.read(element, value: value,
                                selection: NSRange(location: caret.location, length: caret.length))?.text
    }
    private var pendingCaretCommand = false
    private struct PendingSwitch {
        let field:AXUIElement
        let text:String
        let selected:CFRange
        let source:String
        let target:String
        let deadline:Double
        let verifiedCaretText:String?
        var restoringCaret = false
    }
    private var pendingSwitch:PendingSwitch?
    var isPending:Bool {pendingSwitch != nil}
    func cancelPending(){pendingSwitch=nil}
    private func resumeSwitch(_ target:String)->OSStatus {
        guard let pending=pendingSwitch else{return -50}
        func stop(_ stage:Stage)->OSStatus {pendingSwitch=nil;trace(stage);return -50}
        guard target==pending.target,allowed(),currentSource()==pending.source else{return stop(.changedContext)}
        guard now()<pending.deadline else{return stop(.commitUnconfirmed)}
        guard let current=focus() else{return AXError.cannotComplete.rawValue}
        guard CFEqual(current,pending.field) else{return stop(.changedContext)}
        guard let value=text(current),let selected=range(current) else{return AXError.cannotComplete.rawValue}
        guard value.utf16.elementsEqual(pending.text.utf16) else{return stop(.changedContext)}
        if let expected = pending.verifiedCaretText {
            let preceding = CFRange(location:pending.selected.location - 1,length:0)
            let from = pending.restoringCaret ? preceding : pending.selected
            let to = pending.restoringCaret ? pending.selected : preceding
            if Self.equal(selected, from) { return AXError.cannotComplete.rawValue }
            guard Self.equal(selected, to) else { return stop(.changedContext) }
            guard let verified = caretText(current, value, selected) else { return AXError.cannotComplete.rawValue }
            guard verified.utf16.elementsEqual(expected.utf16),
                  allowed(), currentSource() == pending.source,
                  let focused = focus(), CFEqual(focused, current) else { return stop(.changedContext) }
            guard now() < pending.deadline else { return stop(.commitUnconfirmed) }
            if pending.restoringCaret {
                pendingSwitch=nil
                trace(.restored)
                let status=selectSource(target)
                trace(.switched)
                return status
            }
            trace(.collapsed)
            // Only restore a displacement the editor actually acknowledged.
            guard setRange(current,pending.selected) else{return stop(.restoreFailed)}
            pendingSwitch?.restoringCaret=true
            return AXError.cannotComplete.rawValue
        }
        let collapsed=CFRange(location:pending.selected.location,length:0)
        if Self.equal(selected,pending.selected){return AXError.cannotComplete.rawValue}
        guard Self.equal(selected,collapsed) else{return stop(.changedContext)}
        pendingSwitch=nil;trace(.collapsed)
        return finishSwitch(target,source:pending.source,element:current,original:pending.text,selected:pending.selected,collapsed:collapsed)
    }
    private func finishSwitch(_ target:String,source:String,element:AXUIElement,original:String,selected:CFRange,collapsed:CFRange)->OSStatus {
        let result=selectSource(target)
        trace(.switched)
        if currentSource() == (result == noErr ? target:source),allowed(),
           let current=focus(),CFEqual(current,element),text(element)==original,
           Self.equal(range(element),collapsed) {
            trace(setRange(element,selected) ? .restored:.restoreFailed)
        }else{trace(.restoreSkipped)}
        return result
    }
    func select(_ target:String,asynchronous:Bool=false,typedCaret:TypedCaret?=nil)->OSStatus {
        if isPending{return resumeSwitch(target)}
        trace(.begin)
        let source = currentSource(), started = now()
        func fallback(_ stage:Stage)->OSStatus {trace(stage);return selectSource(target)}
        guard source.hasPrefix("com.apple.inputmethod.Korean."),source != target else{return fallback(.unsupportedSource)}
        guard allowed() else { return fallback(.permission) }
        guard let element = focus() else { return fallback(.missingFocus) }
        guard editable(element) else { return fallback(.unsupportedField) }
        guard let original = text(element), original.utf16.count <= 16_384 else { return fallback(.missingText) }
        guard let selected = range(element) else { return fallback(.missingSelection) }
        if typedCaret != nil && selected.length != 0 {
            trace(.changedContext)
            return -50
        }
        let caretCommit = selected.length == 0
        if caretCommit {
            guard asynchronous, target == "com.apple.keylayout.ABC", let typedCaret else{return fallback(.emptySelection)}
            guard CFEqual(typedCaret.field,element), typedCaret.offset == selected.location,
                  selected.location > 0, selected.location <= typedCaret.text.utf16.count else{trace(.changedContext);return -50}
        } else if !Self.valid(selected, length: original.utf16.count) {return fallback(.invalidSelection)}
        guard now() - started < 0.06 else { return fallback(.deadline) }
        guard currentSource() == source else { return fallback(.changedSource) }
        guard allowed(), let current = focus(), CFEqual(current, element),
              text(element) == original, Self.equal(range(element), selected) else { return fallback(.changedContext) }
        if let proof = typedCaret {
            guard let verified = caretText(current, original, selected),
                  verified.utf16.elementsEqual(proof.text.utf16),
                  now() - started < 0.06, allowed(), currentSource() == source,
                  let focused = focus(), CFEqual(focused, element) else {trace(.changedContext);return -50}
        }
        let collapsed=CFRange(location:selected.location,length:0)
        // AX-only collapse can leave the IME's marked text alive: it can
        // reappear on the next Korean activation. A cursor key commits it in
        // the editor. Prepare and post the full pair once, then require proof.
        pendingCaretCommand=caretCommit
        defer {pendingCaretCommand=false}
        guard postCommit(element,123) else { return fallback(.collapseFailed) }
        trace(.commitPosted)
        if asynchronous {
            pendingSwitch=PendingSwitch(field:element,text:original,selected:selected,source:source,target:target,deadline:now()+0.30,verifiedCaretText:typedCaret?.text)
            return AXError.cannotComplete.rawValue
        }
        let commitDeadline=now()+0.04
        var committed=false
        repeat {
            guard allowed(),currentSource()==source else{trace(.changedContext);return -50}
            // Committing marked text can temporarily make AX attributes
            // unavailable. A missing reply is not proof of a changed context.
            guard let current=focus() else{continue}
            guard CFEqual(current,element) else{trace(.changedContext);return -50}
            guard let value=text(element) else{continue}
            guard value==original else{trace(.changedContext);return -50}
            if Self.equal(range(element),collapsed){committed=true;break}
        } while now()<commitDeadline
        // After posting, never race an unacknowledged cursor key with a source
        // switch or restore stale coordinates. Report failure instead.
        guard committed else{trace(.commitUnconfirmed);return -50}
        trace(.collapsed)
        // An AX selection change may itself commit composition. Never restore
        // stale coordinates if that changed the text, focus, or selection.
        return finishSwitch(target,source:source,element:element,original:original,selected:selected,collapsed:collapsed)
    }
}
