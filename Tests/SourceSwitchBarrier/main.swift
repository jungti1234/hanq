import AppKit
import Carbon
var checks=0
func check(_ value:Bool,_ label:String){checks+=1;if !value{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
func key(_ code:CGKeyCode,_ flags:CGEventFlags=[])->CGEvent {let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!;e.flags=flags;return e}
let en="com.apple.keylayout.ABC",ko="com.apple.inputmethod.Korean.2SetKorean"
let field=AXUIElementCreateApplication(123),other=AXUIElementCreateApplication(456)
do {
 let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0),source=en,switches=0,posts=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));check(b.expected?.0=="a","predict previous English key")
 check(b.request(ko),"boundary accepted")
 let next=key(40);check(b.receive(.keyDown,next),"later Korean key queued")
 b.step();check(switches==0 && posts==0,"no switch before previous insertion")
 text="a";range=NSRange(location:1,length:0);b.step();check(switches==1 && source==ko,"switch after exact insertion")
 b.send={e in posts+=1;check(!b.receive(e.type,e),"own replay bypasses queue");b.observe(e.type,e)}
 b.step();check(posts==1 && b.expected?.0=="aㅏ","replay uses new source")
 b.step();check(b.busy,"wait for final insertion")
 text="aㅏ";range=NSRange(location:2,length:0);b.step();check(!b.busy,"finish after editor acknowledgment")
}
do {
 let b=SourceSwitchBarrier();var source=ko,switches=0
 b.read={.init(field:field,text:"알트탭",selection:NSRange(location:1,length:2))};b.source={source};b.select={source=$0;switches+=1;return noErr}
 check(b.request(en),"partial selection accepted");b.step();check(switches==1,"partial selection preserved in boundary proof")
 b.fail("test_end")
}
for scenario in 0..<3 {
 let b=SourceSwitchBarrier();var focused=field,time=0.0,switches=0,retained=0,ready=false
 b.now={time};b.read={.init(field:focused,text:"a",selection:NSRange(location:1,length:0))};b.ready={ready};b.source={en};b.select={_ in switches+=1;return noErr};b.retained={retained += $0.count}
 check(b.request(ko),"request");check(b.receive(.keyDown,key(0)),"queued")
 b.step();check(switches==0,"other repair must finish first")
 if scenario==0{focused=other;ready=true}else if scenario==1{time=4}else{b.fail("input_stopped")}
 b.step();check(!b.busy && retained==1 && switches==0,"retain on changed focus, timeout, or stop")
 ready=true
}
do {
 let b=SourceSwitchBarrier();var text="서울",range=NSRange(location:2,length:0),source=ko,switches=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 b.applySelection={_,_ in true}
 b.observe(.keyDown,key(0,.maskCommand))
 check(b.request(en),"select-all boundary")
 b.step();check(switches==0,"wait until actual selection covers prior text")
 range=NSRange(location:0,length:2);b.step();b.step();check(switches==1,"switch after select-all acknowledgment")
 b.observe(.keyDown,key(0));check(b.expected?.0=="a","new key replaces selected text exactly")
 text="a";range=NSRange(location:1,length:0);b.step();check(!b.busy,"replacement verified")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var source=en,text="a",range=NSRange(location:1,length:0),switches=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 check(b.request(ko),"first request")
 let toggle=key(54);toggle.type = .flagsChanged;toggle.flags=[]
 check(b.receive(.flagsChanged,toggle),"second switch queued")
 b.send={e in
  check(!b.receive(e.type,e),"second request replay arrives")
  check(b.request(en),"second request starts at correct source")
 }
 b.step();b.step();b.step()
 check(switches==2 && source==en,"two boundaries preserve order")
 b.step();check(!b.busy,"two-boundary transaction finishes")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var readable=true,source=en,switches=0,retained=0
 b.read={readable ? .init(field:field,text:"a",selection:NSRange(location:1,length:0)):nil};b.source={source};b.select={source=$0;switches+=1;return noErr};b.retained={retained += $0.count}
 check(b.request(ko),"transient AX request");check(b.receive(.keyDown,key(0)),"queue before AX outage")
 readable=false;b.step();check(b.busy && switches==0 && retained==0,"missing AX reply retains transaction without releasing or discarding keys")
 readable=true;b.step();check(b.busy && switches==1,"retry resumes at confirmed original field")
 b.fail("test_end");check(retained==1,"queued key remains owned until delivery")
}
do {
 let b=SourceSwitchBarrier();b.read={.init(field:field,text:"",selection:NSRange(location:0,length:0))};b.source={en}
 b.observe(.keyDown,key(0));check(b.request(ko),"release-order request")
 let up=key(0);up.type = .keyUp
 check(!b.receive(.keyUp,up),"previously delivered press is released immediately")
 check(b.receive(.keyDown,key(40)),"new press is queued")
 let nextUp=key(40);nextUp.type = .keyUp
 check(b.receive(.keyUp,nextUp),"queued press retains paired release")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var text="pre: ",range=NSRange(location:5,length:0),source=en,switches=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));b.observe(.keyDown,key(49))
 text="pre: A ";range=NSRange(location:7,length:0)
 check(b.matches(.init(field:field,text:text,selection:range)),"editor capitalization inside typed insertion is acknowledged")
 check(!b.matches(.init(field:field,text:"Pre: A ",selection:range)),"case change outside tracked insertion is rejected")
 check(!b.matches(.init(field:field,text:"pre: B ",selection:range)),"different letter is rejected")
 check(!b.matches(.init(field:field,text:"pre: ",selection:range)),"missing insertion is rejected")
 check(!b.matches(.init(field:field,text:"pre: \u{3141} ",selection:range)),"different input language is rejected")
 check(!b.matches(.init(field:field,text:text,selection:NSRange(location:6,length:0))),"unchanged text does not replace caret acknowledgment")
 check(b.request(ko),"capitalized boundary accepted");b.step();check(switches==1 && text=="pre: A ","switch proceeds without rewriting editor capitalization")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0),source=en,ready=true,switches=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.ready={ready};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));b.observe(.keyDown,key(0))
 text="a";range=NSRange(location:1,length:0)
 b.noteExternalEdit()
 b.applySelection={_,_ in true}
 b.observe(.keyDown,key(0,.maskCommand))
 check(b.expected?.0=="a" && b.expected?.1==NSRange(location:0,length:1),"select-all uses repaired text instead of stale two-character prediction")
 check(b.request(ko),"repaired selection boundary accepted")
 b.step();check(switches==0,"repair rebasing does not skip a following select-all acknowledgment")
 range=NSRange(location:0,length:1);b.step();b.step();check(switches==1,"repaired full selection switches after acknowledgment")
 b.fail("test_end")
}
for changedFocus in [false,true] {
 let b=SourceSwitchBarrier();var text="a",range=NSRange(location:1,length:0),source=en,ready=false,focused=field,switches=0
 b.read={.init(field:focused,text:text,selection:range)};b.source={source};b.ready={ready};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));check(b.request(ko),"overlapping repair boundary accepted")
 b.noteExternalEdit();text="repaired";range=NSRange(location:8,length:0)
 b.step();check(switches==0,"repair must finish before baseline refresh")
 if changedFocus{focused=other}
 ready=true;b.step()
 check(switches == (changedFocus ? 0:1),"repair refresh requires same transaction field")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0)
 b.read={.init(field:field,text:text,selection:range)};b.source={ko}
 var repaired=MismatchReplayLedger(before:"",caret:0);repaired.append(source:ko,keys:[(0,false),(40,false)])
 text=repaired.text;range=repaired.selection
 b.noteExternalEdit();b.adoptVerifiedReplay(repaired,snapshot:.init(element:field,text:text,selection:range))
 b.observe(.keyDown,key(2))
 check(b.expected?.0=="망","continuing consonant joins repaired live Hangul composition")
 let previous=b.expected?.0
 b.adoptVerifiedReplay(repaired,snapshot:.init(element:field,text:"changed",selection:range))
 check(b.expected?.0==previous,"unverified replay history is rejected")
}
do {
 let b=SourceSwitchBarrier();var text="a",range=NSRange(location:1,length:0),source=en,writes=0,switches=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 b.applySelection={_,r in writes+=1;check(r==NSRange(location:0,length:2),"requested full range uses confirmed text");return true}
 b.observe(.keyDown,key(1))
 b.observe(.keyDown,key(0,.maskCommand));check(b.request(ko),"lost native selection request accepted")
 b.step();check(writes==0 && switches==0,"do not apply select-all before preceding insertion appears")
 text="as";range=NSRange(location:2,length:0);b.step()
 check(writes==1 && switches==0,"apply explicit selection but wait for its acknowledgment")
 b.step();check(writes==1 && switches==0,"selection write is not repeatedly posted")
 range=NSRange(location:0,length:2);b.step();b.step();check(switches==1,"switch only after restored select-all is observed")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var range=NSRange(location:2,length:0),writes=0,posts=0
 b.read={.init(field:field,text:"ab",selection:range)};b.source={en}
 b.applySelection={_,_ in writes+=1;return true}
 b.send={e in posts+=1;_ = b.receive(e.type,e);b.observe(e.type,e)}
 b.observe(.keyDown,key(0,.maskCommand))
 check(b.busy && b.receive(.keyDown,key(51)),"standalone select-all queues a following delete without requiring language switch")
 b.step();check(writes==1 && posts==0,"delete cannot overtake select-all application")
 b.step();check(posts==0,"delete still waits for editor selection acknowledgment")
 range=NSRange(location:0,length:2);b.step();b.step();check(posts==1,"delete follows acknowledged full selection")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var time=0.0,text="ab",range=NSRange(location:2,length:0),writes=0
 b.now={time};b.source={en};b.read={.init(field:field,text:text,selection:range)}
 b.applySelection={_,_ in writes+=1;return true}
 b.observe(.keyDown,key(0,.maskCommand));b.step();check(writes==1,"initial selection applied")
 time=0.02;b.step();check(writes==2,"unchanged editor may retry ignored selection")
 text="changed";time=0.04;b.step();check(writes==2,"changed text forbids selection retry")
 text="ab";b.step();check(writes==3,"last bounded selection retry")
 time=0.1;b.step();check(writes==3,"selection retries are bounded")
 range=NSRange(location:0,length:2);b.step();b.step();check(!b.busy,"late selection acknowledgment completes standalone action")
}
for consumed in [false,true] {
 let b=SourceSwitchBarrier();var ready=false
 b.source={ko};b.ready={ready}
 var replay=MismatchReplayLedger(before:"",caret:0);replay.append(source:ko,keys:[(2,false)])
 b.noteExternalEdit()
 let keySource=CGEventSource(stateID:.privateState)!;keySource.userData=0x4851455600000001
 let vowel=CGEvent(keyboardEventSource:keySource,virtualKey:38,keyDown:true)!;vowel.flags=[];b.observe(.keyDown,vowel)
 vowel.timestamp+=1000
 check(b.expected == nil,"main tap does not predict keys owned by active repair")
 if consumed {b.confirmDelivery(.keyDown,vowel,passed:false);replay.append(source:ko,keys:[(38,false)])}
 ready=true;b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:replay.text,selection:replay.selection))
 if !consumed {
  var switches=0;b.select={_ in switches+=1;return noErr}
  b.read={.init(field:field,text:replay.text,selection:replay.selection)}
  check(b.request(en),"source request accepts verified repair baseline")
  b.step();check(switches==0,"switch waits for key still between input handlers")
  b.confirmDelivery(.keyDown,vowel,passed:true)
 }
 check(b.expected?.0=="어","key crossing repair completion joins verified composition exactly once")
 b.confirmDelivery(.keyDown,vowel,passed:true)
 check(b.expected?.0=="어","duplicate delivery acknowledgment cannot duplicate a vowel")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var time=0.0,ready=false,reads=0,source=en,switches=0
 b.now={time};b.source={source};b.ready={ready}
 b.read={reads+=1;return .init(field:field,text:"a",selection:NSRange(location:1,length:0))}
 b.select={source=$0;switches+=1;return noErr}
 check(b.request(ko),"request during active repair")
 let initialReads=reads;b.step();time=1.5;b.step()
 check(b.busy && reads==initialReads && switches==0,"repair over one second does not expire barrier or add competing AX reads")
 ready=true;b.step();check(switches==1,"editor acknowledgment gets its own deadline after repair")
 b.fail("test_end")
}
for success in [false,true] {
 let b=SourceSwitchBarrier();var range=NSRange(location:0,length:3),commits=0,posts=0,retained=0
 b.source={ko};b.read={.init(field:field,text:"알트탭",selection:range)}
 b.applySelection={_,_ in true}
 b.commitSelection={_ in commits+=1;range=NSRange(location:0,length:0);return success ? noErr:-50}
 b.send={_ in posts+=1};b.retained={retained+=$0.count}
 b.observe(.keyDown,key(0,.maskCommand));_=b.receive(.keyDown,key(51));b.step()
 check(commits==1 && posts==0,"delete waits for native composition commit")
 if success {
  b.step();check(posts==0,"successful commit still requires restored full selection")
  range=NSRange(location:0,length:3);b.step();check(posts==1 && commits==1,"delete follows commit and restored selection exactly once")
 } else {check(!b.busy && retained==1,"failed commit retains subsequent delete")}
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var source=ko,range=NSRange(location:0,length:3),posts=0
 b.source={source};b.read={.init(field:field,text:"알트탭",selection:range)}
 b.select={source=$0;range=NSRange(location:0,length:0);return noErr}
 b.applySelection={_,_ in true}
 b.send={e in posts+=1;_=b.receive(e.type,e);b.observe(e.type,e)}
 check(b.request(en),"selected source switch begins")
 _=b.receive(.keyDown,key(0));b.step();b.step()
 check(posts==0 && b.expected?.1==NSRange(location:0,length:3),"successful switch waits for asynchronous selection restoration")
 range=NSRange(location:0,length:3);b.step()
 check(posts==1 && b.expected?.0=="a","replacement uses preserved selection instead of transient collapsed caret")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var source=en,text="",range=NSRange(location:0,length:0),posts=0
 b.source={source};b.read={.init(field:field,text:text,selection:range)}
 b.select={source=$0;return noErr};b.send={e in posts+=1;_=b.receive(e.type,e);b.observe(e.type,e)}
 b.observe(.keyDown,key(0));text="a";range=NSRange(location:1,length:0)
 check(b.request(ko),"capitalization race source switch begins")
 _=b.receive(.keyDown,key(0));b.step();text="A";b.step()
 check(posts==1 && b.expected?.0=="aㅁ","delayed capitalization does not block following Korean key")
 text="Aㅁ";range=NSRange(location:2,length:0)
 check(b.matches(.init(field:field,text:text,selection:range)),"tracked capitalization remains valid across source boundary")
 check(!b.matches(.init(field:field,text:"Bㅁ",selection:range)),"different letter remains rejected")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var source=ko,text="",range=NSRange(location:0,length:0)
 b.source={source};b.read={.init(field:field,text:text,selection:range)}
 b.select={source=$0;return noErr}
 b.observe(.keyDown,key(0));text="ㅁ";range=NSRange(location:1,length:0)
 _=b.request(en);b.step();b.step();_=b.request(ko);b.step();b.step()
 b.observe(.keyDown,key(40))
 check(b.expected?.0=="ㅁㅏ","source round trip without English keys still commits earlier Korean composition")
 b.fail("test_end")
}
for verified in [false,true] {
 let b=SourceSwitchBarrier();var ready=false,text="알트탭",range=NSRange(location:3,length:0),posts:[Int64]=[],retained=0
 b.ready={ready};b.source={ko};b.read={.init(field:field,text:text,selection:range)}
 b.applySelection={_,r in range=r;return true};b.retained={retained+=$0.count}
 b.send={e in
  posts.append(e.getIntegerValueField(.keyboardEventKeycode));_=b.receive(e.type,e);b.observe(e.type,e)
  if e.getIntegerValueField(.keyboardEventKeycode)==0 {range=NSRange(location:0,length:text.utf16.count)}
  if e.getIntegerValueField(.keyboardEventKeycode)==51 {text="";range=NSRange(location:0,length:0)}
 }
 b.noteExternalEdit()
 check(b.receive(.keyDown,key(0,.maskCommand)) && b.receive(.keyDown,key(51)),"select-all and following delete wait at repair boundary")
 b.step();check(posts.isEmpty,"editing shortcut cannot interrupt active repair")
 if verified {
  let replay=MismatchReplayLedger(before:text,caret:3)
  b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:text,selection:range))
 }
 ready=true
 for _ in 0..<8 {b.step()}
 check(verified ? posts==[0,51] && text.isEmpty && !b.busy:posts.isEmpty && retained==2,"verified repair hands shortcut to ordinary selection path; failed repair retains it")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();b.ready={false};b.noteExternalEdit()
 var toggles=0
 let gate=MismatchSwitchGate(accepts:{!b.busy},switched:{_ in toggles+=1})
 let engine=MismatchRecoveryEngine()
 engine.willForwardEvent={type,event in b.beginRepairBoundary(type,event)}
 gate.forwarded={type,event,timestamp in engine.captureEventOrigin(type,event,at:timestamp)}
 let selectAll=key(0,.maskCommand)
 check(gate.receive(.keyDown,selectAll) != nil && b.busy,"HID select-all reserves boundary before arriving at main tap")
 let command=key(54,CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10));command.type = .flagsChanged
 check(gate.receive(.flagsChanged,command) != nil && toggles==0,"repair HID gate must defer source toggles while ordered edit queue owns them")
 check(b.receive(.keyDown,selectAll),"original select-all is queued once at session tap")
 check(b.receive(.flagsChanged,command),"right Command stays behind queued select-all")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var source=ko,reads=0,focusReads=0,focused=field,sent:[CGEvent]=[]
 b.source={source};b.select={source=$0;return noErr}
 b.read={reads+=1;return .init(field:field,text:"",selection:NSRange(location:0,length:0))}
 b.readFocus={focusReads+=1;return focused};b.send={sent.append($0)}
 _=b.request(en);_=b.receive(.keyDown,key(0));_=b.receive(.keyDown,key(37));_=b.receive(.keyDown,key(17))
 b.step();b.step();let afterBoundary=reads
 b.step();check(reads==afterBoundary && sent.count==1,"waiting for replay acknowledgment performs no AX text read")
 _=b.receive(.keyDown,sent[0]);b.observe(.keyDown,sent[0]);b.step()
 check(reads==afterBoundary && focusReads==1 && sent.count==2,"ordinary queued key checks focus without repeating text read")
 _=b.receive(.keyDown,sent[1]);b.observe(.keyDown,sent[1]);focused=AXUIElementCreateApplication(54321);b.step()
 check(sent.count==2 && !b.busy,"changed focus still prevents queued delivery")
}

