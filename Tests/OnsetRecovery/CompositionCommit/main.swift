import AppKit
var checks=0
func check(_ ok:Bool,_ message:String){checks+=1;precondition(ok,message)}
func key(_ code:UInt16,_ down:Bool)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
final class Case {
 let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(1234),other=AXUIElementCreateApplication(5678)
 var gate:OnsetInputGate!
 let mode:String
 var text="앞🙂 ㅇ뒤",selection=NSRange(location:5,length:0),marked=true,source=onsetKoreanID
 var commits:[CGEvent]=[],replays:[CGEvent]=[],selections=0,reads=0
 var started=0.0
 init(_ mode:String){
  self.mode=mode;marked=mode != "detached"
  e.enabled=true;e.recovering=true;e.repairSourceID=source;e.planElement=field
  e.currentPlan=OnsetRecoveryPlan(before:"앞🙂 뒤",caret:4,allowSingle:true,roman:"ㅇ",codes:[(2,false)])
  gate=OnsetInputGate(marker:e.marker);gate.beat();check(gate.begin(),"bounded input hold begins");e.gate=gate
  e.testSource={self.source};e.testCanSelect={true}
  e.testSnapshot={
   self.reads+=1
   if self.mode=="transient",!self.commits.isEmpty,self.reads<5{self.e.unavailableReason="text_unreadable";return nil}
   self.e.unavailableReason=""
   return OnsetSnapshot(element:self.mode=="field" && !self.commits.isEmpty ? self.other:self.field,text:self.text,selection:self.selection)
  }
  e.testSetRange={target,range in check(CFEqual(target,self.field),"selection stays on original field");self.selections+=1;self.selection=range;return .success}
  e.testPostCompositionCommit={target,event in
   check(CFEqual(target,self.field),"cursor command targets original field")
   check(event.getIntegerValueField(.keyboardEventKeycode)==123 && event.flags.isEmpty,"only plain Left is posted")
   check(event.getIntegerValueField(.eventSourceUserData)==self.e.compositionCommitMarker && self.e.compositionCommitMarker != self.e.marker && OnsetInputGate.isRecoveryMarker(self.e.compositionCommitMarker),"commit is a distinct repair identity")
   _=self.gate.receive(event.type,event)
   check(self.gate.seenCount()==0,"commit must never acknowledge a character replay")
   self.commits.append(event)
   if self.mode=="post_rejected"{return false}
   guard event.type == .keyUp else{return true}
   if self.mode=="ignored"{return true}
   if self.mode=="body"{self.text="changed";return true}
   if self.mode=="source"{self.source="com.apple.keylayout.ABC";return true}
   if self.mode=="caret"{self.selection=NSRange(location:0,length:0);return true}
   if self.mode=="secure"{self.e.testSnapshot={self.e.unavailableReason="secure_input";return nil};return true}
   if self.mode=="permission"{self.e.testSnapshot={self.e.unavailableReason="accessibility_permission";return nil};return true}
   if self.mode=="stopped"{self.e.closeSession();return true}
   let complete={self.marked=false;self.selection=NSRange(location:4,length:0)}
   if self.mode=="delayed" || self.mode=="transient"{DispatchQueue.main.asyncAfter(deadline:.now()+0.025,execute:complete)}else{complete()}
   return true
  }
  e.testPost={event in
   check(!self.marked,"active marked text must be committed before any replacement")
   self.replays.append(event);_=self.gate.receive(event.type,event)
   guard event.type == .keyDown else{return}
   let code=event.getIntegerValueField(.keyboardEventKeycode)
   switch code {
   case 2:check(self.selection==NSRange(location:4,length:1),"only the original onset is replaced");self.text="앞🙂 ㅇ뒤"
   case 4:self.text="앞🙂 오뒤"
   case 37:self.text="앞🙂 외뒤"
   case 1:self.text="앞🙂 왼뒤"
   default:check(false,"unexpected replay")
   }
   self.selection=NSRange(location:5,length:0)
  }
  for code:UInt16 in [4,37,1]{for down in [true,false]{e.pending.append(key(code,down))}}
 }
 func run(){started=ProcessInfo.processInfo.systemUptime;e.replaceAndReplay(e.currentPlan!,e.testSnapshot!()!)}
 func spin(_ seconds:Double=0.22){let end=Date().addingTimeInterval(seconds);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
for mode in ["marked","detached","delayed","transient"] {
 let c=Case(mode),hold=c.gate.holdUntil;c.run()
 if mode=="delayed" || mode=="transient"{check(c.selections==0 && c.replays.isEmpty,"posting cursor keys is not a commit acknowledgment")}
 c.spin()
 check(c.text=="앞🙂 왼뒤" && c.selection==NSRange(location:5,length:0),"exact text, UTF-16 caret and suffix survive: \(mode)")
 check(c.commits.map{$0.type} == [.keyDown,.keyUp],"one commit pair, no retries")
 check(c.replays.map{$0.getIntegerValueField(.keyboardEventKeycode)} == [2,2,4,4,37,37,1,1],"replacement and all queued edges retain order")
 check(c.e.pending.isEmpty && c.e.retainedInput.isEmpty && !c.e.recovering && c.e.enabled,"no input is stranded")
 check(c.gate.holdUntil==0 && ProcessInfo.processInfo.systemUptime<c.started+0.8 && hold>c.started,"commit does not renew the original hold")
 c.e.closeSession()
}
for mode in ["ignored","body","field","source","caret","secure","permission","stopped","post_rejected"] {
 let c=Case(mode);let original=c.e.pending;let hold=c.gate.holdUntil;c.run();c.spin()
 check(c.selections==0 && c.replays.isEmpty,"unverified commit cannot select or replay: \(mode)")
 check(c.e.pending.count==original.count && zip(c.e.pending,original).allSatisfy{$0 === $1},"every original edge remains owned and unchanged")
 check(c.commits.count<=2,"failure never retries a possibly delivered commit")
 check(!c.e.enabled && (mode=="stopped" ? !c.gate.healthy():!c.e.recovering),"failure stops boundedly: \(mode)")
 check(c.gate.holdUntil<=hold,"failure never extends hold")
 c.e.closeSession()
}
// Explicit detached editor doubles may acknowledge an already committed glyph,
// but still cannot bypass the full field/source/text/caret recheck.
for change in ["body","caret","field","source","reject"] {
 let c=Case("marked")
 c.e.testCommitComposition={_ in
  switch change {
  case "body":c.text="changed"
  case "caret":c.selection=NSRange(location:0,length:0)
  case "field":c.e.testSnapshot={OnsetSnapshot(element:c.other,text:c.text,selection:c.selection)}
  case "source":c.source="com.apple.keylayout.ABC"
  default:return false
  };return true
 }
 c.run();c.spin(0.02)
 check(c.selections==0 && c.replays.isEmpty && c.commits.isEmpty,"test acknowledgment still revalidates \(change)")
 check(c.e.pending.count==6,"unsafe detached double never drops input");c.e.closeSession()
}
print("PASS \(checks) composition commit, native selection ordering, delayed receipt, context/permission/secure failure and original-input preservation checks; no OS keys")
