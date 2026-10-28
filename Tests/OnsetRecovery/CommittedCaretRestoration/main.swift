import AppKit
var checks=0
func check(_ ok:Bool,_ message:String){checks+=1;if !ok{print("FAIL \(message)");exit(1)}}
func key(_ code:UInt16,_ down:Bool)->CGEvent{let v=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;v.flags=[];return v}
final class Case {
 let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(1234),other=AXUIElementCreateApplication(5678)
 let gate:OnsetInputGate;let mode:String
 var text="ㅇㅣ거 ",selection=NSRange(location:4,length:0),source=onsetKoreanID
 var focused=true,restoring=false,writes=0,restoreRequests=0;var posts:[(UInt16,Bool)]=[]
 init(_ mode:String){
  self.mode=mode;gate=OnsetInputGate(marker:e.marker);e.gate=gate;gate.beat();e.enabled=true
  e.testSource={self.source};e.testCanSelect={true};e.testCanReplaceText={true}
  e.testSnapshot={self.focused ? .init(element:self.field,text:self.text,selection:self.selection):.init(element:self.other,text:"other",selection:NSRange(location:5,length:0))}
  e.testOriginalSnapshot={_ in
   if self.mode=="transient_restore",self.restoring,self.selection.length>0{return nil}
   return .init(element:self.field,text:self.text,selection:self.selection)
  }
  e.testSetRange={_,range in
   if range.length>0{DispatchQueue.main.asyncAfter(deadline:.now()+0.01){self.selection=range}}
   else {
    self.restoring=true;self.restoreRequests+=1
    if self.mode=="focus"{self.focused=false}
    if self.mode=="source"{self.source="com.apple.keylayout.ABC"}
    if self.mode=="changed_text"{self.text="changed"}
    if self.mode != "never_restore"{DispatchQueue.main.asyncAfter(deadline:.now()+0.025){self.selection=range}}
   }
   return .success
  }
  e.testReplaceText={_,_ in
   self.writes+=1
   for code:UInt16 in [15,46]{for down in [true,false]{check(self.gate.receive(down ? .keyDown:.keyUp,key(code,down))==nil,"following originals quarantined while AX result unknown")}}
   return self.mode=="error" ? .cannotComplete:.success
  }
  e.testPost={v in
   check(self.selection.length==0,"no original key while own selection remains")
   _=self.gate.receive(v.type,v);let code=UInt16(v.getIntegerValueField(.keyboardEventKeycode));let down=v.type == .keyDown;self.posts.append((code,down))
   if down{self.text=code==15 ? "ㅇㅣ거 ㄱ":"ㅇㅣ거 그";self.selection=NSRange(location:self.text.utf16.count,length:0)}
  }
  gate.configureEarly(true)
  for code:UInt16 in [2,37,15,38,49]{for down in [true,false]{_ = gate.receive(down ? .keyDown:.keyUp,key(code,down))}}
 }
 func spin(){let end=Date().addingTimeInterval(0.42);while Date()<end{gate.beat();RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
for mode in ["ignored","error","transient_restore"] {
 let c=Case(mode);c.e.sample();c.spin()
 check(c.writes==1 && c.restoreRequests==1,"one text attempt and one asynchronous caret restore")
 check(c.posts.map{Int($0.0)}==[15,15,46,46],"unapplied text edit releases the exact original following pair order")
 check(c.text=="ㅇㅣ거 그" && c.selection==NSRange(location:c.text.utf16.count,length:0),"original split text and following native input preserved")
 check(c.e.pending.isEmpty && c.e.retainedInput.isEmpty && !c.e.recovering && c.e.enabled,"no stranded input after deferred caret acknowledgment")
 c.e.closeSession()
}
for mode in ["focus","source","changed_text","never_restore"] {
 let c=Case(mode);c.e.sample();c.spin()
 check(c.writes==1 && c.restoreRequests==1,"unsafe cancellation never repeats edit or restore")
 check(c.posts.isEmpty && c.e.pending.count+c.e.retainedInput.count==4,"changed/unverified context retains originals without foreign injection")
 c.e.closeSession()
}
print("PASS \(checks) asynchronous committed-caret restoration/order/context checks; no OS keys posted")