do {
 let b=SourceSwitchBarrier();var source=ko,sent:[CGEvent]=[],focusReads=0
 b.source={source};b.select={source=$0;return noErr}
 b.read={.init(field:field,text:"",selection:NSRange(location:0,length:0))}
 b.readFocus={focusReads+=1;return other};b.send={sent.append($0)}
 _=b.request(en);_=b.receive(.keyDown,key(0))
 let release=key(0);release.type = .keyUp;_=b.receive(.keyUp,release)
 b.step();b.step();_=b.receive(.keyDown,sent[0]);b.observe(.keyDown,sent[0]);b.step()
 check(sent.count==2 && sent[1].type == .keyUp && focusReads==0,"release of delivered key bypasses redundant AX check even if focus moved")
 b.fail("test_end")
}
// A field replacement between completed transactions is a new observation,
// while replacement during an owned boundary must still retain pending input.
for typedBeforeSwitch in [false,true] {
 let b=SourceSwitchBarrier();var focused=field,text="old",range=NSRange(location:3,length:0),source=en,switches=0,retained=0
 b.read={.init(field:focused,text:text,selection:range)};b.readFocus={focused}
 b.source={source};b.select={source=$0;switches+=1;return noErr};b.retained={retained+=$0.count}
 b.observe(.keyDown,key(0));text="olda";range=NSRange(location:4,length:0)
 focused=other;text="new";range=NSRange(location:3,length:0)
 if typedBeforeSwitch {b.observe(.keyDown,key(11));text="newb";range=NSRange(location:4,length:0)}
 check(b.request(ko),"replacement field accepts first source boundary")
 b.step();check(switches==1 && source==ko && retained==0,"idle replacement uses new field and preserves its preceding input")
 b.step();check(!b.busy,"replacement boundary completes without cursor recovery")
}
do {
 let b=SourceSwitchBarrier();var focused=field,text="old",range=NSRange(location:3,length:0),source=en,switches=0
 b.read={.init(field:focused,text:text,selection:range)};b.readFocus={focused};b.source={source};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));focused=other;text="";range=NSRange(location:0,length:0)
 b.observe(.keyDown,key(11)) // Submitted to the new editor, not yet reflected in AX.
 check(b.expected?.0=="b","first key in replacement field starts new prediction")
 check(b.request(ko),"delayed new-field insertion boundary accepted");b.step()
 check(b.busy && switches==0,"replacement does not switch ahead of its pending insertion")
 text="b";range=NSRange(location:1,length:0);b.step();check(switches==1,"switch after replacement insertion is acknowledged")
 b.fail("test_end")
}
do {
 let b=SourceSwitchBarrier();var focused=field,text="old",range=NSRange(location:3,length:0),source=en,switches=0
 b.read={.init(field:focused,text:text,selection:range)};b.readFocus={focused};b.source={source};b.select={source=$0;switches+=1;return noErr};b.applySelection={_,r in range=r;return true}
 b.observe(.keyDown,key(0));focused=other;text="새 입력칸";range=NSRange(location:text.utf16.count,length:0)
 b.observe(.keyDown,key(0,.maskCommand))
 check(b.expected?.0==text && b.expected?.1==NSRange(location:0,length:text.utf16.count),"replacement select-all is bounded to new text")
 check(b.request(ko),"source toggle joins new-field select-all boundary")
 for _ in 0..<4 {b.step()}
 check(switches==1 && source==ko && !b.busy,"new-field selection is acknowledged before switching")
}
for readyBeforeRequest in [false,true] {
 let b=SourceSwitchBarrier();var focused=field,ready=readyBeforeRequest,switches=0,retained=0,source=en
 b.read={.init(field:focused,text:"a",selection:NSRange(location:1,length:0))};b.readFocus={focused};b.ready={ready};b.source={source};b.select={source=$0;switches+=1;return noErr};b.retained={retained+=$0.count}
 check(b.request(ko),"original transaction starts")
 check(b.receive(.keyDown,key(11)),"original transaction owns following key")
 focused=other;ready=true
 check(b.request(ko),"subsequent toggle stays with active transaction")
 b.step();check(!b.busy && switches==0 && retained==1,"active replacement cannot rebase or send held input to new field")
}
do {
 let b=SourceSwitchBarrier();var readable=true,focused=field,source=en,switches=0,retained=0
 b.read={readable ? .init(field:focused,text:"a",selection:NSRange(location:1,length:0)):nil};b.readFocus={readable ? focused:nil};b.source={source};b.select={source=$0;switches+=1;return noErr};b.retained={retained+=$0.count}
 b.observe(.keyDown,key(0));readable=false;focused=other
 check(b.request(ko),"missing focus does not discard old evidence")
 check(b.receive(.keyDown,key(11)),"uncertain transaction owns following key")
 b.step();check(b.busy && switches==0 && retained==0,"missing reply is not a new-field confirmation")
 readable=true;b.step();check(!b.busy && switches==0 && retained==1,"later actual focus change retains held input")
}
do {
 let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0),source=en,switches=0
 b.read={.init(field:field,text:text,selection:range)};b.readFocus={field};b.source={source};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));text="different";range=NSRange(location:9,length:0)
 check(b.request(ko),"unchanged field preserves preceding prediction");b.step()
 check(switches==0 && b.expected?.0=="a","same-field unexpected content cannot be accepted as a new baseline")
 b.fail("test_end")
}


