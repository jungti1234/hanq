import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;if !value{fputs("FAIL: \(message)\n",stderr);exit(1)}}
func key(_ code:UInt16=15,_ down:Bool=true)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
let expectsOld=CommandLine.arguments.contains("--baseline")
final class Case {
 let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(1234)
 var text=" ㄱ",selection=NSRange(location:2,length:0),source=onsetKoreanID
 var reads=0,edits=0,posts:[CGEvent]=[],delay=0.0
 init(deferred:Bool=false){
  e.enabled=true;e.testCommitComposition={_ in true};e.testSource={self.source};e.testCanSelect={true}
  e.testSnapshot={self.reads+=1;if self.delay>0{Thread.sleep(forTimeInterval:self.delay)};return OnsetSnapshot(element:self.field,text:self.text,selection:self.selection)}
  e.testSetRange={_,r in self.edits+=1;self.selection=r;return .success}
  e.testPost={event in self.posts.append(event);_ = self.e.gate!.receive(event.type,event);self.selection=NSRange(location:2,length:0)}
  e.earlyBaseline=OnsetSnapshot(element:field,text:" ",selection:NSRange(location:1,length:0))
  let g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();g.configureEarly(true)
  check(g.receive(.keyDown,key()) != nil,"original first down passes")
  if deferred {let r=g.early!;g.early = .init(code:r.code,shift:r.shift,time:r.time-0.8,sourceID:r.sourceID);g.holdUntil=1;g.poll();e.unavailableReason="text_unreadable";e.sampleEarly(nil)}
 }
 func finish(){RunLoop.current.run(until:Date().addingTimeInterval(0.04))}
 func close(){e.closeSession()}
}
var timings:[[String:Any]]=[]
for deferred in [false,true] {
 let c=Case(deferred:deferred);c.delay=0.025
 let start=ProcessInfo.processInfo.systemUptime
 c.e.observeDeferredBeforeInput(.keyUp,key(15,false))
 let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000,reads=c.reads
 check(expectsOld ? reads>0:reads==0,"release callback snapshot count")
 if !expectsOld{check(c.edits==0 && c.posts.isEmpty,"release does not claim or replay before observation")}
 _ = c.e.gate!.receive(.keyUp,key(15,false));c.delay=0
 // Explicitly exercise the existing timer's sample, not a newly queued read.
 c.e.sample();c.finish()
 check(c.edits==1 && c.posts.filter{$0.type == .keyDown}.count==1,"existing fresh observation still repairs exactly once")
 check(!c.e.recovering && c.e.gate!.healthy(),"repair finishes with a healthy gate")
 c.e.sample();c.finish();check(c.edits==1,"later sample cannot duplicate repair")
 timings.append(["deferred":deferred,"callbackReads":reads,"callbackMilliseconds":elapsed,"edits":c.edits,"postedDown":c.posts.filter{$0.type == .keyDown}.count])
 c.close()
}
for mode in ["next_down","following_passed","source","field","selection","body","manual","stopped","secure","timeout"] {
 let c=Case();c.text=" ";c.selection=NSRange(location:1,length:0)
 c.e.observeDeferredBeforeInput(.keyUp,key(15,false));_ = c.e.gate!.receive(.keyUp,key(15,false))
 c.text=" ㄱ";c.selection=NSRange(location:2,length:0)
 switch mode {
 case "next_down":c.e.observeDeferredBeforeInput(.keyDown,key(40));_ = c.e.gate!.receive(.keyDown,key(40));_ = c.e.gate!.receive(.keyUp,key(40,false))
 case "following_passed":_ = c.e.gate!.receive(.keyDown,key(40));c.text=" 가";c.selection=NSRange(location:2,length:0)
 case "source":c.source="com.apple.keylayout.ABC"
 case "field":c.e.earlyObservedField=c.field;c.e.testSnapshot={OnsetSnapshot(element:AXUIElementCreateApplication(5678),text:c.text,selection:c.selection)}
 case "selection":c.selection=NSRange(location:0,length:1)
 case "body":c.text="changed ㄱ";c.selection=NSRange(location:9,length:0)
 case "manual":c.e.canBeginRepair={false}
 case "stopped":c.close()
 case "secure":c.e.testSnapshot={c.e.unavailableReason="secure_input";return nil}
 default:let g=c.e.gate!;if let first=g.early{g.early = .init(code:first.code,shift:first.shift,time:first.time-3,sourceID:first.sourceID)};g.holdUntil=1;g.poll()
 }
 if c.e.enabled {c.e.sample()};c.finish()
 check(mode=="next_down" ? c.edits==1:(c.edits==0 && c.posts.isEmpty),"fresh context/next input guard: \(mode)")
 c.close()
}
let json=try! JSONSerialization.data(withJSONObject:["baseline":expectsOld,"measurements":timings,"checks":checks],options:[.sortedKeys])
print(String(data:json,encoding:.utf8)!)
print("PASS \(checks) key-up observation checks; no OS keys posted")
