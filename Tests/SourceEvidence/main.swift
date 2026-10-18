import AppKit
import Carbon
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
let ko=mismatchKoreanID,en="com.apple.keylayout.ABC",field=AXUIElementCreateApplication(12345)
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
var posts=0,edits=0,switches=0
func key(_ code:UInt16=2,_ stamp:UInt64=300)->CGEvent {
    guard let source=CGEventSource(stateID:.privateState),let e=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true) else{exit(2)}
    source.userData=0;e.flags=[];e.timestamp=stamp;return e
}
final class Fixture {
    var time=100.0,selected=en,text="",historyCalls=0,reads=0
    var selection:NSRange?;var activeField=field
    let evidence=MismatchSourceEvidence(),barrier=SourceSwitchBarrier(),engine=MismatchRecoveryEngine(detectionOnly:true)
    init(_ tracing:Bool=true){
        evidence.now={ [unowned self] in time }
        evidence.request(ko,at:200);evidence.didCommit(ko,at:200);evidence.observe(ko)
        barrier.sourceEvidence=evidence;barrier.source={ [unowned self] in selected }
        barrier.read={ [unowned self] in .init(field:activeField,text:text,selection:range) };barrier.readFocus={ [unowned self] in activeField }
        barrier.send={_ in posts+=1};barrier.select={_ in switches+=1;return -50}
        engine.sourceEvidence=evidence;engine.enabled=true;engine.lastSource=ko;engine.locked=field
        engine.testSource={ [unowned self] in selected };engine.testFastContext={true}
        engine.testSnapshot={ [unowned self] in reads+=1;return .init(element:activeField,text:text,selection:range) }
        engine.testPost={_ in posts+=1};engine.testPostAtTap={_,_ in posts+=1};engine.testSelectSource={_ in switches+=1;return -50};engine.testSetRange={_,_ in edits+=1;return .cannotComplete}
        engine.verifiedDeliveryHistory={ [unowned self] snap,prior in historyCalls+=1;return barrier.verifiedTwoSetHistory(snap,after:200,allowPrior:prior) }
        engine.noteUserSourceSwitch(at:200)
        if tracing{engine.incidentTrace=trace;barrier.incidentTrace=trace}else{engine.incidentTrace=InputIncidentTrace(destination:nil);barrier.incidentTrace=InputIncidentTrace(destination:nil)}
    }
    var range:NSRange{selection ?? NSRange(location:text.utf16.count,length:0)}
    func press(_ code:UInt16=2,_ stamp:UInt64=300){
        let e=key(code,stamp);let tag=e.getIntegerValueField(.eventSourceUserData),flags=e.flags
        barrier.observe(.keyDown,e);let passed=engine.event(.keyDown,e) != nil
        check(passed && !engine.recovering && engine.pending.isEmpty,"deferred/English input remains unconsumed and unbuffered")
        check(e.timestamp==stamp && e.flags==flags && e.getIntegerValueField(.eventSourceUserData)==tag,"source evidence does not mutate delivered input")
    }
    func sample(){engine.sample(synchronous:true)}
    func settle(){selected=ko;time+=0.01;evidence.observe(ko);sample()}
}
for tracing in [false,true] {
    do {
        let f=Fixture(tracing);f.press();f.text="d";f.sample()
        check(f.engine.detectionCount==0 && f.historyCalls==0,"Roman query never authorizes repair or AX/history lookup")
        f.selected=ko;f.sample();check(f.engine.detectionCount==0,"query alone cannot validate quarantined input")
        f.settle();check(f.engine.detectionCount==1 && f.historyCalls==1,"fresh independent Korean confirmation recovers first deferred physical key")
    }
    do {
        let f=Fixture(tracing);f.selected=ko;f.press();f.text="d"
        check(f.engine.plan?.roman=="d","initial selected Korean creates a candidate")
        f.selected=en;f.press(40,400);f.text="dk";f.sample()
        check(f.engine.plan?.roman=="d" && f.engine.detectionCount==0,"conflict preserves existing candidate without partial editing")
        f.engine.consumeIdleSnapshot(.init(element:field,text:"dk",selection:NSRange(location:2,length:0)))
        check(f.engine.plan?.roman=="d" && f.engine.detectionCount==0,"an asynchronous AX reply cannot erase or edit a deferred candidate")
        f.settle();check(f.engine.detectionCount==1,"deferred history includes the following key exactly once")
    }
    for reason in ["english-request","english-observed","timeout","unknown","stale-display","uncommitted","no-target","body","selection","field","caps","mouse","command","navigation"] {
        let f=Fixture(tracing)
        if reason=="stale-display"{f.time+=0.6}
        if reason=="uncommitted"{f.evidence.request(ko,at:200)}
        if reason=="no-target"{let other=MismatchSourceEvidence();other.now={100};other.observe(ko);f.engine.sourceEvidence=other;f.barrier.sourceEvidence=other}
        f.press();f.text="d"
        switch reason {
        case "english-request":f.evidence.request(en,at:400);f.evidence.didCommit(en,at:400)
        case "english-observed":f.evidence.observe(en)
        case "timeout":f.time+=0.301
        case "unknown":f.evidence.observe("unknown")
        case "caps":let event=key(57);event.type = .flagsChanged;f.evidence.observeInteraction(.flagsChanged,event)
        case "mouse":f.evidence.observeInteraction(.leftMouseDown,key())
        case "command":let event=key(48);event.flags=[.maskCommand];f.evidence.observeInteraction(.keyDown,event)
        case "navigation":f.evidence.observeInteraction(.keyDown,key(123))
        case "body":f.text="changed d"
        case "selection":f.selection=NSRange(location:0,length:0)
        case "field":f.activeField=AXUIElementCreateApplication(12346)
        default:break
        }
        f.settle();check(f.engine.detectionCount==0,"\(reason) cannot convert normal/ambiguous English")
    }
    do {
        let f=Fixture(tracing);f.evidence.request(en,at:250);f.evidence.didCommit(en,at:250);f.evidence.observe(en)
        for i in 0..<8{f.press(2,UInt64(300+i));f.text+="d";f.sample()}
        check(f.engine.detectionCount==0 && f.engine.plan==nil,"confirmed ordinary English never becomes Korean")
    }
}
// A display-only Korean hint without a committed Korean request is insufficient.
do {
    let e=MismatchSourceEvidence();e.observe(ko)
    check(e.deferredSource(for:en)==nil,"stale display alone is not an authorization")
}
// A confirmed external English interval revokes the old committed target.
do {
    let f=Fixture();f.evidence.observe(en);f.evidence.observe(ko)
    check(!f.evidence.committed,"external English confirmation revokes the old committed request")
    f.press();f.text="d";f.settle()
    check(f.engine.detectionCount==0,"returning to Korean cannot revive an older request for a later Roman key")
}
// Bounded preservation expires even if a periodic Korean read arrives late.
do {
    let f=Fixture();f.press();let saved=f.evidence.epoch;f.time+=0.31;f.evidence.observe(ko)
    check(f.evidence.deferredSource(for:ko)==nil && !f.evidence.permitsHistory(saved),"late observation does not revive expired evidence")
}
check(posts==0 && edits==0 && switches==0,"no global posts, AX edits or input source selections")
// Source metadata uses nonblocking bounded slots, with measured worker waits.
do {
    var records:[InputIncidentTrace.Capture]=[]
    let t=InputIncidentTrace(destination:nil,observationCapacity:16,writer:{records.append($0)})
    let f=Fixture();let value=f.evidence.diagnostic(selected:en)
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    DispatchQueue.global().async{t.withLockedMetadataForTest{entered.signal();release.wait()}}
    check(entered.wait(timeout:.now()+1) == .success,"source evidence contention fixture owns the metadata lock")
    let began=ProcessInfo.processInfo.systemUptime
    for _ in 0..<100{t.sourceEvidence(.deferred,value,event:key())}
    check(ProcessInfo.processInfo.systemUptime-began<0.1,"source evidence caller never waits for the metadata lock")
    release.signal();t.flush();t.mark();t.flush()
    let c=records[0],code=((6-1)*8+4-1)*32+4
    if (c.observationDelivery.overflow[code] ?? 0)==0 {print("source counter debug",code,c.observationDelivery.overflow,c.observationDelivery.processed,"secureInput",IsSecureEventInputEnabled())}
    check((c.observationDelivery.overflow[code] ?? 0)>0,"source evidence overflow has an action-specific counter")
    check((c.observationDelivery.waits[code]?.contended ?? 0)>0,"source evidence worker lock waits are measured")
    _=try RecorderTrace.decode(JSONEncoder().encode(c))
    for _ in 0..<20{t.sourceEvidence(.romanSkipped,value)}
    t.flush();t.mark();t.flush()
    check((records.last!.observationDelivery.coalesced[((6-1)*8+4-1)*32+7] ?? 0)>0,"source evidence repeat suppression is counted")
    _=try RecorderTrace.decode(JSONEncoder().encode(records.last!))
}
// Typed evidence retains original event correlation, numeric times and old compatibility.
let f=Fixture();f.press();f.text="d";f.settle()
trace.mark();trace.flush()
let capture=captures.last!,data=try JSONEncoder().encode(capture),decoded=try RecorderTrace.decode(data)
let evidenceFrames=decoded.frames.filter{$0.kind==10}
check(!evidenceFrames.isEmpty && evidenceFrames.contains{$0.event>0 && $0.sourceEvidence?.historyPreserved==true},"new evidence correlates to the physical key")
check(evidenceFrames.contains{$0.edge==5 && $0.sourceEvidence?.historyPreserved==true},"history restoration is recorded")
let encoded=String(data:data,encoding:.utf8)!
for value in [ko,en,"changed d","\"text\"","\"keyCode\""]{check(!encoded.contains(value),"source evidence excludes arbitrary input/source strings")}
check(evidenceFrames.contains{$0.sourceEvidence?.confirmed==1 && $0.sourceEvidence?.target==1 && $0.sourceEvidence?.confirmedAtMilliseconds != nil && $0.sourceEvidence?.targetAtMilliseconds != nil},"confirmation/request times accompany the decision")
var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
let allRows=object["frames"] as! [[String:Any]],index=allRows.firstIndex{($0["kind"] as? Int)==10}!
for bad:[String:Any] in [["selected":"private source"],["confirmed":8],["targetAgeMicros":60_000_001],["confirmedAtMilliseconds":NSNull()],["private":"typed input"]] {
    var rows=allRows,row=rows[index],evidence=row["sourceEvidence"] as! [String:Any]
    for (k,v) in bad{evidence[k]=v};row["sourceEvidence"]=evidence;rows[index]=row;object["frames"]=rows
    do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:object));check(false,"invalid evidence rejected")}catch{check(true,"invalid evidence rejected")}
}
if let output=ProcessInfo.processInfo.environment["HANQ_SOURCE_EVIDENCE_TEST_OUTPUT"]{try data.write(to:URL(fileURLWithPath:output))}
print("PASS: \(checks) source-evidence checks; ON/OFF same decisions, deferred history restoration, ordinary English/invalid evidence protected; no OS posts")