// A deferred source switch owns the temporary collapsed selection. The barrier
// keeps the original replacement range and queues later keys until completion.
do {
 let b=SourceSwitchBarrier();var source=ko,range=NSRange(location:0,length:3),pending=false,calls=0,posts=0,cancelled=0
 b.read={.init(field:field,text:"가나다",selection:range)};b.source={source}
 b.selectionPending={pending};b.cancelSelection={pending=false;cancelled+=1}
 b.select={target in calls+=1;if calls==1{pending=true;range=NSRange(location:0,length:0);return AXError.cannotComplete.rawValue};pending=false;source=target;range=NSRange(location:0,length:3);return noErr}
 b.send={_ in posts+=1}
 check(b.request(en),"deferred selected request")
 b.step();check(b.busy && pending && calls==1,"pending switch remains owned")
 check(b.receive(.keyDown,key(0)),"input held during deferred commit")
 b.step();check(calls==2 && source==en && b.expected?.1==NSRange(location:0,length:3) && posts==0,"poll despite owned collapse; preserve original selection before replay")
 b.fail("test_cleanup");check(cancelled==1 && !pending,"cancel propagates to selection transaction")
}

for unreadable in [false,true] {
 let b=SourceSwitchBarrier();var clock=0.0,missing=false;var traces:[String]=[]
 b.now={clock};b.source={en};b.trace={traces.append($0)}
 b.read={missing ? nil:.init(field:field,text:"PRIVATE_CONTENT",selection:NSRange(location:15,length:0))}
 b.observe(.keyDown,key(0))
 b.observe(.keyDown,key(0,.maskCommand));missing=unreadable
 b.step();clock=2;b.step()
 check(!b.busy && traces.contains("deadline"),"unconfirmed read and mismatched body both end at bounded deadline")
 check(!traces.joined().contains("PRIVATE_CONTENT"),"wait diagnosis does not log editor content")
}
// An editor may remove its initial AX body on the first key. Select-all can
// acknowledge this only after the full observed insertion is present.
for scenario in 0..<8 {
 let b=SourceSwitchBarrier();var text="initial prompt",range=NSRange(location:0,length:0),focused=field,writes=0
 b.source={en};b.read={.init(field:focused,text:text,selection:range)}
 b.applySelection={_,r in writes+=1;range=r;return true}
 b.observe(.keyDown,key(0));b.observe(.keyDown,key(11)) // ab
 switch scenario {
 case 0:text="ab";range=NSRange(location:2,length:0)
 case 1:text="ab";range=NSRange(location:0,length:2)
 case 2:text="a";range=NSRange(location:1,length:0) // partial delivery
 case 3:text="ac";range=NSRange(location:2,length:0) // different key
 case 4:text="ab?";range=NSRange(location:3,length:0) // unobserved body
 case 5:text="ab";range=NSRange(location:1,length:0) // unexpected caret
 case 6:text="ab";range=NSRange(location:0,length:1) // partial selection
 default:text="ab";range=NSRange(location:2,length:0)
 }
 b.observe(.keyDown,key(0,.maskCommand))
 if scenario==7 {focused=other}
 b.step()
 if scenario<2 {
  check(b.expected?.0=="ab" && b.expected?.1==NSRange(location:0,length:2),"explicit select-all acknowledges all typed keys without initial body")
  b.step();b.step();check(!b.busy,"selection completes without stale initial body deadline")
 } else {
  check(writes==0,"partial delivery, changed text, caret, selection or field cannot authorize selection")
  check(b.expected?.0 != "ab","unverified removal never replaces prediction")
 }
 b.fail("test_cleanup")
}
// A source boundary also needs to acknowledge removal of an initial AX body.
// Every observed key must account for the entire body, at the exact final caret.
for scenario in 0..<9 {
 let b=SourceSwitchBarrier();var text="initial prompt",range=NSRange(location:0,length:0),focused=field,source=en,switches=0
 var traces:[String]=[]
 b.source={source};b.read={.init(field:focused,text:text,selection:range)};b.trace={traces.append($0)}
 b.select={source=$0;switches+=1;return noErr}
 if scenario==8 {range=NSRange(location:3,length:0)}
 b.observe(.keyDown,key(0));b.observe(.keyDown,key(11))
 text="ab";range=NSRange(location:2,length:0)
 switch scenario {
 case 1:text="a";range=NSRange(location:1,length:0)
 case 2:text="ac"
 case 3:text="ab?";range=NSRange(location:3,length:0)
 case 4:range=NSRange(location:1,length:0)
 case 5:range=NSRange(location:0,length:2)
 case 6:break
 case 7:text="Ab"
 default:break
 }
 check(b.request(ko),"initial AX body boundary requested")
 if scenario==6 {focused=other}
 b.step()
 if scenario==0 || scenario==7 {
  check(switches==1 && source==ko,"all observed text acknowledges initial body removal before source switch")
  check(traces.contains("source_initial_body_removed"),"initial body outcome is content-free diagnosis")
  b.step();check(!b.busy,"initial-body switch finishes without key cancellation")
 } else {
  check(switches==0,"partial, changed, extra, selected, moved or noninitial body cannot authorize switch")
 }
 b.fail("test_cleanup")
}
// The same apparent full body may still be an old baseline or partial delivery.
// Never infer initial-body removal from either ambiguity.
for (before,keys,actual) in [("ab",[UInt16(0),11],"ab"),("b",[UInt16(0),11],"ab")] {
 let b=SourceSwitchBarrier();var text=before,range=NSRange(location:0,length:0),switches=0
 b.source={en};b.read={.init(field:field,text:text,selection:range)};b.select={_ in switches+=1;return noErr}
 for code in keys {b.observe(.keyDown,key(code))}
 text=actual;range=NSRange(location:actual.utf16.count,length:0)
 check(b.request(ko),"ambiguous initial body request")
 b.step();check(switches==0,"unchanged baseline and actual pending prefix never authorize source switch")
 b.fail("test_cleanup")
}
// Confirm all five Korean renderers and queued input across that boundary.
for id in KoreanKeyboardLayout.supportedIDs {
 let b=SourceSwitchBarrier();var text="initial prompt",range=NSRange(location:0,length:0),source=id,switches=0,posts=0
 let keys:[UInt16]=id==ko ? [15,40,1]:([KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID].contains(id) ? [40,3,1]:[5,0,45])
 let rendered=MismatchReplayLedger.render((source:id,keys:keys.map{($0,false)}))
 b.source={source};b.read={.init(field:field,text:text,selection:range)}
 b.select={source=$0;switches+=1;return noErr}
 for code in keys {b.observe(.keyDown,key(code))}
 check(b.request(en),"Korean initial body source request")
 check(b.receive(.keyDown,key(0)),"following key kept behind initial body boundary")
 b.step();check(switches==0,"placeholder still visible never proves prior keys")
 text=rendered;range=NSRange(location:rendered.utf16.count,length:0)
 b.step();check(switches==1 && source==en,"five Korean arrays switch only after full insertion")
 b.send={e in posts+=1;check(!b.receive(e.type,e),"own queued key delivery");b.observe(e.type,e);text+="a";range=NSRange(location:text.utf16.count,length:0)}
 b.step();b.step();b.step()
 check(posts==1 && !b.busy && text==rendered+"a","initial body acknowledgment preserves queued key exactly once")
 b.fail("test_cleanup")
}
// Korean insertion also acknowledges initial-body removal; following input
// must replace the verified full selection exactly once.
do {
 let b=SourceSwitchBarrier();var text="initial prompt",range=NSRange(location:0,length:0)
 b.source={ko};b.read={.init(field:field,text:text,selection:range)}
 b.applySelection={_,r in range=r;return true}
 b.observe(.keyDown,key(0));b.observe(.keyDown,key(40))
 text="마";range=NSRange(location:1,length:0)
 b.observe(.keyDown,key(0,.maskCommand));b.step();b.step();b.step()
 check(!b.busy && b.expected?.0=="마","Korean insertion acknowledges removed initial body")
 b.observe(.keyDown,key(2));check(b.expected?.0=="ㅇ","typing after select-all replaces selected Korean body once")
 b.fail("test_cleanup")
}
for reason in ["current","pre_key","pending_key","adopted","ascii","mixed","jamo","partial","wrong-key","text","caret","selection","field","source","expiry","boundary","busy","repair","permission","limit","reset"] {
 let b=SourceSwitchBarrier();var source=ko,time=1.0
 var captures:[InputIncidentTrace.Capture]=[]
 let incident=InputIncidentTrace(destination:nil,writer:{captures.append($0)});b.incidentTrace=incident
 b.now={time};b.source={source};b.read={.init(field:field,text:"앞🙂뒤",selection:NSRange(location:3,length:0))}
 for code:UInt16 in [15,40,1]{let event=key(code);event.timestamp=100;b.observe(.keyDown,event)}
 let verified=MismatchSnapshot(element:field,text:"앞🙂간뒤",selection:NSRange(location:4,length:0))
 if reason=="adopted"{
  var replay=MismatchReplayLedger(before:"앞🙂뒤",caret:3);replay.append(source:ko,keys:[(15,false),(40,false),(1,false)])
  b.noteExternalEdit();b.adoptVerifiedReplay(replay,snapshot:verified)
 }
 if ["pre_key","pending_key"].contains(reason){b.observe(.keyDown,key(40))}
 if reason=="source"{source=en}
 if reason=="expiry"{time=6.01}
 if reason=="busy"{_ = b.request(en)}
 if reason=="repair"{b.noteExternalEdit()}
 if reason=="permission"{b.ready={false}}
 if reason=="reset"{b.resetObservation()}
 var snap=verified
 let failures=["ascii":"rks","mixed":"rㅏㄴ","jamo":"ㄱㅏㄴ","partial":"가s","wrong-key":"rㅓㄴ"]
 if let value=failures[reason]{snap = .init(element:field,text:"앞🙂"+value+"뒤",selection:NSRange(location:3+value.utf16.count,length:0))}
 if reason=="text"{snap = .init(element:field,text:"다🙂간뒤",selection:verified.selection)}
 if reason=="caret"{snap = .init(element:field,text:verified.text,selection:NSRange(location:3,length:0))}
 if reason=="selection"{snap = .init(element:field,text:verified.text,selection:NSRange(location:4,length:1))}
 if reason=="field"{snap = .init(element:other,text:verified.text,selection:verified.selection)}
 if reason=="limit"{
  var long=MismatchReplayLedger(before:"앞🙂뒤",caret:3);long.append(source:ko,keys:Array(repeating:(15,false),count:65))
  snap = .init(element:field,text:long.text,selection:long.selection);b.adoptVerifiedReplay(long,snapshot:snap)
 }
 let result=b.verifiedTwoSetHistory(snap,after:reason=="boundary" ? UInt64.max:0,allowPrior:reason=="pre_key")
 check((result?.plan.replayRoman=="rks") == ["current","pre_key","adopted","ascii","mixed","jamo","partial"].contains(reason),"verified delivery-history \(reason) proof")
 incident.mark();incident.flush()
 let rejected:[String:InputIncidentTrace.DecisionReason]=["pending_key":.handoffTextMismatch,"wrong-key":.handoffTextMismatch,"text":.handoffTextMismatch,"caret":.handoffTextMismatch,"selection":.handoffTextMismatch,"field":.handoffField,"source":.handoffSource,"expiry":.handoffExpired,"boundary":.handoffBoundary,"busy":.handoffBusy,"repair":.handoffExternalEdit,"permission":.handoffNotReady,"limit":.handoffNoHistory,"reset":.handoffField]
 check(captures[0].frames.last{$0.kind == .detectionDecision}?.category==(rejected[reason] ?? .handoffAccepted).rawValue,"actual delivery-history \(reason) decision reason")
 b.fail("test_cleanup")
}

