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
 gate.forwarded={type,event in engine.captureEventOrigin(type,event)}
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
print("Source switch barrier:",checks,"checks passed")
