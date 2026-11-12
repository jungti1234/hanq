import AppKit
import Carbon

func runBoundaryDiagnosticTests() {
    let at0=NSRange(location:0,length:0),at1=NSRange(location:1,length:0),at2=NSRange(location:2,length:0)
    var history=BoundaryDiagnosticHistory();history.note(1,baseline:true,at:0);history.note(10,baseline:false,at:0.01)
    var report=BoundaryDiagnosticTransaction(id:1,started:0.1)
    check(report.observe(prediction:at1,reported:at0,text:1,history:history,at:0.2)?.resolution==5,"first caret mismatch remains unresolved")
    let caught=report.observe(prediction:at1,reported:at1,text:1,history:history,at:0.25)!
    check(caught.resolution==2 && caught.change==2,"report changes to stable prediction")
    check(caught.seed==1 && caught.mutation==10 && caught.baselineAgeMicros==250000,"baseline and most recent prediction cause have distinct ages")
    history.note(7,baseline:false,at:0.3)
    _=report.observe(prediction:at1,reported:at1,text:1,history:history,at:0.31)
    check(report.evidence(phase:3,reason:1,history:history,at:0.32).resolution==2,"post-switch history cannot rewrite earlier resolution")
    var prediction=BoundaryDiagnosticTransaction(id:2,started:0)
    _=prediction.observe(prediction:at1,reported:at0,text:1,history:history,at:0)
    history.note(13,baseline:false,at:0.1)
    check(prediction.observe(prediction:at0,reported:at0,text:1,history:history,at:0.1)?.resolution==3,"prediction changes to unchanged report")
    var both=BoundaryDiagnosticTransaction(id:3,started:0)
    _=both.observe(prediction:at1,reported:at0,text:1,history:history,at:0)
    check(both.observe(prediction:at2,reported:at2,text:1,history:history,at:0.2)?.resolution==4,"both sides changing is not report-only evidence")
    var unchanged=BoundaryDiagnosticTransaction(id:4,started:0)
    _=unchanged.observe(prediction:at1,reported:at0,text:1,history:history,at:0)
    for _ in 0..<200 {_=unchanged.observe(prediction:at1,reported:at0,text:1,history:history,at:0.1)}
    let timeout=unchanged.evidence(phase:3,reason:2,history:history,at:1.004)
    check(timeout.resolution==5 && timeout.coalesced>190 && timeout.sampleAgeMicros==904000,"persistent mismatch preserves last-read freshness and coalesces repeated samples")
    check(timeout.requestAgeMicros==1004000 && timeout.observations==201 && timeout.valid,"terminal diagnostics reflect real observations, not a new AX read")
    var bounded=BoundaryDiagnosticTransaction(id:5,started:0);var emitted=0
    for i in 0..<200 {if bounded.observe(prediction:at1,reported:at0,text:i%2==0 ? 1:5,history:history,at:Double(i)/1000) != nil{emitted+=1}}
    check(emitted==32 && bounded.evidence(phase:3,reason:2,history:history,at:1).suppressed>0,"comparison transitions capped at 32 plus request/end")
    var unknown=BoundaryDiagnosticTransaction(id:6,started:0)
    check(unknown.observe(prediction:nil,reported:at0,text:0,history:history,at:0)?.resolution==0,"missing prediction stays unknown")
    check(unknown.observe(prediction:NSRange(location:Int.max,length:1),reported:at0,text:1,history:history,at:0.1)?.expected==0,"overflowing range never produces a relation")
    _=unknown.observe(prediction:at1,reported:NSRange(location:NSNotFound,length:0),text:1,history:history,at:0.2)
    check(unknown.evidence(phase:3,reason:4,history:history,at:0.3).reported==0,"unavailable report is not a collapsed caret")
    let capped=report.evidence(phase:3,reason:1,history:history,at:100)
    check(capped.baselineAgeMicros==60000000 && capped.requestAgeMicros==60000000,"ages cap at 60 seconds")
    check(report.evidence(phase:3,reason:1,history:history,at:-1).requestAgeMicros==nil,"backward clock is unmeasured")
    var wrapped=history;wrapped.revision=1_000_000;wrapped.note(10,baseline:false,at:0.4)
    check(wrapped.revision==0,"bounded revision wraps instead of silently losing later mutations")

    // Same injected product operations with diagnostics OFF/ON; never post keys.
    var outcomes:[[Int]]=[]
    for enabled in [false,true] {
        let b=SourceSwitchBarrier();var body="",range=at0,selected=ko,time=0.0,reads=0,queries=0,switches=0,posts=0,writes=0,retained=0
        var evidence:[InputIncidentTrace.BoundaryEvidence]=[]
        b.incidentTrace=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:enabled,writer:{_ in})
        b.diagnostic={evidence.append($0)};b.now={time}
        b.read={reads+=1;return .init(field:field,text:body,selection:range)};b.readFocus={field}
        b.source={queries+=1;return selected};b.select={selected=$0;switches+=1;return noErr}
        b.send={_ in posts+=1};b.applySelection={_,_ in writes+=1;return false};b.retained={retained += $0.count}
        b.observe(.keyDown,key(0));body="ㅁ"
        check(b.request(en),"diagnosed request accepted")
        b.step()
        for code in [CGKeyCode(54),56,1,1,56] {
            let value=key(code);value.type = code==1 ? .keyDown:.flagsChanged
            check(b.receive(value.type,value),"diagnosed queue owns undelivered event")
        }
        time=1.004;b.step()
        outcomes.append([reads,queries,switches,posts,writes,retained,b.busy ? 1:0])
        check(retained==5 && switches==0 && posts==0 && writes==0,"diagnostics cannot weaken range guard or replay retained events")
        if enabled {
            check(evidence.first?.phase==1 && evidence.last?.phase==3 && evidence.last?.reason==2,"request and terminal compare evidence stay paired")
            check(evidence.last?.seed==1 && evidence.last?.mutation==10 && evidence.last?.resolution==5,"original prediction provenance survives deadline")
            check(evidence.allSatisfy{$0.valid},"every emitted evidence record conforms to wire contract")
            let object=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence)) as! [[String:Any]]
            check(object.allSatisfy{Set($0.keys).subtracting(InputIncidentTrace.BoundaryEvidence.ages)==InputIncidentTrace.BoundaryEvidence.required},"no body, keys, actual ranges, hashes or app identity are serialized")
        } else {check(evidence.isEmpty,"diagnostics OFF emits no comparison evidence")}
        b.fail("test_cleanup")
        let idleReads=reads,idleQueries=queries,idleEvidence=evidence.count
        for _ in 0..<1000 {b.step()}
        check(reads==idleReads && queries==idleQueries && evidence.count==idleEvidence,"idle step adds no AX/source query, comparison record or file request")
    }
    check(outcomes[0]==outcomes[1],"ON/OFF has identical existing AX/source call counts, edits, delivery and retained result")
    do {
        let trace=InputIncidentTrace(secureInput:{false},destination:nil,writer:{_ in}),b=SourceSwitchBarrier()
        var text="",selection=at0,source=ko,records:[InputIncidentTrace.BoundaryEvidence]=[]
        b.incidentTrace=trace;b.diagnostic={records.append($0)};b.now={0}
        b.read={.init(field:field,text:text,selection:selection)};b.readFocus={field};b.source={source};b.select={source=$0;return noErr};b.send={_ in}
        b.observe(.keyDown,key(0));text="ㅁ";check(b.request(en),"generation trial begins")
        b.step();let before=records.count
        trace.setCollectionEnabled(false);trace.flush();b.step()
        check(records.count==before,"OFF stops an in-flight comparison immediately")
        trace.setCollectionEnabled(true);trace.flush();b.step()
        check(records.count==before,"re-enabled collection cannot invent the earlier request baseline")
        b.fail("test_cleanup");check(b.request(en),"new request after generation change")
        check(records.last?.phase==1 && records.last?.seed==2,"new generation records its own request read instead of stale key provenance")
        b.fail("test_cleanup")
    }
}