// Reuse the proved body across a switch while initializing only the new
// source interval on its first delivered key. Old keys remain ineligible.
for selected in [false,true] {
 let b=SourceSwitchBarrier();var source=en,text="a",range=NSRange(location:selected ? 0:1,length:selected ? 1:0)
 var captures:[InputIncidentTrace.Capture]=[]
 let incident=InputIncidentTrace(destination:nil,writer:{captures.append($0)});b.incidentTrace=incident
 b.source={source};b.read={.init(field:field,text:text,selection:range)};b.select={source=$0;return noErr}
 if !selected {
  text="";range=NSRange(location:0,length:0)
  let first=key(0);first.timestamp=100;b.observe(.keyDown,first)
  text="a";range=NSRange(location:1,length:0)
 }
 check(b.request(ko,at:200),"post-switch history boundary accepted")
 b.step();b.step()
 check(b.verifiedTwoSetHistory(.init(element:field,text:text,selection:range),after:200)==nil,"empty new source interval cannot inherit pre-switch keys")
 let later=key(2);later.timestamp=300;b.observe(.keyDown,later)
 let roman=selected ? "d":"ad"
 let result=b.verifiedTwoSetHistory(.init(element:field,text:roman,selection:NSRange(location:roman.utf16.count,length:0)),after:200)
 check(result?.plan.roman=="d","first key after switch initializes history even when ledger survived")
 check(b.verifiedTwoSetHistory(.init(element:field,text:roman,selection:NSRange(location:roman.utf16.count,length:0)),after:350)==nil,"initialized interval still rejects a later boundary")
 incident.mark();incident.flush()
 check(captures[0].frames.contains{$0.kind == .detectionDecision && $0.category==InputIncidentTrace.DecisionReason.handoffAccepted.rawValue},"post-switch handoff acceptance is recorded")
 b.fail("test_cleanup")
}


