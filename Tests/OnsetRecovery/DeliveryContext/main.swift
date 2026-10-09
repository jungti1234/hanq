import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
for failure in ["text_unreadable","selection_invalid","target_not_frontmost","changed_field","changed_source"] {
 let e=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(1234);let other=AXUIElementCreateApplication(5678)
 e.enabled=true;e.recovering=true;e.replayStarted=true;e.planElement=field
 e.currentPlan=OnsetRecoveryPlan(before:"",caret:0,allowSingle:true,roman:"ㄱ",codes:[(15,false)])
 let keys=(0..<18).map{CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode($0),keyDown:$0 % 2 == 0)!}
 e.pending=keys;var posts=0;var sourceReads=0
 e.testPost={_ in posts+=1}
 e.testSource={sourceReads+=1;return failure=="changed_source" ? "com.apple.keylayout.ABC" : onsetKoreanID}
 e.testSnapshot={
  if failure=="changed_field" {return OnsetSnapshot(element:other,text:"간",selection:NSRange(location:1,length:0))}
  if failure=="changed_source" {return OnsetSnapshot(element:field,text:"간",selection:NSRange(location:1,length:0))}
  e.unavailableReason=failure;return nil
 }
 e.drain([])
 check(posts==0,"failure must not post into an unverified target")
 check(!e.enabled && !e.recovering,"136 failure remains terminal; diagnostic candidate changes no recovery policy")
 check(e.pending.count==18 && zip(e.pending,keys).allSatisfy{$0 === $1},"all 18 original edges remain parked in order")
 check(e.rollbackReason=="replay_target_changed","failure reaches original rollback reason")
 check(sourceReads==(failure=="changed_source" ? 1:0),"source read short circuit preserved")
}
print("PASS \(checks) delivery failure classification assertions; diagnostic candidate preserves 136 behavior; no OS keys")
