import Foundation
import Darwin
import CryptoKit

setbuf(stdout,nil)
var checks=0
func check(_ value:@autoclosure () throws->Bool,_ title:String){checks+=1;print("CHECK \(checks) \(title)");if (try? value()) != true{fputs("FAIL shared: \(title)\n",stderr);exit(1)}}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),fm=FileManager.default
func directory(_ name:String)->URL{let p=root.appendingPathComponent(name);try! fm.createDirectory(at:p,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return p}
func names(_ directory:URL)->[String]{((try? fm.contentsOfDirectory(atPath:directory.path)) ?? []).filter{DiagnosticSharedStore.validName($0) && (try? DiagnosticSharedStore.readHeader(directory.appendingPathComponent($0)).0.role) != 1}.sorted()}
func records(_ directory:URL)throws->[DiagnosticCriticalJournal.Event]{let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);defer{close(fd)};return try DiagnosticCriticalJournal.readFiles(fd).flatMap{DiagnosticCriticalJournal.decode($0.1)?.events ?? []}}
func frame(_ sequence:Int,_ ms:Int)->InputIncidentTrace.Frame{InputIncidentTrace.Frame(sequence:sequence,milliseconds:ms,lane:.main,kind:.context,event:0,edge:0,category:0,inputOrigin:0,consumed:false,durationMicros:0,count:0,selected:false,field:0,decisionTiming:nil,observationTiming:nil)}
var wall=100000.0,retryTime=100.0
let run=UUID().uuidString
func input(_ frames:[DiagnosticPackedFrame],_ incident:Int=1,_ phase:Int=0,_ time:Int64?=nil,_ meta:DiagnosticJSON = .object(["schema":.integer(1)]))->DiagnosticSharedStore.Input{
    .init(metadata:meta,frames:frames,run:run,incident:incident,phase:phase,trigger:3,milliseconds:time ?? Int64(wall*1000))
}
let packets=(1...100).map{try! DiagnosticPackedFrame(frame($0,$0*100))}
for p in packets{check(try p.unpack().sequence==p.sequence,"packed roundtrip")}
struct Limits:Codable,Equatable{let low:Int64,high:UInt64,a:[Int],b:Bool,s:String,d:Double}
let limit=Limits(low:.min,high:.max,a:[-1,0,1],b:true,s:"schema only",d:0.125)
check(try DiagnosticPackedCodec.shared.decode(Limits.self,from:DiagnosticPackedCodec.shared.encode(limit))==limit,"full integer ranges and nested types")
let emptyHistory=DiagnosticFrameHistory(capacity:0)
check(emptyHistory[65535]==nil && emptyHistory.packet(at:65535)==nil,"disabled empty history is safe at shutdown")
let disabled=InputIncidentTrace(secureInput:{false},destination:root.appendingPathComponent("disabled"),initiallyEnabled:false)
disabled.stopAndFlush()
check(!fm.fileExists(atPath:root.appendingPathComponent("disabled").path),"disabled shutdown creates no store")
let history=DiagnosticFrameHistory(capacity:128)
for i in 0..<1000{history[i%128]=frame(i,i*1000);history.trim(now:i*1000)}
check(history.selection(from:0,through:1_000_000).count==61,"60 second history bounds")
check(history.selection(from:990_000,through:999_000).map(\.sequence)==Array(990..<1000),"history retains exact recent order after wraps")
check(history.accountedBytes<8*1024*1024,"accounted buffer bounded")

let shared=DiagnosticSharedStore(directory:directory("shared"),clock:{wall},retryClock:{retryTime})
check(shared.submit(input(packets)),"first shared save")
check(shared.submit(input(packets,2)),"second shared save")
check(shared.stats.suppliedFrames==200 && shared.stats.storedFrames==100 && shared.stats.reusedFrames==100,"identical observations written once")
for name in names(shared.directory){let x=try! DiagnosticSharedStore.expand(name,in:shared.directory);check(x.frames.map(\.sequence)==Array(1...100),"reconstruct shared frame order");check(x.metadata == .object(["schema":.integer(1)]),"metadata exact reconstruction")}
let oldFiles=names(shared.directory)
wall+=72*3600-1
check(shared.drain() && names(shared.directory)==oldFiles,"72h minus one second retains")
wall+=62
check(shared.drain() && names(shared.directory).isEmpty,"expired unreferenced details retired")
wall+=1
check(shared.submit(input(packets,3,0,Int64(wall*1000))),"new save after GC uses checkpoint")

