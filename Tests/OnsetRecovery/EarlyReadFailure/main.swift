// Initial AX failure must not disable observation of subsequent input.
// All snapshots and key posts are test doubles; no global event tap is started.
import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
final class Context {
 var source=onsetKoreanID;var busy=false;var posts=0
 var field=AXUIElementCreateApplication(1234)
 var snap:OnsetSnapshot?
 let e=OnsetRecoveryEngine()
 init(){
  e.enabled=true;e.testSource={self.source};e.canBeginRepair={!self.busy};e.testPost={_ in self.posts+=1};e.testSnapshot={self.snap}
  let g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();g.configureEarly(true)
  for code:UInt16 in [15,40]{let v=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!;v.flags=[];_ = g.receive(.keyDown,v)}
 }
 func pause(){e.unavailableReason="text_unreadable";e.sampleEarly(nil,now:e.gate!.reservation()!.time+0.151);check(e.enabled && e.waitingForContext,"early pause entered");check(e.retainedInput.count==1,"held event isolated")}
 func view(_ f:AXUIElement?=nil,_ selection:NSRange=NSRange(location:1,length:0)){snap=OnsetSnapshot(element:f ?? field,text:"ㄱ",selection:selection)}
 func safe(){check(posts==0,"no stale replay");check(e.retainedInput.count==1,"old event remains isolated")}
}
for reason in ["not_supported_text_field","focused_element_unreadable","text_unreadable","selection_unreadable","selection_invalid"] {
 let c=Context();c.e.unavailableReason=reason;c.e.sampleEarly(nil,now:c.e.gate!.reservation()!.time+0.151)
 check(c.e.waitingForContext && c.e.enabled,"all classified transient reads pause");c.view();c.e.resumeIfReady(now:1);c.e.resumeIfReady(now:1.11);check(!c.e.waitingForContext,"classified transient resumes");c.safe();c.e.closeSession()
}
// Production manual-edit / mismatch / external capture predicates use this shared gate.
for label in ["manual_jamo_or_hanja_edit","mismatch_repair","external_key_capture"] {
 let c=Context();c.pause();c.busy=true;c.view();c.e.resumeIfReady(now:1);c.e.resumeIfReady(now:1.11)
 c.e.unavailableReason="not_supported_text_field";c.e.sampleEarly(nil)
 let key=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;key.flags=[]
 check(c.e.gate!.receive(.keyDown,key) != nil,"\(label): input is not held")
 check(c.e.gate!.reservation()==nil && !c.e.recovering,"\(label): no repair starts")
 c.busy=false;c.e.sampleEarly(nil);_ = c.e.gate!.receive(.keyDown,key)
 check(c.e.gate!.reservation() != nil,"\(label): future detection can return")
 c.safe();c.e.closeSession()
}
let source=Context();source.pause();source.view();source.source="com.apple.keylayout.ABC";source.e.resumeIfReady(now:1);source.e.resumeIfReady(now:2);check(source.e.waitingForContext,"non-Korean cannot resume")
source.source=onsetKoreanID;source.e.resumeIfReady(now:3);source.e.resumeIfReady(now:3.11);check(!source.e.waitingForContext,"supported source stabilizes");source.safe();source.e.closeSession()
let fields=Context();fields.pause();fields.view();fields.e.resumeIfReady(now:1)
let b=AXUIElementCreateApplication(5678);fields.view(b);fields.e.resumeIfReady(now:1.09);fields.e.resumeIfReady(now:1.15);check(fields.e.waitingForContext,"new field restarts stability interval")
fields.e.resumeIfReady(now:1.20);check(!fields.e.waitingForContext && CFEqual(fields.e.lastEditable!.element,b),"resume uses new stable field");fields.safe();fields.e.closeSession()
let selected=Context();selected.pause();selected.view(nil,NSRange(location:0,length:1));selected.e.resumeIfReady(now:1);selected.e.resumeIfReady(now:2);check(selected.e.waitingForContext,"selection prevents resume")
selected.view();selected.e.resumeIfReady(now:3);selected.snap=nil;selected.e.resumeIfReady(now:3.09);selected.view();selected.e.resumeIfReady(now:3.15);selected.e.resumeIfReady(now:3.21);check(selected.e.waitingForContext,"missing observation resets stability")
selected.e.resumeIfReady(now:3.26);check(!selected.e.waitingForContext,"new uninterrupted stability resumes");selected.safe();selected.e.closeSession()
for reason in ["secure_input","secure_field","accessibility_permission","target_not_frontmost","active_composition"] {
 let c=Context();c.e.unavailableReason=reason;c.e.sampleEarly(nil,now:c.e.gate!.reservation()!.time+0.151)
 check(!c.e.enabled && !c.e.waitingForContext,"hard failure remains terminal: \(reason)");check(c.posts==0,"hard failure posts nothing");c.e.closeSession()
}
let changed=Context();changed.source="com.apple.keylayout.ABC";changed.e.unavailableReason="text_unreadable";changed.e.sampleEarly(nil,now:changed.e.gate!.reservation()!.time+0.151);check(!changed.e.enabled && !changed.e.waitingForContext,"source change outranks transient failure");changed.e.closeSession()
let busy=Context();busy.busy=true;busy.e.unavailableReason="text_unreadable";busy.e.sampleEarly(nil,now:busy.e.gate!.reservation()!.time+0.151);check(!busy.e.enabled && !busy.e.waitingForContext,"existing manual edit outranks transient failure");busy.e.closeSession()
let lifecycle=Context();lifecycle.pause();let controller=OnsetRecoveryController();controller.engine=lifecycle.e
check(controller.prepareManualEdit(),"manual edit permitted when paused");controller.stop();lifecycle.view();lifecycle.e.resumeIfReady(now:9);lifecycle.e.resumeIfReady(now:10);check(!lifecycle.e.enabled,"lifecycle stop cannot be resumed");check(lifecycle.posts==0,"lifecycle stop never replays");lifecycle.e.closeSession()


