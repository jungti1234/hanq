import AppKit

var checks=0
func check(_ ok:Bool,_ message:String){checks+=1;if !ok{print("FAIL \(message)");exit(1)}}
func key(_ code:UInt16,_ down:Bool=true)->CGEvent {
    let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
    event.flags=[];return event
}

// The first key focuses a previously unknown empty editor. An ignored cursor
// command must not turn the following real release/vowel into retained input.
final class Case {
    let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(1234)
    let other=AXUIElementCreateApplication(5678)
    var text="ㅇ",selection=NSRange(location:1,length:0)
    var commands=0,posts=0,selections=0,writes=0,passed=0
    let gate:OnsetInputGate
    init(_ mode:String,deferred:Bool=false){
        gate=OnsetInputGate(marker:e.marker);e.gate=gate;gate.beat()
        e.enabled=true;e.testSource={onsetKoreanID};e.testCanSelect={true}
        e.testSnapshot={.init(element:self.field,text:self.text,selection:self.selection)}
        e.testPostCompositionCommit={_,_ in self.commands+=1;return true}
        e.testPost={_ in self.posts+=1}
        e.testSetRange={_,range in self.selections+=1;self.selection=range;return .success}
        e.testCanReplaceText={true}
        e.testReplaceText={_,value in self.writes+=1;self.text=value;self.selection=NSRange(location:value.utf16.count,length:0);return .success}
        e.testOriginalSnapshot=e.testSnapshot.map{read in {_ in read()}}
        switch mode {
        case "foreign":e.earlyBaseline = .init(element:other,text:"",selection:NSRange(location:0,length:0))
        case "placeholder":e.earlyBaseline = .init(element:field,text:"Ask anything",selection:NSRange(location:0,length:0))
        case "known":e.earlyBaseline = .init(element:field,text:"",selection:NSRange(location:0,length:0))
        default:break
        }
        gate.configureEarly(true)
        send(2)
        if deferred {
            gate.holdUntil=1;gate.poll()
            e.unavailableReason="text_unreadable";e.sampleEarly(nil)
        }
    }
    func send(_ code:UInt16,_ down:Bool=true){if gate.receive(down ? .keyDown:.keyUp,key(code,down)) != nil{passed+=1}}
    func spin(_ duration:Double=0.15){let end=Date().addingTimeInterval(duration);while Date()<end{gate.beat();RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
for deferred in [false,true] {
    for mode in ["missing","foreign","placeholder","known"] {
        let c=Case(mode,deferred:deferred)
        c.e.sample()
        check(c.commands==0 && c.selections==0 && c.posts==0,"unanchored \(mode)/deferred=\(deferred): no cursor command, selection or replay")
        c.send(2,false);c.send(37);c.text="이";c.send(37,false)
        c.spin()
        check(c.passed==4,"original first release and vowel pass exactly once")
        check(c.e.pending.isEmpty && c.e.retainedInput.isEmpty && c.gate.take().isEmpty,"no original input stranded after ignored-command window")
        check(!c.e.recovering && c.e.enabled && c.gate.healthy() && c.gate.holdUntil==0,"unanchored entry stays observation-only")
        c.e.sample();check(c.writes==0 && c.text=="이","ordinary native composition needs no repair")
        c.e.closeSession()
    }
}
// An unanchored sequence may use only the existing full-word exact-match path,
// after all original keys passed and a final Space was released.
for deferred in [false,true] {
    let c=Case("missing",deferred:deferred);c.e.sample()
    c.send(2,false);c.send(37);c.text="ㅇㅣ";c.selection=NSRange(location:2,length:0);c.send(37,false)
    c.e.sample();check(c.writes==0 && c.commands==0,"split prefix stays unedited until committed")
    c.send(49);c.text="ㅇㅣ ";c.selection=NSRange(location:3,length:0);c.send(49,false)
    c.e.sample();c.spin(0.03)
    check(c.passed==6 && c.writes==1 && c.text=="이 ","exact committed split uses one target-bound replacement")
    check(c.commands==0 && c.posts==0 && !c.e.recovering,"late replacement never replays physical keys or sends a cursor command")
    c.e.closeSession()
}
print("PASS \(checks) first-key-focus input continuity checks; no OS keys posted")
