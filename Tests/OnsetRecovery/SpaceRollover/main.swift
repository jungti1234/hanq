import AppKit
var checks=0
func check(_ b:Bool,_ m:String){checks+=1;if !b{print("FAIL \(m)");exit(1)}}
func key(_ code:UInt16,_ down:Bool=true)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
final class Case {
 let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(1234),other=AXUIElementCreateApplication(5678)
 let g:OnsetInputGate
 var text="ㅇㅣ거 ",range=NSRange(location:4,length:0),source=onsetKoreanID
 var writes=0,selected=0;var delivered:[(UInt16,Bool)]=[];var replacementDelay=0.0
 init(holdPrevious:Bool=false){
  g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();e.enabled=true;e.testSource={self.source}
  e.testCanSelect={true};e.testCanReplaceText={true}
  e.testSnapshot={.init(element:self.field,text:self.text,selection:self.range)}
  e.testOriginalSnapshot={_ in .init(element:self.field,text:self.text,selection:self.range)}
  e.testSetRange={_,r in self.selected+=1;self.range=r;return .success}
  e.testReplaceText={_,value in
   self.writes+=1
   let apply={self.text=value;self.range=NSRange(location:value.utf16.count,length:0)}
   if self.replacementDelay==0{apply()}else{DispatchQueue.main.asyncAfter(deadline:.now()+self.replacementDelay,execute:apply)}
   return .success
  }
  e.testPost={v in _=self.g.receive(v.type,v);self.receive(v)}
  e.earlyBaseline = .init(element:field,text:"",selection:NSRange(location:0,length:0));e.publishPassedBaseline(e.earlyBaseline)
  g.configureEarly(false)
  for c:UInt16 in [2,37,15,38]{_ = g.receive(.keyDown,key(c));if !holdPrevious || c != 38{_ = g.receive(.keyUp,key(c,false))}}
  _ = g.receive(.keyDown,key(49))
  check(g.passedObservation()?.pressed==(holdPrevious ? [38,49]:[49]),"physical held set matches setup")
 }
 func receive(_ v:CGEvent){
  let code=UInt16(v.getIntegerValueField(.keyboardEventKeycode)),down=v.type == .keyDown
  delivered.append((code,down));guard down else{return}
  if code==15{text="이거 ㄱ"}
  if code==46{text="이거 그"}
  if code==1{text="이거 근"}
  range=NSRange(location:text.utf16.count,length:0)
 }
 func physical(_ code:UInt16,_ down:Bool=true){let v=key(code,down);if g.receive(v.type,v) != nil{receive(v)}}
 func spin(_ seconds:Double=0.08){let end=Date().addingTimeInterval(seconds);while Date()<end{g.beat();RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
for delayed in [false,true] {
 let c=Case();c.replacementDelay=delayed ? 0.025:0;c.e.sample()
 check(c.writes==1,"committed Space text may be replaced before its release")
 c.physical(15);c.physical(49,false);c.physical(15,false);c.physical(46);c.physical(46,false);c.physical(1);c.physical(1,false);c.spin()
 check(c.text=="이거 근" && c.range==NSRange(location:"이거 근".utf16.count,length:0),"following word/caret survives Space rollover")
 check(c.delivered.map{Int($0.0)}==[15,49,15,46,46,1,1],"exact original down/up order; no fabricated Space down")
 check(c.delivered.filter{$0.0==49}.count==1 && !c.delivered.first(where:{$0.0==49})!.1,"only original Space release delivered once")
 check(!c.e.recovering && c.e.pending.isEmpty && c.e.retainedInput.isEmpty && c.g.healthy(),"no stranded input")
 c.e.closeSession()
}
for mode in ["held_previous","other_down","unsupported","race","source"] {
 let c=Case(holdPrevious:mode=="held_previous")
 if mode=="other_down"{_ = c.g.receive(.keyDown,key(15))}
 if mode=="unsupported"{c.e.testCanReplaceText={false}}
 if mode=="race"{c.e.testCanReplaceText={_ = c.g.receive(.keyDown,key(15));return true}}
 if mode=="source"{c.source="com.apple.keylayout.ABC"}
 c.e.sample();c.spin(0.01)
 check(c.writes==0 && c.selected==0 && !c.e.recovering,"reject unsafe Space claim: \(mode)")
 check(c.g.take().isEmpty && c.e.pending.isEmpty && c.e.retainedInput.isEmpty,"rejected claim never quarantines keys")
 c.e.closeSession()
}
print("PASS \(checks) committed-Space rollover/atomic-claim/order checks; no OS keys posted")
