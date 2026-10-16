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
owner.statusIcon.start(menu: NSMenu())
owner.enabled = true; owner.koreanEnabled = true; owner.hanjaEnabled = true
let prefs = UserDefaults.standard
let before = [prefs.object(forKey: "koreanKeyEnabled"), prefs.object(forKey: "hanjaKeyEnabled")]
owner.setUpdateRestricted(true)
owner.startMapping()
owner.toggleKorean(); owner.toggleHanja()
precondition(owner.updateRestricted && !owner.enabled && owner.tap == nil)
precondition(!owner.pendingActivation && !owner.toggleItem.isEnabled && !owner.hanjaItem.isEnabled)
precondition(String(describing: before) == String(describing: [prefs.object(forKey: "koreanKeyEnabled"), prefs.object(forKey: "hanjaKeyEnabled")]))
owner.statusIcon.stop()
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


// Exercise the production onset -> source barrier -> retained-input wiring,
// with owned snapshots and a mocked sender (no taps, OS posts or source changes).
do {
 let b=owner.sourceSwitchBarrier,field=AXUIElementCreateApplication(12345)
 let previousRetained=owner.mismatchRecovery.engine.retained
 for missing in [false,true] {
  b.fail("test_cleanup")
  var text="",range=NSRange(location:0,length:0),source="com.apple.keylayout.ABC",time=0.0,posts=0
  b.now={time};b.ready={true};b.source={source};b.read={.init(field:field,text:text,selection:range)};b.readFocus={field}
  b.select={source=$0;return noErr}
  b.beginOnsetReplay(field:field,before:"",caret:0)
  let inputSource=CGEventSource(stateID:.privateState)!;inputSource.userData=0x4852000100000011
  let original=CGEvent(keyboardEventSource:inputSource,virtualKey:0,keyDown:true)!;original.flags=[];original.timestamp=100
  b.observeBeforeOnset(.keyDown,original,waiting:true)
  let receipt=original.copy()!;receipt.timestamp=200
  if !missing {owner.onsetRecovery.didProcessPhysicalKey(receipt,true);text="a";range=NSRange(location:1,length:0)}
  precondition(b.request("com.apple.inputmethod.Korean.2SetKorean"))
  let next=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!;next.flags=[]
  precondition(b.receive(.keyDown,next))
  b.send={event in posts+=1;precondition(!b.receive(event.type,event));b.observe(event.type,event);text=b.expected!.0;range=b.expected!.1}
  for _ in 0..<5 {b.step()}
  if missing {time=1.1;b.step()}
  precondition(posts==(missing ? 0:1),"production callback must release only proved input once")
  precondition(owner.mismatchRecovery.engine.retained.count==previousRetained.count+(missing ? 1:0),"source-boundary retention reaches production retained store only for unproved delivery")
  owner.mismatchRecovery.engine.retained=previousRetained
 }
 b.fail("test_cleanup")
}
print("PASS: production onset identity handoff resumes retimestamped delivery; missing proof retains original once; no OS posts")

if let index=CommandLine.arguments.firstIndex(of:"--diagnose-input-incidents"),index+1<CommandLine.arguments.count {
    owner.markInputIncident()
    InputIncidentTrace.shared.flush()
    let directory=URL(fileURLWithPath:CommandLine.arguments[index+1])
    let files=try! FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
    precondition(!files.isEmpty,"production marker action must persist a metadata incident")
    print("PASS: production incident marker action and diagnostic-enabled lifecycle, no global taps or posts")
}

// A failed boundary must settle observed modifier state without performing the
// deferred action. A retained key is still retained, never posted to the editor.
for initialSource in ["com.apple.keylayout.ABC",mismatchKoreanID] {
 for code: Int64 in [54,61] {
  let app=AppDelegate(),field=AXUIElementCreateApplication(34567),b=app.sourceSwitchBarrier
  var time=0.0,posts=0,switches=0
  b.now={time};b.ready={true};b.source={initialSource};b.readFocus={field}
  b.read={.init(field:field,text:"abc",selection:NSRange(location:3,length:0))}
  b.send={_ in posts+=1};b.select={_ in switches+=1;return noErr}
  let held=CGEventFlags(rawValue:code==54 ? CGEventFlags.maskCommand.rawValue|0x10:CGEventFlags.maskAlternate.rawValue|0x40)
  if code==54 {_=app.filter.process(type:.flagsChanged,key:code,flags:held,acceptNewPress:true)}
  else {_=app.optionFilter.process(type:.flagsChanged,key:code,flags:held,acceptNewPress:true)}
  b.observe(.keyDown,observedKey(0)) // Force a pre-existing unacknowledged insertion.
  precondition(b.request(initialSource==mismatchKoreanID ? "com.apple.keylayout.ABC":mismatchKoreanID))
  let up=observedKey(CGKeyCode(code));up.type = .flagsChanged;up.flags=[]
  precondition(b.receive(.flagsChanged,up))
  time=1.1;b.step()
  precondition(!b.busy && posts==0 && switches==0 && app.mismatchRecovery.engine.retained.count==1)
  let next=code==54 ? app.filter.process(type:.flagsChanged,key:code,flags:held,acceptNewPress:true):app.optionFilter.process(type:.flagsChanged,key:code,flags:held,acceptNewPress:true)
  precondition(next.edge=="right-down","failed boundary must not swallow the next right modifier press")
 }
}
print("PASS: failed boundaries settle observed Command/Option releases in both source directions without posting or switching")

