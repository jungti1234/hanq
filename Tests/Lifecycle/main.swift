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

// Product repair paths must never edit the same field concurrently.
let combined=AppDelegate()
combined.koreanEnabled=false
precondition(!combined.mismatchRecovery.engine.canToggleRightCommand())
combined.koreanEnabled=true
precondition(combined.mismatchRecovery.engine.canToggleRightCommand())
combined.mismatchRecovery.engine.recovering=true
precondition(!combined.onsetRecovery.canBeginRepair())
combined.mismatchRecovery.engine.recovering=false
let onset=OnsetRecoveryEngine();combined.onsetRecovery.engine=onset
onset.recovering=true
precondition(!combined.mismatchRecovery.engine.canObserve())
precondition(!combined.mismatchRecovery.engine.canBeginRepair())
onset.recovering=false
precondition(combined.mismatchRecovery.engine.canObserve())
precondition(combined.mismatchRecovery.engine.canBeginRepair())
print("PASS: product onset/mismatch exclusion and right Command preference")

// A tagged/session-level right Command may bypass the HID boundary gate.
// The primary mapping must still queue a user boundary instead of switching
// relative to recovery's temporary ABC input source.
let transition=AppDelegate()
let recovery=transition.mismatchRecovery.engine
recovery.recovering=true;recovery.recoverySourceID=mismatchKoreanID
recovery.intendedSource=mismatchKoreanID
recovery.testSource={"com.apple.keylayout.ABC"}
var directSwitches=0
transition.selectionSourceSwitch.selectSource={_ in directSwitches+=1;return noErr}
precondition(transition.switchInputSource(to:mismatchKoreanID)==noErr)
precondition(recovery.intendedSource==recovery.englishID && directSwitches==0)
precondition(transition.switchInputSource(to:mismatchKoreanID)==noErr)
precondition(recovery.intendedSource==mismatchKoreanID && directSwitches==0)
recovery.recovering=false
transition.selectionSourceSwitch.currentSource={"com.apple.keylayout.ABC"}
precondition(transition.switchInputSource(to:mismatchKoreanID)==noErr && directSwitches==1)
print("PASS: primary source switch honors recovery intent, queues each boundary once and preserves normal switching")

// A queued switch has not changed the editor's source. Its preceding Korean
// candidate must remain available while the barrier waits for that repair.
let waiting=AppDelegate(), waitingField=AXUIElementCreateApplication(12345)
let detector=waiting.mismatchRecovery.engine
var waitingText="",waitingRange=NSRange(location:0,length:0),waitingSource=mismatchKoreanID
let boundary=waiting.sourceSwitchBarrier
boundary.read={.init(field:waitingField,text:waitingText,selection:waitingRange)}
boundary.source={waitingSource};boundary.ready={true}
boundary.select={waitingSource=$0;return noErr}
func observedKey(_ code:CGKeyCode)->CGEvent {
    let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!
    event.flags=[];return event
}
boundary.observe(.keyDown,observedKey(2));boundary.observe(.keyDown,observedKey(40))
var preceding=MismatchRecoveryPlan(before:"",caret:0)
_ = preceding.append(code:2,shift:false);_ = preceding.append(code:40,shift:false)
detector.plan=preceding;detector.planElement=waitingField
waitingText="ㅇㅏ";waitingRange=NSRange(location:2,length:0)
precondition(waiting.switchInputSource(to:"com.apple.keylayout.ABC",at:1000)==noErr)
precondition(detector.plan?.replayRoman=="dk" && detector.lastUserSourceSwitchTimestamp==0,
             "queued switch must preserve preceding repair detection until editor acknowledgment")
boundary.step()
precondition(waitingSource==mismatchKoreanID && detector.plan != nil)
waitingText="아";waitingRange=NSRange(location:1,length:0)
boundary.step()
precondition(waitingSource=="com.apple.keylayout.ABC" && detector.plan==nil && detector.lastUserSourceSwitchTimestamp==1000)
boundary.fail("test_end")
print("PASS: queued user switch preserves preceding Korean candidate and advances timestamp only at verified source change")