let grace=Context();let reserved=grace.e.gate!.reservation()!.time;grace.e.unavailableReason="selection_invalid"
grace.e.sampleEarly(nil,now:reserved+0.10);check(grace.e.enabled && !grace.e.waitingForContext && grace.e.gate!.reservation() != nil,"existing 100ms grace retained")
grace.e.sampleEarly(nil,now:reserved+0.149);check(!grace.e.waitingForContext,"no pause before 150ms")
grace.e.sampleEarly(nil,now:reserved+0.151);check(grace.e.enabled && grace.e.waitingForContext && grace.e.gate!.reservation()==nil,"pause after grace")
grace.e.closeSession()
// An expired untouched attempt needs no 100ms field stabilization or session restart.
for expired in [false,true] {
 let e=OnsetRecoveryEngine();let g=OnsetInputGate(marker:e.marker);e.gate=g;e.enabled=true
 e.testSource={onsetKoreanID};var posts=0;e.testPost={_ in posts+=1}
 let field=AXUIElementCreateApplication(1234)
 g.beat();g.configureEarly(true)
 let down=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;down.flags=[]
 _ = g.receive(.keyDown,down)
 let start=g.reservation()!.time
 if expired{g.heartbeat=0;g.poll()}
 e.unavailableReason="text_unreadable";e.sampleEarly(nil,now:start+0.151)
 check(e.enabled && !e.waitingForContext && g.healthy(),"untouched attempt keeps observation available")
 check(g.reservation()==nil && e.pending.isEmpty && posts==0,"no stale edit or replay")
 let snap=OnsetSnapshot(element:field,text:"ㄱㅏㄴ ",selection:NSRange(location:4,length:0))
 e.sampleEarly(snap);e.unavailableReason="not_supported_text_field";e.sampleEarly(nil)
 g.beat();_ = g.receive(.keyDown,down)
 check(g.reservation() != nil && e.earlyBaseline?.text==snap.text,"next outside onset keeps fresh baseline without stabilization")
 e.closeSession()
}
// A gate-side empty queue may already have moved into the engine.
let moved=Context();moved.e.collectHeld();moved.e.gate!.heartbeat=0;moved.e.gate!.poll()
check(moved.e.gate!.healthy(),"gate cannot decide whether engine holds input")
moved.e.unavailableReason="text_unreadable";moved.e.sampleEarly(nil)
check(moved.e.waitingForContext && moved.e.retainedInput.count==1 && moved.posts==0,"engine pending input retains old safety path")
moved.e.closeSession()
print("PASS total \(checks) initial read failure assertions; no OS key posting")
