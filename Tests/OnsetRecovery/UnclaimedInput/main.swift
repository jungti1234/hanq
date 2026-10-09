import AppKit
var checks=0
func check(_ ok:Bool,_ message:String){checks+=1;if !ok{print("FAIL \(message)");exit(1)}}
func key(_ code:UInt16,_ down:Bool=true)->CGEvent {let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
// An unknown field must never turn ordinary physical keys into retained input.
for collectBeforeFailure in [false,true] {
 let e=OnsetRecoveryEngine();e.enabled=true;e.testSource={onsetKoreanID}
 let g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();g.configureEarly(true)
 var passed=0;var posts=0;e.testPost={_ in posts+=1}
 let first=key(15);_ = g.receive(.keyDown,first);passed+=1
 let start=g.reservation()!.time
 for (code,down):(UInt16,Bool) in [(15,false),(40,true),(40,false),(1,true),(1,false)] {
  if g.receive(down ? .keyDown:.keyUp,key(code,down)) != nil{passed+=1}
  if collectBeforeFailure{e.collectHeld()}
 }
 e.unavailableReason="text_unreadable";e.sampleEarly(nil,now:start+0.151)
 let field=AXUIElementCreateApplication(1234)
 e.testSnapshot={OnsetSnapshot(element:field,text:"ㄱㅏㄴ",selection:NSRange(location:3,length:0))}
 e.resumeIfReady(now:1);e.resumeIfReady(now:1.11)
 check(passed==6 && posts==0 && e.pending.isEmpty && e.retainedInput.isEmpty,"unknown field: every original event passes exactly once without later replay")
 check(e.enabled && !e.waitingForContext && g.healthy(),"unknown field does not interrupt later observation")
 check(!g.claimEarly(),"a passed vowel invalidates the old consonant claim")
 e.closeSession()
}
// A next event may cross the gate while AX is returning the first snapshot.
let e=OnsetRecoveryEngine();e.enabled=true;e.testSource={onsetKoreanID};e.testCanSelect={true}
let g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();g.configureEarly(true)
_ = g.receive(.keyDown,key(15));var edits=0;var posts=0
let field=AXUIElementCreateApplication(1234)
e.testSetRange={_,_ in edits+=1;return .success};e.testPost={_ in posts+=1}
e.testSnapshot={check(g.receive(.keyDown,key(40)) != nil,"concurrent original event passes");return OnsetSnapshot(element:field,text:"ㄱ",selection:NSRange(location:1,length:0))}
e.sample();RunLoop.current.run(until:Date().addingTimeInterval(0.03))
check(edits==0 && posts==0 && !e.recovering && g.take().isEmpty,"stale snapshot cannot edit after a following original event")
e.closeSession()
// Once explicitly claimed, the existing bounded queue still holds both edges.
let claimed=OnsetInputGate(marker:1);claimed.beat();claimed.configureEarly(true)
_ = claimed.receive(.keyDown,key(15));check(claimed.claimEarly(),"verified claim available")
check(claimed.receive(.keyDown,key(40))==nil && claimed.receive(.keyUp,key(40,false))==nil,"claimed repair captures both edges")
check(claimed.take().map{$0.type} == [.keyDown,.keyUp],"claimed queue order preserved");claimed.stop()
// Immediate reentry must use the completed text, not the pre-repair baseline.
let completed=OnsetRecoveryEngine();completed.enabled=true;completed.recovering=true;completed.testSource={onsetKoreanID};completed.planElement=field
let cg=OnsetInputGate(marker:completed.marker);cg.beat();_ = cg.begin();completed.gate=cg
completed.lastEditable=OnsetSnapshot(element:field,text:"",selection:NSRange(location:0,length:0))
completed.testSnapshot={OnsetSnapshot(element:field,text:"간 ",selection:NSRange(location:2,length:0))}
completed.drain([]);RunLoop.current.run(until:Date().addingTimeInterval(0.03))
completed.unavailableReason="not_supported_text_field";completed.sampleEarly(nil)
check(completed.earlyBaseline?.text=="간 ","immediate outside observation uses completed baseline")
completed.closeSession()
print("PASS \(checks) unclaimed input preservation assertions; no OS key posting")
