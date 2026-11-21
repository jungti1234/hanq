import AppKit
import ApplicationServices
import Foundation
import Darwin

setbuf(stdout,nil)
let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),fm=FileManager.default
var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ label:String){checks+=1;if (try? value()) != true{fputs("FAIL applications: \(label)\n",stderr);exit(1)};print("PASS \(label)")}
func directory(_ name:String)->URL{let u=root.appendingPathComponent(name);try! fm.createDirectory(at:u,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return u}
func bytes<T:Encodable>(_ value:T)throws->Data{let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(value)}
let native=DiagnosticApplicationRegistry.runningApplication(getpid())
check(native?.bundleID=="test.hanq.diagnostic-apps" && native?.version=="1.2.3" && native?.build=="437","real owned test app resolves bundle ID, version and build")
check(native?.name != nil && native?.isCurrent()==true,"real owned process name and lifetime are available")
var focusProbe=InputIncidentFocusProbe.Read(target:101)
focusProbe.observe(nil,owner:102,route:2)
check(focusProbe.applications.target==101 && focusProbe.applications.owner==nil,"failed fallback never claims frontmost PID as actual element owner")
focusProbe.observe(AXUIElementCreateApplication(102),owner:102,route:1);focusProbe.observedRole("AXTextField")
focusProbe.observe(AXUIElementCreateApplication(103),owner:103,route:1)
check(focusProbe.applications.owner==102,"app identity follows the snapshot subject despite later focus movement")

var resolves=0,alive=true
let registry=DiagnosticApplicationRegistry(capacity:2){pid in
 resolves+=1
 return .init(name:pid==101 ? "첫 편집기":"다른 편집기",bundleID:"test.editor.\(pid)",version:"1.0",build:"7",launchMilliseconds:Int64(pid)*1000,isCurrent:{pid != 101 || alive})
}
let ref=registry.references(.init(target:101,owner:101))!
check(ref.target==ref.owner && resolves==1,"same target and owner share one identity")
for _ in 0..<10000{_ = registry.references(.init(target:101,owner:101))}
check(resolves==1 && registry.countForTest==1,"ten thousand observations reuse cached identity")
let other=registry.references(.init(target:102,owner:nil))!
check(other.owner==0 && other.target != ref.target,"missing owner is not replaced by target")
alive=false
let reused=registry.references(.init(target:101,owner:nil))!
check(reused.target != ref.target && resolves==3,"terminated PID gets a new process reference")
check(registry.snapshot([ref.target])?.unavailableReferences == [ref.target],"evicted identity remains explicitly unavailable rather than misattributed")
check(registry.countForTest==2,"identity cache stays bounded")
let long=DiagnosticApplicationRegistry{_ in .init(name:String(repeating:"한",count:800)+"\nPRIVATE",bundleID:"test.editor\n",version:String(repeating:"v",count:200))}
let longRef=long.references(.init(target:777))!,longRecord=long.snapshot([longRef.target])!.records[0]
check(longRecord.valid && longRecord.shortened && longRecord.name?.count==256 && longRecord.version?.count==64,"metadata bounds and control-character removal are explicit")
let unknown=DiagnosticApplicationRegistry{_ in nil},unknownRef=unknown.references(.init(target:888))!
let unknownRecord=unknown.snapshot([unknownRef.target])!.records[0]
check(unknownRecord.pid==888 && unknownRecord.name==nil && unknownRecord.bundleID==nil,"unresolved app preserves only known PID without guessing")

var now=100.0,secure=false,lookups=0,captured:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(secureInput:{secure},destination:nil,capacity:8192,clock:{now},applicationResolver:{pid in
 lookups+=1;return .init(name:pid==101 ? "Target Editor":"Observed Owner",bundleID:"test.app.\(pid)",version:"2.0",build:"17")
},writer:{captured.append($0)})
for _ in 0..<1000 {
 let span=trace.beginRead(.onsetAX);now+=0.001
 trace.endRead(.onsetAX,span,outcome:.success,applications:.init(target:101,owner:102))
 trace.shape(.onsetAX,identity:1,count:10,selected:false,editing:false,applications:.init(target:101,owner:101))
 trace.flush();now+=0.01
}
trace.mark();trace.flush()
check(lookups==2,"production collector resolves each observed process once")
let before=captured.first{$0.phase==0}!,captureData=try bytes(before)
check((try? RecorderTrace.decode(captureData)) != nil,"strict independent collector accepts app-aware production capture")
try captureData.write(to:root.appendingPathComponent("capture.json"))
check(before.applicationInfo?.records.count==2,"one bounded metadata table serves all ordinary observations")
let captureText=String(decoding:captureData,as:UTF8.self)
check(captureText.components(separatedBy:"Target Editor").count==2 && captureText.components(separatedBy:"Observed Owner").count==2,"app names are not repeated in every ordinary frame")
let frames=try before.frames.unpacked(),read=frames.first{$0.kind == .read && $0.category==2}!
check(read.applications?.target != read.applications?.owner,"actual target and observed owner remain distinct on the read")
check(frames.contains{$0.shapeEvidence?.applications?.target == $0.shapeEvidence?.applications?.owner && $0.shapeEvidence?.applications != nil},"shape observations retain their proven owner")
let missing=trace.beginRead(.onsetAX);now+=0.001;trace.endRead(.onsetAX,missing,outcome:.focusedElementUnreadable,applications:.init(target:101));trace.flush()
secure=true
let countBeforeSecure=lookups
let secured=trace.beginRead(.onsetAX);trace.endRead(.onsetAX,secured,outcome:.secureInput,applications:.init(target:999));trace.shape(.onsetAX,identity:3,count:2,selected:false,editing:false,applications:.init(target:999));trace.flush()
check(lookups==countBeforeSecure,"secure input never resolves app metadata")
secure=false
let field=trace.beginRead(.onsetAX);trace.endRead(.onsetAX,field,outcome:.secureField,applications:.init(target:998));trace.flush()
check(lookups==countBeforeSecure,"secure field outcome blocks metadata even with a supplied PID")
trace.setCollectionEnabled(false);trace.flush()
let countBeforeOFF=lookups
trace.shape(.onsetAX,identity:4,count:1,selected:false,editing:false,applications:.init(target:997));trace.flush()
check(lookups==countBeforeOFF && trace.beginRead(.onsetAX)==nil,"OFF performs no app metadata lookup")
trace.setCollectionEnabled(true);trace.flush();trace.shape(.onsetAX,identity:1,count:10,selected:false,editing:false,applications:.init(target:101,owner:101));trace.flush()
check(lookups==countBeforeOFF+1,"OFF releases prior cached identity before a new collection")
trace.stopAndFlush()

// Metadata resolution must not hold the caller; a later secure-input change
// must also invalidate identities already queued behind a slow resolution.
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),returned=DispatchSemaphore(value:0)
var workerSecure=false,workerLookups=0
let asynchronous=InputIncidentTrace(secureInput:{workerSecure},destination:nil,applicationResolver:{_ in
 workerLookups+=1;entered.signal();_ = release.wait(timeout:.now()+5);return .init(name:"Owned fixture")
},writer:{_ in})
DispatchQueue.global().async {
 asynchronous.shape(.onsetAX,identity:1,count:1,selected:false,editing:false,applications:.init(target:1001))
 returned.signal()
}
let didEnter=entered.wait(timeout:.now()+2) == .success
let didReturn=returned.wait(timeout:.now()+1) == .success
asynchronous.shape(.onsetAX,identity:2,count:1,selected:false,editing:false,applications:.init(target:1002))
workerSecure=true;release.signal();asynchronous.flush()
check(didEnter && didReturn,"blocked metadata resolution never blocks the input-side caller")
check(workerLookups==1,"secure input starting after enqueue blocks later metadata resolution")
asynchronous.stopAndFlush()

