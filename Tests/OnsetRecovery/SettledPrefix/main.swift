import AppKit
import Carbon
var checks=0
func check(_ ok:Bool,_ name:String){checks+=1;if !ok{fatalError(name)}}
let codes:[(UInt16,Bool)]=[15,40,1,40,14,40,3,40,0,40,12,40,17,40,49].map{($0,false)}
let body="ㄱㅏ나다라마바사 "
func plan(_ keys:[(UInt16,Bool)]=codes,_ text:String=body,_ selection:NSRange?=nil,_ source:String=onsetKoreanID)->OnsetRecoveryPlan? {
 OnsetRecoveryEngine.settledPrefixPlan(keys:keys,text:text,selection:selection ?? NSRange(location:text.utf16.count,length:0),sourceID:source)
}
check(!OnsetRecoveryEngine().prefixCandidateEnabled,"off by default")
let p=plan()!;check(p.roman=="ㄱㅏ","only pair");check(p.replayedText=="가","one syllable");check(p.before=="나다라마바사 ","suffix untouched");check(p.restoredCaret==8,"end mapped")
check(plan(Array(codes.dropLast()),"ㄱㅏ나다라마바사")==nil,"idle is not commit")
check(plan(codes,"가나다라마바사 ")==nil,"already composed")
check(plan(codes,body,NSRange(location:8,length:0))==nil,"moved caret")
check(plan(codes,body,NSRange(location:0,length:2))==nil,"selection")
check(plan(codes,body,nil,"com.apple.keylayout.ABC")==nil,"source")
check(plan(codes,body+"아")==nil,"following input")
check(plan(codes,"ㄱㅏ나다라바마사 ")==nil,"suffix mismatch")
var shifted=codes;shifted[14].1=true;check(plan(shifted)==nil,"shift Space")
var earlySpace=codes;earlySpace[4].0=49;check(plan(earlySpace)==nil,"interior boundary")
for i in 0..<14{var mutated=codes;mutated[i].0=2;check(plan(mutated)==nil,"key history \(i)")}
func ev(_ code:CGKeyCode,_ down:Bool,_ flags:CGEventFlags=[],pid:Int64=123)->CGEvent {let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=flags;e.setIntegerValueField(.eventTargetUnixProcessID,value:pid);return e}
// Completed prefix edits no longer arm or hold Undo/Redo. These are native
// commands, even when followed immediately by text or mouse input.
func gate()->OnsetInputGate {let g=OnsetInputGate(marker:42);g.beat();return g}
for flags:CGEventFlags in [.maskCommand,[.maskCommand,.maskShift]] {
 let g=gate()
 for down in [true,false] {
  let event=ev(6,down,flags)
  check(g.receive(down ? .keyDown:.keyUp,event)?.takeUnretainedValue() === event,"native history event passes unchanged")
  check(!g.ownsInput,"native history never acquires hold")
 }
 let release=ev(55,false);release.type = .flagsChanged
 check(g.receive(.flagsChanged,release) != nil,"Command release passes")
 for down in [true,false] {check(g.receive(down ? .keyDown:.keyUp,ev(2,down)) != nil,"immediate following key passes")}
 check(g.take().isEmpty && g.healthy(),"no native-history input buffered or engine stopped")
}
do {let g=gate()
 for (type,point) in [(CGEventType.leftMouseDown,CGPoint(x:30,y:10)),(.leftMouseUp,CGPoint(x:30,y:10)),(.leftMouseDown,CGPoint(x:30,y:30)),(.leftMouseUp,CGPoint(x:30,y:30))] {
  let e=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)!
  check(g.receive(type,e) != nil,"native menu mouse event passes")
 }
 check(!g.ownsInput && g.take().isEmpty,"native menu never arms a replay hold")
}

for (before,after) in [(NSRange(location:9,length:0),NSRange(location:8,length:0)),(NSRange(location:5,length:0),NSRange(location:4,length:0)),(NSRange(location:4,length:2),NSRange(location:3,length:2)),(NSRange(location:0,length:2),NSRange(location:0,length:1)),(NSRange(location:0,length:9),NSRange(location:0,length:8))] {
 check(OnsetPrefixCoordinator.mappedSelection(before,textLength:9)==after,"saved selection mapping")
}
for bad in [NSRange(location:1,length:0),NSRange(location:0,length:1),NSRange(location:10,length:0),NSRange(location:8,length:2),NSRange(location:Int.max,length:1)] {
 check(OnsetPrefixCoordinator.mappedSelection(bad,textLength:9)==nil,"ambiguous or invalid selection rejected")
}
check(OnsetPrefixCoordinator.exact("abc","abc"),"exact identical UTF16")
check(!OnsetPrefixCoordinator.exact("\u{AC00}","\u{1100}\u{1161}"),"canonical Hangul is not an identical editor body")
check(!OnsetPrefixCoordinator.exact("e\u{301}","\u{E9}"),"canonical Latin is not an identical editor body")
check(!OnsetPrefixCoordinator.exactPrefix("\u{1100}\u{1161}x","\u{AC00}"),"prefix comparison also preserves code units")
check(!OnsetPrefixCoordinator.exact(nil,""),"missing read is not empty text")
print("PASS \(checks) plan, selection mapping, exact body and native history pass-through assertions")