// Retry partial writes without duplicate suffixes or losing the initialization marker.
for initial in [true,false]{
    var broken=initial,calls=0,partial=true
    let store=DiagnosticSharedStore(directory:directory(initial ? "owner-retry":"payload-retry"),clock:{wall},retryClock:{retryTime},writer:{fd,p,n in
        calls+=1
        if broken {if partial{partial=false;return Darwin.write(fd,p,min(n,7))};errno=ENOSPC;return -1}
        return Darwin.write(fd,p,n)
    })
    if !initial{check(store.prepare(),"payload fixture initialized");broken=true}
    check(!store.submit(input(packets)),"partial ENOSPC is visible")
    let before=calls;for _ in 0..<100{_ = store.drain()}
    check(calls==before,"retry pacing prevents storm")
    broken=false;retryTime+=61
    check(store.drain() && store.stats.saved==1,"same-process recovery saves waiting capture")
    check(store.stats.lastFailure==nil,"current failure clears after recovery")
    let loaded=try! DiagnosticSharedStore.expand(names(store.directory)[0],in:store.directory)
    check(loaded.frames.count==100,"partial recovery decoded exactly")
}
// A hot 65s dedup lookup must also be byte bounded; losing an optimization
// entry must never lose the frame's on-disk evidence.
let hotStore=DiagnosticSharedStore(directory:directory("hot-cache"),clock:{wall})
let hot=(1...45000).map{try! DiagnosticPackedFrame(frame($0,$0))}
check(hotStore.submit(input(hot)),"dense shared cache fixture stored")
check(hotStore.stats.cachedFrameBytes<=DiagnosticSharedStore.maximumFrameCacheBytes,"dedup lookup has independent byte bound")
check(hotStore.submit(input(hot,2)),"evicted lookup entries can be stored again")
check(hotStore.stats.reusedFrames>0 && hotStore.stats.storedFrames>hot.count,"cache eviction affects sharing only")
let hotName=names(hotStore.directory).first{(try? DiagnosticSharedStore.readHeader(hotStore.directory.appendingPathComponent($0)).0.incident)==2}!
check(try DiagnosticSharedStore.expand(hotName,in:hotStore.directory).frames.count==45000,"all dense frames reconstruct after cache eviction")
// Metadata differences include removed members, null, booleans and arrays.
let metaStore=DiagnosticSharedStore(directory:directory("meta"),clock:{wall})
var last:DiagnosticJSON = .object(["gone":.integer(4),"bool":.bool(true),"a":.array([.null,.integer(1)])])
check(metaStore.submit(input(packets,1,0,Int64(wall*1000),last)),"metadata checkpoint")
for i in 2...70 {
    last = .object(["bool":.bool(i%2==0),"a":.array([.integer(Int64(i)),.null])])
    check(metaStore.submit(input(packets,i,0,Int64(wall*1000),last)),"delta \(i)")
    let name=names(metaStore.directory).first{(try? DiagnosticSharedStore.readHeader(metaStore.directory.appendingPathComponent($0)).0.incident)==i}!
    check(try DiagnosticSharedStore.expand(name,in:metaStore.directory).metadata==last,"delta and checkpoints reconstruct \(i)")
}
// Earlier frame owners survive while a fresh incident still references them.
wall+=72*3600-1
check(metaStore.submit(input(packets,71,0,Int64(wall*1000),last)),"fresh dependent capture")
wall+=62;check(metaStore.drain(),"dependency GC")
let newest=names(metaStore.directory).first{(try? DiagnosticSharedStore.readHeader(metaStore.directory.appendingPathComponent($0)).0.incident)==71}!
check(try DiagnosticSharedStore.expand(newest,in:metaStore.directory).frames.count==100,"GC retains required frame and metadata dependencies")

