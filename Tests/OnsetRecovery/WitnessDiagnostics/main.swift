import AppKit

var checks=0
func check(_ value:@autoclosure ()->Bool,_ name:String){checks+=1;if !value(){fputs("FAIL: \(name)\n",stderr);exit(1)}}

// Every AX/owner/readiness operation is injected. No tap, focus request,
// system key post, clipboard, source switch or actual editor is used.
final class Probe {
    let h=OnsetFocusHandoff()
    let root=AXUIElementCreateApplication(97001),field=AXUIElementCreateApplication(97002),other=AXUIElementCreateApplication(97003)
    var time=10.0,mode="recorded",context="",afterRead=false
    var batchCalls=0,readCalls=0,readyCalls=0,ownerCalls=0,frontCalls=0
    init(_ mode:String,diagnostics:Bool){
        self.mode=mode;h.collectWitnessDiagnostics=diagnostics;h.now={self.time}
        h.ready={self.readyCalls+=1;return self.context != "not_ready" && !(self.context=="not_ready_after" && self.afterRead)}
        h.frontPID={self.frontCalls+=1;return self.context=="front_after" && self.afterRead ? 43:42}
        h.owner={_ in self.ownerCalls+=1;return self.mode=="owner" || self.context=="owner" ? 43:42}
        h.writable={_,_ in true};h.children={_ in []}
        h.read={element,name in
            self.readCalls+=1
            if name==kAXWindowAttribute {
                self.afterRead=true
                if self.context=="window_missing"{return nil}
                if self.context=="window_changed"{return self.other}
                return self.root
            }
            return nil
        }
        h.batch={element,names in
            self.batchCalls+=1
            if CFEqual(element,self.field),names.count>3,self.mode=="batch"{return []}
            if CFEqual(element,self.field),names.count>3,self.mode=="deadline"{self.time+=0.020}
            return names.map{self.attribute(element,$0)}
        }
        h.advance(window:root,outside:other)
    }
    func range(_ location:Int,_ length:Int)->CFTypeRef{var r=CFRange(location:location,length:length);return AXValueCreate(.cfRange,&r)!}
    func attribute(_ e:AXUIElement,_ name:String)->CFTypeRef? {
        if name==kAXRoleAttribute{return (CFEqual(e,field) ? kAXTextAreaRole:kAXWindowRole) as CFString}
        if name==kAXChildrenAttribute{return (CFEqual(e,root) ? [field]:[]) as CFArray}
        if name==kAXSubroleAttribute{return (mode=="role" ? kAXSecureTextFieldSubrole:"") as CFString}
        if name==kAXValueAttribute {
            if mode=="value"{return nil}
            return (mode=="empty" ? "":mode=="large" ? String(repeating:"x",count:4097):"synthetic display") as CFString
        }
        if name==kAXNumberOfCharactersAttribute {
            if mode=="count_missing"{return nil}
            return NSNumber(value:mode=="count_wrong" ? 1:17)
        }
        if name==kAXSelectedTextRangeAttribute{return range(mode=="caret" ? NSNotFound:0,0)}
        if name==kAXEnabledAttribute{return mode=="disabled" ? kCFBooleanFalse:kCFBooleanTrue}
        if name=="AXHidden"{return kCFBooleanFalse}
        if name==kAXWindowAttribute {
            if mode=="window_missing"{return nil}
            return mode=="window_wrong" ? other:root
        }
        return nil
    }
    var calls:[Int]{[batchCalls,readCalls,readyCalls,ownerCalls,frontCalls]}
}

let representationCases:[(String,Int)]=[("recorded",1),("batch",2),("role",3),("value",4),("empty",5),("large",5),("count_missing",6),("count_wrong",7),("caret",8),("disabled",9),("window_missing",10),("window_wrong",11),("owner",12),("deadline",13)]
for (mode,reason) in representationCases {
    let off=Probe(mode,diagnostics:false),on=Probe(mode,diagnostics:true)
    let a=off.h.representationWitness(for:off.field,before:10.01)
    let b=on.h.representationWitness(for:on.field,before:10.01)
    check((a != nil)==(b != nil),"same eligibility ON/OFF: \(mode)")
    check(off.calls==on.calls,"no diagnostic AX/owner/readiness query: \(mode)")
    check(off.h.witnessDetail(for:off.field)==nil,"OFF has no details: \(mode)")
    let detail=on.h.witnessDetail(for:on.field)!
    check(detail.representation==reason,"representation reason \(mode): \(detail.representation)")
    check((0...9).contains(detail.discovery),"bounded discovery \(mode)")
}

let lookupCases:[(String,Int)]=[("available",1),("field",2),("no_prior",3),("old",4),("clock",5),("expired",6),("not_ready",7),("owner",8),("window_missing",9),("window_changed",10),("not_ready_after",11),("front_after",12)]
for (mode,expected) in lookupCases {
    func run(_ diagnostics:Bool)->(Bool,[Int],InputIncidentTrace.OnsetDetail?){
        let p=Probe("recorded",diagnostics:diagnostics)
        var key=10.01
        if mode=="no_prior"{key=9.99}
        if mode=="old"{key=10.751;p.time=10.8}
        if mode=="clock"{p.time=9.99}
        if mode=="expired"{key=10.5;p.time=11.101}
        p.context=mode;p.afterRead=false
        let result=p.h.representationWitness(for:mode=="field" ? p.other:p.field,before:key)
        return (result != nil,p.calls,p.h.witnessDetail(for:mode=="field" ? p.other:p.field))
    }
    let a=run(false),b=run(true)
    check(a.0==b.0 && a.1==b.1,"lookup query/behavior parity: \(mode)")
    check(b.2?.lookup==expected,"lookup reason \(mode): \(b.2?.lookup ?? -1)")
}