func originPacket(_ code:CGKeyCode,_ timestamp:CGEventTimestamp,_ tag:Int64)->CGEvent {
 let source=CGEventSource(stateID:.privateState)!;source.userData=tag
 let e=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true)!
 e.flags=[];e.timestamp=timestamp
 return e
}
// Quartz may rewrite a returned event's timestamp between main and onset taps.
// A missed receipt must not strand later typing behind a source boundary.
for token:Int64 in [0x4852000100000101,0x4851455600000101] {
 for passed in [true,false] {
 for mismatchFirst in [false,true] {
  let b=SourceSwitchBarrier();var time=0.0,source=en,text="",range=NSRange(location:0,length:0),switches=0,posts=0,retained=0
  b.now={time};b.source={source};b.read={.init(field:field,text:text,selection:range)};b.readFocus={field}
  b.select={source=$0;switches+=1;return noErr};b.retained={retained += $0.count}
  b.beginOnsetReplay(field:field,before:"",caret:0)
  var original=originPacket(0,100,UInt64(bitPattern:token)>>48 == 0x4852 ? token:0)
  let mismatch=MismatchRecoveryEngine();mismatch.enabled=true;mismatch.testSource={en}
  let captured=mismatch.captureEventOrigin(.keyDown,original)
  check(captured != nil,"original source intent captured")
  if UInt64(bitPattern:token)>>48 == 0x4852 {check(captured==token,"physical provenance identity retained")}
  // A received event gets the source's userData. CGEvent.data does not
  // serialize all source metadata, so use the real source API as in source-timestamp tests.
  original=originPacket(0,100,captured!)
  // Capture the real token at main; use the same event through either tap order.
  b.observeBeforeOnset(.keyDown,original,waiting:true)
  let identity=original.getIntegerValueField(.eventSourceUserData)
  original.timestamp=200
  if mismatchFirst {_ = mismatch.event(.keyDown,original)}
  original.timestamp=300
  let receipt=original.copy()!
  if !mismatchFirst {_ = mismatch.event(.keyDown,original)}
  check(original.getIntegerValueField(.eventSourceUserData)==identity,"mismatch consumes intent without erasing downstream identity")
  let boundary=KeyboardStateMirror();boundary.beginTesting()
  let boundaryResult=boundary.receive(.keyDown,original)
  // Source-backed synthetic getters can retain source userData; actual app
  // delivery is checked separately in the live fixture, never inferred from serialization.
  check(boundaryResult != nil,"origin identity never consumes or duplicates the original at final boundary")
  check(receipt.getIntegerValueField(.eventSourceUserData)==identity,"asynchronous onset receipt survives boundary cleanup")
  b.confirmOnsetDelivery(receipt,passed:passed)
  text=passed ? "a":"";range=NSRange(location:text.utf16.count,length:0)
  check(b.request(ko),"source request after retimestamped onset receipt")
  check(b.receive(.keyDown,key(40)),"following text queued until source proof")
  b.send={e in
   posts+=1;check(!b.receive(e.type,e),"one boundary replay only")
   b.observe(e.type,e);text=b.expected!.0;range=b.expected!.1
  }
  for _ in 0..<5{b.step()}
  time=1.1;b.step()
  print("retimestamp onset passed=\(passed) switches=\(switches) posts=\(posts) retained=\(retained)")
  check(switches==1 && posts==1 && retained==0 && !b.busy,"retimestamped onset receipt must not cause deadline retention of following input")
  check(text==(passed ? "aㅏ":"ㅏ"),"original delivery decision and following composition preserved")
 }
 }
}


