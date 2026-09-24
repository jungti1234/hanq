import AppKit
import ApplicationServices
import Carbon

/// Uses a normal Paste action so the receiving editor owns one undo operation.
/// Editors that do not expose a readable value and writable selection are skipped.
final class JamoRepair {
    private var revision = 0
    private var busy = false
    var isEditing: Bool { busy || watchingHanja }
    var canBeginEdit: () -> Bool = { true }
    private let marker: Int64 = 0x454F5448
    private var hanjaWatchID = 0
    private var watchingHanja = false
    private var confirmationRevision: Int?

    private enum Action {
        case paste(String)
        case hanja
    }

    func inputDidChange(type: CGEventType? = nil, key: Int64 = -1, flags: CGEventFlags = []) {
        revision += 1
        guard watchingHanja else { return }
        switch HanjaReplacement.input(type: type, key: key, flags: flags) {
        case .confirm:
            confirmationRevision = revision
        case .navigate:
            confirmationRevision = nil
        case .cancel:
            cancelHanjaWatch()
        }
    }

    func inputSourceDidChange() {
        revision += 1
        cancelHanjaWatch()
    }

    private func cancelHanjaWatch() {
        hanjaWatchID += 1
        watchingHanja = false
        confirmationRevision = nil
    }

    func request(allowHanja: Bool) {
        InputDiagnostics.shared.record("한자 요청: allowed=\(allowHanja) busy=\(busy)")
        guard AXIsProcessTrusted(), !busy, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let inputSourceID = InputSourceSnapshot.read()?.id
        cancelHanjaWatch()
        revision += 1
        let expectedRevision = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, AXIsProcessTrusted(), self.revision == expectedRevision,
                  InputSourceSnapshot.read()?.id == inputSourceID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !IsSecureEventInputEnabled() else { return }
            guard self.canBeginEdit() else { return }
            self.perform(pid: pid, allowHanja: allowHanja, inputSourceID: inputSourceID)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else {
            if name == kAXFocusedUIElementAttribute || name == kAXValueAttribute || name == kAXSelectedTextRangeAttribute {
                NSLog("자모 AX 읽기 실패: %@ error=%d", name, error.rawValue)
            }
            return nil
        }
        return value
    }

