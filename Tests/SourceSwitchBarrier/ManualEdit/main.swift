import AppKit
import Carbon
var checks=0
func check(_ v:@autoclosure ()->Bool,_ why:String){checks+=1;if !v(){fputs("FAIL: \(why)\n",stderr);exit(1)}}
let en="com.apple.keylayout.ABC",ko="com.apple.inputmethod.Korean.2SetKorean"
let field=AXUIElementCreateApplication(123),other=AXUIElementCreateApplication(456)
func key(_ code:CGKeyCode,_ flags:CGEventFlags=[])->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!;e.flags=flags;return e}
for pending in [false,true] {
 let b=SourceSwitchBarrier();var text="",selection=NSRange(location:0,length:0),source=en,time=0.0,switches=0,stages:[String]=[]
 b.now={time};b.source={source};b.read={.init(field:field,text:text,selection:selection)};b.readFocus={field};b.select={source=$0;switches+=1;return noErr};b.trace={stages.append($0)}
 for (char,code) in zip(Array("Tkdldnjfem"),[17,40,2,37,2,45,38,3,14,46]){
  b.observe(.keyDown,key(CGKeyCode(code),char=="T" ? .maskShift:[]));text.append(char);selection=NSRange(location:text.utf16.count,length:0)
 }
 check(b.expected?.0=="Tkdldnjfem","real typed history created")
 let token=b.beginManualEdit(field:field,source:en)!
 check(b.expected==nil,"old English prediction invalidated before paste")
 check(b.beginManualEdit(field:field,source:en)==nil,"second replacement cannot overlap")
 if pending {
  b.read={nil};check(b.request(ko),"in-flight manual edit owns switch even if AX temporarily unavailable")
  b.step();check(switches==0 && stages.contains("waiting_for_repair"),"no select before verified manual receipt")
  time=0.8;b.step();check(switches==0,"elapsed time does not bypass verification")
 }
 text="싸이월드";selection=NSRange(location:4,length:0);b.read={.init(field:field,text:text,selection:selection)}
 b.finishManualEdit(token,snapshot:.init(field:field,text:text,selection:selection))
 check(b.expected?.0==text && b.expected?.1==selection,"verified full text/caret adopted")
 if !pending{check(b.request(ko),"immediate right Command after completed conversion")}
 b.step();check(source==ko && switches==1,"first request selects Korean; no stale English wait")
 check(!stages.contains("waiting_for_text") && stages.contains("manual_edit_verified"),"verified conversion never waits for pre-conversion text")
}
// Failure, late completion, wrong field/source and teardown cannot revive stale history.
for scenario in 0..<6 {
 let b=SourceSwitchBarrier();var source=en,switches=0,retained:[CGEvent]=[]
 b.source={source};b.select={source=$0;switches+=1;return noErr};b.read={.init(field:field,text:"a",selection:NSRange(location:1,length:0))};b.retained={retained += $0}
 let token=b.beginManualEdit(field:field,source:en)!
 if scenario<4 {check(b.request(ko),"request while editing");check(b.receive(.keyDown,key(0)),"later physical input queued behind manual result")}
 var snapshot:SourceSwitchBarrier.Snapshot? = .init(field:field,text:"아",selection:NSRange(location:1,length:0))
 switch scenario {
 case 0:snapshot=nil
 case 1:snapshot = .init(field:other,text:"아",selection:NSRange(location:1,length:0))
 case 2:source=ko
 case 3:snapshot = .init(field:field,text:"아",selection:NSRange(location:9,length:0))
 case 4:b.fail("input_stopped")
 default:b.noteExternalEdit()
 }
 b.finishManualEdit(token,snapshot:snapshot);b.step()
 check(switches==0,"unsafe/obsolete completion cannot switch")
 check(b.expected==nil,"unsafe/obsolete completion cannot restore prediction")
 if scenario<4{check(retained.count==1 && retained[0].getIntegerValueField(.keyboardEventKeycode)==0,"preserve queued original input on failed verification")}
 b.finishManualEdit(token,snapshot:.init(field:field,text:"아",selection:NSRange(location:1,length:0)))
 check(b.expected==nil,"late success cannot undo a failed transaction")
}
for ready in [false,true] {
 let b=SourceSwitchBarrier();b.ready={ready};b.read={.init(field:field,text:"a",selection:NSRange(location:1,length:0))}
 if ready{_ = b.request(ko)}
 check(b.beginManualEdit(field:field,source:en)==nil,"do not discard active source boundary or unavailable repair")
 b.fail("input_stopped")
}
// The lease starts before asynchronous selection acknowledgment, not at paste.
// Cancellation during this earlier phase must retain queued input and ignore a
// late selection/paste completion without affecting a newer replacement.
for cancel in [false,true] {
 let b=SourceSwitchBarrier();var source=en,switches=0,retained:[CGEvent]=[]
 b.source={source};b.select={source=$0;switches+=1;return noErr};b.retained={retained += $0}
 b.read={.init(field:field,text:"Tkdldnjfem",selection:NSRange(location:0,length:10))}
 let token=b.beginManualEdit(field:field,source:en)!
 check(b.request(ko),"source request accepted during selection wait")
 for code:CGKeyCode in [15,40,1] {check(b.receive(.keyDown,key(code)),"following letters stay behind selection and paste")}
 b.step();check(switches==0 && retained.isEmpty,"no source or delivery before replacement acknowledgment")
 if cancel {
  b.finishManualEdit(token,snapshot:nil)
  check(retained.map{$0.getIntegerValueField(.keyboardEventKeycode)}==[15,40,1],"selection failure retains original input order")
  let next=b.beginManualEdit(field:field,source:en)!
  b.finishManualEdit(token,snapshot:.init(field:field,text:"stale",selection:NSRange(location:5,length:0)))
  check(b.request(ko),"new request remains scoped to new edit")
  b.step();check(switches==0,"late old acknowledgment cannot release a new request")
  b.finishManualEdit(next,snapshot:nil)
 }else{
  let final=SourceSwitchBarrier.Snapshot(field:field,text:"싸이월드",selection:NSRange(location:4,length:0))
  b.read={final};b.finishManualEdit(token,snapshot:final);b.step()
  check(switches==1 && source==ko,"verified selection and paste release exactly one pending switch")
  b.fail("test teardown")
 }
}
// The new fixed phases use existing nonblocking boundary collection and strict codecs.
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
for stage in [InputIncidentTrace.BoundaryStage.manualEditStarted,.manualEditVerified,.manualEditUnverified]{trace.sourceBoundary(stage,queued:0,awaitingOnset:0)}
trace.flush();trace.mark();trace.flush();let capture=captures.last!
check(capture.frames.filter{$0.kind == .sourceBoundary && $0.category>=29}.count==3,"manual phases retained")
check((try? RecorderTrace.decode(JSONEncoder().encode(capture))) != nil,"strict collector accepts fixed manual phases")
print("PASS \(checks) manual replacement boundary, real typed history, immediate/pending switch, unsafe completion and original-input preservation checks; no OS keys/AX")
