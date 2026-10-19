import Foundation
import ApplicationServices

var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
func make(_ code:CGKeyCode,_ at:Double,_ type:CGEventType = .keyDown)->CGEvent {
    let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!
    e.type=type;e.timestamp=UInt64(at*1_000_000_000);e.flags=[]
    let secret=Array("PRIVATE_UNICODE_PAYLOAD".utf16)
    e.keyboardSetUnicodeString(stringLength:secret.count,unicodeString:secret)
    return e
}
var last:Data?
for (preKey,output,expectedClass) in [(CGKeyCode(17),"t",1),(49,"t",1),(49,"ㅅ",3),(49,"사",2)] {
    var now=100.0,captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,clock:{now},writer:{captures.append($0)})
    var probe=InputIncidentShapeProbe()
    func shape(_ text:String) {
        let change=probe.observe(identity:1,text:text,selection:NSRange(location:text.utf16.count,length:0),generation:trace.collectionGeneration)
        trace.shape(.onsetAX,identity:1,count:text.utf16.count,selected:false,editing:false,change:change)
    }
    shape("prefix ")
    now=100.020
    let prior=make(preKey,now);trace.event(.hid,.keyDown,prior);trace.event(.main,.keyDown,prior)
    now=100.030
    let toggle=make(54,now,.flagsChanged)
    var control=InputIncidentControl();control.role=1;control.eventType=1;control.route=14;control.filterMeasured=true;control.filterEdge=1;control.filterConsumed=true
    trace.control(.hid,.flagsChanged,toggle,control)
    trace.sourceEvidence(.requested,.init(selected:6,confirmed:6,target:1,observedAtMilliseconds:100030,targetEventMilliseconds:100030,ageClipped:false,confirmedAtMilliseconds:100020,targetAtMilliseconds:100030,confirmedAgeMicros:10000,targetAgeMicros:0,committed:false,deferred:false,candidatePreserved:false,historyPreserved:false))
    trace.control(.main,.flagsChanged,toggle,control,consumed:true)
    now=100.040
    trace.sourceEvidence(.committed,.init(selected:1,confirmed:6,target:1,observedAtMilliseconds:100040,targetEventMilliseconds:100030,ageClipped:false,confirmedAtMilliseconds:100020,targetAtMilliseconds:100030,confirmedAgeMicros:20000,targetAgeMicros:10000,committed:true,deferred:false,candidatePreserved:false,historyPreserved:false))
    now=100.050;trace.hud(.requested,sourceClass:1)
    now=100.051;trace.hud(.ordered,sourceClass:1)
    now=100.080;trace.hud(.firstDraw,sourceClass:1)
    now=100.200
    let following=make(17,100.190)
    following.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x4852000000000001))
    trace.event(.hid,.keyDown,following)
    following.timestamp+=1000;trace.event(.main,.keyDown,following)
    now=100.220;shape("prefix "+output)
    trace.mark();trace.flush()
    let capture=captures[0],data=try! JSONEncoder().encode(capture)
    check((try? RecorderTrace.decode(data)) != nil,"strict collector accepts switch evidence")
    let frames=capture.frames
    check(frames.filter{$0.kind == .hud}.map{$0.edge}==[1,2,3],"HUD ordering and first draw retained independently")
    check(frames.first{$0.kind == .event}?.eventEvidence?.keyClass==(preKey==49 ? 1:2),"space distinguished from letter without letter identity")
    check(frames.last{$0.kind == .shape}?.shapeEvidence?.caretPrecedingClass==expectedClass,"AX ASCII/Hangul/Jamo classification")
    let keyFrames=frames.filter{$0.kind == .event && $0.milliseconds>=199}
    check(keyFrames.count==2 && keyFrames[0].event==keyFrames[1].event,"retimestamp remains explicitly heuristic event correlation")
    check(keyFrames[0].eventEvidence!.timestampMicros != keyFrames[1].eventEvidence!.timestampMicros,"original timestamp preserved separately at each observed stage")
    let json=String(data:data,encoding:.utf8)!
    check(!json.contains("PRIVATE_UNICODE_PAYLOAD") && !json.contains("keyCode") && !json.contains("prefix"),"no input content or physical letter identity exported")
    var object=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
    var rows=object["frames"] as! [[String:Any]]
    let index=rows.firstIndex{$0["eventEvidence"] != nil}!
    var evidence=rows[index]["eventEvidence"] as! [String:Any];evidence["keyCode"]=17
    rows[index]["eventEvidence"]=evidence;object["frames"]=rows
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:object)))==nil,"collector rejects injected raw key fields")
    last=data
}
for (s,range,value) in [("",NSRange(location:0,length:0),0),("abc",NSRange(location:3,length:1),0),("abc",NSRange(location:99,length:0),0),(" ",NSRange(location:1,length:0),4),("7",NSRange(location:1,length:0),5)] {
    check(InputIncidentShapeProbe.precedingClass(s,range)==value,"bounded caret evidence rejects invalid/selected ranges")
}
let disabled=InputIncidentTrace(destination:nil)
disabled.hud(.requested,sourceClass:1);disabled.event(.hid,.keyDown,make(49,1));disabled.mark();disabled.flush()
check(!disabled.enabled,"OFF does not collect")
if CommandLine.arguments.count>1{try! last!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
print("PASS \(checks) switch timing, space/letter, AX class, HUD stages, privacy and strict collector checks; no OS posts, AX queries or source changes")