let criticalDir=directory("critical"),journal=DiagnosticCriticalJournal(directory:criticalDir,segmentBytes:4096,wallClock:{wall})
let cause=OperationalFailure.posix(.probeLaunch,ENOSPC)
for batch in 0..<50{for _ in 0..<64{journal.record(cause)};check(journal.flush(timeout:5),"same-time error batch \(batch)")}
check(try records(criticalDir).count==3200,"all repeated important errors preserved across size rolls")
check(Set(try! records(criticalDir).map{$0.run+":"+String($0.sequence)}).count==3200,"unique error IDs")
for batch in 0..<400{for _ in 0..<128{journal.record(.policy(.incidentTrigger,3),observation:true)};check(journal.flush(timeout:5),"observation batch \(batch)")}
check(try records(criticalDir).filter{$0.failure==cause}.count==3200,"ordinary flood cannot evict error lane")
check(journal.status().writtenBytes>8*1024*1024,"flood exceeds old combined 8MiB retention")
print("MEASURE separated journal: \(journal.status().writtenBytes) logical bytes; 3200 errors + 51200 observations")
// A stalled observation writer must not block termination or error writes.
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),guardLock=NSLock()
var hasBlocked=false
let blockedDir=directory("blocked"),blocked=DiagnosticCriticalJournal(directory:blockedDir,writer:{fd,p,n in
    let text=String(data:Data(bytes:p!,count:n),encoding:.utf8) ?? ""
    guardLock.lock();let block=text.contains("observations") && !hasBlocked;if block{hasBlocked=true};guardLock.unlock()
    if block{entered.signal();release.wait()};return Darwin.write(fd,p,n)
})
blocked.record(.policy(.incidentTrigger,3),observation:true)
check(entered.wait(timeout:.now()+3) == .success,"ordinary writer stalled")
blocked.record(cause);blocked.record(.policy(.termination,72))
let start=ProcessInfo.processInfo.systemUptime
check(!blocked.flush(timeout:0.1) && ProcessInfo.processInfo.systemUptime-start<0.5,"bounded terminal flush")
let protected=try! records(blockedDir)
check(protected.contains{$0.failure.stage == .termination} && protected.contains{$0.failure==cause},"termination and error saved despite stalled ordinary writer")
release.signal();check(blocked.flush(timeout:5),"ordinary writer eventually resumes")
let early=OperationalDiagnostics(sink:{_ in}),earlyDir=directory("early"),earlyJournal=DiagnosticCriticalJournal(directory:earlyDir)
for _ in 0..<100{early.record(cause)};early.installJournal(earlyJournal)
check(earlyJournal.flush(timeout:5) && (try! records(earlyDir)).count==100,"pre-install repeats are not coalesced away")