// Do not invent a release when the physical key remains down, or turn a
// deferred re-press into a new action while cleaning up an aborted queue.
for repress in [false,true] {
 let app=AppDelegate(),b=app.sourceSwitchBarrier,field=AXUIElementCreateApplication(45678)
 let held=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10)
 b.read={.init(field:field,text:"abc",selection:NSRange(location:3,length:0))};b.readFocus={field};b.source={mismatchKoreanID}
 _=app.filter.process(type:.flagsChanged,key:54,flags:held,acceptNewPress:true)
 precondition(b.request("com.apple.keylayout.ABC"))
 if repress {
  let up=observedKey(54);up.type = .flagsChanged;up.flags=[];precondition(b.receive(.flagsChanged,up))
  let down=observedKey(54);down.type = .flagsChanged;down.flags=held;precondition(b.receive(.flagsChanged,down))
 } else {
  let letter=observedKey(0);letter.flags=held;precondition(b.receive(.keyDown,letter))
 }
 b.fail("focus_changed")
 let repeated=app.filter.process(type:.flagsChanged,key:54,flags:held,acceptNewPress:true)
 precondition(repeated.edge==nil && app.filter.consuming == !repress)
 _=app.filter.process(type:.flagsChanged,key:54,flags:[],acceptNewPress:true)
 precondition(app.filter.process(type:.flagsChanged,key:54,flags:held,acceptNewPress:true).edge=="right-down")
}
print("PASS: aborted queues preserve a genuinely held key and do not activate a deferred re-press")

// Registered external language and Hanja keys must settle their per-device
// state too, without issuing either action or posting the retained input.
do {
 let suite="taek.in.hanq.boundary-release-tests.\(UUID().uuidString)"
 // Use an independent suite; never touch saved user profiles.
 let isolated=UserDefaults(suiteName:suite)!
 defer {isolated.removePersistentDomain(forName:suite)}
 let profiles=ExternalKeyboardProfiles(defaults:isolated)
 profiles.save(.init(korean:.init(keyCode:61),hanja:.init(keyCode:62)),for:"fixture")
 let device=ExternalKeyboardDevice(registryID:100,identity:"fixture",name:"Fixture",external:true)
 let controller=ExternalKeyboardController(profiles:profiles,devices:.init(snapshot:[100:device]))
 func physical(_ code:CGKeyCode,_ flags:CGEventFlags)->CGEvent {
  let event=observedKey(code);event.type = .flagsChanged;event.flags=flags
  event.setIntegerValueField(CGEventField(rawValue:87)!,value:100);event.setIntegerValueField(.eventSourceUnixProcessID,value:0)
  return event
 }
 for code:CGKeyCode in [61,62] {
  let app=AppDelegate();app.externalKeyboards=controller
  let b=app.sourceSwitchBarrier,field=AXUIElementCreateApplication(56789)
  let held=CGEventFlags(rawValue:code==61 ? CGEventFlags.maskAlternate.rawValue|0x40:CGEventFlags.maskControl.rawValue|0x2000)
  let down=physical(code,held)
  precondition(controller.process(type:.flagsChanged,event:down,active:true,koreanAllowed:true,hanjaAllowed:true).consume)
  b.read={.init(field:field,text:"abc",selection:NSRange(location:3,length:0))};b.readFocus={field};b.source={mismatchKoreanID}
  precondition(b.request("com.apple.keylayout.ABC"));precondition(b.receive(.flagsChanged,physical(code,[])))
  b.fail("deadline")
  precondition(!controller.consuming && app.mismatchRecovery.engine.retained.count==1)
  let next=controller.process(type:.flagsChanged,event:down,active:true,koreanAllowed:true,hanjaAllowed:true)
  precondition(next.consume && (code != 61 || next.korean))
  _=controller.process(type:.flagsChanged,event:physical(code,[]),active:false,koreanAllowed:false,hanjaAllowed:false)
 }
}
print("PASS: retained releases settle registered per-device modifiers without a language or Hanja action")

// A divergent editor cancels before the next physical key, balancing the
// already suppressed right release without retaining or replaying text.
do {
 let app=AppDelegate()
 let b=app.sourceSwitchBarrier,field=AXUIElementCreateApplication(45678)
 var text="",range=NSRange(location:0,length:0),selections=0
 b.read={.init(field:field,text:text,selection:range)};b.source={"com.apple.keylayout.ABC"};b.ready={true};b.select={_ in selections+=1;return noErr}
 b.observe(.keyDown,observedKey(0));text="external";range=NSRange(location:8,length:0)
 let down=CGEvent(keyboardEventSource:nil,virtualKey:54,keyDown:true)!;down.type = .flagsChanged;down.flags=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10)
 precondition(app.filter.process(type:.flagsChanged,key:54,flags:down.flags,acceptNewPress:true).edge=="right-down")
 precondition(b.request(mismatchKoreanID));b.step()
 let up=down.copy()!;up.flags=[];precondition(b.receive(.flagsChanged,up))
 precondition(!b.receive(.keyDown,observedKey(11)) && !b.busy && selections==0)
 precondition(!app.filter.consuming && app.mismatchRecovery.engine.retained.isEmpty)
 precondition(app.filter.process(type:.flagsChanged,key:54,flags:down.flags,acceptNewPress:true).edge=="right-down")
 print("PASS: divergent switch cancellation passes original input and settles product right Command state without text retention")
}
