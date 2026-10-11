import AppKit
import InputMethodKit
import ObjectiveC

@objc(HanQCandidateInputController)
final class HanQCandidateInputController: IMKInputController {}

enum HanjaCandidateEventDisposition { case normal, consumed, panelMouse }

/// Apple's candidate view, fed by HanQ rather than the Korean IME. No input
/// source is installed or selected. Private callbacks are checked before use.
final class HanjaCandidatePanel: NSObject {
    private static var server: IMKServer?
    private var panel: IMKCandidates?
    private weak var nativeWindow: NSWindow?
    private var callbackController: NSObject?
    private var selection = HanjaCandidateSelection(candidates: [])
    private var nativeCandidates: [NSObject] = []
    private var anchor = NSPoint.zero
    private var updating = false
    private var ownedKeys = Set<Int64>()
    private(set) var active = false
    var allowed: () -> Bool = { false }
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private static func signature(_ types: String) -> String { types.filter { !$0.isNumber } }
    private static func method(_ cls: AnyClass, _ name: String, _ types: String) -> Bool {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              let encoding = method_getTypeEncoding(method) else { return false }
        return signature(String(cString: encoding)) == types
    }

    private static var supported: Bool {
        guard let contract = objc_getProtocol("IMKCandidatesDelegate") else { return false }
        let expected: [String: String] = [
            "candidateSelected:candidateController:": "v@:@@",
            "candidateSelectionChanged:candidateController:": "v@:@@",
            "didShowCandidates:": "v@:@", "didHideCandidates:": "v@:@",
            "didUpdateCandidates:": "v@:@", "didFinishInteracting:": "v@:@",
            "didSelectSortingMode:candidateController:": "v@:@@",
            "firstVisibleLineForCandidateController:": "Q@:@",
            "selectedCandidateForProposedCandidate:candidateController:": "@@:@@",
            "windowPositionForController:proposedSize:": "{CGPoint=dd}@:@{CGSize=dd}"
        ]
        var found = Set<String>()
        for required in [true, false] {
            var count: UInt32 = 0
            guard let methods = protocol_copyMethodDescriptionList(contract, required, true, &count) else { continue }
            defer { free(methods) }
            for index in 0..<Int(count) {
                let description = methods[index]
                guard let name = description.name, let types = description.types,
                      expected[NSStringFromSelector(name)] == signature(String(cString: types)) else { return false }
                found.insert(NSStringFromSelector(name))
            }
        }
        guard found == Set(expected.keys) else { return false }
        return method(IMKCandidates.self, "setDelegate:", "v@:@")
            && method(IMKCandidates.self, "visibleCandidates", "@@:")
            && method(IMKCandidates.self, "setFocusedCandidate:", "v@:@")
            && method(IMKCandidates.self, "setNumberOfFixedSizeCandidates:", "v@:Q")
    }

    func show(_ values: [String], at point: NSPoint) -> Bool {
        guard Self.supported, !values.isEmpty, values.count <= 128,
              values.allSatisfy({ !$0.isEmpty }), Set(values).count == values.count,
              Bundle.main.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String == "HanQCandidateInputController",
              let identifier = Bundle.main.bundleIdentifier else { return false }
        if Self.server == nil {
            Self.server = IMKServer(name: "taek.in.hanq.candidates." + UUID().uuidString, bundleIdentifier: identifier)
        }
        guard let server = Self.server else { return false }
        panel = IMKCandidates(server: server, panelType: kIMKSingleColumnScrollingCandidatePanel)
        guard let panel else { return false }
        selection = HanjaCandidateSelection(candidates: values)
        anchor = point
        active = true
        updating = true
        panel.setValue(self, forKey: "delegate")
        let result = updatePage()
        updating = false
        if !result { close(notify: false); return false }
        return true
    }

    private func candidateText(_ object: NSObject) -> String? {
        guard Self.method(type(of: object), "text", "@@:") else { return nil }
        let text = object.value(forKey: "text")
        return (text as? String) ?? (text as? NSAttributedString)?.string
    }

    private func updatePage() -> Bool {
        guard let panel else { return false }
        updating = true
        defer { updating = false }
        let page = selection.page
        let selector = NSSelectorFromString("setNumberOfFixedSizeCandidates:")
        typealias SetCount = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(panel.method(for: selector), to: SetCount.self)(panel, selector, UInt(page.count))
        panel.setCandidateData(page)
        panel.show()
        callbackController = panel
        guard let objects = panel.value(forKey: "visibleCandidates") as? [NSObject],
              objects.compactMap(candidateText) == page else { return false }
        nativeCandidates = objects
        guard nativeCandidates.indices.contains(selection.index - selection.pageStart) else { return false }
        panel.setValue(nativeCandidates[selection.index - selection.pageStart], forKey: "focusedCandidate")
        nativeWindow = NSApp.windows.first { window in
            window.isVisible && window.contentView.map { NSStringFromClass(type(of: $0)) == "IMKUIVisualEffectView" } == true
        }
        if let window = nativeWindow {
            window.setFrameTopLeftPoint(position(panel, size: window.frame.size))
        }
        return panel.isVisible() && nativeWindow != nil
    }

