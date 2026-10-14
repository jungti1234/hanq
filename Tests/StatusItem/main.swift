import AppKit

if CommandLine.arguments.contains("--notify") {
    StatusItemController.requestRunningInstanceRepair()
    exit(0)
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--preview") {
    let notice = MenuBarRecoveryNotice { print("Preview feedback action; no browser opened") }
    notice.show()
    NSApp.run()
    exit(0)
}
var time: TimeInterval = 0
var traces: [String] = []
let resource = CommandLine.arguments[1]
let controller = StatusItemController(now: { time }, loadImage: { NSImage(contentsOfFile: resource) })
controller.trace = { traces.append($0) }
let menu = NSMenu()
let action = NSMenuItem(title: "한Q 상태 검사", action: nil, keyEquivalent: "")
action.state = .on
menu.addItem(action)
controller.start(menu: menu)
let original = controller.item!
precondition(original.button?.image?.isTemplate == true && original.button?.title == "")
precondition(original.menu === menu && original.isVisible)
let savedName = original.autosaveName
let positionKey = "NSStatusItem Preferred Position " + savedName!
let priorPosition = UserDefaults.standard.object(forKey: positionKey)
defer {
    if let priorPosition { UserDefaults.standard.set(priorPosition, forKey: positionKey) }
    else { UserDefaults.standard.removeObject(forKey: positionKey) }
}
controller.setDisabled(true)
original.isVisible = false
controller.check()
precondition(original.isVisible && controller.item === original)
print("PASS: app-level hidden flag recovers without replacing the registration")

original.button?.image = nil
original.button?.title = ""
original.length = 0
original.menu = nil
controller.check()
precondition(original.button?.image != nil && original.length == NSStatusItem.variableLength)
precondition(original.menu === menu && original.button?.appearsDisabled == true)
print("PASS: empty content, collapsed length and menu loss repair in place")

controller.requestRefresh(reason: "screens-changed")
time = 1
controller.requestRefresh(reason: "screens-wake")
time = 29
controller.check()
precondition(controller.item === original)
controller.setMenuOpen(true)
time = 31
controller.check()
precondition(controller.item === original)
controller.setMenuOpen(false)
// Real AppKit removal clears the position; the name alone did not preserve it.
UserDefaults.standard.set(420, forKey: positionKey)
controller.check()
let replacement = controller.item!
precondition(replacement !== original && original.menu == nil)
precondition(replacement.menu === menu && replacement.menu?.items.first === action && action.state == .on)
precondition(replacement.autosaveName == savedName && replacement.button?.appearsDisabled == true)
precondition(UserDefaults.standard.integer(forKey: positionKey) == 420)
print("PASS: display/wake burst coalesces, open menu defers recovery, identity and menu state survive")
print("PASS: AppKit removal preserves the stored menu-bar position")

// Actual removal leaves isVisible=true and the button alive on macOS 15.
// Recover that registration even though checking isVisible alone cannot help.
NSStatusBar.system.removeStatusItem(replacement)
time = 32
controller.check()
time = 35
controller.check()
time = 62
controller.check()
precondition(controller.item !== replacement && controller.item?.menu === menu)
let repairedWindow = controller.item!
print("PASS: externally removed registration recovers despite its stale visible flag")

// System hiding/overflow may expose the same window state. After one attempt,
// a continuously hidden item must not be recreated on every timer tick.
for instant in [63.0, 120.0, 600.0] {
    time = instant
    repairedWindow.button?.window?.orderOut(nil)
    controller.check()
    precondition(controller.item === repairedWindow)
}
print("PASS: continuously hidden windows do not cause repeated registrations")

NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
time = 603
controller.check()
precondition(controller.item !== repairedWindow)
let afterDisplay = controller.item!
controller.requestRefresh(reason: "reopen")
time = 634
controller.check()
precondition(controller.item !== afterDisplay && controller.item?.menu === menu)
print("PASS: real display notification and explicit reopen request re-register the item")

