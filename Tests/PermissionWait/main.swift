import AppKit
import Darwin

setbuf(stdout,nil)
var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){
    checks+=1
    if (try? value()) != true{fputs("FAIL: \(message)\n",stderr);exit(1)}
}
let fm=FileManager.default,root=URL(fileURLWithPath:fm.currentDirectoryPath)
_ = NSApplication.shared
let trace=InputIncidentTrace.shared
check(trace.enabled && trace.destinationDirectory != nil,"explicit isolated diagnostics enabled")
// The normal executable bootstrap installs this journal before the delegate.
OperationalDiagnostics.shared.installJournal(DiagnosticCriticalJournal(directory:trace.destinationDirectory!,preserve:trace.preservesDiagnostics))
let app=AppDelegate()
app.window=NSWindow(contentRect:.init(x:0,y:0,width:1,height:1),styleMask:[],backing:.buffered,defer:true)
app.permissionContent=NSView()
let barrier=app.sourceSwitchBarrier,originalTrace=barrier.trace
var reasons:[String]=[],cleanups=0,permissionReads=0,posts=0,selects=0
barrier.trace={reason in reasons.append(reason);originalTrace(reason)}
barrier.cancelSelection={_ in cleanups+=1}
barrier.send={_ in posts+=1};barrier.select={_ in selects+=1;return noErr}
func denied(){app.updatePermission(isTrusted:{permissionReads+=1;return false});trace.flush()}
func stopCount()->Int{reasons.filter{$0=="input_stopped"}.count}
func fileEvents(_ lane:String)throws->[DiagnosticCriticalJournal.Event]{
    let dir=trace.destinationDirectory!.appendingPathComponent(lane)
    let fd=open(dir.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);defer{if fd>=0{close(fd)}}
    guard fd>=0 else{return []}
    return try DiagnosticCriticalJournal.readFiles(fd).flatMap{DiagnosticCriticalJournal.decode($0.1)?.events ?? []}
}
func savedPairs()throws->[Int:Set<Int>]{
    let dir=trace.destinationDirectory!.appendingPathComponent("Shared-v1")
    var result:[Int:Set<Int>]=[:]
    for name in try fm.contentsOfDirectory(atPath:dir.path) where DiagnosticSharedStore.validName(name){
        let header=try DiagnosticSharedStore.readHeader(dir.appendingPathComponent(name)).0
        if header.role==0{result[header.incident,default:[]].insert(header.phase)}
    }
    return result
}

// Replay the 181 identical permission checks observed in the live incident.
// No real permission decision, event tap or keyboard event is changed.
for _ in 0..<181{denied()}
check(permissionReads==181 && cleanups==181,"every permission read and safety cleanup still runs")
check(stopCount()==1,"181 empty missing-permission checks create only the first failure boundary")
check(!app.enabled && app.tap==nil && app.tapSource==nil && app.pendingActivation,"input remains stopped")
check(OperationalDiagnostics.shared.flushCritical(timeout:5),"idle occurrence durable")
let initialTriggers=try fileEvents("CriticalObservations-v3").filter{$0.failure.stage == .incidentTrigger}
check(initialTriggers.count==1,"one actual journal capture request, not only a callback count")
trace.stopAndFlush()
let initialPairs=try savedPairs()
check(initialPairs.count==1 && initialPairs.values.allSatisfy{$0==[0,1]},"first stop keeps both stored phases")

func collection(_ active:Bool){
    var done=false
    trace.setCollectionEnabled(active){done=true}
    let end=Date().addingTimeInterval(5)
    while !done && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    check(done && trace.enabled==active,"collection transition completed")
}
collection(false)
let offFiles=try savedPairs().count
for _ in 0..<20{denied()}
check(try savedPairs().count==offFiles,"OFF adds no details")
collection(true)
let beforeOn=stopCount()
for _ in 0..<181{denied()}
check(stopCount()==beforeOn+1,"new collection keeps one first stop and suppresses only empty repeats")

// Permission recovery resets the episode. Restriction prevents hooks/probes;
// revocation exit behavior is deliberately not invoked by this fixture.
app.updateRestricted=true
app.updatePermission(isTrusted:{true})
app.permissionGranted=false
let beforeEpisode=stopCount()
for _ in 0..<5{denied()}
check(stopCount()==beforeEpisode+1,"a new permission-wait episode gets its own first record")

