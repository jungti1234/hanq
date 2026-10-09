import AppKit
var checks=0;var failures=0
func check(_ value:Bool,_ message:String){checks+=1;if !value{failures+=1;print("FAIL",message)}}
func key(_ code:UInt16,_ down:Bool)->CGEvent{let v=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;v.flags=[];return v}
final class Case {
 let e=OnsetRecoveryEngine();let g:OnsetInputGate;let field=AXUIElementCreateApplication(1234)
 var text="ㄱㅏㄴ ";var selection=NSRange(location:4,length:0);var focused=true;var writes=0;var selections=0;var posts=0;var foreignPosts=0;var mode:String
 init(_ mode:String){self.mode=mode;g=OnsetInputGate(marker:e.marker);e.gate=g;e.enabled=true;g.beat();g.configureEarly(true)
  e.testSource={onsetKoreanID};e.testCanSelect={true}
  e.testSnapshot={if !self.focused{self.e.unavailableReason="not_supported_text_field";return nil};return OnsetSnapshot(element:self.field,text:self.text,selection:self.selection)}
  e.testSetRange={_,range in self.selections+=1;self.selection=range;if self.mode=="focus_before_write",range.length>0{self.focused=false};return .success}
  e.testPost={v in
   self.posts+=1;_ = self.g.receive(v.type,v)
   #if HANQ_OLD_REPLAY
   if self.posts==1 {self.text="ㄱ";self.selection=NSRange(location:1,length:0);self.focused=false}else{self.foreignPosts+=1}
   #else
   if !self.focused{self.foreignPosts+=1}
   #endif
  }
  #if !HANQ_OLD_REPLAY
  e.testCanReplaceText={self.mode != "unsupported"}
  e.testOriginalSnapshot={_ in self.mode=="unreadable_after_write" && self.writes>0 ? nil:OnsetSnapshot(element:self.field,text:self.text,selection:self.selection)}
  e.testReplaceText={target,value in
   check(CFEqual(target,self.field),"write bound to original AX element")
   self.writes+=1
   if self.mode=="focus_during_write" || self.mode=="pending_focus_change"{self.focused=false}
   if self.mode=="pending" || self.mode=="pending_focus_change" {for down in [true,false]{check(self.g.receive(down ? .keyDown:.keyUp,key(40,down))==nil,"following originals held")}}
   if self.mode=="not_applied"{return .cannotComplete}
   self.text=(self.text as NSString).replacingCharacters(in:self.selection,with:value);self.selection=NSRange(location:value.utf16.count,length:0)
   return self.mode=="ambiguous_success" ? .cannotComplete:.success
  }
  #endif
  for code:UInt16 in [15,40,1,49]{for down in [true,false]{check(g.receive(down ? .keyDown:.keyUp,key(code,down)) != nil,"all original edges pass before claim")}}
 }
 func spin(_ duration:Double=0.25){let end=Date().addingTimeInterval(duration);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
let changed=Case("focus_during_write");changed.e.sample();changed.spin()
check(changed.text=="간 ","focus switch cannot lose committed vowel")
check(changed.posts==0 && changed.foreignPosts==0,"no repair key can reach a different focus")
#if !HANQ_OLD_REPLAY
check(changed.writes==1 && !changed.e.recovering,"single target write confirmed while focus outside")
changed.e.closeSession()
for mode in ["normal","ambiguous_success","not_applied","unsupported","focus_before_write","unreadable_after_write","pending","pending_focus_change"] {
 let c=Case(mode);c.e.sample();c.spin()
 check(c.foreignPosts==0,"no key to other focus: \(mode)")
 check(c.writes<=1,"never retry text edit: \(mode)")
 if ["not_applied","unsupported","focus_before_write"].contains(mode){
  check(c.text=="ㄱㅏㄴ ","cancel/unsupported preserves original text: \(mode)")
  check(c.selection==NSRange(location:4,length:0),"cancel restores only own selection: \(mode)")
 }else{check(c.text=="간 ","target replacement preserved: \(mode)")}
 if mode=="unsupported"{check(c.selections==0 && c.writes==0,"unsupported field never selected or edited")}
 if mode=="pending"{check(c.posts==2 && c.e.pending.isEmpty,"following original pair delivered once")}
 else{check(c.posts==0,"no physical repair fallback")}
 if mode=="pending_focus_change"{check(c.e.pending.count+c.e.retainedInput.count==2,"undelivered original pair preserved on focus change")}
 c.e.closeSession()
}
let partial=OnsetLateSequenceDetector.inspect(keys:[(15,false),(40,false),(1,false)],before:"",caret:0,text:"ㄱㅏㄴ",selection:NSRange(location:3,length:0))
if case .waiting=partial{check(true,"active word waits for commitment")}else{check(false,"active word must not use committed text replacement")}
let plan=OnsetRecoveryPlan(before:"",caret:0,roman:"ㄱㅏㄴ ",codes:[(15,false),(40,false),(1,false),(49,false)],replayedText:"간 ")
check(plan.isCommittedLate && !plan.supportsReplay,"multi-key plans cannot enter physical replay")
#endif
print("\(failures==0 ? "PASS":"FAIL") \(checks) target-bound committed replacement assertions; no OS keys posted")
exit(failures==0 ? 0:1)