controller.requestRefresh(reason: "wake")
UserDefaults.standard.set(430, forKey: positionKey)
controller.stop()
precondition(UserDefaults.standard.integer(forKey: positionKey) == 430)
time = 1000
controller.check()
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
precondition(controller.item == nil)
precondition(traces.filter { $0.hasPrefix("status.register") }.count == 5)
print("PASS: termination cancels pending recovery and notification observers")

var burst = MenuBarReopenAttempts()
precondition(!burst.record(at: 0) && !burst.record(at: 1) && burst.record(at: 2))
precondition(!burst.record(at: 3) && !burst.record(at: 4))
precondition(!burst.record(at: 65) && !burst.record(at: 66) && burst.record(at: 67))
var rolling = MenuBarReopenAttempts()
precondition(!rolling.record(at: 0) && !rolling.record(at: 40) && !rolling.record(at: 61))
precondition(rolling.record(at: 62))
print("PASS: third reopen explains once per burst, stale attempts expire and a new burst rearms")

let userRepair = StatusItemController(now: { time }, loadImage: { NSImage(contentsOfFile: resource) })
userRepair.trace = { traces.append($0) }
var notices = 0
userRepair.onRepeatedUserLaunch = { notices += 1 }
userRepair.start(menu: menu)
let initiallyHealthy = userRepair.item!
userRepair.requestUserRepair()
let firstRepair = userRepair.item!
precondition(firstRepair !== initiallyHealthy && firstRepair.menu === menu)
precondition(notices == 0)
// Even a healthy-looking item is replaced on first explicit reopen, immediately
// after startup; the background 30s cooldown must not delay this user request.
time += 0.2
userRepair.requestUserRepair()
time += 0.2
userRepair.requestUserRepair()
precondition(notices == 0 && userRepair.item === firstRepair)
time += 1.6
userRepair.check()
let afterBurst = userRepair.item!
precondition(afterBurst !== firstRepair && notices == 1)
time += 0.1
userRepair.requestUserRepair()
time += 0.1
userRepair.requestRefresh(reason: "screens-changed")
time += 0.1
userRepair.requestUserRepair()
time += 1.7
userRepair.check()
precondition(userRepair.item !== afterBurst && notices == 1)
print("PASS: healthy-looking explicit reopen bypasses automatic cooldown, rapid repeats coalesce without starvation")

userRepair.setMenuOpen(true)
time += 70
let trackingItem = userRepair.item!
for _ in 0..<3 { userRepair.requestUserRepair() }
precondition(userRepair.item === trackingItem && notices == 1)
userRepair.setMenuOpen(false)
userRepair.check()
precondition(userRepair.item !== trackingItem && notices == 2)
print("PASS: open menu defers explicit repair and the third-attempt notice until tracking ends")

time += 70
let beforeDuplicate = userRepair.item!
let sender = Process()
sender.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
sender.arguments = ["--notify"]
try sender.run()
let deadline = Date().addingTimeInterval(3)
while userRepair.item === beforeDuplicate && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
sender.waitUntilExit()
precondition(sender.terminationStatus == 0 && userRepair.item !== beforeDuplicate)
precondition(notices == 2)
userRepair.stop()
print("PASS: separate duplicate-launch process forwards repair to the existing UI only")

var feedbackCalls = 0
let notice = MenuBarRecoveryNotice { feedbackCalls += 1 }
notice.show()
let firstPanel = notice.panel!
notice.show()
precondition(notice.panel === firstPanel && firstPanel.isVisible)
func buttons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
}
let noticeButtons = buttons(in: firstPanel.contentView!)
let feedbackButton = noticeButtons.first { $0.title == "피드백 남기기…" }!
feedbackButton.performClick(nil)
precondition(feedbackCalls == 1 && !firstPanel.isVisible)
print("PASS: nonmodal notice reuses one panel and its feedback button invokes the existing feedback action")

let fallback = StatusItemController(loadImage: { nil })
fallback.trace = { _ in }
fallback.start(menu: NSMenu())
precondition(fallback.item?.button?.title == "한Q" && fallback.item?.button?.imagePosition == .noImage)
precondition(fallback.item?.button?.toolTip == "한Q")
fallback.stop()
print("PASS: missing PDF has visible text fallback and accessibility metadata")
