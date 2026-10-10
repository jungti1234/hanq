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

// The onset replay bypasses the main tap, but must still feed source-boundary
// prediction once. A subsequent physical vowel/final continues its composition.
do {
 let app=AppDelegate(), field=AXUIElementCreateApplication(23456)
 let b=app.sourceSwitchBarrier, c=app.onsetRecovery
 var text="abc ㄱ",range=NSRange(location:5,length:0),source=mismatchKoreanID,ready=false
 b.read={.init(field:field,text:text,selection:range)};b.readFocus={field};b.source={source};b.ready={ready}
 b.applySelection={_,r in range=r;return true};b.commitSelection={_ in noErr}
 b.select={source=$0;return noErr}
 c.launchEngine={$0.enabled=true};c.replaceStoppedEngine()
 let engine=c.engine!
 engine.testPost={_ in};engine.testSource={source}
 engine.willBeginRepair()
 engine.willReplay(field,"abc ",4)
 var plan=OnsetRecoveryPlan(before:"abc ",caret:4);plan.codes=[(15,false)];plan.roman="ㄱ";plan.allowSingle=true
 engine.currentPlan=plan;engine.replayStarted=true
 precondition(engine.post(observedKey(15)))
 let physicalVowel=observedKey(40)
 b.observeBeforeOnset(.keyDown,physicalVowel,waiting:true)
 precondition(b.expected?.0=="abc ㄱ","main tap defers key that the onset gate may hold")
 // The downstream mismatch handler can strip its token; timestamp remains.
 physicalVowel.setIntegerValueField(.eventSourceUserData,value:0)
 engine.didProcessPhysicalKey(physicalVowel,false)
 precondition(engine.post(observedKey(40)))
 precondition(b.expected?.0=="abc 가","posted onset and held vowel replace old prediction exactly once")
 ready=true
 let final=observedKey(2)
 b.observeBeforeOnset(.keyDown,final,waiting:true)
 engine.didProcessPhysicalKey(final,true)
 engine.didProcessPhysicalKey(final,true)
 precondition(b.expected?.0=="abc 강","physical final consonant continues replayed composition")
 let all=observedKey(0);all.flags = .maskCommand
 b.observe(.keyDown,all);b.step()
 precondition(range.length==0,"posting alone cannot authorize select-all before editor text")
 text="abc 강";range=NSRange(location:5,length:0)
 b.step();b.step();b.step()
 precondition(!b.busy && range==NSRange(location:0,length:5),"one select-all after onset replay completes at acknowledged body")
 precondition(b.request("com.apple.keylayout.ABC"));b.step();b.step()
 b.observe(.keyDown,observedKey(0))
 precondition(b.expected?.0=="a","source switch and replacement preserve post-onset selected range")
 b.fail("test_end");engine.enabled=false;engine.replayStarted=false
}
print("PASS: production onset replay handoff, continuing final, delayed editor, select-all, source switch and replacement")

precondition(MismatchRecoveryEngine.supportsSnapshotRole("AXComboBox",includeContent:true,allowComboBox:true))
precondition(!MismatchRecoveryEngine.supportsSnapshotRole("AXComboBox",includeContent:true,allowComboBox:false),"automatic mismatch recovery scope remains unchanged")
precondition(!MismatchRecoveryEngine.supportsSnapshotRole("AXComboBox",includeContent:false,allowComboBox:true),"combo cannot bypass text/range validation through role-only snapshot")
precondition(!MismatchRecoveryEngine.supportsSnapshotRole("AXPopUpButton",includeContent:true,allowComboBox:true),"menu-only controls are not text editors")
precondition(SelectionPreservingSourceSwitch.supportsEditableRole("AXComboBox"))
precondition(!SelectionPreservingSourceSwitch.supportsEditableRole("AXPopUpButton"))
print("PASS: combo source boundary requires content/range validation without widening automatic mismatch detection")
