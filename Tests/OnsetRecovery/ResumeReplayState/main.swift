import AppKit
var checks=0;var failures=0
func check(_ value:Bool,_ name:String){checks+=1;if !value{failures+=1;print("FAIL",name)}}
func key(_ code:UInt16,_ down:Bool)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
final class Case {
 let e=OnsetRecoveryEngine();let g:OnsetInputGate;let field=AXUIElementCreateApplication(1234);let other=AXUIElementCreateApplication(5678)
 var active=true;var selection=NSRange(location:2,length:0);var changed=false;var sent=0;var source=onsetKoreanID
 init(){g=OnsetInputGate(marker:e.marker);e.gate=g;e.enabled=true;g.beat();e.recovering=true;e.replayStarted=true
  e.testSource={self.source};e.testSnapshot={self.active ? OnsetSnapshot(element:self.changed ? self.other:self.field,text:"간 ",selection:self.selection):nil};e.testPost={_ in self.sent+=1}
 }
 func pause(){e.pauseForContext("repair_context_lost")}
 func resume(){let now=ProcessInfo.processInfo.systemUptime;e.resumeIfReady(now:now);e.resumeIfReady(now:now+0.11)}
 func next()->Bool{g.beat();g.configureEarly(true);check(g.receive(.keyDown,key(15,true)) != nil,"next original passes");check(g.reservation() != nil,"next reservation created");return e.abandonUneditedReservation()}
}
for _ in 0..<3 {
 let c=Case();c.pause();c.resume()
 check(!c.e.waitingForContext,"stable context resumes")
 check(!c.e.replayStarted,"finished replay state cleared")
 check(c.next(),"next unedited reservation resumes instead of pausing again")
 check(!c.e.waitingForContext && c.e.retainedInput.isEmpty && c.sent==0,"no quarantine or replay on resumption")
 c.e.closeSession()
}
for kind in ["pending","prefix","gate","retained"] {
 let c=Case();let pair=[key(40,true),key(40,false)]
 switch kind {
 case "pending":c.e.pending=pair
 case "prefix":c.e.prefixRemainder=pair
 case "gate":check(c.g.begin(),"gate hold begins");for k in pair{check(c.g.receive(k.type,k)==nil,"original held")}
 default:c.e.retainedInput=pair
 }
 c.pause();c.resume()
 check(c.e.retainedInput.count==2,"unsent pair retained: \(kind)")
 check(c.e.retainedInput.map{$0.type}==[.keyDown,.keyUp],"retained edge order: \(kind)")
 check(c.e.replayStarted,"unresolved delivery state not cleared: \(kind)")
 check(!c.next(),"unresolved delivery cannot rearm: \(kind)")
 check(c.sent==0 && c.e.retainedInput.count==2,"no automatic replay or deletion: \(kind)");c.e.closeSession()
}
let ack=Case();ack.e.postedToGate=1;ack.pause();ack.resume()
check(ack.e.waitingForContext && ack.e.replayStarted,"unacknowledged post blocks state clearing")
let confirmation=key(15,true);confirmation.setIntegerValueField(.eventSourceUserData,value:ack.e.marker);_ = ack.g.receive(.keyDown,confirmation)
ack.resume();check(!ack.e.waitingForContext && !ack.e.replayStarted,"only acknowledged delivery can finish resumption");check(ack.sent==0,"ack recovery sends no keys");ack.e.closeSession()
for mode in ["unreadable","selection","layout","field"] {
 let c=Case();c.pause();let now=ProcessInfo.processInfo.systemUptime
 switch mode {
 case "unreadable":c.active=false
 case "selection":c.selection=NSRange(location:0,length:2)
 case "layout":c.source="com.apple.keylayout.ABC"
 default:c.e.resumeIfReady(now:now);c.changed=true
 }
 c.e.resumeIfReady(now:now+0.11)
 check(c.e.waitingForContext && c.e.replayStarted,"unsafe/unstable context cannot clear state: \(mode)")
 check(c.sent==0,"unsafe resume sends nothing");c.e.closeSession()
}
print("\(failures==0 ? "PASS":"FAIL") \(checks) replay pause/resume state assertions; no OS key posting")
exit(failures==0 ? 0:1)