    private func updateFocus(oldPage: Int) {
        guard let panel else { return }
        if oldPage != selection.pageStart {
            if !updatePage() { close(notify: true) }
        } else if nativeCandidates.indices.contains(selection.index - selection.pageStart) {
            panel.setValue(nativeCandidates[selection.index - selection.pageStart], forKey: "focusedCandidate")
        }
    }

    func receive(_ type: CGEventType, _ event: CGEvent) -> HanjaCandidateEventDisposition {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, ownedKeys.remove(code) != nil { return .consumed }
        if !active, type == .keyDown, ownedKeys.contains(code),
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return .consumed }
        guard active else { return .normal }
        guard allowed() else { close(notify: true); return .normal }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            let point = NSPoint(x: event.location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
            if type == .leftMouseDown, nativeWindow?.frame.contains(point) == true { return .panelMouse }
            close(notify: true)
            return .normal
        }
        let modified = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        if modified { close(notify: true); return .normal }
        guard type == .keyDown else { return .normal }
        let oldPage = selection.pageStart
        switch HanjaCandidateSelection.key(code) {
        case .number(let number):
            ownedKeys.insert(code)
            if selection.selectOnPage(number) { commit(selection.selected) }
        case .move(let delta):
            ownedKeys.insert(code); selection.move(delta); updateFocus(oldPage: oldPage)
        case .first:
            ownedKeys.insert(code); selection.move(-selection.index); updateFocus(oldPage: oldPage)
        case .last:
            ownedKeys.insert(code); selection.move(selection.candidates.count); updateFocus(oldPage: oldPage)
        case .confirm:
            ownedKeys.insert(code); commit(selection.selected)
        case .cancel:
            ownedKeys.insert(code); close(notify: true)
        case .other:
            close(notify: true); return .normal
        }
        return .consumed
    }

    private func commit(_ value: String?) {
        guard active, allowed(), let value, selection.candidates.contains(value) else { close(notify: true); return }
        let callback = onCommit
        close(notify: false)
        callback?(value)
    }

    func close(notify: Bool) {
        let wasActive = active
        active = false
        let retired = panel
        retired?.setValue(nil, forKey: "delegate")
        retired?.hide()
        // A native mouse callback can still be unwinding. Retain its controller
        // until the next main turn before dropping its candidate data.
        DispatchQueue.main.async { retired?.setCandidateData([]) }
        panel = nil
        nativeCandidates = []
        callbackController = nil
        selection = HanjaCandidateSelection(candidates: [])
        let callback = onCancel
        onCancel = nil; onCommit = nil
        if wasActive && notify { callback?() }
    }
    func stop() { close(notify: true); ownedKeys.removeAll() }

    @objc(candidateSelected:candidateController:)
    func didSelect(_ candidate: NSObject, controller: AnyObject) {
        guard controller === callbackController, nativeCandidates.contains(where: { $0 === candidate }) else { return }
        commit(candidateText(candidate))
    }
    @objc(candidateSelectionChanged:candidateController:)
    func didChange(_ candidate: NSObject, controller: AnyObject) {
        if !updating, controller === callbackController, nativeCandidates.contains(where: { $0 === candidate }),
           let value = candidateText(candidate) { _ = selection.select(value) }
    }
    @objc(didShowCandidates:) func didShow(_ controller: AnyObject) {}
    @objc(didHideCandidates:) func didHide(_ controller: AnyObject) {
        if active && !updating && controller === callbackController { close(notify: true) }
    }
    @objc(didUpdateCandidates:) func didUpdate(_ controller: AnyObject) {}
    @objc(didFinishInteracting:) func didFinish(_ controller: AnyObject) {
        if active && !updating && controller === callbackController { close(notify: true) }
    }
    @objc(didSelectSortingMode:candidateController:) func didSort(_ mode: AnyObject, controller: AnyObject) {}
    @objc(firstVisibleLineForCandidateController:) func firstLine(_ controller: AnyObject) -> UInt { 0 }
    @objc(selectedCandidateForProposedCandidate:candidateController:)
    func selected(_ candidate: AnyObject, controller: AnyObject) -> AnyObject { candidate }
    @objc(windowPositionForController:proposedSize:)
    func position(_ controller: AnyObject, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return anchor }
        return NSPoint(x: max(bounds.minX, min(anchor.x, bounds.maxX - size.width)),
                       y: max(bounds.minY + size.height, min(anchor.y, bounds.maxY)))
    }
}
