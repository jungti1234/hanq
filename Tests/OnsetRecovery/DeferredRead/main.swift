import AppKit
var checks=0
func check(_ x:Bool,_ message:String){checks+=1;precondition(x,message)}
func key(_ code:UInt16=40,_ down:Bool=true)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
final class Case {
 let e=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(1234)
 var text="ㄱ";var selection=NSRange(location:1,length:0);var source=onsetKoreanID;var posts=0;var edits=0
 init(age:Double=0.8){
  e.enabled=true;e.testSource={self.source};e.testCanSelect={true}
  e.testSnapshot={OnsetSnapshot(element:self.field,text:self.text,selection:self.selection)}
  e.testSetRange={_,range in self.edits+=1;self.selection=range;return .success}
  e.testPost={event in self.posts+=1;_ = self.e.gate!.receive(event.type,event);self.selection=NSRange(location:1,length:0)}
  let g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();g.configureEarly(true)
  _ = g.receive(.keyDown,key(15));_ = g.receive(.keyUp,key(15,false))
  let first=g.early!;g.early=OnsetInputGate.Reservation(code:first.code,shift:first.shift,time:first.time-age,sourceID:first.sourceID)
  g.holdUntil=1;g.poll();e.unavailableReason="text_unreadable";e.sampleEarly(nil)
  check(e.enabled && !e.waitingForContext && g.healthy(),"132 observation remains active")
 }
 func finish(){RunLoop.current.run(until:Date().addingTimeInterval(0.04))}
}
let late=Case();late.e.observeDeferredBeforeInput(.keyDown,key());late.finish()
check(late.edits==1 && late.posts==2 && !late.e.recovering,"late exact first consonant replayed once")
late.e.observeDeferredBeforeInput(.keyDown,key());check(late.edits==1,"no duplicate late correction");late.e.closeSession()
for mode in ["following", "race", "source", "body", "selection", "manual", "shortcut", "retained", "unacknowledged", "stopped"] {
 let c=Case();let g=c.e.gate!
 switch mode {
 case "following":_ = g.receive(.keyDown,key())
 case "race":c.e.testSnapshot={_ = g.receive(.keyDown,key());return OnsetSnapshot(element:c.field,text:c.text,selection:c.selection)}
 case "source":c.source="com.apple.keylayout.ABC"
 case "body":c.text="ㄱㅏ";c.selection=NSRange(location:2,length:0)
 case "selection":c.selection=NSRange(location:0,length:1)
 case "manual":c.e.canBeginRepair={false}
 case "shortcut":let event=key();event.flags = .maskCommand;c.e.observeDeferredBeforeInput(.keyDown,event)
 case "retained":c.e.retainedInput=[key()]
 case "unacknowledged":c.e.postedToGate=1
 default:c.e.closeSession()
 }
 c.e.observeDeferredBeforeInput(.keyDown,key());c.finish()
 check(c.posts==0 && c.edits==0,"unsafe late correction rejected: \(mode)");c.e.closeSession()
}
let publication=Case();publication.text="";publication.selection=NSRange(location:0,length:0)
publication.e.sample();check(publication.e.gate!.deferredReservation() != nil && publication.posts==0,"empty publication keeps only observation, not a hold")
check(publication.e.gate!.holdUntil==0,"late publication does not extend input hold")
publication.text="ㄱ";publication.selection=NSRange(location:1,length:0);publication.e.sample();publication.finish()
check(publication.posts==2 && publication.edits==1,"later exact publication can repair");publication.e.closeSession()
let other=Case();other.text="";other.selection=NSRange(location:0,length:0);other.e.sample()
other.e.testSnapshot={OnsetSnapshot(element:AXUIElementCreateApplication(5678),text:"ㄱ",selection:NSRange(location:1,length:0))}
other.e.sample();other.finish();check(other.posts==0 && other.edits==0,"changed observed field cannot receive late repair");other.e.closeSession()
let expired=Case(age:2.1);expired.e.observeDeferredBeforeInput(.keyDown,key());expired.finish()
check(expired.posts==0 && expired.edits==0,"late observation lifetime is bounded");expired.e.closeSession()
let release=OnsetInputGate(marker:123);release.beat();release.configureEarly(true)
_ = release.receive(.keyDown,key(15));release.holdUntil=1;release.poll()
check(release.deferredReservation() != nil,"empty reservation keeps observation")
check(release.receive(.keyUp,key(15,false)) != nil && release.deferredReservation() != nil,"original first release neither held nor invalidates observation")
_ = release.receive(.keyDown,key(15));check(release.deferredReservation()==nil,"repeat down invalidates late observation")
release.stop()
print("PASS \(checks) deferred observation checks; no OS keys posted")