for change in ["tag","code"] {
 let b=SourceSwitchBarrier();var switches=0,text="",range=NSRange(location:0,length:0)
 b.source={en};b.read={.init(field:field,text:text,selection:range)};b.select={_ in switches+=1;return noErr}
 b.beginOnsetReplay(field:field,before:"",caret:0)
 let event=originPacket(0,100,0x4852000100000111)
 b.observeBeforeOnset(.keyDown,event,waiting:true)
 let wrong=change=="tag" ? originPacket(0,200,0x4852000100000112):event.copy()!
 wrong.timestamp=200
 if change=="code"{wrong.setIntegerValueField(.keyboardEventKeycode,value:1)}
 b.confirmOnsetDelivery(wrong,passed:true)
 check(b.request(ko),"wrong receipt test boundary")
 b.step();check(switches==0 && b.expected?.0=="","wrong \(change) cannot acknowledge another key")
 let right=event.copy()!;right.timestamp=300;b.confirmOnsetDelivery(right,passed:true)
 text="a";range=NSRange(location:1,length:0);b.step()
 check(switches==1,"correct tagged receipt still resumes after wrong \(change)")
 b.fail("test_cleanup")
}
do {
 let b=SourceSwitchBarrier();var switches=0
 b.source={en};b.read={.init(field:field,text:"",selection:NSRange(location:0,length:0))};b.select={_ in switches+=1;return noErr}
 b.beginOnsetReplay(field:field,before:"",caret:0)
 let event=key(0);event.timestamp=100;event.setIntegerValueField(.eventSourceUserData,value:0)
 b.observeBeforeOnset(.keyDown,event,waiting:true)
 let changed=event.copy()!;changed.timestamp=200;b.confirmOnsetDelivery(changed,passed:true)
 check(b.request(ko),"untagged receipt test boundary");b.step()
 check(switches==0,"untagged changed timestamp is never guessed from key code")
 b.confirmOnsetDelivery(event,passed:false);b.step();check(switches==1,"exact legacy timestamp receipt remains supported")
 b.fail("test_cleanup")
}

