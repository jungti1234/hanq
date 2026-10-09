import AppKit
var checks=0;var failures=0
func check(_ b:Bool,_ name:String){checks+=1;if !b{failures+=1;print("FAIL",name)}}
func key(_ code:UInt16,_ down:Bool)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
let old=AXUIElementCreateApplication(1234),field=AXUIElementCreateApplication(5678)
let e=OnsetRecoveryEngine();let g=OnsetInputGate(marker:e.marker);g.beat();e.gate=g;e.enabled=true
var text="간 ",selection=NSRange(location:2,length:0),outside=true,reads=0,writes=0,posts=0,source=onsetKoreanID
e.testSource={source};e.testSnapshot={if outside{e.unavailableReason="not_supported_text_field";return nil};return OnsetSnapshot(element:field,text:text,selection:selection)}
e.testCanSelect={true};e.testCanReplaceText={true}
e.testOriginalSnapshot={target in reads+=1;check(CFEqual(target,field),"paused read remains on original field");return OnsetSnapshot(element:field,text:text,selection:selection)}
e.testSetRange={_,r in selection=r;return .success};e.testReplaceText={_,s in writes+=1;text=(text as NSString).replacingCharacters(in:selection,with:s);selection=NSRange(location:selection.location+s.utf16.count,length:0);return .success};e.testPost={_ in posts+=1}
e.lastEditable=OnsetSnapshot(element:old,text:"이전 본문",selection:NSRange(location:5,length:0));e.publishPassedBaseline(e.lastEditable)
e.planElement=field;e.waitingForContext=true;e.resumeIfReady(now:20)
check(e.lastEditable.map{CFEqual($0.element,field)} ?? false,"acknowledged pause refreshes current original field instead of previous trial")
for code:UInt16 in [15,40,1,49]{for down in [true,false]{check(g.receive(down ? .keyDown:.keyUp,key(code,down)) != nil,"paused original input passes");check(g.held.isEmpty,"pause baseline never holds input")}}
text="간 ㄱㅏㄴ ";selection=NSRange(location:6,length:0);outside=false
e.resumeIfReady(now:21);e.resumeIfReady(now:21.2);e.sample()
let end=Date().addingTimeInterval(0.08);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}
check(text=="간 간 " && writes==1 && posts==0,"reentry after pause has one original-target replacement without replay")
e.closeSession()
#if !HANQ_OLD_PAUSED
for mode in ["unacknowledged","retained","source_changed","selected"] {
 let x=OnsetRecoveryEngine();let gate=OnsetInputGate(marker:x.marker);gate.beat();x.gate=gate;x.enabled=true;x.planElement=field;x.waitingForContext=true;x.testSource={mode=="source_changed" ? "com.apple.keylayout.ABC":onsetKoreanID};var queried=0
 x.testOriginalSnapshot={_ in queried+=1;return OnsetSnapshot(element:field,text:"간 ",selection:NSRange(location:2,length:mode=="selected" ? 1:0))}
 if mode=="unacknowledged"{x.postedToGate=1}
 if mode=="retained"{x.retainedInput=[key(15,true)]}
 x.refreshAcknowledgedPassedBaseline()
 check(mode=="selected" ? queried==1 && x.publishedPassedBaselines.isEmpty:queried==0,"no publish/read beyond confirmation guard: \(mode)")
 x.closeSession()
}
#endif
let race=OnsetRecoveryEngine();let rg=OnsetInputGate(marker:race.marker);rg.beat();rg.configureEarly(true);race.gate=rg;race.enabled=true
_ = rg.receive(.keyDown,key(15,true));var sourceCalls=0;var raceText="ㄱㅏㄴ ";var raceRange=NSRange(location:4,length:0);var edits=0
race.testSource={sourceCalls+=1;if sourceCalls==2{_ = rg.receive(.keyUp,key(15,false));for code:UInt16 in [40,1,49]{for down in [true,false]{check(rg.receive(down ? .keyDown:.keyUp,key(code,down)) != nil,"concurrent unclaimed keys already passed")}}};return onsetKoreanID}
race.testSnapshot={OnsetSnapshot(element:field,text:raceText,selection:raceRange)};race.testCanSelect={true};race.testCanReplaceText={true};race.testSetRange={_,r in raceRange=r;return .success};race.testOriginalSnapshot={_ in OnsetSnapshot(element:field,text:raceText,selection:raceRange)};race.testReplaceText={_,s in edits+=1;raceText=s;raceRange=NSRange(location:s.utf16.count,length:0);return .success}
race.sample();check(race.enabled && rg.healthy(),"reservation race never stops an untouched session");check(raceText=="간 " && edits==1,"already-passed exact word repaired after reservation race");race.closeSession()
#if !HANQ_OLD_PAUSED
let async=OnsetRecoveryEngine();let ag=OnsetInputGate(marker:async.marker);ag.beat();async.gate=ag;async.enabled=true;var queries=0
async.testSource={onsetKoreanID};async.testSnapshot={queries+=1;return OnsetSnapshot(element:field,text:"",selection:NSRange(location:0,length:0))};async.sample();_ = ag.receive(.keyDown,key(15,true));let prior=queries
async.observeDeferredBeforeInput(.keyDown,key(40,true));check(queries==prior,"supplemental history never adds synchronous AX reads before original key delivery");async.closeSession()
#endif
print("\(failures==0 ? "PASS":"FAIL") \(checks) paused baseline and unedited reservation race assertions; no OS keys posted")
exit(failures==0 ? 0:1)