// Slow facts retain their own app context when no detailed capture is chosen.
let journalDir=directory("journal"),journal=DiagnosticCriticalJournal(directory:journalDir)
OperationalDiagnostics.shared.installJournal(journal)
let slow=InputIncidentTrace(secureInput:{false},destination:journalDir,clock:{now},applicationResolver:{pid in .init(name:"Slow Editor",bundleID:"test.slow",version:"3.0")})
for _ in 0..<3{let span=slow.beginRead(.mismatchAX,purpose:.background);slow.flush();now+=0.06;slow.endRead(.mismatchAX,span,outcome:.success,applications:.init(target:501,owner:501));slow.flush()}
slow.stopAndFlush();check(journal.flush(timeout:5),"compact journal flushes")
let fd=open(journalDir.path,O_RDONLY|O_DIRECTORY);defer{close(fd)}
let events=try DiagnosticCriticalJournal.readFiles(fd).flatMap{DiagnosticCriticalJournal.decode($0.1)?.events ?? []}
let facts=events.filter{$0.failure.stage == .slowRead && $0.failure.code==2}
check(facts.count==3 && facts.allSatisfy{$0.context?.applicationInfo?.records.first?.bundleID=="test.slow"},"every compact occurrence retains independently usable app identity")

// Shared metadata for a previously selected app must be disclosed if the new
// selection still needs that original file as a dependency.
let store=DiagnosticSharedStore(directory:directory("shared"),preserve:true),run=UUID().uuidString
func input(_ n:Int,_ name:String)throws->DiagnosticSharedStore.Input {
 let info=DiagnosticApplicationSnapshot(records:[.init(id:n,pid:Int32(600+n),name:name,bundleID:"test.\(n)",version:"1.0")],unavailableReferences:[])
 var frame=InputIncidentTrace.Frame(sequence:n,milliseconds:n*10,lane:.onsetAX,kind:.read,event:n,edge:0,category:2,inputOrigin:0,consumed:false,durationMicros:1000,count:0,selected:false,field:0,decisionTiming:nil,observationTiming:nil)
 frame.applications = .init(target:n,owner:n)
 let meta:[String:Any]=["schema":1,"runID":run,"incident":n,"phase":0,"trigger":1,"applicationInfo":try JSONSerialization.jsonObject(with:bytes(info))]
 let json=try JSONDecoder().decode(DiagnosticJSON.self,from:JSONSerialization.data(withJSONObject:meta))
 return .init(metadata:json,frames:[try DiagnosticPackedFrame(frame)],run:run,incident:n,phase:0,trigger:1,milliseconds:1000+Int64(n))
}
check(try store.submit(input(1,"Shared Older App")),"first app metadata stored")
check(try store.submit(input(2,"Selected App")),"second app metadata stored with shared dependencies")
let copy=directory("snapshot"),pending=try store.copyReviewSnapshot(into:copy,request:DiagnosticSnapshotRequest())
try DiagnosticSharedStore.writeExport(bytes(pending),to:copy.appendingPathComponent("pending-export.json"))
try DiagnosticSharedStore.writeExport(Data("{}".utf8),to:copy.appendingPathComponent("review-dates.json"))
try DiagnosticSharedStore.writeExport(Data("{\"schema\":1,\"status\":{}}".utf8),to:copy.appendingPathComponent("storage-status.json"))
let snapshot=try DiagnosticReviewSnapshot(directory:copy)
let environment=DiagnosticReviewEnvironment(appVersion:"0.3.2",build:"437",macOSVersion:"test",modelIdentifier:nil,keyboardLayout:.unknownOrOther,koreanKeyEnabled:false,hanjaKeyEnabled:false,hudEnabled:false,capsLockSwitchEnabled:nil,loginItemState:.unknown,diagnosticsEnabled:true,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
let selected=snapshot.incidents.first{$0.number==2}!,files=try snapshot.files(selected:[selected.id],environment:environment)
let inventory=files.first{$0.path=="applications.json"}!
check(inventory.readableText.contains("Selected App") && inventory.readableText.contains("Shared Older App"),"preview discloses apps from selected capture AND included shared dependencies")
let phasePreview=try selected.documents[0]!.readableText
check(phasePreview.contains("Selected App") && !phasePreview.contains("Shared Older App") && phasePreview.contains("관측한 요소의 소유 앱"),"phase preview distinguishes its own target and owner from extra shared app metadata")
let archive=try DiagnosticReviewArchive(files:files),zipURL=root.appendingPathComponent("applications.zip");try archive.save(to:zipURL)
let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");unzip.arguments=["-x","-k",zipURL.path,root.appendingPathComponent("restored").path];try unzip.run();unzip.waitUntilExit();check(unzip.terminationStatus==0,"identity ZIP restores")
let restored=root.appendingPathComponent("restored/HanQ-Diagnostics")
for file in files{check(try Data(contentsOf:restored.appendingPathComponent(file.path))==file.data,"ZIP exact bytes \(file.path)")}
let expanded=try DiagnosticSharedStore.expand(selected.originals[0]!.filename,in:restored)
check(expanded.frames[0].applications != nil,"restored original preserves app-to-observation references")
let forbidden=["windowTitle","documentPath","clipboard","inputText","applicationURL","bundleURL","executableURL"]
for word in forbidden{check(!String(decoding:try bytes(expanded.metadata),as:UTF8.self).contains(word),"no excluded metadata key \(word)")}

let controller=DiagnosticReviewController(environment:environment);controller.install(snapshot)
func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
let views=descendants(controller.window!.contentView!),table=views.compactMap{$0 as? NSTableView}.first{$0.numberOfColumns==1}!
let deadline=Date().addingTimeInterval(10)
while table.numberOfRows==0 && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
let appRow=(0..<table.numberOfRows).first{row in descendants(table.view(atColumn:0,row:row,makeIfNecessary:true)!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="포함되는 앱 정보"}}
check(appRow != nil,"actual AppKit file list exposes included app identities")
table.selectRowIndexes(IndexSet(integer:appRow!),byExtendingSelection:false)
let textView=views.compactMap{$0 as? NSTextView}.first!
check(textView.string.contains("Shared Older App") && textView.string.contains("Selected App"),"actual AppKit preview shows both disclosed identities")
controller.window!.appearance=NSAppearance(named:.darkAqua)
controller.window!.contentView!.layoutSubtreeIfNeeded()
let content=controller.window!.contentView!,bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds)!
content.cacheDisplay(in:content.bounds,to:bitmap)
try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("applications-preview.png"))
controller.close()
struct OldPacketLayout{let sequence:Int,milliseconds:Int,data:Data}
let metrics:[String:Any]=["checks":checks,"normalObservations":1000,"metadataResolves":2,"appTableBytes":try bytes(before.applicationInfo).count,"oldPacketStride":MemoryLayout<OldPacketLayout?>.stride,"packetStride":MemoryLayout<DiagnosticPackedFrame?>.stride,"fullHistoryIndexDeltaBytes":(MemoryLayout<DiagnosticPackedFrame?>.stride-MemoryLayout<OldPacketLayout?>.stride)*65536,"sourceCaptureBytes":captureData.count,"ZIPBytes":archive.bytes]
try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("metrics.json"))
print("PASS application identity \(checks) checks")
