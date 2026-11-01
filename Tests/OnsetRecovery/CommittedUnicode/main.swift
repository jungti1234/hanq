import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;if !value{print("FAIL",message);exit(1)}}
func key(_ code:UInt16,_ down:Bool)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
func unicode(_ event:CGEvent)->String{var n=0;var units=[UniChar](repeating:0,count:64);event.keyboardGetUnicodeString(maxStringLength:64,actualStringLength:&n,unicodeString:&units);return String(utf16CodeUnits:units,count:n)}
final class Case {
    let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(1234),other=AXUIElementCreateApplication(5678)
    let g:OnsetInputGate,mode:String
    var text="ㅇㅏㄴ녕 ",range=NSRange(location:5,length:0),source=onsetKoreanID
    var focused=true,selectedAt=0.0,commits=0,native=0,AXWrites=0,selections=0,restores=0,bufferPosts=0
    init(_ mode:String,bundle:String="org.example.editor"){
        self.mode=mode;g=OnsetInputGate(marker:e.marker);e.gate=g;g.beat();e.enabled=true
        e.testSource={self.source};e.testCanSelect={true};e.testCanReplaceText={true};e.testTargetBundleID={bundle}
        e.testSnapshot={.init(element:self.focused ? self.field:self.other,text:self.focused ? self.text:"other",selection:self.focused ? self.range:NSRange(location:5,length:0))}
        e.testOriginalSnapshot={_ in .init(element:self.field,text:self.text,selection:self.range)}
        e.testSelectedText={_ in
            if mode=="selection_never"{return nil}
            if mode.hasPrefix("caret_") {
                if mode=="caret_stale" || ProcessInfo.processInfo.systemUptime-self.selectedAt<0.16{return "ㅇㅏㄴ녕 "}
                return ""
            }
            if mode=="selection_delayed",ProcessInfo.processInfo.systemUptime-self.selectedAt<0.025{return ""}
            return (self.text as NSString).substring(with:self.range)
        }
        e.testSetRange={_,r in
            if r.length>0{self.selections+=1;self.selectedAt=ProcessInfo.processInfo.systemUptime}
            else{self.restores+=1}
            if mode.hasPrefix("caret_"),r.length>0 {
                self.range=NSRange(location:5,length:0)
                for down in [true,false]{check(self.g.receive(down ? .keyDown:.keyUp,key(15,down))==nil,"original held during contradictory selection")}
            }else{self.range=r}
            return .success
        }
        e.testPostCompositionCommit={field,event in
            check(CFEqual(field,self.field),"commit pinned to original field")
            self.commits+=1
            if mode=="commit_rejected"{return false}
            if event.type == .keyUp && mode != "commit_unconfirmed"{
                if mode=="commit_changed"{self.text="changed";self.range=NSRange(location:7,length:0)}
                else{self.range=NSRange(location:4,length:0)}
            }
            return true
        }
        e.testPostCommittedUnicode={field,events in
            self.native+=1
            check(CFEqual(field,self.field) && events.count==2,"one pair pinned to original field")
            check(events.map{$0.type}==[.keyDown,.keyUp],"native edge order")
            check(events.allSatisfy{unicode($0)=="안녕 "},"one exact composed replacement includes existing Space")
            check(events.allSatisfy{$0.getIntegerValueField(.eventSourceUserData)==self.e.compositionCommitMarker},"native prefix cannot acknowledge later HID originals")
            if mode=="post_rejected"{return false}
            if ["ignored","late","pending_focus","pending_source","normal_pending"].contains(mode){
                for down in [true,false]{check(self.g.receive(down ? .keyDown:.keyUp,key(15,down))==nil,"following original pair held")}
            }
            let apply={self.text="안녕 ";self.range=NSRange(location:3,length:0)}
            if mode=="late"{DispatchQueue.main.asyncAfter(deadline:.now()+0.22,execute:apply)}
            else if mode != "ignored"{apply()}
            if mode=="pending_focus"{self.focused=false}
            if mode=="pending_source"{self.source="com.apple.keylayout.ABC"}
            return true
        }
        e.testPost={event in
            self.bufferPosts+=1;check(self.range.length==0,"no original while replacement selection remains")
            _ = self.g.receive(event.type,event)
            if event.type == .keyDown{self.text+="ㄱ";self.range=NSRange(location:self.text.utf16.count,length:0)}
        }
        if mode=="anchored" {
            self.text="";self.range=NSRange(location:0,length:0);e.sample()
            self.text="ㅇㅏㄴ녕 ";self.range=NSRange(location:5,length:0)
        }else{g.configureEarly(true)}
        for code:UInt16 in [2,40,1,1,32,2,49]{for down in [true,false]{check(g.receive(down ? .keyDown:.keyUp,key(code,down)) != nil,"fixture history passes before claim")}}
    }
    func spin(_ seconds:Double=0.34){let end=Date().addingTimeInterval(seconds);while Date()<end{g.beat();RunLoop.current.run(until:Date().addingTimeInterval(0.001))}}
}
for bundle in ["com.openai.codex","com.microsoft.edgemac","org.example.editor"] {
for mode in ["anchored","caret_stale","caret_delayed","normal","selection_delayed","normal_pending","ignored","late","pending_focus","pending_source","selection_never","commit_rejected","commit_unconfirmed","commit_changed","post_rejected"]{
    let c=Case(mode,bundle:bundle);c.e.sample();c.spin()
    check(c.AXWrites==0,"one generic strategy never combines AX text write with Unicode: \(mode)")
    check(c.native<=1,"never retry uncertain native replacement: \(mode)")
    if ["anchored","normal","selection_delayed","normal_pending"].contains(mode){
        check(c.text==(mode=="normal_pending" ? "안녕 ㄱ":"안녕 ") && c.e.deliveryPrefixConfirmed && !c.e.recovering,"verified replacement and subsequent originals preserved: \(mode)")
        check(c.bufferPosts==(mode=="normal_pending" ? 2:0),"only exact following originals delivered")
    }
    if ["ignored","late","pending_focus","pending_source"].contains(mode){
        check(c.bufferPosts==0 && c.e.pending.count+c.e.retainedInput.count==2,"uncertain or changed context preserves original pair: \(mode)")
        check(c.restores==0,"uncertain native edit never restores selection or performs fallback: \(mode)")
    }
    if mode=="selection_never"{check(c.native==0 && c.restores==1 && c.text=="ㅇㅏㄴ녕 ","unproved selected text cancels before edit")}
    if mode.hasPrefix("commit_"){check(c.native==0 && c.selections==0,"unconfirmed commit prevents selection and replacement: \(mode)")}
    if mode=="caret_stale" {check(c.native==0 && c.bufferPosts==0 && c.e.pending.count+c.e.retainedInput.count==2,"collapsed range alone cannot release originals over stale selection")}
    if mode=="caret_delayed" {check(c.native==0 && c.bufferPosts==2 && c.text=="ㅇㅏㄴ녕 ㄱ","unchanged body and stable collapsed selection allow original release")}
    c.e.closeSession()
}
}
let missingCodes:[UInt16]=[15,46,3,38,0,49]
let missing=missingCodes.map{($0,false)}
if case .rejected=OnsetLateSequenceDetector.inspect(keys:missing,before:"",caret:0,text:"그ㅁ ",selection:NSRange(location:3,length:0)){
    check(true,"missing middle sounds never reconstructed by guess")
}else{check(false,"truncated input must not be guessed into a complete word")}
print("PASS \(checks) committed Unicode/selection/receipt/uncertain-delivery safety checks; no OS events posted")