let generationTrace=InputIncidentTrace(destination:nil,writer:{_ in})
let generationEngine=OnsetRecoveryEngine()
generationEngine.enabled=true;generationEngine.decisionTrace=generationTrace
generationEngine.testSource={"unsupported.test.layout"}
generationEngine.sample()
generationEngine.focusHandoff.noteDiscovery(8)
let generationField=AXUIElementCreateApplication(97004)
check(generationEngine.focusHandoff.witnessDetail(for:generationField)?.discovery==8,"current generation measured")
generationTrace.setCollectionEnabled(false);generationTrace.flush()
generationTrace.setCollectionEnabled(true);generationTrace.flush()
generationEngine.sample()
check(generationEngine.focusHandoff.witnessDetail(for:generationField)?.discovery==0,"OFF/ON between samples does not reuse prior diagnostic generation")
generationEngine.enabled=false;generationTrace.stopAndFlush()

let inputs:[([(UInt16,Bool)],String,Int,NSRange,String,Int)]=[
    ([],"",0,NSRange(location:0,length:0),onsetKoreanID,1),
    ([(5,false),(46,false)],"",0,NSRange(location:0,length:1),onsetKoreanID,2),
    ([(5,false),(46,false)],"",0,NSRange(location:0,length:0),"unsupported.test.layout",3),
    ([(46,false),(5,false)],"",0,NSRange(location:0,length:0),onsetKoreanID,4),
    ([(5,false),(49,true)],"",0,NSRange(location:0,length:0),onsetKoreanID,5),
    ([(5,false),(123,false)],"",0,NSRange(location:0,length:0),onsetKoreanID,6),
    ([(5,false),(5,false)],"",0,NSRange(location:0,length:0),onsetKoreanID,7),
    ([(5,false),(46,false)],"",0,NSRange(location:4,length:0),onsetKoreanID,8)
]
for (keys,before,caret,range,source,expected) in inputs {
    var reason=0
    let result=OnsetLateSequenceDetector.inspect(keys:keys,before:before,caret:caret,text:"합성 문구",selection:range,sourceID:source,onRejected:{reason=$0.rawValue})
    if case .rejected=result {}else{check(false,"must reject \(expected)")}
    check(reason==expected,"history reason \(expected): \(reason)")
}

var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
let first=ProcessInfo.processInfo.systemUptime
func detail(_ lookup:Int,_ age:Int)->InputIncidentTrace.OnsetDetail{.init(discovery:8,representation:1,lookup:lookup,history:0,observationAgeMicros:age)}
for i in 0..<50{trace.onsetDecision(.publication,.representationMissing,firstTime:first,keys:1,detail:detail(2,i))}
trace.onsetDecision(.publication,.representationMissing,firstTime:first,keys:1,detail:detail(4,100))
var independent=detail(4,100)
independent.switchKey=1;independent.draftRead=7;independent.draftLookup=3;independent.insertedSpan=0
for _ in 0..<20{trace.onsetDecision(.history,.historyRejected,firstTime:first,keys:2,detail:independent)}
independent.switchKey=5
trace.onsetDecision(.history,.historyRejected,firstTime:first,keys:2,detail:independent)
trace.flush();trace.mark();trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check(captures.allSatisfy{(try? RecorderTrace.decode(JSONEncoder().encode($0))) != nil},"strict optional detail")
let frames=captures.flatMap{$0.frames}.filter{$0.kind == .onsetDecision}
check(frames.count==4,"state changes survive coalescing but age-only changes do not flood")
let object=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(captures[0])) as! [String:Any]
for bad:[String:Any] in [
    ["discovery":1,"representation":1,"lookup":2,"history":0,"switchKey":1],
    ["discovery":1,"representation":1,"lookup":2,"history":0,"switchKey":14,"draftRead":0,"draftLookup":0,"insertedSpan":0],
    ["discovery":1,"representation":1,"lookup":2,"history":0,"switchKey":true,"draftRead":0,"draftLookup":0,"insertedSpan":0],
    ["discovery":10,"representation":1,"lookup":2,"history":0],
    ["discovery":1,"representation":14,"lookup":2,"history":0],
    ["discovery":1,"representation":1,"lookup":13,"history":0],
    ["discovery":1,"representation":1,"lookup":2,"history":9],
    ["discovery":true,"representation":1,"lookup":2,"history":0],
    ["discovery":1,"representation":1,"lookup":2,"history":0,"text":"secret"],
    ["discovery":1,"representation":1,"lookup":2,"history":0,"observationAgeMicros":60_000_001]
] {
    var copy=object,rows=copy["frames"] as! [[String:Any]]
    let i=rows.firstIndex{($0["kind"] as? Int)==13}!
    var evidence=rows[i]["onsetEvidence"] as! [String:Any];evidence["detail"]=bad;rows[i]["onsetEvidence"]=evidence;copy["frames"]=rows
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:copy)))==nil,"invalid detail refused")
}
if CommandLine.arguments.count>1{try! JSONEncoder().encode(captures[0]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
trace.stopAndFlush()
print("PASS \(checks) witness recording/lookup/history details, AX parity, OFF and strict privacy checks")