let field=AXUIElementCreateApplication(12345),en="com.apple.keylayout.ABC",ko="com.apple.inputmethod.Korean.2SetKorean"
barrier.source={en};barrier.readFocus={field}
barrier.read={.init(field:field,text:"a",selection:NSRange(location:1,length:0))}
barrier.ready={false}
let beforeWork=stopCount(),retainedBefore=app.mismatchRecovery.engine.retained.count
var expected:[UInt64]=[]
for n in 1...2{
    check(barrier.request(ko),"new boundary accepted for pending-input fixture")
    let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
    event.timestamp=UInt64(1000+n);expected.append(event.timestamp)
    check(barrier.receive(.keyDown,event),"new input remains queued")
    denied()
    check(!barrier.busy && barrier.diagnosticCounts.queued==0,"new boundary safely cleared")
}
check(stopCount()==beforeWork+2,"two real failures back-to-back are not suppressed")
let retained=Array(app.mismatchRecovery.engine.retained.dropFirst(retainedBefore))
check(retained.map{$0.timestamp}==expected,"retained event identity/order survives both failures")
check(posts==0 && selects==0,"no replay or source selection occurs during failure")
let afterWork=stopCount()
for _ in 0..<20{denied()}
check(stopCount()==afterWork && app.mismatchRecovery.engine.retained.count==retainedBefore+2,"previously retained input stays intact without inventing new failures")

barrier.ready={true}
let token=barrier.beginManualEdit(field:field,source:en)
check(token != nil,"manual edit active without a source request")
let beforeManual=stopCount();denied()
check(stopCount()==beforeManual+1,"a live manual edit is not classified as empty")
barrier.finishManualEdit(token!,snapshot:.init(field:field,text:"b",selection:NSRange(location:1,length:0)))
check(barrier.expected==nil,"late completion cannot revive cleared history")
let selectAll=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
selectAll.flags = .maskCommand
barrier.observe(.keyDown,selectAll)
check(!barrier.canPrepareFreshMismatchObservation,"native selection acknowledgment is pending without queued keys")
let beforeSelection=stopCount();denied()
check(stopCount()==beforeSelection+1,"selection-only wait keeps its failure detail")
let onsetKey=CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:true)!
barrier.observeBeforeOnset(.keyDown,onsetKey,waiting:true)
check(barrier.diagnosticCounts.awaitingOnset==1,"delivery receipt is pending without a source request")
let beforeReceipt=stopCount();denied()
check(stopCount()==beforeReceipt+1 && barrier.diagnosticCounts.awaitingOnset==0,"receipt-only wait records the failure and clears stale observation")
let beforeOther=reasons.filter{$0=="allocation"}.count
for _ in 0..<2{barrier.fail("allocation",recordIdleInputStop:false)}
check(reasons.filter{$0=="allocation"}.count==beforeOther+2,"other repeated failure causes always remain")
let beforeExplicit=stopCount()
app.stopMapping();app.stopMapping()
check(stopCount()==beforeExplicit+2,"explicit teardown outside permission rechecks retains default diagnostics")

for _ in 0..<6{OperationalDiagnostics.shared.record(.posix(.storagePrepare,EACCES))}
trace.stopAndFlush()
check(OperationalDiagnostics.shared.flushCritical(timeout:5),"important errors durable")
let errors=try fileEvents("CriticalErrors-v3").filter{$0.failure.stage == .storagePrepare && $0.failure.code==EACCES}
check(errors.count==6 && Set(errors.map{$0.sequence}).count==6,"six same-code important errors each preserved")
let pairs=try savedPairs()
check(pairs.values.allSatisfy{$0==[0,1]},"all admitted incidents have both phases")
check(app.mismatchRecovery.engine.retained.count==retainedBefore+2,"later cleanup never discards retained inputs")
let result:[String:Any]=["checks":checks,"permissionChecks":permissionReads,"safetyCleanups":cleanups,
    "idleRechecks":181,"idleCaptureRequests":initialTriggers.count,"idleSavedPairs":initialPairs.count,
    "importantErrors":errors.count,"retainedTestInputs":retained.count,"postedKeys":posts,"sourceSelections":selects,
    "allSavedPairs":pairs.count,"allSavedPairsComplete":true,"scope":"compiled AppDelegate and storage with injected permission result; no live app replacement or physical keys"]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
app.window.close()
print("PASS permission wait \(checks) checks: 181 rechecks -> 1 stored pair; new failures, 6 important errors and retained inputs preserved")