// Two apps at the supported Unicode bounds can take more than a KiB.
do {
    let apps=(1...2).map { id in
        DiagnosticApplicationRecord(id:id,pid:Int32(100+id),name:String(repeating:"🚲",count:256),
            bundleID:String(repeating:"🚲",count:256),version:String(repeating:"🚲",count:64),
            build:String(repeating:"🚲",count:64),launchMilliseconds:1000)
    }
    let appInfo=DiagnosticApplicationSnapshot(records:apps,unavailableReferences:[])
    check(appInfo.valid,"valid two-app metadata at the Unicode size limits")
    var context=DiagnosticCriticalJournal.Context(trace:run,incident:7,sequence:1,lane:7,kind:2,category:2,count:1,episode:0)
    context.applicationReferences=DiagnosticApplicationReferences(target:1,owner:2)
    context.applicationInfo=appInfo
    let observed=OperationalFailure.policy(.slowRead,2)
    func observation(_ sequence:Int,withContext:Bool)->DiagnosticCriticalJournal.Event {
        .init(run:run,sequence:sequence,milliseconds:Int64(sequence),failure:observed,context:withContext ? context:nil)
    }
    let large=observation(1,withContext:true)
    let encodedSize=try! JSONEncoder().encode(large).count
    check(encodedSize>4096 && encodedSize<8192-512,"valid row spans more than the smaller segment")
    for segment in [8192,4096] {
        let journalDir=directory("critical-size-\(segment)")
        let sized=DiagnosticCriticalJournal(directory:journalDir,segmentBytes:segment,wallClock:{wall})
        sized.record(large,observation:true)
        sized.record(observation(2,withContext:true),observation:true)
        sized.record(observation(3,withContext:false),observation:true)
        check(sized.flush(timeout:5) && sized.storageIssues().isEmpty,"later ordinary event still persists within \(segment)-byte segments")
        let saved=try! records(journalDir).sorted{$0.sequence<$1.sequence}
        check(saved.map(\.sequence)==[1,2,3] && saved.allSatisfy{$0.run==run && $0.failure==observed},"every original occurrence and reason retained")
        check(saved.map(\.milliseconds)==[1,2,3],"original occurrence times retained")
        if segment==8192 {
            check(saved.prefix(2).allSatisfy{$0.context?.applicationInfo?.records==apps && $0.contextOmission==nil},"full app metadata survives segment rotation")
            check(sized.status().rotations>0,"real encoded size triggers rotation")
        }else{
            check(saved.prefix(2).allSatisfy{$0.context==nil && $0.contextOmission == .segmentCapacity},"unrepresentable context marks only its own occurrence")
        }
        check(saved[2].contextOmission==nil,"following small event needs no omission marker")
        let fd=open(journalDir.path,O_RDONLY|O_NOFOLLOW|O_DIRECTORY)
        let files=try! DiagnosticCriticalJournal.readFiles(fd)
        close(fd)
        check(files.allSatisfy{$0.1.count<=segment},"encoded rows, newlines and headers fit configured segment")
        if segment==4096 {
            let reviewDir=directory("omitted-context-review")
            for (name,data) in files {try! DiagnosticSharedStore.writeExport(data,to:reviewDir.appendingPathComponent(name))}
            try! DiagnosticSharedStore.writeExport(Data("{}".utf8),to:reviewDir.appendingPathComponent("review-dates.json"))
            try! DiagnosticSharedStore.writeExport(Data(#"{"schema":1,"status":{}}"#.utf8),to:reviewDir.appendingPathComponent("storage-status.json"))
            let review=try! DiagnosticReviewSnapshot(directory:reviewDir)
            check(review.critical?.sections.flatMap(\.fields).contains{field in
                field.label=="세부 정보 없이 저장한 사건" && field.value=="2"
            }==true,"review reports original occurrences with omitted context")
        }
    }
}

// Product integration: routine observation never creates a capture; automatic
// ten-second and manual sixty-second pre-windows retain the three-second post.
let liveDir=directory("trace")
let recorder=try! RecorderSession(source:liveDir,outputRoot:directory("recorder"),product:[:])
let liveJournal=DiagnosticCriticalJournal(directory:liveDir)
OperationalDiagnostics.shared.installJournal(liveJournal)
var tick=100.0
let trace=InputIncidentTrace(secureInput:{false},destination:liveDir,persistentOwnership:true,clock:{tick})
trace.flush()
for i in 0...70{tick=100+Double(i);trace.context();trace.flush()}
trace.captureForTest(.onsetObservation);trace.flush()
check(names(liveDir.appendingPathComponent(DiagnosticSharedStore.directoryName)).isEmpty,"routine onset has zero detailed writes")
trace.captureForTest(.axDelay);trace.flush()
trace.captureForTest(.manual);trace.flush()
for i in 1...3{tick=170+Double(i);trace.context();trace.flush()}
trace.finishCaptureWindowsForTest();trace.flush()
let liveShared=liveDir.appendingPathComponent(DiagnosticSharedStore.directoryName)
let captures=try! names(liveShared).map{try DiagnosticSharedStore.expand($0,in:liveShared)}
check(captures.count==4,"both immediate pres and completed posts")
check(captures.first{$0.header.trigger==3 && $0.header.phase==0}!.frames.map(\.milliseconds)==Array(stride(from:60000,through:70000,by:1000)),"automatic pre 10 seconds")
check(captures.first{$0.header.trigger==1 && $0.header.phase==0}!.frames.count==61,"manual pre 60 seconds")
check(captures.filter{$0.header.phase==1}.allSatisfy{$0.frames.map(\.milliseconds)==[71000,72000,73000]},"full three second post")
check(liveJournal.flush(timeout:5),"trace facts flushed")
try! recorder.finish(scenario:"ordinary")
check(recorder.copied==4 && recorder.rejected==0,"standalone recorder expands and sanitizes four shared captures")
let export=root.appendingPathComponent("export"),done=DispatchSemaphore(value:0)
var exportError:Error?
trace.prepareExport(to:export,reviewMetadata:true){result in if case .failure(let e)=result{exportError=e};done.signal()}
check(done.wait(timeout:.now()+10) == .success && exportError==nil,"snapshot export")
let review=try! DiagnosticReviewSnapshot(directory:export)
check(review.incidents.count==2 && review.incidents.allSatisfy(\.complete),"review recognizes shared incidents")
let environment=DiagnosticReviewEnvironment(appVersion:"0",build:"test",macOSVersion:"test",modelIdentifier:nil,keyboardLayout:.unknownOrOther,koreanKeyEnabled:false,hanjaKeyEnabled:false,hudEnabled:false,capsLockSwitchEnabled:nil,loginItemState:.unknown,diagnosticsEnabled:true,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
let selected=try! review.files(selected:[review.incidents[0].id],environment:environment)
for file in selected where DiagnosticSharedStore.validName(file.path){check(try Data(contentsOf:liveShared.appendingPathComponent(file.path))==file.data,"original shared bytes preserved through review")}
let archive=try! DiagnosticReviewArchive(files:selected)
check(archive.bytes>0,"selected dependency archive built")
trace.stopAndFlush()
// A late post keeps its pre until 72h after the pair's final phase.
var pairTime=1_000_000.0
let paired=DiagnosticSharedStore(directory:directory("paired-age"),clock:{pairTime})
check(paired.submit(input(packets,1,0,Int64(pairTime*1000))),"paired pre")
pairTime+=3;check(paired.submit(input(packets,1,1,Int64(pairTime*1000))),"paired post")
pairTime+=72*3600-1;check(paired.drain() && names(paired.directory).count==2,"pre retained until post reaches 72h")
pairTime+=62;check(paired.drain() && names(paired.directory).isEmpty,"paired phases expire together")
// Important error retention is based on age, never the ordinary lane's volume.
var errorWall=10_000_000.0
let ageDir=directory("critical-age"),ageJournal=DiagnosticCriticalJournal(directory:ageDir,wallClock:{errorWall})
ageJournal.record(cause);check(ageJournal.flush(timeout:5),"age fixture error durable")
errorWall+=72*3600-1
check(ageJournal.flush(timeout:5) && (try! records(ageDir)).filter{$0.failure==cause}.count==1,"important error survives 72h minus one second")
errorWall+=122
check(ageJournal.flush(timeout:5) && (try! records(ageDir)).isEmpty,"expired error segment retires only after age grace")
let preserveDir=directory("critical-preserved"),preserveJournal=DiagnosticCriticalJournal(directory:preserveDir,preserve:true,wallClock:{errorWall})
preserveJournal.record(cause);check(preserveJournal.flush(timeout:5),"preservation fixture error durable")
errorWall+=100*3600
check(preserveJournal.flush(timeout:5) && (try! records(preserveDir)).count==1,"explicit investigation preserves errors beyond default age")
let preserveTrace=InputIncidentTrace(secureInput:{false},destination:nil,retention:.investigation)
check(preserveTrace.preservesDiagnostics,"investigation bootstrap retains critical journal policy");preserveTrace.stopAndFlush()
// Ordinary and manual pending memory are independent and follow retry queues.
let memory=DiagnosticCaptureMemory()
var a=memory.lease(8*1024*1024,manual:false),m=memory.lease(8*1024*1024,manual:true)
check(a != nil && m != nil && memory.lease(1,manual:false)==nil,"separate pending memory reservations")
a=nil;check(memory.status.automatic==0 && memory.status.manual==8*1024*1024,"one lane cannot consume or release the other")
m=nil;check(memory.status.manual==0,"lease releases accounted memory")
// Small delay facts retain duration and a read ID independently of big detail.
let factsDir=directory("slow-facts"),factsJournal=DiagnosticCriticalJournal(directory:factsDir)
OperationalDiagnostics.shared.installJournal(factsJournal)
var factsClock=100.0
let facts=InputIncidentTrace(secureInput:{false},destination:factsDir,clock:{factsClock})
let read=facts.beginRead(.mismatchAX);facts.flush();factsClock+=0.06
facts.endRead(.mismatchAX,read,outcome:.success);facts.flush()
check(factsJournal.flush(timeout:5),"slow read facts durable")
let slow=(try! records(factsDir)).filter{$0.failure.stage == .slowRead}
check(slow.count==2 && slow[0].context?.operationID==slow[1].context?.operationID && (slow[1].context?.durationMicros ?? 0)>=59999,"start/result ID and actual delay retained")
facts.stopAndFlush()
print("PASS shared storage \(checks) checks")