    private func selection(_ element: AXUIElement) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setSelection(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
            AXValueCreate(.cfRange, &value)!) == .success
    }

    private func perform(pid: pid_t, allowHanja: Bool, inputSourceID: String?, readAttempt: Int = 0) {
        guard AXIsProcessTrusted(), !busy, InputSourceSnapshot.read()?.id == inputSourceID else { return }
        InputDiagnostics.shared.record("자모 요청: 접근성 읽기 시작")
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            retryRead(app: app, pid: pid, allowHanja: allowHanja, inputSourceID: inputSourceID, attempt: readAttempt)
            return
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard (attribute(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return }
        guard let text = attribute(element, kAXValueAttribute) as? String,
              let originalSelection = selection(element),
              originalSelection.location <= (text as NSString).length,
              originalSelection.length <= (text as NSString).length - originalSelection.location else {
            retryRead(app: app, pid: pid, allowHanja: allowHanja, inputSourceID: inputSourceID, attempt: readAttempt)
            return
        }
        // Some editors expose an active IME composition. Leave it to the IME.
        if let rawMarked = attribute(element, "AXMarkedTextRange"), CFGetTypeID(rawMarked) == AXValueGetTypeID() {
            var marked = CFRange()
            if AXValueGetValue(rawMarked as! AXValue, .cfRange, &marked), marked.length > 0 {
                InputDiagnostics.shared.record("자모 조합 생략: 입력기 조합 중")
                return
            }
        }
        guard var range = JamoComposer.targetRange(in: text, selection: originalSelection) else { return }
        let original = (text as NSString).substring(with: range)
        let replacement = JamoComposer.compose(original)
        let action: Action
        let koreanSourceID = KoreanEnglishSwitch.romanSourceID(for: InputSourceSnapshot.read())
        let layout = KoreanKeyboardLayout.resolve(sourceID: koreanSourceID)
        if let romanReplacement = JamoComposer.selectedRomanReplacement(in: text, selection: originalSelection, layout: layout) {
            action = .paste(romanReplacement)
        } else if replacement.utf8.elementsEqual(original.utf8) {
            guard allowHanja,
                  let hanjaRange = JamoComposer.hanjaTargetRange(in: text, selection: originalSelection) else { return }
            range = hanjaRange
            action = .hanja
        } else {
            action = .paste(replacement)
        }
        let isHanja: Bool
        if case .hanja = action { isHanja = true } else { isHanja = false }
        InputDiagnostics.shared.record("변환 선택 준비: hanja=\(isHanja) selected=\(originalSelection.length > 0)")
        var writable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &writable) == .success,
              writable.boolValue,
              InputSourceSnapshot.read()?.id == inputSourceID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !IsSecureEventInputEnabled(),
              (attribute(element, kAXValueAttribute) as? String) == text,
              selection(element) == originalSelection,
              attribute(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, element) }) == true,
              setSelection(element, range) else {
            InputDiagnostics.shared.record("변환 중단: 선택 설정 또는 입력 상태 재확인 실패")
            return
        }
        busy = true
        let expectedRevision = revision
        waitForSelection(element, app: app, pid: pid, text: text, range: range,
                         originalSelection: originalSelection, action: action,
                         expectedRevision: expectedRevision, inputSourceID: inputSourceID, attempt: 0)
    }

    /// Chromium/Electron may not publish their editable accessibility tree until
    /// an assistive client requests it. Retry briefly, without blocking the tap.
    private func retryRead(app: AXUIElement, pid: pid_t, allowHanja: Bool, inputSourceID: String?, attempt: Int) {
        guard attempt < 3 else {
            InputDiagnostics.shared.record("자모 조합 생략: 접근성 준비 후에도 텍스트 또는 선택 범위를 읽을 수 없음")
            return
        }
        if attempt == 0 {
            for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                let result = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
                InputDiagnostics.shared.record("자모 접근성 준비: \(name) result=\(result.rawValue)")
            }
        }
        let expectedRevision = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.revision == expectedRevision,
                  InputSourceSnapshot.read()?.id == inputSourceID,
                  AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.perform(pid: pid, allowHanja: allowHanja, inputSourceID: inputSourceID, readAttempt: attempt + 1)
        }
    }

    private func waitForSelection(_ element: AXUIElement, app: AXUIElement, pid: pid_t,
                                  text: String, range: NSRange, originalSelection: NSRange,
                                  action: Action, expectedRevision: Int, inputSourceID: String?, attempt: Int) {
        // AX selection setters can return before the editor reflects the new range.
        // Do not abandon the transaction with only its selection step applied.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            let stillFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && self.attribute(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, element) }) == true
            let unchanged = (self.attribute(element, kAXValueAttribute) as? String)
                .map { $0.utf8.elementsEqual(text.utf8) } == true
            guard AXIsProcessTrusted(), stillFocused, unchanged, self.revision == expectedRevision,
                  InputSourceSnapshot.read()?.id == inputSourceID,
                  !IsSecureEventInputEnabled() else {
                InputDiagnostics.shared.record("변환 중단: 선택 대기 중 입력 상태 변경")
                self.busy = false
                return
            }
            if self.selection(element) == range {
                switch action {
                case .paste(let replacement):
                    self.pasteReplacement(element, pid: pid, text: text, range: range,
                                          originalSelection: originalSelection, replacement: replacement)
                case .hanja:
                    // Wait for AX to reflect the selection before opening the
                    // native candidates. The IME owns replacement and Escape.
                    self.postHanja(pid)
                    InputDiagnostics.shared.record("한자 후보 요청 전송: 선택 확인 완료")
                    self.busy = false
                    self.watchHanjaResult(element, app: app, pid: pid, text: text, range: range)
                }
            } else if attempt < 10 {
                self.waitForSelection(element, app: app, pid: pid, text: text, range: range,
                                      originalSelection: originalSelection, action: action,
                                      expectedRevision: expectedRevision, inputSourceID: inputSourceID, attempt: attempt + 1)
            } else {
                NSLog("변환 중단: 선택 반영 시간 초과")
                _ = self.setSelection(element, originalSelection)
                self.busy = false
            }
        }
    }

    private func watchHanjaResult(_ element: AXUIElement, app: AXUIElement, pid: pid_t,
                                  text: String, range: NSRange) {
        cancelHanjaWatch()
        watchingHanja = true
        let watchID = hanjaWatchID
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        guard let source = InputSourceSnapshot.read()?.id else { cancelHanjaWatch(); return }
        var stableValue: String?
        var stableRevision: Int?
        var confirmationStarted: TimeInterval?
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.watchingHanja, self.hanjaWatchID == watchID else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else { self.cancelHanjaWatch(); return }
                // No editor polling while the user is merely browsing candidates.
                guard let confirmed = self.confirmationRevision else { poll(); return }
                if stableRevision != confirmed {
                    stableValue = nil
                    stableRevision = confirmed
                    confirmationStarted = ProcessInfo.processInfo.systemUptime
                }
                guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      InputSourceSnapshot.read()?.id == source,
                      self.attribute(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, element) }) == true,
                      let current = self.attribute(element, kAXValueAttribute) as? String,
                      let caret = self.selection(element) else { self.cancelHanjaWatch(); return }
                if current.utf8.elementsEqual(text.utf8) {
                    if ProcessInfo.processInfo.systemUptime - (confirmationStarted ?? 0) < 1 { poll() }
                    else { self.cancelHanjaWatch() }
                    return
                }
                guard let correction = HanjaReplacement.correction(original: text, target: range,
                                                                    current: current, selection: caret) else {
                    self.cancelHanjaWatch()
                    return
                }
                // Do not edit a candidate preview or an active IME composition.
                if let raw = self.attribute(element, "AXMarkedTextRange"), CFGetTypeID(raw) == AXValueGetTypeID() {
                    var marked = CFRange()
                    if AXValueGetValue(raw as! AXValue, .cfRange, &marked), marked.length > 0 {
                        stableValue = nil
                        poll()
                        return
                    }
                }
                guard stableValue.map({ $0.utf8.elementsEqual(current.utf8) }) == true else {
                    stableValue = current
                    poll()
                    return
                }
                self.cancelHanjaWatch()
                guard self.revision == confirmed, !self.busy,
                      self.setSelection(element, correction.range) else { return }
                self.busy = true
                InputDiagnostics.shared.record("한자 호환 보정: 원문 뒤 추가 확인")
                self.waitForSelection(element, app: app, pid: pid, text: current, range: correction.range,
                                      originalSelection: caret, action: .paste(correction.replacement),
                                      expectedRevision: confirmed, inputSourceID: source, attempt: 0)
            }
        }
        poll()
    }

    private func pasteReplacement(_ element: AXUIElement, pid: pid_t, text: String,
                                  range: NSRange, originalSelection: NSRange, replacement: String) {
        guard AXIsProcessTrusted() else { busy = false; return }
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        clipboard.clearContents()
        guard clipboard.setString(replacement, forType: .string) else {
            _ = setSelection(element, originalSelection); busy = false; return
        }
        let ownedChange = clipboard.changeCount
        busy = true
        postKey(9, flags: .maskCommand, pid: pid)
        let expected = (text as NSString).replacingCharacters(in: range, with: replacement)
        // Restore only our clipboard generation, after the editor has consumed it.
        func finish(_ attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                let value = self.attribute(element, kAXValueAttribute) as? String
                let unchanged = value.map { $0.utf8.elementsEqual(text.utf8) } == true
                if unchanged, attempt < 30 { finish(attempt + 1); return }
                if clipboard.changeCount == ownedChange {
                    clipboard.clearContents()
                    let items = saved.map { entries -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (type, data) in entries { item.setData(data, forType: type) }
                        return item
                    }
                    if !items.isEmpty { clipboard.writeObjects(items) }
                }
                if unchanged, self.selection(element) == range,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    _ = self.setSelection(element, originalSelection)
                }
                if value.map({ $0.utf8.elementsEqual(expected.utf8) }) != true { NSLog("자모 조합: 편집기 적용을 확인하지 못했습니다.") }
                self.busy = false
            }
        }
        finish(0)
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.postToPid(pid)
        }
    }

    private func postHanja(_ pid: pid_t) { postKey(36, flags: .maskAlternate, pid: pid) }
}
