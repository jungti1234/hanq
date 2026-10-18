import Foundation
import ApplicationServices
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
var time=100.0,captures:[InputIncidentTrace.Capture]=[]
var probe=InputIncidentShapeProbe()
let trace=InputIncidentTrace(destination:nil,capacity:16,clock:{time},writer:{captures.append($0)})
func observe(_ text:String,_ range:NSRange = NSRange(location:1,length:0),editing:Bool=false,identity:UInt=1){
    let change=probe.observe(identity:identity,text:text,selection:range,generation:trace.collectionGeneration)
    trace.shape(.mismatchAX,identity:identity,count:text.utf16.count,selected:range.length>0,editing:editing,change:change)
    trace.flush()
}
func capture()->InputIncidentTrace.Capture {trace.mark();trace.flush();let value=captures.last!;trace.finishCaptureWindowsForTest();trace.flush();return value}
func latest()->InputIncidentTrace.ShapeEvidence {capture().shapeBaselines![0].current.evidence}
observe("d");let initial=latest()
check(!initial.comparisonKnown && !initial.contentChanged && initial.observations==1,"first observation is unknown baseline")
time+=0.02;observe("ㅇ");let substitution=latest()
check(substitution.comparisonKnown && substitution.contentChanged && !substitution.selectionChanged,"same UTF16 length substitution retained")
time+=0.02;observe("ㅇ",NSRange(location:0,length:0));let caret=latest()
check(caret.selectionChanged && !caret.contentChanged,"empty selection cursor movement retained without coordinate")
time+=0.02;observe("ㅇ",NSRange(location:0,length:1));check(latest().selectionChanged,"selection starts")
time+=0.02;observe("ab",NSRange(location:0,length:1));check(latest().contentChanged,"growth retained")
time+=0.02;observe("ab",NSRange(location:1,length:1));check(latest().selectionChanged,"nonempty selection location changes")
time+=0.02;observe("ab",NSRange(location:0,length:2));check(latest().selectionChanged,"nonempty selection length changes")
time+=0.02;observe("ab",NSRange(location:0,length:2),editing:true);check(latest().editingChanged && latest().editing,"editing-only transition retained")
let start=time
for _ in 0..<5{time+=0.02;observe("ab",NSRange(location:0,length:2),editing:true)}
let repeated=capture();let evidence=repeated.shapeBaselines![0].current.evidence
check(evidence.observations==6 && evidence.coalesced==5,"suppressed repetition keeps exact span count")
check(evidence.firstMilliseconds==Int((start-100)*1000) && evidence.lastMilliseconds>evidence.firstMilliseconds,"repetition start and last successful observation preserved")
time+=1.01;observe("ab",NSRange(location:0,length:2),editing:true)
check(capture().frames.contains{$0.shapeEvidence?.phase==2 && $0.shapeEvidence!.observations==7},"one second checkpoint emitted")
time+=0.02;observe("ab",NSRange(location:0,length:2),editing:true)
time+=0.02;observe("ac",NSRange(location:0,length:2),editing:true)
let closed=capture()
check(closed.frames.contains{$0.shapeEvidence?.phase==3 && $0.shapeEvidence!.observations==8},"final suppressed endpoint closed on content change")
check(closed.shapeBaselines![0].previous?.evidence.observations==8,"preceding baseline survives independently")
for _ in 0..<30{let read=trace.beginRead(.mismatchAX);trace.endRead(.mismatchAX,read);trace.flush()}
let evicted=capture()
check(evicted.frames.allSatisfy{$0.kind != .shape},"ring baseline really evicted by reads")
check(evicted.shapeBaselines![0].current.count==2 && evicted.shapeBaselines![0].previous != nil,"capture retains current and prior baselines beyond ring")
trace.context();trace.flush();let invalid=capture()
check(!invalid.shapeBaselines![0].active,"context closes validity but preserves fixed metadata")
observe("ac",NSRange(location:0,length:2));check(!latest().comparisonKnown,"new context does not infer continuity")
let encoded=try JSONEncoder().encode(capture())
let decoded=try RecorderTrace.decode(encoded)
check(decoded.shapeBaselines?.count==1,"strict collector accepts new snapshot metadata")
let roundtrip=try RecorderTrace.decode(JSONEncoder().encode(decoded))
check(roundtrip.shapeBaselines![0].current.count==2,"sanitize roundtrip preserves baseline")
let object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
check(!String(data:encoded,encoding:.utf8)!.contains("\"text\"") && !String(data:encoded,encoding:.utf8)!.contains("\"location\""),"neither content nor cursor coordinates encoded")
// Scalar sample discontinuity proves a dropped shape; never claim continuity.
let missed=probe.observe(identity:1,text:"SECRET_SYNTHETIC_SENTINEL",selection:NSRange(location:3,length:0),generation:trace.collectionGeneration)
check(missed.content,"fixture changed, but deliberately did not submit")
observe("ac",NSRange(location:0,length:2));let gap=latest()
check(gap.gap && !gap.comparisonKnown && !gap.contentChanged,"sample gap is explicit unknown comparison")
let gapData=try JSONEncoder().encode(capture())
check(!String(data:gapData,encoding:.utf8)!.contains("SECRET_SYNTHETIC_SENTINEL"),"content sentinel never reaches diagnostic queue or JSON")
// Exact scalar order, not canonical String equality, with matching UTF16 counts.
var unicodeProbe=InputIncidentShapeProbe()
let a="a\u{301}\u{323}",b="a\u{323}\u{301}"
_ = unicodeProbe.observe(identity:1,text:a,selection:NSRange(location:3,length:0),generation:1)
check(a==b && a.utf16.count==b.utf16.count,"canonical-equivalence fixture")
check(unicodeProbe.observe(identity:1,text:b,selection:NSRange(location:3,length:0),generation:1).content,"equal-length canonical order change detected")
check(!unicodeProbe.observe(identity:1,text:b,selection:NSRange(location:3,length:0),generation:2).known,"diagnostic generation reset discards prior comparison")
func rejects(_ document:[String:Any],_ message:String){do{_=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:document));check(false,message)}catch{checks+=1}}
var base=object;var baselines=base["shapeBaselines"] as! [[String:Any]]
var point=baselines[0]["current"] as! [String:Any],meta=point["evidence"] as! [String:Any]
for (key,bad) in [("text","PRIVATE" as Any),("phase",4),("observations",0),("coalesced",999),("editing",1),("comparisonKnown",NSNull()),("lastMilliseconds",-1)] {
 var row=meta;row[key]=bad;var p=point;p["evidence"]=row;var lane=baselines[0];lane["current"]=p;var d=base;d["shapeBaselines"]=[lane];rejects(d,"invalid or private metadata rejected")
}
var duplicate=base;duplicate["shapeBaselines"]=[baselines[0],baselines[0]];rejects(duplicate,"duplicate lane rejected")
var old=base;old.removeValue(forKey:"shapeBaselines");old["frames"]=[]
let oldTrace=try RecorderTrace.decode(JSONSerialization.data(withJSONObject:old))
check(oldTrace.shapeBaselines==nil,"old traces remain explicitly unmeasured")
// A held trace lock cannot block the submitting snapshot path; queue credits
// overflow immediately and the first later sample advertises the discontinuity.
var overflowCaptures:[InputIncidentTrace.Capture]=[]
let over=InputIncidentTrace(destination:nil,observationCapacity:8,writer:{overflowCaptures.append($0)})
var overProbe=InputIncidentShapeProbe()
func send(_ text:String){let c=overProbe.observe(identity:1,text:text,selection:NSRange(location:1,length:0),generation:over.collectionGeneration);over.shape(.onsetAX,identity:1,count:text.utf16.count,selected:false,editing:false,change:c)}
send("a");over.flush()
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
Thread{over.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2) == .success,"diagnostic lock held")
let began=DispatchTime.now().uptimeNanoseconds
for i in 0..<100{send(i%2==0 ? "b":"c")}
check(DispatchTime.now().uptimeNanoseconds-began<50_000_000,"caller returns before locked worker is released")
Thread.sleep(forTimeInterval:0.025);release.signal();check(done.wait(timeout:.now()+2) == .success,"worker released")
over.flush();send("d");over.flush();over.mark();over.flush()
let overflow=overflowCaptures.last!
check(overflow.observationDelivery.overflow[928,default:0]>0,"shape overflow classified")
check(overflow.shapeBaselines![0].current.evidence.gap,"queue overflow breaks comparison continuity")
check(overflow.frames.contains{$0.shapeEvidence != nil && $0.observationTiming?.contended==true},"actual lock wait remains individually visible")
check((try? RecorderTrace.decode(JSONEncoder().encode(overflow))) != nil,"overflow/lock metadata strict decode")
// Important queue delay survives as a shape checkpoint, with no real sleep.
var calls=0,delayedCaptures:[InputIncidentTrace.Capture]=[]
let delayed=InputIncidentTrace(destination:nil,observationClock:{calls+=1;return calls<3 ? 1_000_000_000:(calls==3 ? 2_000_000_000:2_075_000_000)},writer:{delayedCaptures.append($0)})
delayed.shape(.onsetAX,identity:1,count:3,selected:false,editing:false);delayed.flush()
delayed.shape(.onsetAX,identity:1,count:3,selected:false,editing:false);delayed.flush();delayed.mark();delayed.flush()
check(delayedCaptures.last!.frames.contains{$0.shapeEvidence?.phase==2 && $0.observationTiming?.queueMicros==75_000},"long unchanged-shape queue delay remains individual")
// Both capture phases attach bounded baselines, even after a late read flood.
let afterDone=DispatchSemaphore(value:0);var afterCapture:InputIncidentTrace.Capture?
let after=InputIncidentTrace(destination:nil,capacity:2,writer:{value in if value.phase==1{afterCapture=value;afterDone.signal()}})
after.shape(.onsetAX,identity:1,count:4,selected:false,editing:false);after.flush();after.mark();after.flush()
for _ in 0..<4{let read=after.beginRead(.onsetAX);after.endRead(.onsetAX,read);after.flush()}
check(afterDone.wait(timeout:.now()+3) == .success,"post capture actually published")
check(afterCapture?.shapeBaselines?.first?.current.count==4 && afterCapture!.frames.allSatisfy{$0.kind != .shape},"post phase preserves baseline outside ring")
check((try? RecorderTrace.decode(JSONEncoder().encode(afterCapture!))) != nil,"post baseline strict decode")
// A large AX-style NSString must not fall into an unoptimized Swift unit loop.
// All contents are fixed synthetic fixtures; only durations/counts are exported.
var comparisonTiming:[[String:Any]]=[]
for size in [1000,100000,1000000] {
    let body=NSMutableString(capacity:size)
    body.append(String(repeating:"한",count:size))
    let first=(body.copy() as! NSString) as String
    body.replaceCharacters(in:NSRange(location:size/2,length:1),with:"글")
    let second=(body.copy() as! NSString) as String
    var largeProbe=InputIncidentShapeProbe(),durations:[UInt64]=[]
    for i in 0..<12 {
        let began=DispatchTime.now().uptimeNanoseconds
        let value=largeProbe.observe(identity:9,text:i%2==0 ? first:second,selection:NSRange(location:0,length:0),generation:1)
        durations.append(DispatchTime.now().uptimeNanoseconds-began)
        check(i==0 ? !value.known:value.content,"large literal content comparison correct")
    }
    comparisonTiming.append(["utf16":size,"maximumMicros":Double(durations.max()!)/1000])
    check(durations.max()!<10_000_000,"large snapshot comparison below10ms investigation threshold")
}
if let output=CommandLine.arguments.dropFirst().first {try JSONSerialization.data(withJSONObject:comparisonTiming,options:[.sortedKeys]).write(to:URL(fileURLWithPath:output+".comparison.json"))}
if let output=CommandLine.arguments.dropFirst().first {try encoded.write(to:URL(fileURLWithPath:output));try JSONEncoder().encode(overflow).write(to:URL(fileURLWithPath:output+".overflow.json"))}
// Semantic metadata distinguishes evidence from a claim about the document.
for (text,kind) in [("",1),("\n\r",2),(" \t\n",3),("문장",4),("\u{200b}",4)] {
    check(InputIncidentAXEvidence.classify(text)==kind,"value class expected \(kind), got \(InputIncidentAXEvidence.classify(text))")
}
check(InputIncidentAXEvidence.match(" hint\n",["hint"])==4,"trimmed placeholder match is only a hint")
check(InputIncidentAXEvidence.match("user",[nil])==1,"unsupported is distinct from negative match")
check(InputIncidentAXEvidence.match("user",[" "])==2,"empty label distinct")
check(InputIncidentAXEvidence.match("user",["hint"])==3,"nonmatching label distinct")
let registry=InputIncidentFieldRegistry(),elementA=AXUIElementCreateApplication(90001),elementA2=AXUIElementCreateApplication(90001),elementB=AXUIElementCreateApplication(90002)
let ra=registry.identify(elementA,owner:90001,window:elementB,generation:1)
let ra2=registry.identify(elementA2,owner:90001,window:elementB,generation:1)
check(ra.0==ra2.0 && ra.1==ra2.1 && ra.2==ra2.2,"CFEqual refs share anonymous field/owner/window tokens")
let rb=registry.identify(elementB,owner:90002,window:nil,generation:1)
check(rb.0 != ra.0 && rb.1 != ra.1 && rb.2==0,"different owner/field and unavailable window")
let rg=registry.identify(elementA,owner:90001,window:elementB,generation:2)
check(rg.0 != ra.0 && rg.3>ra.3,"new generation cannot reuse identity continuity")
for i in 0..<70{_ = registry.identify(AXUIElementCreateApplication(pid_t(91000+i)),owner:pid_t(91000+i),window:nil,generation:2)}
let re=registry.identify(elementA,owner:90001,window:nil,generation:2)
check(re.3>rg.3 && re.0 != rg.0,"bounded identity registry advertises eviction epoch")
var semanticProbe=InputIncidentShapeProbe()
var ax=InputIncidentAXEvidence();ax.owner=1;ax.window=2;ax.identityEpoch=1;ax.route=2;ax.placeholder=4;ax.label=1;ax.characterCount=2;ax.representation=1
let semanticTrace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
func semantic(_ value:String,_ identity:UInt=1){let change=semanticProbe.observe(identity:identity,text:value,selection:NSRange(location:0,length:0),generation:semanticTrace.collectionGeneration,ax:ax);semanticTrace.shape(.mismatchAX,identity:identity,count:value.utf16.count,selected:false,editing:false,change:change);semanticTrace.flush()}
semantic("PUBLIC_HINT\n");semantic("PUBLIC_HINT\n");ax.placeholder=3;semantic("\n")
semanticTrace.mark();semanticTrace.flush()
let semanticCapture=captures.last!,semanticData=try JSONEncoder().encode(semanticCapture)
let semanticDecoded=try RecorderTrace.decode(semanticData)
check(semanticDecoded.shapeBaselines![0].current.evidence.ax?.valueClass==2,"newline-only transition metadata survives collection")
check(semanticDecoded.shapeBaselines![0].previous?.evidence.ax?.placeholder==4,"previous placeholder hint survives alongside current")
check(!String(data:semanticData,encoding:.utf8)!.contains("PUBLIC_HINT"),"placeholder and user value never serialized")
check((try? RecorderTrace.decode(JSONEncoder().encode(semanticDecoded))) != nil,"semantic strict sanitized roundtrip")
ax.window=3;semantic("different")
semanticTrace.mark();semanticTrace.flush()
check(!captures.last!.shapeBaselines![0].current.evidence.comparisonKnown && captures.last!.shapeBaselines![0].current.evidence.ax?.windowRelation==2,"same field in different window cannot imply body continuity")
semantic("different",2);semanticTrace.mark();semanticTrace.flush()
check(captures.last!.shapeBaselines![0].current.evidence.ax?.fieldRelation==2 && !captures.last!.shapeBaselines![0].current.evidence.contentChanged,"different field does not imply deletion")
var semanticObject=try JSONSerialization.jsonObject(with:semanticData) as! [String:Any]
var semanticBases=semanticObject["shapeBaselines"] as! [[String:Any]],semanticPoint=semanticBases[0]["current"] as! [String:Any],semanticEvidence=semanticPoint["evidence"] as! [String:Any],semanticAX=semanticEvidence["ax"] as! [String:Any]
for (key,bad) in [("valueClass",6 as Any),("placeholder",true),("owner",0),("windowRelation",3),("text","SECRET"),("route",NSNull())] {
    var badAX=semanticAX;badAX[key]=bad;var badE=semanticEvidence;badE["ax"]=badAX;var badP=semanticPoint;badP["evidence"]=badE;var badB=semanticBases[0];badB["current"]=badP;var badD=semanticObject;badD["shapeBaselines"]=[badB];rejects(badD,"malformed/private semantic metadata rejected")
}
let attributeList:[AnyObject]=["AXTextArea" as NSString,"" as NSString,"HINT\n" as NSString,NSNumber(value:0),"HINT" as NSString,"other" as NSString,"HINT" as NSString,NSNumber(value:5),elementA]
let attributeResult=InputIncidentAXEvidence.attributes(attributeList,value:"HINT\n",verified:"HINT\n",route:2)
check(attributeResult.0.placeholder==4 && attributeResult.0.label==4 && attributeResult.0.characterCount==2 && attributeResult.0.representation==1 && attributeResult.1 != nil,"supported attribute batch produces fixed hints")
var wrong=attributeList;wrong[7]=NSNumber(value:99)
check(InputIncidentAXEvidence.attributes(wrong,value:"HINT\n",verified:"different",route:3).0.characterCount==3,"independent reported length disagreement retained")
wrong[7]=NSNumber(value:true);wrong[4]=NSNumber(value:5);wrong[8]=NSNumber(value:1)
let invalidAttributes=InputIncidentAXEvidence.attributes(wrong,value:"HINT\n",verified:"different",route:3)
check(invalidAttributes.0.placeholder==1 && invalidAttributes.0.characterCount==1 && invalidAttributes.0.representation==2 && invalidAttributes.1==nil,"unsupported/error/malformed attributes remain unknown")
check(InputIncidentAXEvidence.attributes(Array(attributeList.prefix(4)),value:"HINT\n",verified:"HINT\n",route:2).0.placeholder==1,"base-only retry records supplemental unavailable")
// Callback classification examines at most 4096 UTF16 units. A long blank
// prefix is explicitly unknown; no scheduler-sensitive wall-clock unit gate.
check(InputIncidentAXEvidence.classify(String(repeating:"x",count:1_000_000))==4,"large nonblank prefix gives a proven nonblank class")
check(InputIncidentAXEvidence.classify(String(repeating:" ",count:1_000_000))==5,"long whitespace scan is explicitly budget limited")
check(InputIncidentAXEvidence.classify(String(repeating:" ",count:4096)+"body")==5,"nonblank beyond scan budget must not be guessed")
check(InputIncidentAXEvidence.classify(String(repeating:"\n",count:4096))==2,"exact scan boundary remains fully observed")

print("PASS \(checks) shape comparison/span/baseline/privacy/overflow/nonblocking/strict compatibility checks; no AX, source or global key actions")
