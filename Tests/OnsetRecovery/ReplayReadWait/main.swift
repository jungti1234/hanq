import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
final class Case {
 let e=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(1234);let other=AXUIElementCreateApplication(5678)
 let g:OnsetInputGate;var unavailable=true;var reason="selection_invalid";var changed=false;var source=onsetKoreanID;var sent:[CGEvent]=[]
 init(){
  g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();check(g.begin(),"hold begins")
  e.enabled=true;e.recovering=true;e.replayStarted=true;e.planElement=field
  e.currentPlan=OnsetRecoveryPlan(before:"",caret:0,allowSingle:true,roman:"ㄱ",codes:[(15,false)])
  e.testSource={self.source};e.testPost={self.sent.append($0)}
  e.testSnapshot={
   if self.unavailable{self.e.unavailableReason=self.reason;return nil}
   self.e.unavailableReason="";return OnsetSnapshot(element:self.changed ? self.other:self.field,text:"간",selection:NSRange(location:1,length:0))
  }
  e.pending=(0..<18).map{CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode($0),keyDown:$0 % 2 == 0)!}
 }
 func spin(_ seconds:Double){let end=Date().addingTimeInterval(seconds);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
for reason in ["text_unreadable","selection_unreadable","selection_invalid"] {
 let c=Case();c.reason=reason;let deadline=c.g.holdUntil;let original=c.e.pending
 c.e.drain([]);c.spin(0.04)
 check(c.sent.isEmpty && c.e.pending.count==18,"no transmission while content read fails")
 check(c.e.recovering && c.e.enabled && c.e.retainedInput.isEmpty,"same transaction stays alive")
 check(c.g.holdUntil==deadline,"retry does not renew hold deadline")
 let extra=CGEvent(keyboardEventSource:nil,virtualKey:49,keyDown:true)!;extra.flags=[]
 check(c.g.receive(.keyDown,extra)==nil,"new input remains held behind older pending input")
 c.unavailable=false;c.spin(0.1)
 let expected=(original+[extra]).map{($0.getIntegerValueField(.keyboardEventKeycode),$0.type.rawValue)}
 let actual=c.sent.map{($0.getIntegerValueField(.keyboardEventKeycode),$0.type.rawValue)}
 check(expected.elementsEqual(actual,by:{$0.0==$1.0 && $0.1==$1.1}),"resume transmits each down/up once and in order")
 check(!c.e.recovering && c.e.pending.isEmpty && c.e.retainedInput.isEmpty,"successful delivery leaves no quarantine")
 c.e.closeSession()
}
for boundary in ["field","source","secure","frontmost","deadline","heartbeat","cancel"] {
 let c=Case();c.e.drain([]);check(c.sent.isEmpty,"initial read failure holds")
 switch boundary {
 case "field":c.unavailable=false;c.changed=true
 case "source":c.source="com.apple.keylayout.ABC"
 case "secure":c.reason="secure_input"
 case "frontmost":c.reason="target_not_frontmost"
 case "deadline":c.g.holdUntil=ProcessInfo.processInfo.systemUptime-0.001
 case "heartbeat":c.g.heartbeat=ProcessInfo.processInfo.systemUptime-0.251
 default:c.e.closeSession()
 }
 c.spin(0.04)
 check(c.sent.isEmpty,"no stale replay after \(boundary)")
 check(c.e.pending.count+c.e.retainedInput.count==18,"original edges are not silently deleted after \(boundary)")
 check(!c.e.recovering || !c.g.healthy(),"boundary ends replay or gate closes")
 c.e.closeSession()
}
// A read failure before the first replacement post must preserve its prefix.
for reason in ["text_unreadable","selection_invalid"] {
 let c=Case();c.reason=reason;c.e.pending=[]
 let prefix=[CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!,CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:false)!]
 c.e.drain(prefix);c.spin(0.025)
 check(c.sent.isEmpty,"prefix waits while target is unreadable")
 c.unavailable=false;c.spin(0.03)
 check(c.sent.count==2 && c.sent[0].type == .keyDown && c.sent[1].type == .keyUp,"unposted prefix survives transient read retry exactly once")
 c.e.closeSession()
}
print("PASS \(checks) bounded replay snapshot wait assertions; no OS keys")
