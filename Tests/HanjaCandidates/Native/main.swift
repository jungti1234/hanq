import AppKit
import InputMethodKit
import ObjectiveC
import Carbon

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    checks += 1
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func event(_ key: CGKeyCode, down: Bool = true, repeatKey: Bool = false, flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
    return event
}
final class Fixture {
    let owner = HanjaCandidatePanel()
    var commits: [String] = []
    var cancellations = 0
    var allowed = true
    func show(_ values: [String] = ["韓國", "汗國"]) {
        owner.allowed = { [unowned self] in self.allowed }
        owner.onCommit = { [unowned self] in self.commits.append($0) }
        owner.onCancel = { [unowned self] in self.cancellations += 1 }
        check(owner.show(values, at: NSPoint(x: 650, y: 650)), "product Apple panel can show supplied candidates")
    }
    @discardableResult func press(_ key: CGKeyCode, flags: CGEventFlags = []) -> HanjaCandidateEventDisposition {
        owner.receive(.keyDown, event(key, flags: flags))
    }
    var native: IMKCandidates {
        // Inspect the actual framework instance to invoke its selection path,
        // rather than calling HanQ's selection callback directly.
        Mirror(reflecting: owner).children.first(where: { $0.label == "panel" })!.value as! IMKCandidates
    }
}
func runChecks() {
func sourceIDs() -> Set<String> {
    let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    return Set(sources.compactMap { source in
        TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
    })
}
func currentSource() -> String? {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    }
}
let originalSources = sourceIDs(), originalSource = currentSource()
let originalApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
let first = Fixture(); first.show()
let sizedWindow = NSApp.windows.first { $0.isVisible && $0.contentView.map { NSStringFromClass(type(of: $0)) == "IMKUIVisualEffectView" } == true }!
check(sizedWindow.frame.height < 100, "two candidates do not leave a nine-row blank panel")
check(abs(sizedWindow.frame.minX - 650) < 1 && abs(sizedWindow.frame.maxY - 650) < 1,
    "native window top-left remains at the supplied Cocoa screen anchor")
check(first.press(18) == .consumed && first.commits == ["韓國"], "number 1 commits the first dictionary candidate")
check(first.owner.receive(.keyUp, event(18, down: false)) == .consumed, "commit key release consumed after window closes")
let arrow = Fixture(); arrow.show(); arrow.press(125)
let selector = NSSelectorFromString("selectCurrentlyFocusedItem")
typealias Commit = @convention(c) (AnyObject, Selector) -> Void
unsafeBitCast(arrow.native.method(for: selector), to: Commit.self)(arrow.native, selector)
check(arrow.commits == ["汗國"], "real Apple candidate delegate confirms the highlighted second candidate")
let second = Fixture(); second.show(); second.press(19)
check(second.commits == ["汗國"], "number 2 commits second candidate")
check(second.owner.receive(.keyDown, event(19, repeatKey: true)) == .consumed, "held confirmation does not type repeated digits")
check(second.owner.receive(.keyUp, event(19, down: false)) == .consumed, "held confirmation release consumed")
let escape = Fixture(); escape.show(); escape.press(53)
check(escape.commits.isEmpty && escape.cancellations == 1 && !escape.owner.active, "Escape cancels exactly once")
let invalidNumber = Fixture(); invalidNumber.show(); invalidNumber.press(20)
check(invalidNumber.owner.active && invalidNumber.commits.isEmpty, "unavailable numbered item cannot insert a digit")
invalidNumber.press(53)
let typing = Fixture(); typing.show()
check(typing.press(0) == .normal && typing.cancellations == 1 && typing.commits.isEmpty, "new text cancels and passes through")
let shortcut = Fixture(); shortcut.show()
check(shortcut.press(0, flags: .maskCommand) == .normal && shortcut.cancellations == 1, "Command shortcut remains available")
let changed = Fixture(); changed.show(); changed.allowed = false
check(changed.press(19) == .normal && changed.commits.isEmpty && changed.cancellations == 1, "changed input context prevents commit")
let pages = Fixture(); let values = (1...20).map { "候補\($0)" }; pages.show(values)
check(NSApp.windows.first { $0.isVisible }!.frame.height > 200, "nine visible candidates retain enough list height")
for _ in 0..<10 { pages.press(125) }
pages.press(18)
check(pages.commits == [values[9]], "numbering restarts at 1 on the second page")
let end = Fixture(); end.show(values); end.press(119); end.press(36)
check(end.commits == [values[19]], "End and Return reach last candidate across pages")
let stop = Fixture(); stop.show(); stop.press(125); stop.owner.stop()
check(stop.owner.receive(.keyUp, event(125, down: false)) == .normal && stop.cancellations == 1, "tap teardown clears held candidate keys")
let mouse = Fixture(); mouse.show()
let window = NSApp.windows.first { $0.isVisible && $0.contentView.map { NSStringFromClass(type(of: $0)) == "IMKUIVisualEffectView" } == true }!
let inside = event(0)
inside.location = CGPoint(x: window.frame.midX, y: NSScreen.screens.first!.frame.maxY - window.frame.midY)
check(mouse.owner.receive(.leftMouseDown, inside) == .panelMouse && mouse.owner.active,
    "candidate mouse click is passed to native UI without cancelling")
let outside = event(0); outside.location = CGPoint(x: -100_000, y: -100_000)
check(mouse.owner.receive(.leftMouseDown, outside) == .normal && mouse.cancellations == 1,
    "outside mouse click closes candidates and remains available")
let stale = Fixture(); stale.show()
let oldPanel = stale.native
let oldCandidate = oldPanel.value(forKey: "focusedCandidate") as! NSObject
stale.owner.close(notify: false); stale.show()
stale.owner.didSelect(oldCandidate, controller: oldPanel)
stale.owner.didFinish(oldPanel)
check(stale.commits.isEmpty && stale.owner.active, "old native callbacks cannot commit or close a new request")
stale.press(19)
check(stale.commits == ["汗國"], "current request still commits after rejecting stale callbacks")
check(!HanjaCandidatePanel().show([], at: .zero), "empty candidate list cannot show a panel")
check(!HanjaCandidatePanel().show(["韓國", "韓國"], at: .zero), "ambiguous duplicate candidate list rejected")
check(sourceIDs() == originalSources && currentSource() == originalSource, "no input source registration or switching")
check(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp,
    "native candidate windows do not activate HanQ over the user's editor")
print("PASS: \(checks) product Apple candidate panel checks; actual view/delegate, no input source changes or OS key posting")
}
final class Runner: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        runChecks()
        NSApp.terminate(nil)
    }
}
let runner = Runner()
app.delegate = runner
app.run()
