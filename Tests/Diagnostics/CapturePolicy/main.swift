import Foundation
import ApplicationServices
import Darwin

setbuf(stdout,nil)
var checks=0
func check(_ value:@autoclosure () throws->Bool,_ label:String){checks+=1;if (try? value()) != true{fputs("FAIL \(label)\n",stderr);exit(1)}}
let fm=FileManager.default,root=URL(fileURLWithPath:fm.currentDirectoryPath)
func directory(_ name:String)->URL{let p=root.appendingPathComponent(name);try! fm.createDirectory(at:p,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return p}
func events(_ url:URL)throws->[DiagnosticCriticalJournal.Event]{let fd=open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);defer{close(fd)};return try DiagnosticCriticalJournal.readFiles(fd).flatMap{DiagnosticCriticalJournal.decode($0.1)?.events ?? []}}
func captures(_ dir:URL)throws->[[String:Any]]{
    let url=dir.appendingPathComponent("Shared-v1")
    return try fm.contentsOfDirectory(atPath:url.path).filter{DiagnosticSharedStore.validName($0)}.compactMap{name in
        let h=try DiagnosticSharedStore.readHeader(url.appendingPathComponent(name)).0
        guard h.role==0 else{return nil}
        let expanded=try DiagnosticSharedStore.expand(name,in:url)
        return try JSONSerialization.jsonObject(with:JSONEncoder().encode(expanded.metadata)) as? [String:Any]
    }
}
// No legacy observation is silently reclassified without purpose/activity proof.
for n in 1...17 {
    let outcome=InputIncidentTrace.ReadOutcome(rawValue:n)!
    check(!InputIncidentTrace.compactRead(.unknown,outcome,activityUnchanged:true),"legacy unknown retains detail \(n)")
    check(!InputIncidentTrace.compactRead(.active,outcome,activityUnchanged:true),"active retains detail \(n)")
    check(!InputIncidentTrace.compactRead(.background,outcome,activityUnchanged:false),"concurrent activity retains detail \(n)")
    check(InputIncidentTrace.compactRead(.background,outcome,activityUnchanged:true)==[1,4,8,13].contains(n),"conservative background policy \(n)")
}
check(!InputIncidentTrace.compactRead(.background,nil,activityUnchanged:true),"unknown result retains detail")
let shared=InputIncidentShapeCorrelation()
var a=InputIncidentShapeProbe(),b=InputIncidentShapeProbe()
func observe(_ probe:inout InputIncidentShapeProbe,_ text:String,field:UInt=1,epoch:Int64=0)->InputIncidentTrace.ShapeChange{
    probe.observe(identity:field,text:text,selection:NSRange(location:0,length:0),generation:1,correlation:shared,activity:epoch)
}
_ = observe(&a,"abcdefgh");_ = observe(&b,"abcdefgh")
let first=observe(&a,"x"),second=observe(&b,"x")
check(first.transitionID != nil && first.transitionID==second.transitionID,"two lanes share one literal content transition")
let different=observe(&a,"y")
check(different.transitionID != first.transitionID,"same length different text never shares transition")
_ = observe(&a,"abcdefgh");let repeatChange=observe(&a,"x")
check(repeatChange.transitionID != first.transitionID,"repeated old-to-new transition has a new revision")
check(observe(&b,"z",field:2).transitionID==nil,"different field cannot merge")
check(observe(&a,"new",epoch:1).transitionID==nil,"input or context boundary invalidates identity")
check(observe(&a,String(repeating:"x",count:8193)).transitionID==nil,"large text falls back to independent detail")
check(observe(&a,"x").transitionID==nil,"return from oversized value cannot reuse stale revision")
let gen=a.observe(identity:1,text:"y",selection:NSRange(location:0,length:0),generation:2,correlation:shared)
check(gen.transitionID==nil,"new diagnostic generation cannot merge")
var unicode=InputIncidentShapeProbe()
_ = unicode.observe(identity:5,text:"각",selection:NSRange(location:0,length:0),generation:1,correlation:shared)
let decomposed=unicode.observe(identity:5,text:"\u{1100}\u{1161}\u{11A8}",selection:NSRange(location:0,length:0),generation:1,correlation:shared)
check(decomposed.content && decomposed.transitionID != nil,"canonical Unicode equivalence is not literal equality")
check(shared.retainedUTF16ForTest<=8192,"comparison keeps only bounded text")

