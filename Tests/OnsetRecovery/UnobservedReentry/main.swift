import AppKit
var checks=0;var failures=0
func check(_ v:Bool,_ name:String){checks+=1;if !v{failures+=1;print("FAIL",name)}}
final class Case {
 let e=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(1234);let other=AXUIElementCreateApplication(5678);var g:OnsetInputGate!;var text="앞🙂";var range=NSRange(location:3,length:0);var source=onsetKoreanID;var mode:String;var writes=0;var posts=0;var selections=0
 init(_ mode:String){self.mode=mode;g=OnsetInputGate(marker:e.marker);g.beat();e.gate=g;e.enabled=true
  e.testSource={self.source};e.testCanSelect={true};e.testCanReplaceText={self.mode != "unsupported"}
  e.testSnapshot={OnsetSnapshot(element:self.mode=="changed_field" && self.text.utf16.count>3 ? self.other:self.field,text:self.text,selection:self.range)}
  e.testOriginalSnapshot={_ in OnsetSnapshot(element:self.field,text:self.text,selection:self.range)}
  e.testSetRange={_,range in self.selections+=1;self.range=range;return .success}
  e.testReplaceText={target,value in check(CFEqual(target,self.field),"replacement remains on original field");self.writes+=1;self.text=(self.text as NSString).replacingCharacters(in:self.range,with:value);self.range=NSRange(location:self.range.location+value.utf16.count,length:0);return .success}
  e.testPost={_ in self.posts+=1}
  if mode=="selected_baseline"{range=NSRange(location:0,length:1)}
  e.sample()
 }
 func word(){
  let baseline=text
  for (index,code) in [UInt16(15),40,1,49].enumerated(){for down in [true,false]{
   let v=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;v.flags=mode=="shortcut" && index==0 ? .maskCommand:[]
   if mode=="autorepeat" && index==0{v.setIntegerValueField(.keyboardEventAutorepeat,value:1)}
   check(g.receive(down ? .keyDown:.keyUp,v) != nil,"unverified originals always pass")
   check(g.held.isEmpty && g.reservation()==nil,"observation never reserves or holds input")
  }}
  text=baseline+"ㄱㅏㄴ ";range=NSRange(location:text.utf16.count,length:0)
  if mode=="changed_prefix"{text="다른"+text;range.location=text.utf16.count}
  if mode=="changed_caret"{range=NSRange(location:0,length:0)}
  if mode=="source_change"{source="com.apple.keylayout.ABC"}
  e.sample();let end=Date().addingTimeInterval(0.08);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}
 }
}
let repeated=Case("normal")
for i in 1...3{repeated.word();check(repeated.text=="앞🙂"+String(repeating:"간 ",count:i),"entry \(i) corrected without observing outside focus");check(repeated.writes==i && repeated.posts==0,"entry \(i) has one target-bound edit and no replay")}
repeated.e.closeSession()
#if !HANQ_OLD_BLIND
for mode in ["changed_field","changed_prefix","changed_caret","source_change","unsupported","shortcut","autorepeat","selected_baseline"]{
 let c=Case(mode);c.word();check(c.writes==0 && c.selections==0 && c.posts==0,"no edit or replay for \(mode)");check(c.text.contains("ㄱㅏㄴ "),"original input preserved for \(mode)");c.e.closeSession()
}
let missing=Case("normal");missing.e.publishedPassedBaselines=[];missing.word();check(missing.writes==0 && missing.posts==0,"missing baseline never falls back to empty text");missing.e.closeSession()
let gate=OnsetInputGate(marker:123);gate.beat();gate.configurePassedBaseline(7,sourceID:onsetKoreanID)
let first=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;first.flags=[];_ = gate.receive(.keyDown,first)
check(gate.passedObservation()?.baselineRevision==7,"first key atomically anchors publication revision")
gate.configurePassedBaseline(8,sourceID:onsetKoreanID);check(gate.passedObservation()?.baselineRevision==7,"new publications never retarget active history")
check(gate.held.isEmpty && gate.reservation()==nil,"published baseline gives no permission to hold or edit")
#endif
print("\(failures==0 ? "PASS":"FAIL") \(checks) unobserved reentry identity and input preservation assertions; no OS keys posted")
exit(failures==0 ? 0:1)
