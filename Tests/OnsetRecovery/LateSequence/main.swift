import AppKit
var checks=0
func check(_ value:Bool,_ reason:String){checks+=1;precondition(value,reason)}
let word:[(UInt16,Bool)]=[(15,false),(40,false),(1,false),(49,false)]
func event(_ code:UInt16,_ down:Bool)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
func isCandidate(_ result:OnsetLateSequenceDetector.Result)->Bool{if case .candidate = result{return true};return false}
check(isCandidate(OnsetLateSequenceDetector.inspect(keys:word,before:"",caret:0,text:"ㄱㅏㄴ ",selection:NSRange(location:4,length:0))),"exact split first word")
check(isCandidate(OnsetLateSequenceDetector.inspect(keys:word,before:"앞뒤",caret:1,text:"앞ㄱㅏㄴ 뒤",selection:NSRange(location:5,length:0))),"observed baseline and suffix preserved")
for (text,range) in [("옛ㄱㅏㄴ ",NSRange(location:5,length:0)),("ㄱㅏㄴ ",NSRange(location:3,length:0)),("ㄱㅏㄴ ",NSRange(location:0,length:4))] {
 check(!isCandidate(OnsetLateSequenceDetector.inspect(keys:word,before:"",caret:0,text:text,selection:range)),"unrelated content/caret/selection rejected")
}
if case .complete=OnsetLateSequenceDetector.inspect(keys:word,before:"",caret:0,text:"간 ",selection:NSRange(location:2,length:0)){check(true,"normal native composition untouched")}else{check(false,"normal composition")}
for (text,caret) in [("",0),("ㄱ",1),("ㄱㅏ",2),("ㄱㅏㄴ",3)] {
 if case .waiting=OnsetLateSequenceDetector.inspect(keys:word,before:"",caret:0,text:text,selection:NSRange(location:caret,length:0)){check(true,"wait for complete publication")}else{check(false,"prefix must wait")}
}
final class Case {
 let e=OnsetRecoveryEngine();let g:OnsetInputGate;let field=AXUIElementCreateApplication(1234)
 var text="ㄱㅏㄴ ";var selection=NSRange(location:4,length:0);var source=onsetKoreanID;var edits=0;var writes=0;var posts:[(UInt16,CGEventType)]=[]
 init(){
  g=OnsetInputGate(marker:e.marker);g.beat();g.configureEarly(true);e.gate=g;e.enabled=true
  e.testSource={self.source};e.testCanSelect={true};e.testSnapshot={OnsetSnapshot(element:self.field,text:self.text,selection:self.selection)}
  e.testSetRange={_,range in self.edits+=1;self.selection=range;return .success}
  e.testCanReplaceText={true};e.testOriginalSnapshot={_ in OnsetSnapshot(element:self.field,text:self.text,selection:self.selection)}
  e.testReplaceText={_,value in self.writes+=1;self.text=value;self.selection=NSRange(location:value.utf16.count,length:0);return .success}
  e.testPost={v in
   let code=UInt16(v.getIntegerValueField(.keyboardEventKeycode));self.posts.append((code,v.type));_ = self.g.receive(v.type,v)
   if code==49,v.type == .keyDown {self.text="간 ";self.selection=NSRange(location:2,length:0)}
  }
  for (code,_) in word {for down in [true,false]{check(g.receive(down ? .keyDown:.keyUp,event(code,down)) != nil,"unclaimed originals pass")}}
  check(g.held.isEmpty && g.holdUntil==0,"observing history never holds original input")
 }
 func spin(){let end=Date().addingTimeInterval(0.08);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
let c=Case();c.e.sample();c.spin();check(c.edits==1 && c.writes==1 && c.posts.isEmpty,"one committed replacement and no physical replay");check(!c.e.recovering && c.e.pending.isEmpty,"replay completes without stranded input");check(c.e.lastEditable?.text=="간 ","new baseline is corrected text");c.e.sample();c.spin();check(c.edits==1,"same sequence cannot repair twice");c.e.closeSession()
for mode in ["source","selection","text","manual","retained","ack","race","field"] {
 let c=Case()
 switch mode {
 case "source":c.source="com.apple.keylayout.ABC"
 case "selection":c.selection=NSRange(location:0,length:4)
 case "text":c.text="다른 입력";c.selection=NSRange(location:5,length:0)
 case "manual":c.e.canBeginRepair={false}
 case "retained":c.e.retainedInput=[event(40,true)]
 case "ack":c.e.postedToGate=1
 case "race":c.e.testCanSelect={_ = c.g.receive(.keyDown,event(40,true));return true}
 default:c.e.observePassedIdentity();c.e.passedField=AXUIElementCreateApplication(5678)
 }
 c.e.sample();c.spin();check(c.edits==0 && c.posts.isEmpty,"unsafe late sequence must not edit: \(mode)");c.e.closeSession()
}
for kind in ["pointer","shortcut","repeat","unknownUp","limit","cancel"] {
 let c=Case();let old=c.g.passedObservation()!
 switch kind {
 case "pointer":_ = c.g.receive(.leftMouseDown,event(0,true))
 case "shortcut":let v=event(40,true);v.flags = .maskCommand;_ = c.g.receive(.keyDown,v)
 case "repeat":let v=event(40,true);v.setIntegerValueField(.keyboardEventAutorepeat,value:1);_ = c.g.receive(.keyDown,v)
 case "unknownUp":_ = c.g.receive(.keyUp,event(40,false))
 case "limit":for _ in 0..<13{_ = c.g.receive(.keyDown,event(40,true));_ = c.g.receive(.keyUp,event(40,false))}
 default:c.e.cancelDeferredObservation()
 }
 check(c.g.passedObservation()==nil && !c.g.claimPassed(old),"unsafe history cannot claim: \(kind)");check(c.g.held.isEmpty,"invalidated history never quarantines original input");c.e.closeSession()
}
let race=Case();let old=race.g.passedObservation()!;_ = race.g.receive(.keyDown,event(40,true));check(!race.g.claimPassed(old),"atomic claim rejects a newer passed event");race.e.closeSession()
let expired=Case();Thread.sleep(forTimeInterval:2.01);check(expired.g.passedObservation()==nil,"history expires without input capture");expired.e.closeSession()
print("PASS \(checks) late sequence identity, exact text, source, race, expiry and no-capture assertions; no OS keys")
