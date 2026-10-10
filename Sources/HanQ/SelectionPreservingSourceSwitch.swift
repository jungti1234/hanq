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
            guard let source=self?.commitSource,CGPreflightPostEventAccess() else{return false}
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
        postCommitAndSelectAll = { [weak self] field in
            guard CGPreflightPostEventAccess(),let events=self?.commitSelectionEvents() else{return false}
            var pid:pid_t=0
            guard AXUIElementGetPid(field,&pid) == .success,pid>0 else{return false}
            for event in events {event.postToPid(pid)}
            return true
        }
        postSelectAll = { [weak self] field in
            guard CGPreflightPostEventAccess(),let events=self?.commitSelectionEvents() else{return false}
            var pid:pid_t=0
            guard AXUIElementGetPid(field,&pid) == .success,pid>0 else{return false}
            for event in events.dropFirst(2){event.postToPid(pid)}
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

    var postSelectAll:(AXUIElement)->Bool = {_ in false}
    var postCommitAndSelectAll:(AXUIElement)->Bool = {_ in false}
    func commitSelectionEvents()->[CGEvent]? {
        guard let source=commitSource else{return nil}
        let marker:Int64=0x48414E514155544F
        source.userData=marker
        let recipe:[(CGKeyCode,Bool,CGEventType,CGEventFlags)]=[
            (124,true,.keyDown,[]),(124,false,.keyUp,[]),
            (55,true,.flagsChanged,.maskCommand),(0,true,.keyDown,.maskCommand),
            (0,false,.keyUp,.maskCommand),(55,false,.flagsChanged,[])]
        let events=recipe.compactMap{code,down,type,flags -> CGEvent? in
            guard let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down) else{return nil}
            event.type=type;event.flags=flags
            event.setIntegerValueField(.eventSourceUserData,value:marker);return event
        }
        return events.count==recipe.count ? events:nil
    }
    /// The user explicitly requested select-all. Order its native command after
    /// composition commit, rather than racing an AX selection with the IME.
    func commitSelection(field:AXUIElement,text expectedText:String,range expectedRange:NSRange,asynchronous:Bool=false)->OSStatus {
        if pendingSelectAll != nil{return resumeSelectAll(field:field,text:expectedText,range:expectedRange)}
        guard !expectedText.isEmpty,currentSource().hasPrefix("com.apple.inputmethod.Korean.") else{return noErr}
        guard allowed() else{return -50}
        guard let current=focus() else{return AXError.cannotComplete.rawValue}
        guard CFEqual(current,field),editable(field),expectedRange==NSRange(location:0,length:expectedText.utf16.count) else{return -50}
        guard let value=text(field) else{return AXError.cannotComplete.rawValue}
        guard value==expectedText else{return -50}
        if asynchronous {
            guard postCommit(field,124) else{return -50}
            pendingSelectAll=PendingSelectAll(field:field,text:expectedText,source:currentSource(),deadline:now()+0.30,selectionPosted:false)
            trace(.commitPosted);return AXError.cannotComplete.rawValue
        }
        guard postCommitAndSelectAll(field) else{return -50}
        trace(.commitPosted);return noErr
    }
    private struct PendingSelectAll {
        let field:AXUIElement
        let text:String
        let source:String
        let deadline:Double
        var selectionPosted:Bool
    }
    private var pendingSelectAll:PendingSelectAll?
    private func resumeSelectAll(field:AXUIElement,text expectedText:String,range expectedRange:NSRange)->OSStatus {
        guard var pending=pendingSelectAll else{return -50}
        func stop(_ stage:Stage)->OSStatus {pendingSelectAll=nil;trace(stage);return -50}
        guard CFEqual(field,pending.field),expectedText==pending.text,
              expectedRange==NSRange(location:0,length:pending.text.utf16.count),
              allowed(),currentSource()==pending.source else{return stop(.changedContext)}
        guard now()<pending.deadline else{return stop(.commitUnconfirmed)}
        guard let current=focus() else{return AXError.cannotComplete.rawValue}
        guard CFEqual(current,field) else{return stop(.changedContext)}
        guard let value=text(field),let selected=range(field) else{return AXError.cannotComplete.rawValue}
        guard value==pending.text else{return stop(.changedContext)}
        if !pending.selectionPosted {
            guard Self.equal(selected,CFRange(location:pending.text.utf16.count,length:0)) else{return AXError.cannotComplete.rawValue}
            guard postSelectAll(field) else{return stop(.collapseFailed)}
            pending.selectionPosted=true;pendingSelectAll=pending
            return AXError.cannotComplete.rawValue
        }
        guard Self.equal(selected,CFRange(location:0,length:pending.text.utf16.count)) else{return AXError.cannotComplete.rawValue}
        pendingSelectAll=nil;return noErr
    }
    private struct PendingSwitch {
        let field:AXUIElement
        let text:String
        let selected:CFRange
        let source:String
        let target:String
        let deadline:Double
    }
    private var pendingSwitch:PendingSwitch?
    var isPending:Bool {pendingSwitch != nil}
    func cancelPending(){pendingSwitch=nil;pendingSelectAll=nil}
    private func resumeSwitch(_ target:String)->OSStatus {
        guard let pending=pendingSwitch else{return -50}
        func stop(_ stage:Stage)->OSStatus {pendingSwitch=nil;trace(stage);return -50}
        guard target==pending.target,allowed(),currentSource()==pending.source else{return stop(.changedContext)}
        guard now()<pending.deadline else{return stop(.commitUnconfirmed)}
        guard let current=focus() else{return AXError.cannotComplete.rawValue}
        guard CFEqual(current,pending.field) else{return stop(.changedContext)}
        guard let value=text(current),let selected=range(current) else{return AXError.cannotComplete.rawValue}
        guard value==pending.text else{return stop(.changedContext)}
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
    func select(_ target:String,asynchronous:Bool=false)->OSStatus {
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
        guard selected.length > 0 else { return fallback(.emptySelection) }
        guard Self.valid(selected, length: original.utf16.count) else { return fallback(.invalidSelection) }
        guard now() - started < 0.06 else { return fallback(.deadline) }
        guard currentSource() == source else { return fallback(.changedSource) }
        guard allowed(), let current = focus(), CFEqual(current, element),
              text(element) == original, Self.equal(range(element), selected) else { return fallback(.changedContext) }
        let collapsed=CFRange(location:selected.location,length:0)
        // AX-only collapse can leave the IME's marked text alive: it can
        // reappear on the next Korean activation. A cursor key commits it in
        // the editor. Prepare and post the full pair once, then require proof.
        guard postCommit(element,123) else { return fallback(.collapseFailed) }
        trace(.commitPosted)
        if asynchronous {
            pendingSwitch=PendingSwitch(field:element,text:original,selected:selected,source:source,target:target,deadline:now()+0.30)
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