// Autorepeat may carry the press origin again. Every receipt still owns one
// occurrence; a later same-key event must not overwrite an earlier one.
for retimed in [false,true] {
 let b=SourceSwitchBarrier()
 b.source={en};b.read={.init(field:field,text:"",selection:NSRange(location:0,length:0))}
 b.beginOnsetReplay(field:field,before:"",caret:0)
 let first=originPacket(0,100,0x4852000100000222),repeated=originPacket(0,200,0x4852000100000222)
 repeated.setIntegerValueField(.keyboardEventAutorepeat,value:1)
 b.observeBeforeOnset(.keyDown,first,waiting:true)
 b.observeBeforeOnset(.keyDown,repeated,waiting:true)
 check(b.diagnosticCounts.awaitingOnset==2,"repeated press identity preserves both pending occurrences")
 let receipt=first.copy()!,repeatReceipt=repeated.copy()!
 if retimed{receipt.timestamp=300;repeatReceipt.timestamp=400}
 b.confirmOnsetDelivery(receipt,passed:true)
 check(b.diagnosticCounts.awaitingOnset==1 && b.expected?.0=="a","first receipt confirms exactly one occurrence")
 b.confirmOnsetDelivery(repeatReceipt,passed:true)
 check(b.diagnosticCounts.awaitingOnset==0 && b.expected?.0=="aa","repeat receipt confirms remaining occurrence exactly once")
 b.fail("test_cleanup")
}

// Diagnostic wait reasons use existing decisions, emit once per reason, and
// leave the same text/caret/source/receipt safety checks in place.
do {
 let b=SourceSwitchBarrier();var available=true,text="",range=NSRange(location:0,length:0),source=en,ready=true,stages:[String]=[],switches=0
 b.read={available ? .init(field:field,text:text,selection:range):nil};b.readFocus={field};b.ready={ready};b.source={source}
 b.trace={stages.append($0)};b.select={source=$0;switches+=1;return noErr}
 b.observe(.keyDown,key(0));check(b.request(ko),"diagnostic mismatch request")
 for _ in 0..<5 {b.step()}
 check(stages.filter{$0=="waiting_for_text"}.count==1 && switches==0,"unchanged text mismatch emits one wait reason without switching")
 text="a";b.step();check(stages.last=="waiting_for_caret" && switches==0,"caret mismatch is distinct from text mismatch")
 available=false;b.step();check(stages.last=="waiting_for_snapshot","unreadable snapshot is distinct from a changed field")
 ready=false;b.step();check(stages.last=="waiting_for_repair","repair wait is distinct from unreadable snapshot")
 ready=true;available=true;range=NSRange(location:1,length:0);b.step()
 check(switches==1 && stages.last=="editor_confirmed_switch","wait diagnostics preserve normal source completion")
 b.step();check(!b.busy,"diagnosed boundary finishes normally")
 b.fail("test_cleanup")
}