// Reproduce the live two-path case: the onset reader does not read AXWindow,
// while the mismatch reader already has it. Unknown must not erase known.
for windows in [[0,6],[6,0],[0,0],[6,6]] {
    let correlation=InputIncidentShapeCorrelation()
    var left=InputIncidentShapeProbe(),right=InputIncidentShapeProbe()
    func sample(_ probe:inout InputIncidentShapeProbe,_ value:String,_ window:Int,field:UInt=5,identityEpoch:Int=1,activity:Int64=0)->InputIncidentTrace.ShapeChange {
        var ax=InputIncidentAXEvidence();ax.window=window;ax.identityEpoch=identityEpoch
        return probe.observe(identity:field,text:value,selection:NSRange(location:0,length:0),generation:1,ax:ax,correlation:correlation,activity:activity)
    }
    for _ in 0..<4{_ = sample(&left,"abcdefghijklmnop",windows[0]);_ = sample(&right,"abcdefghijklmnop",windows[1])}
    let l=sample(&left,"\n",windows[0]),r=sample(&right,"\n",windows[1])
    check(l.transitionID != nil && l.transitionID==r.transitionID,"same literal transition across measured/unmeasured windows \(windows)")
    let later=sample(&left,"other",windows[0])
    check(later.transitionID != l.transitionID,"later different transition stays independent \(windows)")
    check(sample(&right,"changed",7).transitionID==nil,"different known window cannot attach to old transition \(windows)")
}
let windowGuard=InputIncidentShapeCorrelation()
_ = windowGuard.observe("before",field:1,generation:1,window:6,identityEpoch:1,activity:0)
_ = windowGuard.observe("before",field:1,generation:1,window:0,identityEpoch:1,activity:0)
check(windowGuard.observe("after",field:1,generation:1,window:7,identityEpoch:1,activity:0)?.previous==nil,"unknown window does not bridge two different known windows")
_ = windowGuard.observe("before",field:1,generation:1,window:0,identityEpoch:1,activity:0)
check(windowGuard.observe("after",field:1,generation:1,window:0,identityEpoch:2,activity:0)?.previous==nil,"identity registry reset breaks unknown-window continuity")
_ = windowGuard.observe("before",field:1,generation:1,window:0,identityEpoch:2,activity:0)
check(windowGuard.observe("after",field:1,generation:1,window:0,identityEpoch:2,activity:1)?.previous==nil,"input activity breaks unknown-window continuity")

