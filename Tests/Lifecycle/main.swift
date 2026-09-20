import AppKit
import ApplicationServices

// Exercises the production teardown with a Mach port/run-loop source, without
// installing a global event tap or changing Accessibility permissions.
let owner = AppDelegate()
owner.enabled = true
owner.koreanEnabled = true
owner.hanjaEnabled = true
_ = owner.filter.process(type: .flagsChanged, key: 54,
    flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10), acceptNewPress: true)
_ = owner.optionFilter.process(type: .flagsChanged, key: 61,
    flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40), acceptNewPress: true)
var context = CFMachPortContext()
let port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil)!
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
owner.tap = port
owner.tapSource = source
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
owner.stopMapping()
precondition(!owner.enabled && !owner.koreanEnabled && !owner.hanjaEnabled)
precondition(owner.tap == nil && owner.tapSource == nil)
precondition(!CFMachPortIsValid(port) && !CFRunLoopSourceIsValid(source))
precondition(!owner.filter.consuming && !owner.optionFilter.consuming)
owner.stopMapping()
let flags = CGEventFlags.maskCommand
let result = owner.filter.process(type: .keyDown, key: 0, flags: flags, acceptNewPress: false)
precondition(!result.consume && result.flags == flags)
print("PASS: production teardown releases port/source, clears held keys, passes input, and is idempotent")

// A restriction must remove the real input hook and prevent every activation route.
_ = NSApplication.shared
owner.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
owner.enabled = true; owner.koreanEnabled = true; owner.hanjaEnabled = true
let prefs = UserDefaults.standard
let before = [prefs.object(forKey: "koreanKeyEnabled"), prefs.object(forKey: "hanjaKeyEnabled")]
owner.setUpdateRestricted(true)
owner.startMapping()
owner.toggleKorean(); owner.toggleHanja()
precondition(owner.updateRestricted && !owner.enabled && owner.tap == nil)
precondition(!owner.pendingActivation && !owner.toggleItem.isEnabled && !owner.hanjaItem.isEnabled)
precondition(String(describing: before) == String(describing: [prefs.object(forKey: "koreanKeyEnabled"), prefs.object(forKey: "hanjaKeyEnabled")]))
NSStatusBar.system.removeStatusItem(owner.statusItem)
print("PASS: mandatory-update restriction disables input, blocks reactivation and preserves preferences")

precondition(owner.updater.responds(to: NSSelectorFromString("updater:didFinishLoadingAppcast:")))
precondition(owner.updater.responds(to: NSSelectorFromString("allowedChannelsForUpdater:")))
print("PASS: Sparkle optional delegate callbacks use the expected Objective-C selectors")