// A native backspace can leave a live syllable. Its remaining observed keys
// may be reused only after the complete post-delete text/caret is verified.
for scenario in ["live", "repeat", "whole", "text", "caret", "focus", "source", "unverified", "shortcut"] {
 let b=SourceSwitchBarrier();var text="pre: ",range=NSRange(location:5,length:0),source=ko,focused=field,switches=0
 b.read={.init(field:focused,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 for code:UInt16 in [15,40,1] {b.observe(.keyDown,key(code));text=b.expected!.0;range=b.expected!.1}
 if scenario=="unverified" {text="pre: changed";range=NSRange(location:text.utf16.count,length:0)}
 b.observe(.keyDown,key(51,scenario=="shortcut" ? .maskAlternate:[]))
 text="pre: 가";range=NSRange(location:6,length:0)
 if scenario=="repeat" {b.observe(.keyDown,key(51));text="pre: ㄱ";b.observe(.keyDown,key(40));text="pre: 가"}
 if scenario=="whole" {text="pre: ";range=NSRange(location:5,length:0)}
 if scenario=="text" {text="new: 가"}
 if scenario=="caret" {range=NSRange(location:5,length:0)}
 if scenario=="focus" {focused=other}
 if scenario=="source" {source=en}
 b.observe(.keyDown,key(1))
 let joins=["live","repeat"].contains(scenario)
 check((b.expected?.0=="pre: 간")==joins,"post-backspace \(scenario) requires exact original field, text, caret, source and observed prefix")
 if joins {text="pre: 간";range=NSRange(location:6,length:0);check(b.request(en),"post-backspace boundary requested");b.step();b.step();check(source==en && switches==1 && !b.busy,"post-backspace first switch completes")}
 if scenario=="whole" {check(b.expected?.0=="pre: ㄴ","whole-syllable deletion uses actual empty baseline")}
 b.fail("test_cleanup")
}

// Deletion may commit the previous syllable while retaining a detached initial.
// Its observed-key boundary must survive the next medial instead of making 익.
do {
 let b=SourceSwitchBarrier();var text="앞🙂 ",range=NSRange(location:text.utf16.count,length:0),source=ko,switches=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;switches+=1;return noErr}
 for code:UInt16 in [15,46,3,38,0,2,37,15,38] {b.observe(.keyDown,key(code));text=b.expected!.0;range=b.expected!.1}
 check(text=="앞🙂 그럼이거","phrase before component deletion")
 b.observe(.keyDown,key(51));text="앞🙂 그럼이ㄱ";range=NSRange(location:text.utf16.count,length:0)
 b.observe(.keyDown,key(38));check(b.expected?.0=="앞🙂 그럼이거","verified observed-key split keeps preceding 이 committed")
 text="앞🙂 그럼이거";range=NSRange(location:text.utf16.count,length:0)
 check(b.request(en),"phrase switch requested");b.step();b.step()
 check(source==en && switches==1 && !b.busy,"phrase switches on first request after component deletion")
 b.fail("test_cleanup")
}

// Web editors expose an AX-only terminal LF and use NBSP for typed spaces.
// Acknowledge only observed insertion style and that one original end suffix.
for id in KoreanKeyboardLayout.supportedIDs {
 let b=SourceSwitchBarrier();var text="앞🙂\n",range=NSRange(location:3,length:0),source=id
 let keys:[UInt16]=id==ko ? [15,40,1]:([KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID].contains(id) ? [40,3,1]:[5,0,45])
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;return noErr}
 for c in keys {b.observe(.keyDown,key(c))}
 text="앞🙂간";range=NSRange(location:4,length:0)
 check(b.matches(.init(field:field,text:text,selection:range)),"native-layout \(id) exact insertion with AX-only end LF removed")
 check(b.request(en),"terminal LF request");b.step();b.step();check(source==en && !b.busy,"terminal LF does not freeze following input")
 b.fail("test_cleanup")
}
do {
 let b=SourceSwitchBarrier();var text="keep space \n",range=NSRange(location:11,length:0),source=en
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;return noErr}
 for c:UInt16 in [0,49,11,49] {b.observe(.keyDown,key(c))}
 text="keep space A\u{00a0}b\u{00a0}";range=NSRange(location:text.utf16.count,length:0)
 check(b.matches(.init(field:field,text:text,selection:range)),"one terminal LF plus typed NBSP/case style is exact editor equivalence")
 for wrong in ["keep\u{00a0}space A\u{00a0}b\u{00a0}","keep space A b  ","keep space A b", "keep space A b\u{200b}","keep space A b\n\n"] {
  check(!b.matchesText(.init(field:field,text:wrong,selection:range)),"surrounding space, missing/doubled character and other whitespace remain mismatches")
 }
 check(!b.matches(.init(field:field,text:text,selection:NSRange(location:11,length:0))),"equivalent text never bypasses caret acknowledgment")
 check(b.request(ko),"styled web request");b.step();b.step();check(source==ko && !b.busy,"styled web boundary completes without text edits")
 b.fail("test_cleanup")
}
// A contradictory editor body must not capture the next original key. Settle
// only suppressed modifier edges; no text replay or source change is permitted.
for blocked in [false,true] {
 let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0),ready=true,switches=0,posts=0,retained=0,settled=0,stages:[String]=[]
 b.read={.init(field:field,text:text,selection:range)};b.source={en};b.ready={ready};b.select={_ in switches+=1;return noErr};b.send={_ in posts+=1};b.retained={retained += $0.count};b.cancelledModifiers={settled += $0.count};b.trace={stages.append($0)}
 b.observe(.keyDown,key(0));text="external";range=NSRange(location:8,length:0)
 check(b.request(ko),"divergent boundary request");b.step()
 let up=key(54);up.type = .flagsChanged;up.flags=[];check(b.receive(.flagsChanged,up),"suppressed right release queued before following input")
 if blocked{ready=false}
 check(b.receive(.keyDown,key(11))==blocked,"divergence passes current physical input only when no repair owns it")
 check(b.busy==blocked && settled==(blocked ? 0:1),"divergence cancellation settles observed modifier edges")
 check(posts==0 && switches==0 && retained==0,"no source selection, synthetic replay or text retention on input resumption")
 if !blocked{check(stages.contains("editor_diverged_input_resumed"),"content-free cancellation reason recorded")}
 b.fail("test_cleanup")
}
do {
 let b=SourceSwitchBarrier();var text="\n",range=NSRange(location:0,length:0)
 b.read={.init(field:field,text:text,selection:range)};b.source={en}
 b.observe(.keyDown,key(0));text="";check(b.request(ko),"empty web prefix boundary");b.step()
 check(b.receive(.keyDown,key(11)) && b.busy,"AX-only LF removal before delayed first character remains a pending prefix")
 b.fail("test_cleanup")
}

do {
 let b=SourceSwitchBarrier();var text="",range=NSRange(location:0,length:0),settled=0
 b.read={.init(field:field,text:text,selection:range)};b.source={en};b.cancelledModifiers={settled += $0.count}
 b.observe(.keyDown,key(0));text="external";range=NSRange(location:8,length:0);check(b.request(ko),"unmapped modifier boundary");b.step()
 let left=key(55,.maskCommand);left.type = .flagsChanged;check(b.receive(.flagsChanged,left),"left Command remains owned by the existing ordered queue")
 check(b.receive(.keyDown,key(11,.maskCommand)) && b.busy && settled==0,"unmapped modifier is never discarded to resume following input")
 b.fail("test_cleanup")
}

do {
 let b=SourceSwitchBarrier();var text="\n",range=NSRange(location:0,length:0),source=ko
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;return noErr}
 for c:UInt16 in [15,40,1] {b.observe(.keyDown,key(c))}
 text="간";range=NSRange(location:1,length:0);b.observe(.keyDown,key(51));text="가"
 b.observe(.keyDown,key(1));check(b.matches(.init(field:field,text:"간",selection:range)),"web LF equivalence also preserves verified deletion continuation")
 b.fail("test_cleanup")
}
do {
 let b=SourceSwitchBarrier();var text="\n",range=NSRange(location:0,length:0),source=en,writes=0
 b.read={.init(field:field,text:text,selection:range)};b.source={source};b.select={source=$0;return noErr};b.applySelection={_,_ in writes+=1;return false}
 for c:UInt16 in [5,34,17,4,32,11] {b.observe(.keyDown,key(c))}
 text="github";range=NSRange(location:0,length:6);b.observe(.keyDown,key(0,.maskCommand));check(b.request(ko),"web select-all boundary")
 for _ in 0..<4{b.step()}
 check(source==ko && !b.busy && writes==0,"explicit select-all uses verified body length after AX-only terminal LF disappears")
 b.fail("test_cleanup")
}

print("Source switch barrier:",checks,"checks passed")