let dir=directory("policy"),journal=DiagnosticCriticalJournal(directory:dir)
OperationalDiagnostics.shared.installJournal(journal)
var now=100.0
let trace=InputIncidentTrace(secureInput:{false},destination:dir,clock:{now})
var expectedFull=0,expectedCompact=0,readCount=0
func read(_ outcome:InputIncidentTrace.ReadOutcome,purpose:InputIncidentTrace.ReadPurpose,activity:Bool=false,ax:InputIncidentAXResult?=nil,expected:Bool){
    let span=trace.beginRead(.onsetAX,purpose:purpose);trace.flush();now+=0.06
    if activity{trace.context()}
    trace.endRead(.onsetAX,span,outcome:outcome,axResult:ax);trace.flush();readCount+=1
    if expected{expectedCompact+=1}else{expectedFull+=1}
}
for n in [1,4,8,13]{read(.init(rawValue:n)!,purpose:.background,expected:true)}
for n in [2,3,5,6,7,9,10,11,12,14,15,16,17]{read(.init(rawValue:n)!,purpose:.background,expected:false)}
read(.success,purpose:.unknown,expected:false)
read(.success,purpose:.active,expected:false)
read(.success,purpose:.background,activity:true,expected:false)
var raw=InputIncidentAXResult();raw.focus(1,.cannotComplete);raw.focus(2,.success)
read(.success,purpose:.background,ax:raw,expected:false)
for _ in 0..<3{read(.focusedElementUnreadable,purpose:.background,expected:false)}
let late=trace.beginRead(.mismatchAX,purpose:.background,activityAtRequest:trace.activityEpoch-1);trace.flush();now+=0.06
trace.endRead(.mismatchAX,late,outcome:.success);trace.flush();readCount+=1;expectedFull+=1
// The same proved transition keeps both occurrences and earliest pre/latest post.
now+=1
var onsetProbe=InputIncidentShapeProbe(),mismatchProbe=InputIncidentShapeProbe()
func recordShape(_ probe:inout InputIncidentShapeProbe,_ lane:InputIncidentTrace.Lane,_ text:String,_ window:Int){
    var ax=InputIncidentAXEvidence();ax.window=window;ax.identityEpoch=1
    let change=probe.observe(identity:99,text:text,selection:NSRange(location:0,length:0),generation:trace.collectionGeneration,ax:ax,correlation:trace.shapeCorrelation,activity:trace.activityEpoch)
    trace.shape(lane,identity:99,count:text.utf16.count,selected:false,editing:false,change:change);trace.flush()
}
recordShape(&onsetProbe,.onsetAX,"abcdefgh",0)
recordShape(&mismatchProbe,.mismatchAX,"abcdefgh",6)
recordShape(&onsetProbe,.onsetAX,"x",0)
now+=0.2
recordShape(&mismatchProbe,.mismatchAX,"x",6)
trace.sourceBoundary(.initialTransportCompleted,queued:0,awaitingOnset:0);trace.flush()
trace.sourceBoundary(.editorDivergedInputResumed,queued:0,awaitingOnset:0);trace.flush()
trace.sourceBoundary(.nativeSelectAllDivergedInputResumed,queued:0,awaitingOnset:0);trace.flush()
trace.stopAndFlush();check(journal.flush(timeout:5),"occurrence journal durable")
let records=try events(dir),ends=records.filter{$0.failure.stage == .slowRead && $0.failure.code==2}
check(ends.count==readCount,"every slow read result remains individually recorded")
check(ends.filter{$0.context?.detailPolicy==2}.count==expectedCompact,"only proved background outcomes compact")
check(Set(ends.compactMap{$0.context?.readToken}).count==readCount,"independent read IDs even within ten seconds")
check(ends.contains{$0.context?.axResult?.system==AXError.cannotComplete.rawValue && $0.context?.axResult?.application==0 && $0.context?.detailPolicy==1},"raw focus errors survive successful fallback")
let stored=try captures(dir)
check(stored.filter{($0["trigger"] as? Int)==3 && ($0["phase"] as? Int)==0}.count==expectedFull,"all independent errors retain detail")
let shapes=stored.filter{($0["trigger"] as? Int)==4}
check(shapes.count==2,"one pre/post pair for shared transition")
let post=shapes.first{($0["phase"] as? Int)==1}!
let preservation=post["capturePreservation"] as! [String:Any],requests=preservation["requests"] as! [[String:Any]]
check(requests.count==2 && Set(requests.compactMap{$0["requestID"] as? String}).count==2,"merged detail retains both request identities")
let coverage=post["coverage"] as! [String:Any]
check((coverage["requestedFromMilliseconds"] as? Int)==(requests.first!["milliseconds"] as? Int),"post begins at first occurrence")
check((coverage["requestedThroughMilliseconds"] as? Int)==(requests.last!["milliseconds"] as! Int)+3000,"post extends through last occurrence plus three seconds")
check(records.filter{$0.failure.stage == .captureDisposition && $0.failure.code==8}.count==1,"shared detail has explicit linked disposition")
check(records.filter{$0.failure.stage == .boundaryCompletion}.count==1,"ordinary transport completion retained compactly")
check(stored.filter{($0["trigger"] as? Int)==5 && ($0["phase"] as? Int)==0}.count==2,"different divergence causes retain separate details")
check(InputIncidentTrace.BoundaryStage.event("initial_transport_completed") == .initialTransportCompleted,"completion distinct from interruption")
let watchDir=directory("watchdog"),watchJournal=DiagnosticCriticalJournal(directory:watchDir)
OperationalDiagnostics.shared.installJournal(watchJournal)
var watchClock=100.0
let watch=InputIncidentTrace(secureInput:{false},destination:watchDir,clock:{watchClock})
let unfinished=watch.beginRead(.onsetAX,purpose:.background);watch.flush();watch.start();watchClock+=0.15
Thread.sleep(forTimeInterval:0.35);watch.flush()
check(watchJournal.flush(timeout:5),"unfinished occurrence saved")
check((try events(watchDir)).filter{$0.failure.stage == .incidentTrigger}.count==1,"watchdog does not create a new capture every tick")
watchClock+=0.05;watch.endRead(.onsetAX,unfinished,outcome:.success);watch.flush();watch.stopAndFlush()
check(watchJournal.flush(timeout:5),"completed watchdog occurrence saved")
let watched=try captures(watchDir)
check(watched.count==2,"watchdog and completion share pre/post pair")
check((try events(watchDir)).filter{$0.context?.detailPolicy==2}.isEmpty,"unfinished read detail never downgraded after completion")
_ = watch.shapeCorrelation.observe("PRIVATE_RAM_ONLY",field:1,generation:1,window:0,identityEpoch:0,activity:0)
check(watch.shapeCorrelation.retainedUTF16ForTest>0,"comparison fixture owns a RAM value")
watch.setCollectionEnabled(false)
check(watch.shapeCorrelation.retainedUTF16ForTest==0,"OFF immediately releases comparison text before writer drain")
watch.flush()
print("PASS capture policy \(checks) checks; reads=\(readCount) compact=\(expectedCompact) detailed=\(expectedFull)")
