import ApplicationServices
import Foundation
import CryptoKit
import Darwin
import Carbon
import OSLog
import AppKit

// Only existing snapshot PIDs enter the diagnostic worker. No window title,
// URL, document path, input text or AX object is accepted by this interface.
struct DiagnosticApplicationPIDs {
    let target:pid_t
    var owner:pid_t?=nil
}
// Decision-worker-owned bounded cache. A running-app object distinguishes a
// terminated process from a later process reusing its PID. Names are fetched
// once per cached process; ordinary frames carry only numeric references.
final class DiagnosticApplicationRegistry {
    struct Resolved {
        var name:String?,bundleID:String?,version:String?,build:String?,launchMilliseconds:Int64?
        var isCurrent:()->Bool={true}
    }
    private struct Entry {let record:DiagnosticApplicationRecord,isCurrent:()->Bool;var used:Int}
    private let resolve:(pid_t)->Resolved?,capacity:Int
    private var entries:[Int:Entry]=[:],byPID:[pid_t:Int]=[:],next=0,use=0
    init(capacity:Int=128,resolve:@escaping (pid_t)->Resolved?=DiagnosticApplicationRegistry.runningApplication){self.capacity=max(1,min(128,capacity));self.resolve=resolve}
    static func runningApplication(_ pid:pid_t)->Resolved? {
        guard let app=NSRunningApplication(processIdentifier:pid),!app.isTerminated,app.processIdentifier==pid else{return nil}
        let info=app.bundleURL.flatMap{Bundle(url:$0)?.infoDictionary}
        let result=Resolved(name:app.localizedName,bundleID:app.bundleIdentifier,
            version:info?["CFBundleShortVersionString"] as? String,build:info?["CFBundleVersion"] as? String,
            launchMilliseconds:app.launchDate.map{Int64(max(0,min($0.timeIntervalSince1970*1000,9_000_000_000_000_000)))},
            isCurrent:{!app.isTerminated && app.processIdentifier==pid})
        return result.isCurrent() ? result:nil
    }
    func reset(){entries=[:];byPID=[:]}
    private func reference(_ pid:pid_t?)->Int {
        guard let pid,pid>0,next<Int(Int32.max) else{return 0};use+=1
        if let id=byPID[pid],var entry=entries[id],entry.isCurrent(){entry.used=use;entries[id]=entry;return id}
        let value=resolve(pid)
        next+=1
        var record=DiagnosticApplicationRecord(id:next,pid:pid,launchMilliseconds:value?.launchMilliseconds)
        func bounded(_ text:String?,_ limit:Int)->String? {
            guard let text else{return nil};var output=String.UnicodeScalarView(),visited=0
            for scalar in text.unicodeScalars {
                if output.count>=limit || visited>=limit*4{record.shortened=true;break};visited+=1
                if CharacterSet.controlCharacters.contains(scalar){record.shortened=true;continue}
                output.append(scalar)
            }
            return output.isEmpty ? nil:String(output)
        }
        record.name=bounded(value?.name,256);record.bundleID=bounded(value?.bundleID,256)
        record.version=bounded(value?.version,64);record.build=bounded(value?.build,64)
        if entries.count>=capacity,let oldest=entries.min(by:{$0.value.used<$1.value.used}) {
            entries.removeValue(forKey:oldest.key)
            if byPID[oldest.value.record.pid]==oldest.key{byPID.removeValue(forKey:oldest.value.record.pid)}
        }
        entries[next]=Entry(record:record,isCurrent:value?.isCurrent ?? {true},used:use);byPID[pid]=next
        return next
    }
    func references(_ pids:DiagnosticApplicationPIDs?)->DiagnosticApplicationReferences? {
        guard let pids else{return nil}
        let result=DiagnosticApplicationReferences(target:reference(pids.target),owner:reference(pids.owner))
        return result.packed==0 ? nil:result
    }
    func snapshot(_ ids:Set<Int>)->DiagnosticApplicationSnapshot? {
        guard !ids.isEmpty else{return nil}
        let records=ids.sorted().compactMap{entries[$0]?.record}
        return DiagnosticApplicationSnapshot(records:records,unavailableReferences:ids.subtracting(records.map(\.id)).sorted())
    }
    #if HANQ_DIAGNOSTIC_TESTING
    var countForTest:Int{entries.count}
    #endif
}

// Operational failures are independent of opt-in input tracing. Only fixed
// stages/domains and numeric error codes cross this boundary, never paths or
// NSError descriptions/userInfo (which can contain user data).
enum OperationalStage:Int,Codable {
    case diagnosticOpen=1,diagnosticWrite
    case probeDirectory=10,probeValidate,probeEnter,probeLaunch,probeRead,probeDecode,probeToken
    case probeEncode,probeOpen,probeWrite,probePublish,probeTimeout,probeCleanup
    case permissionDenied,permissionUnavailable,permissionRestored,watchdog,transport
    case budgetPersistence=30,storageWrite
    case storagePrepare,storageOwnership,storagePublish,storagePrune,storageEncode,storageStatus
    case recoveryFailure=40,incidentTrigger,termination,captureDisposition,journalOverflow,storageRead,slowRead,boundaryCompletion
}
struct OperationalFailure:Error,Codable,Hashable {
    enum Domain:Int,Codable {case policy=0,posix,cocoa,osStatus,mach,other}
    let stage:OperationalStage
    let domain:Domain
    let code:Int
    let underlyingPOSIX:Int
    static func posix(_ stage:OperationalStage,_ code:Int32)->Self {
        Self(stage:stage,domain:.posix,code:Int(code),underlyingPOSIX:Int(code))
    }
    static func policy(_ stage:OperationalStage,_ code:Int)->Self {
        Self(stage:stage,domain:.policy,code:code,underlyingPOSIX:0)
    }
    static func capture(_ error:Error,stage:OperationalStage)->Self {
        let value=error as NSError
        let domain:Domain
        switch value.domain {
        case NSPOSIXErrorDomain:domain = .posix
        case NSCocoaErrorDomain:domain = .cocoa
        case NSOSStatusErrorDomain:domain = .osStatus
        case NSMachErrorDomain:domain = .mach
        default:domain = .other
        }
        var underlying=domain == .posix ? value.code:0
        var next: NSError?=value
        for _ in 0..<4 {
            guard let current=next else{break}
            if current.domain==NSPOSIXErrorDomain{underlying=current.code;break}
            next=current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return Self(stage:stage,domain:domain,code:value.code,underlyingPOSIX:underlying)
    }
}
final class OperationalDiagnostics {
    struct Entry:Codable {
        let failure:OperationalFailure
        var count:Int
        let firstNanoseconds:UInt64
        var lastNanoseconds:UInt64
        var elapsedMilliseconds:Int
        var lastEmittedNanoseconds:UInt64
        var event:DiagnosticCriticalJournal.Event
    }
    static let shared=OperationalDiagnostics()
    private static let logger=Logger(subsystem:"taek.in.hanq",category:"operations")
    private let lock=NSLock()
    private var entries:[Entry]=[]
    private var evicted=0
    private var journal:DiagnosticCriticalJournal?
    private var earlyEvents:[(DiagnosticCriticalJournal.Event,Bool)]=[]
    private var earlyOverflow=0,earlyObservationOverflow=0
    private let run=UUID().uuidString
    private var eventSequence=0
    private let clock:()->UInt64
    private let sink:(Entry)->Void
    init(clock:@escaping ()->UInt64={DispatchTime.now().uptimeNanoseconds},
         sink:@escaping (Entry)->Void={entry in
             let value=entry.failure
             OperationalDiagnostics.logger.error("stage=\(value.stage.rawValue,privacy:.public) domain=\(value.domain.rawValue,privacy:.public) code=\(value.code,privacy:.public) errno=\(value.underlyingPOSIX,privacy:.public) event=\(entry.event.sequence,privacy:.public) run=\(entry.event.run,privacy:.public) incident=\(entry.event.context?.incident ?? 0,privacy:.public) count=\(entry.count,privacy:.public) elapsedMS=\(entry.elapsedMilliseconds,privacy:.public)")
         }) {self.clock=clock;self.sink=sink}
    func installJournal(_ value:DiagnosticCriticalJournal) {
        lock.lock();journal=value;let pending=earlyEvents;earlyEvents.removeAll();let lost=earlyOverflow,ordinaryLost=earlyObservationOverflow;earlyOverflow=0;earlyObservationOverflow=0;lock.unlock()
        for (event,observation) in pending{value.record(event,observation:observation)}
        if ordinaryLost>0{value.record(.policy(.journalOverflow,2),context:DiagnosticCriticalJournal.Context(trace:run,incident:0,sequence:0,lane:0,kind:0,category:0,count:ordinaryLost,episode:0),observation:true)}
        if lost>0{value.record(.policy(.journalOverflow,1),context:DiagnosticCriticalJournal.Context(trace:run,incident:0,sequence:0,lane:0,kind:0,category:0,count:lost,episode:0))}
    }
    @discardableResult func flushCritical(timeout:Double=0.25,retryNow:Bool=false)->Bool {
        lock.lock();let value=journal;lock.unlock();return value?.flush(timeout:timeout,retryNow:retryNow) ?? false
    }
    // Every failure occurrence reaches OSLog and the compact journal with a
    // unique event ID. The 64-entry summary is not the event retention policy.
    // No disk write, arbitrary string, or logging of a logger failure here.
    func record(_ failure:OperationalFailure,elapsedMilliseconds:Int=0,context:DiagnosticCriticalJournal.Context?=nil,observation:Bool=false) {
        let now=clock()
        lock.lock()
        eventSequence+=1
        let event=DiagnosticCriticalJournal.Event(run:run,sequence:eventSequence,milliseconds:Int64(Date().timeIntervalSince1970*1000),failure:failure,context:context)
        let index:Int
        if let existing=entries.firstIndex(where:{$0.failure==failure}) {index=existing}
        else {
            if entries.count==64{entries.removeFirst();evicted=min(Int.max-1,evicted)+1}
            entries.append(Entry(failure:failure,count:0,firstNanoseconds:now,lastNanoseconds:now,
                                 elapsedMilliseconds:0,lastEmittedNanoseconds:now,event:event))
            index=entries.count-1
        }
        entries[index].count=min(Int.max-1,entries[index].count)+1
        entries[index].lastNanoseconds=now
        entries[index].elapsedMilliseconds=max(0,min(elapsedMilliseconds,60_000))
        entries[index].event=event
        let emit = !observation
        if emit{entries[index].lastEmittedNanoseconds=now}
        let value=entries[index],journal=self.journal
        if journal==nil {
            let terminal=failure.stage == .termination
            let count=earlyEvents.filter{terminal ? $0.0.failure.stage == .termination:($0.1==observation && $0.0.failure.stage != .termination)}.count
            if count<(terminal ? 16:(observation ? 256:2048)){earlyEvents.append((event,observation))}
            else if observation{earlyObservationOverflow+=1}else{earlyOverflow+=1}
        }
        lock.unlock()
        journal?.record(event,observation:observation)
        if emit{sink(value)}
    }
    func snapshot()->(entries:[Entry],evicted:Int) {
        lock.lock();defer{lock.unlock()};return(entries,evicted)
    }
    func storageStatus(for directory:URL,flush:Bool=false)->DiagnosticCriticalJournal.Status? {
        lock.lock();let journal=self.journal;lock.unlock()
        guard let journal,journal.directory==directory.standardizedFileURL else{return nil}
        if flush{_ = journal.flush(timeout:0.25)}
        return journal.status()
    }
    func storageIssues(for directory:URL)->[DiagnosticStorageIssue] {
        lock.lock();let journal=self.journal;lock.unlock()
        guard let journal,journal.directory==directory.standardizedFileURL else{return []}
        return journal.storageIssues()
    }
    func pendingExport(for directory:URL)throws->[(String,Data,Int)] {
        lock.lock();let journal=self.journal;lock.unlock()
        guard let journal,journal.directory==directory.standardizedFileURL else{return []}
        return try journal.pendingExport()
    }
}
enum OperationalIO {
    typealias Write=(Int32,UnsafeRawPointer?,Int)->Int
    // Capture errno before cleanup. Short writes and EINTR never lose a suffix;
    // a zero-byte write is a separate no-progress policy failure.
    static func writeAll(_ data:Data,to descriptor:Int32,stage:OperationalStage,
                         write:Write={Darwin.write($0,$1,$2)})->OperationalFailure? {
        data.withUnsafeBytes {bytes in
            var offset=0
            while offset<bytes.count {
                let count=write(descriptor,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count<0 {
                    let code=errno
                    if code==EINTR{continue}
                    return .posix(stage,code)
                }
                guard count>0,count<=bytes.count-offset else{return .policy(stage,1)}
                offset+=count
            }
            return nil
        }
    }
}

// Separate lane writer. Immutable retired segments expire by age; file size
// only starts a new segment, never evicts a still-retained occurrence.
final class DiagnosticCriticalLane {
    struct Context:Codable {
        let trace:String,incident:Int,sequence:Int,lane:Int,kind:Int,category:Int,count:Int,episode:Int
        var observedMilliseconds:Int?=nil
        var requestID:String?=nil
        var durationMicros:Int?=nil
        var durationClipped:Bool?=nil
        var operationID:Int?=nil
        var beganMilliseconds:Int?=nil
        var outcome:Int?=nil
        var readPurpose:Int?=nil
        var activityUnchanged:Bool?=nil
        var detailPolicy:Int?=nil // 1 full detail, 2 compact background observation
        var readToken:String?=nil
        var axResult:InputIncidentAXResult?=nil
        var applicationReferences:DiagnosticApplicationReferences?=nil
        var applicationInfo:DiagnosticApplicationSnapshot?=nil
    }
    struct Event:Codable {
        enum ContextOmission:String,Codable {case encodingFailed,segmentCapacity}

        let run:String,sequence:Int,milliseconds:Int64,failure:OperationalFailure,context:Context?
        var contextOmission:ContextOmission?=nil
        var valid:Bool {UUID(uuidString:run) != nil && sequence>0 && milliseconds>=0 &&
            (contextOmission==nil || context==nil) &&
            (context.map{UUID(uuidString:$0.trace) != nil && $0.incident>=0 && $0.sequence>=0 && $0.episode>=0} ?? true)}
    }
    struct Header:Codable {let schema:Int,generation:Int;var createdMilliseconds:Int64?=nil;var lane:String?=nil;var session:String?=nil}
    struct Decoded {let generation:Int,events:[Event],incomplete:Int}
    struct Status:Codable {
        let pendingErrors:Int,pendingObservations:Int,droppedErrors:Int,droppedObservations:Int
        let writeFailures:Int,lastErrno:Int,lastPolicy:Int,writtenBytes:Int,rotations:Int
    }
    static let filenames=[".critical-events-v2-0.jsonl",".critical-events-v2-1.jsonl"]
    static let maximumSegmentBytes=4*1024*1024
    private let queue=DispatchQueue(label:"hanq.diagnostics.critical",qos:.utility)
    private let lock=NSLock()
    private let directory:URL,writer:OperationalIO.Write,clock:()->Double,segmentBytes:Int
    private let run=UUID().uuidString
    private var nextSequence=0,pending:[(Event,Bool)]=[],scheduled=false
    private var droppedErrors=0,droppedObservations=0,writeFailures=0,lastErrno=0,lastPolicy=0,rotations=0
    private var reportedErrors=0,reportedObservations=0
    private var writtenBytes=0,inFlight:Data?,inFlightOffset=0,inFlightCount=0
    private var retryAt=0.0,retryDelay=1.0,blocked=false
    // Published under lock; blocked/retryAt themselves belong to the writer queue.
    private var currentStorageIssue:DiagnosticStorageIssue?
    private var directoryIdentity:stat?,lockIdentity:stat?,identities:[Int:stat]=[:]
    private var current=0,generation=0,descriptor:Int32 = -1,lockFD:Int32 = -1
    private var currentName="",created=0.0,lastPruned = -Double.infinity
    private let lane:String,wallClock:()->Double,preserve:Bool
    private var timer:DispatchSourceTimer?
    init(directory:URL,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},
         segmentBytes:Int=DiagnosticCriticalLane.maximumSegmentBytes,lane:String="errors",preserve:Bool=false,wallClock:@escaping ()->Double={Date().timeIntervalSince1970},
         writer:@escaping OperationalIO.Write={Darwin.write($0,$1,$2)}) {
        self.directory=directory;self.clock=clock;self.writer=writer;self.lane=lane;self.preserve=preserve;self.wallClock=wallClock
        self.segmentBytes=max(4096,min(segmentBytes,Self.maximumSegmentBytes))
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler{[weak self] in self?.drain(all:false)}
        self.timer=timer;timer.resume()
    }
    deinit {timer?.cancel();if descriptor>=0{close(descriptor)};if lockFD>=0{close(lockFD)}}
    func record(_ failure:OperationalFailure,context:Context?=nil,observation:Bool=false) {
        lock.lock();nextSequence+=1;let sequence=nextSequence;lock.unlock()
        record(Event(run:run,sequence:sequence,milliseconds:Int64(wallClock()*1000),failure:failure,context:context),observation:observation)
    }
    func record(_ event:Event,observation:Bool=false) {
        lock.lock()
        let count=pending.reduce(0){$0+($1.1==observation ? 1:0)}
        if count >= (observation ? 256:2048) {
            if observation{droppedObservations=min(Int.max-1,droppedObservations)+1}
            else{droppedErrors=min(Int.max-1,droppedErrors)+1}
            lock.unlock();return
        }
        pending.append((event,observation))
        let start = !scheduled
        if start{scheduled=true}
        lock.unlock()
        if start{queue.async{[self] in drain(all:false)}}
    }
    // Only the waiting caller is bounded. The writer may still be blocked in
    // the kernel; a safety exit must never wait for it indefinitely.
    @discardableResult func flush(timeout:Double=0.25,retryNow:Bool=false)->Bool {
        let signal=DispatchSemaphore(value:0)
        queue.async{[self] in if retryNow{retryAt=0};drain(all:true);signal.signal()}
        guard signal.wait(timeout:.now()+timeout) == .success else{return false}
        lock.lock();defer{lock.unlock()};return pending.isEmpty && droppedErrors==reportedErrors && droppedObservations==reportedObservations
    }
    func status()->Status {
        lock.lock();defer{lock.unlock()}
        return Status(pendingErrors:pending.filter{!$0.1}.count,pendingObservations:pending.filter{$0.1}.count,
            droppedErrors:droppedErrors,droppedObservations:droppedObservations,writeFailures:writeFailures,lastErrno:lastErrno,lastPolicy:lastPolicy,writtenBytes:writtenBytes,rotations:rotations)
    }
    func storageIssue(component:DiagnosticStorageIssue.Component)->DiagnosticStorageIssue? {
        lock.lock();defer{lock.unlock()}
        guard var issue=currentStorageIssue else{return nil}
        issue.component=component;issue.pendingCount=pending.count
        return issue
    }
    func pendingExport()throws->(String,Data,Int)? {
        lock.lock();let events=pending.map(\.0);lock.unlock()
        guard !events.isEmpty else{return nil}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var data=try encoder.encode(Header(schema:3,generation:1,createdMilliseconds:Int64(wallClock()*1000),lane:lane,session:run))
        data.append(10)
        for event in events{data.append(try encoder.encode(event));data.append(10)}
        return ("critical-memory-v3-\(lane)-\(UUID().uuidString).jsonl",data,events.count)
    }
    static func scan(_ data:Data,visit:(Event)->Void)->(generation:Int,incomplete:Int)? {
        guard data.count<=maximumSegmentBytes else{return nil}
        var start=data.startIndex,generation:Int?,incomplete=0
        let decoder=JSONDecoder()
        while start<data.endIndex {
            let end=data[start...].firstIndex(of:10) ?? data.endIndex
            let line=Data(data[start..<end])
            if generation==nil {
                guard let header=try? decoder.decode(Header.self,from:line),
                      (header.schema==2 || header.schema==3),header.generation>0,
                      header.generation<9_000_000_000_000_000 else{return nil}
                generation=header.generation
            }else{
                autoreleasepool {
                    if let event=try? decoder.decode(Event.self,from:line),event.valid{visit(event)}else{incomplete+=1}
                }
            }
            start=end==data.endIndex ? end:data.index(after:end)
        }
        guard let generation else{return nil};return (generation,incomplete)
    }
    static func decode(_ data:Data)->Decoded? {
        var events:[Event]=[]
        guard let result=scan(data,visit:{events.append($0)}) else{return nil}
        return Decoded(generation:result.generation,events:events,incomplete:result.incomplete)
    }
    static func forEachFile(_ dir:Int32,_ body:(String,Data)throws->Void)throws {
        for name in try DiagnosticOwnedIO.names(dir).filter({filenames.contains($0) || validName($0)}) {
            let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            if fd<0 {if errno==ENOENT{continue};throw DiagnosticLogExport.Failure.unavailable}
            defer{close(fd)}
            var info=stat()
            guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o7777==0o600,
                  info.st_nlink==1,info.st_size>=0,info.st_size<=maximumSegmentBytes else{throw DiagnosticLogExport.Failure.unavailable}
            let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:Int(info.st_size)) ?? Data()
            guard data.count==info.st_size else{throw DiagnosticLogExport.Failure.unavailable}
            try autoreleasepool{try body(String(name.dropFirst()),data)}
        }
    }
    static func readFiles(_ dir:Int32)throws ->[(String,Data)] {
        var files:[(String,Data)]=[]
        try forEachFile(dir){files.append(($0,$1))};return files
    }
    static func validName(_ name:String)->Bool {
        name.hasPrefix(".critical-") && name.contains("-v3-") && name.hasSuffix(".jsonl") && !name.contains("/")
    }
    private func same(_ a:stat,_ b:stat)->Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    private func policyFailure(_ code:Int) {
        blocked=true
        lock.lock();writeFailures+=1;lastErrno=0;lastPolicy=code
        currentStorageIssue=DiagnosticStorageIssue(component:.criticalErrors,failure:.policy(.storageWrite,code),retry:.stopped,milliseconds:Int64(wallClock()*1000))
        lock.unlock()
        Logger(subsystem:"taek.in.hanq",category:"critical-storage").error("criticalStorage policy=\(code,privacy:.public)")
    }
    private func failed(_ code:Int32) {
        if !DiagnosticStorageRecovery.transient(.posix(.storageWrite,code)){blocked=true}
        lock.lock();writeFailures+=1;lastErrno=Int(code)
        currentStorageIssue=DiagnosticStorageIssue(component:.criticalErrors,failure:.posix(.storageWrite,code),retry:blocked ? .stopped:.automatic,milliseconds:Int64(wallClock()*1000))
        lock.unlock()
        Logger(subsystem:"taek.in.hanq",category:"critical-storage").error("criticalStorage errno=\(code,privacy:.public)")
        retryAt=clock()+retryDelay;retryDelay=min(60,retryDelay*2)
    }
    private func openDirectory()->Int32? {
        for path in [directory.deletingLastPathComponent().path,directory.path] {
            var info=stat()
            if lstat(path,&info)<0 {
                guard errno==ENOENT,directoryIdentity==nil else{failed(errno);return nil}
                if mkdir(path,0o700) != 0 && errno != EEXIST{failed(errno);return nil}
                guard lstat(path,&info)==0 else{failed(errno);return nil}
            }
            guard info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0 else{policyFailure(1);return nil}
        }
        let dir=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard dir>=0 else{failed(errno);return nil}
        var info=stat()
        guard fstat(dir,&info)==0 else{let code=errno;close(dir);failed(code);return nil}
        if let old=directoryIdentity,old.st_dev != info.st_dev || old.st_ino != info.st_ino{close(dir);policyFailure(1);return nil}
        directoryIdentity=info
        if lockFD<0 {
            let fd=openat(dir,".critical-writer-v2.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0o600)
            var file=stat()
            guard fd>=0 else{let code=errno;close(dir);failed(code);return nil}
            guard fstat(fd,&file)==0,file.st_mode&S_IFMT==S_IFREG,file.st_uid==getuid(),file.st_mode&0o7777==0o600,file.st_nlink==1,
                  flock(fd,LOCK_EX|LOCK_NB)==0 else{close(fd);close(dir);policyFailure(1);return nil}
            lockFD=fd;lockIdentity=file
        }else {
            var file=stat()
            guard let old=lockIdentity,fstatat(dir,".critical-writer-v2.lock",&file,AT_SYMLINK_NOFOLLOW)==0,same(old,file) else{close(dir);policyFailure(1);return nil}
        }
        return dir
    }
    private func prepare(_ dir:Int32)->Bool {
        if descriptor>=0 {
            var info=stat()
            guard let old=identities[current],fstatat(dir,currentName,&info,AT_SYMLINK_NOFOLLOW)==0,same(old,info) else{policyFailure(1);return false}
            return true
        }
        return rotate(dir,to:0)
    }
    private func rotate(_ dir:Int32,to index:Int)->Bool {
        let name=".critical-\(lane)-v3-\(run)-\(generation+1).jsonl"
        let fd=openat(dir,name,O_WRONLY|O_APPEND|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{failed(errno);return false}
        let now=wallClock()
        let data=(try! JSONEncoder().encode(Header(schema:3,generation:generation+1,createdMilliseconds:Int64(now*1000),lane:lane,session:run)))+Data([10])
        // Header writes use the real writer: an interrupted initialization is
        // preserved as a partial file; the next retry creates a new unique file.
        if let error=OperationalIO.writeAll(data,to:fd,stage:.storageWrite,write:{[self] fd,p,n in
            let value=writer(fd,p,n);if value>0{lock.lock();writtenBytes+=value;lock.unlock()};return value
        }){close(fd);generation+=1;failed(Int32(clamping:error.underlyingPOSIX));return false}
        guard fsync(fd)==0 else{close(fd);generation+=1;failed(errno);return false}
        var info=stat();guard fstat(fd,&info)==0 else{close(fd);failed(errno);return false}
        if descriptor>=0{close(descriptor)}
        descriptor=fd;current=0;identities[0]=info;currentName=name;generation+=1;created=now
        lock.lock();if generation>1{rotations+=1};lock.unlock()
        guard fsync(dir)==0 else{failed(errno);return false}
        return true
    }
    private func prune(_ dir:Int32) {
        guard !preserve,wallClock()-lastPruned>=60 else{return}
        lastPruned=wallClock()
        do {
            for name in try DiagnosticOwnedIO.names(dir) where Self.validName(name) && name != currentName {
                let url=directory.appendingPathComponent(name)
                // Unknown or crash-partial files are evidence, never garbage.
                guard let bytes=try? DiagnosticOwnedIO.read(url,maximum:Self.maximumSegmentBytes),
                      let first=bytes.split(separator:10).first,
                      let header=try? JSONDecoder().decode(Header.self,from:Data(first)),header.schema==3,
                      header.lane==lane,let session=header.session,UUID(uuidString:session) != nil,
                      name==".critical-\(lane)-v3-\(session)-\(header.generation).jsonl",
                      let started=header.createdMilliseconds,wallClock()*1000>=Double(started)+72*3600*1000+60000 else{continue}
                let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{continue};defer{close(fd)}
                let original=try DiagnosticOwnedIO.regular(fd,maximum:Self.maximumSegmentBytes)
                var actual=stat();guard fstatat(dir,name,&actual,AT_SYMLINK_NOFOLLOW)==0,same(original,actual) else{policyFailure(1);return}
                if unlinkat(dir,name,0) != 0{failed(errno);return}
            }
        }catch{policyFailure(2)}
    }
    private func drain(all:Bool) {
        defer{
            lock.lock();let more = !pending.isEmpty && !blocked && clock()>=retryAt
            scheduled=more;lock.unlock()
            if more{queue.async{[weak self] in self?.drain(all:false)}}
        }
        lock.lock();let needed = !pending.isEmpty;lock.unlock()
        guard !blocked,clock()>=retryAt else{return}
        if !needed && wallClock()-lastPruned<60{return}
        guard let dir=openDirectory() else{return};defer{close(dir)}
        if inFlight==nil,descriptor>=0,wallClock()-created>=60{close(descriptor);descriptor = -1;currentName=""}
        prune(dir)
        guard needed,prepare(dir) else{return}
        repeat {
            if inFlight == nil {
                lock.lock();let events=Array(pending.prefix(8));lock.unlock()
                guard !events.isEmpty else{return}
                let encoder=JSONEncoder()
                // Reserve room for a new segment header. Count the encoded bytes
                // and each newline so app metadata can span more than one KiB.
                let payloadCapacity=segmentBytes-512
                var data=Data(),count=0
                for (event,_) in events {
                    let encoded=try? encoder.encode(event)
                    let line:Data
                    if let encoded,encoded.count<payloadCapacity {
                        line=encoded
                    }else{
                        // Keep the original occurrence and reason even when its
                        // optional context cannot fit in an empty segment.
                        let occurrence=Event(run:UUID(uuidString:event.run)==nil ? run:event.run,
                            sequence:event.sequence,milliseconds:event.milliseconds,
                            failure:event.failure,context:nil,contextOmission:encoded==nil ? .encodingFailed:.segmentCapacity)
                        line=try! encoder.encode(occurrence)
                    }
                    guard line.count<payloadCapacity-data.count else{break}
                    data.append(line);data.append(10);count+=1
                }
                if Int(identities[current]?.st_size ?? 0)+data.count>segmentBytes || wallClock()-created>=60 {
                    guard rotate(dir,to:0) else{return}
                }
                inFlight=data;inFlightOffset=0;inFlightCount=count
            }
            guard let data=inFlight else{return}
            let failure=data.withUnsafeBytes{bytes->OperationalFailure? in
                while inFlightOffset<bytes.count {
                    let count=writer(descriptor,bytes.baseAddress!.advanced(by:inFlightOffset),bytes.count-inFlightOffset)
                    if count<0 {let code=errno;if code==EINTR{continue};return .posix(.storageWrite,code)}
                    guard count>0,count<=bytes.count-inFlightOffset else{return .policy(.storageWrite,1)}
                    inFlightOffset+=count;lock.lock();writtenBytes+=count;lock.unlock()
                }
                return nil
            }
            var info=stat()
            guard fstat(descriptor,&info)==0 else{failed(errno);return}
            identities[current]=info
            if let failure{failed(Int32(clamping:failure.underlyingPOSIX));return}
            guard fsync(descriptor)==0 else{failed(errno);return}
            lock.lock();pending.removeFirst(inFlightCount)
            for (code,total,reported) in [(1,droppedErrors,reportedErrors),(2,droppedObservations,reportedObservations)] where total>reported {
                nextSequence+=1
                let context=Context(trace:run,incident:0,sequence:0,lane:0,kind:0,category:0,count:total-reported,episode:0)
                pending.append((Event(run:run,sequence:nextSequence,milliseconds:Int64(wallClock()*1000),failure:.policy(.journalOverflow,code),context:context),false))
            }
            reportedErrors=droppedErrors;reportedObservations=droppedObservations
            lock.unlock()
            inFlight=nil;inFlightCount=0;inFlightOffset=0;retryAt=0;retryDelay=1;lock.lock();lastErrno=0;currentStorageIssue=nil;lock.unlock()
            if !all{return}
        }while true
    }
}

/// Opt-in incident tracing. No text, keycodes, clipboard or AX content is logged.
/// Independent probes let us distinguish a stuck main loop from stale permission
/// answers. They are measurements only and do not change permission policy.
final class InputDiagnostics {
    static let shared = InputDiagnostics()
    private let descriptor: Int32
    private var timers: [DispatchSourceTimer] = []

    private init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--diagnose-input"), index + 1 < args.count {
            descriptor = open(args[index + 1], O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            if descriptor<0{OperationalDiagnostics.shared.record(.posix(.diagnosticOpen,errno))}
        } else { descriptor = -1 }
    }

    var isEnabled:Bool {descriptor >= 0}

    func record(_ message: @autoclosure () -> String) {
        guard descriptor >= 0 else { return }
        let line = "\(Date().timeIntervalSince1970) mono=\(DispatchTime.now().uptimeNanoseconds) pid=\(getpid()) \(message())\n"
        if let failure=OperationalIO.writeAll(Data(line.utf8),to:descriptor,stage:.diagnosticWrite) {
            OperationalDiagnostics.shared.record(failure)
        }
    }

    func start() {
        guard descriptor >= 0, timers.isEmpty else { return }
        record("diagnostics.start")
        for (name, probe) in [("ax", { AXIsProcessTrusted() }), ("post", { CGPreflightPostEventAccess() })] {
            let queue = DispatchQueue(label: "taek.in.hanq.diagnostics.\(name)")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                self?.record("probe.\(name).begin")
                let result = probe()
                self?.record("probe.\(name).end granted=\(result)")
            }
            timers.append(timer)
            timer.resume()
        }
    }

    deinit {
        timers.forEach { $0.cancel() }
        if descriptor >= 0 { close(descriptor) }
    }
}

// A fixed atomic generation: callers never wait for a settings/trace lock.
struct DiagnosticQuitState:Equatable {
    let detailPhases:Int,errors:Int,observations:Int
    var hasPending:Bool{detailPhases>0 || errors>0 || observations>0}
}

/// AppKit termination and updater relaunch use the same nonblocking decision.
/// A stalled filesystem is unknown, never evidence that the queue is empty.
final class DiagnosticQuitCoordinator {
    enum Choice {case cancel,export,discard}
    var prepare:(@escaping(DiagnosticQuitState)->Void)->Void
    var resume:()->Void
    var decide:(DiagnosticQuitState?,@escaping(Choice)->Void)->Void
    var exportPending:()->Void
    private(set) var active=false
    private var generation=0,deciding=false
    init(prepare:@escaping(@escaping(DiagnosticQuitState)->Void)->Void,resume:@escaping()->Void,
         decide:@escaping(DiagnosticQuitState?,@escaping(Choice)->Void)->Void,exportPending:@escaping()->Void){
        self.prepare=prepare;self.resume=resume;self.decide=decide;self.exportPending=exportPending
    }
    @discardableResult func request(timeout:Double=3,reply:@escaping(Bool)->Void)->Bool {
        guard !active else{return false}
        active=true;deciding=false;generation+=1;let current=generation
        func finish(_ allowed:Bool,_ export:Bool=false){
            guard self.active,self.generation==current else{return}
            self.active=false;self.generation+=1
            if !allowed{self.resume()}
            reply(allowed)
            if export{self.exportPending()}
        }
        func completed(_ state:DiagnosticQuitState?){
            guard self.active,self.generation==current,!self.deciding else{return}
            self.deciding=true
            if let state,!state.hasPending{finish(true);return}
            self.decide(state){choice in
                DispatchQueue.main.async{
                    switch choice{case .cancel:finish(false);case .export:finish(false,true);case .discard:finish(true)}
                }
            }
        }
        prepare{state in DispatchQueue.main.async{completed(state)}}
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0,timeout)){completed(nil)}
        return true
    }
}

private final class DiagnosticCollectionGate {
    private var value:Int32
    init(_ enabled:Bool){value=enabled ? 1:-1}
    var generation:Int32 {OSAtomicAdd32Barrier(0,&value)}
    func pause()->Int32 {
        while true {
            let previous=generation
            let next = -(abs(previous)%Int32.max+1)
            if OSAtomicCompareAndSwap32Barrier(previous,next,&value){return next}
        }
    }
    func activate(_ paused:Int32)->Bool {OSAtomicCompareAndSwap32Barrier(paused,-paused,&value)}
}

// Fixed control-path metadata only. Neither raw keycodes/flags, source IDs,
// device IDs, text nor mutable event references may enter this value.
struct InputIncidentControl:Codable,Equatable {
    enum Route:Int {case passed=1,tapDisabled,permissionDenied,updateRestricted,manualMarker,replayMarker,mirrorMarker,mirrorInactive,recipientMovedEarly,candidateConsumed,candidatePanel,barrierQueued,externalConsumed,filterConsumed,recipientMovedLate,hidTagIgnored,hidConsumed,hidPassed,onsetLockTimeout,onsetStopped,onsetStale,onsetDeadline,onsetPointer,onsetShortcut,onsetFirstRelease,onsetUnclaimed,onsetBufferLimit,onsetBuffered,onsetPassed,recoveryRedirect,secureSuppressed}
    var role:Int=0 // 0 health/unbound, 1 right Command, 2 right Option, 3 configured Korean, 4 configured Hanja
    var eventType:Int=0 // 1 flagsChanged, 2 down, 3 up, 4 tap disabled
    var route:Int=Route.passed.rawValue
    var runtime:Int=0 // enabled/permission/restricted/Korean/Hanja/barrier/recovery
    var incomingFlags:Int=0;var filterFlags:Int=0 // left/right/aggregate, three bits only
    var filterMeasured:Bool=false;var filterBefore:Int=0;var filterAfter:Int=0
    var filterAccepted:Bool=false;var filterEdge:Int=0;var filterConsumed:Bool=false
    var filterReason:Int=0 // 0 unmeasured, 1 down accepted, 2 up drained, 3 no right bit, 4 already down, 5 disallowed, 6 consuming, 7 other event
    var externalDevice:Int=0;var externalHandling:Int=0;var externalRole:Int=0
    var hidAcceptance:Int=0 // 0 unmeasured, 1 allowed, 2 disabled, 3 suspended, 4 not recovering, 5 toggle disallowed, 6 secure, 7 no target, 8 unsafe context, 9 Korean disabled, 10 source barrier busy
    var querySite:Int=0 // 0 unqueried, 1 legacy Korean, 2 external binding, 3 Hanja
    var queryStatus:Int=0 // 0 unqueried, 1 no current, 2 no list, 3 no target, 4 resolved, 5 current only
    var currentClass:Int=0;var targetClass:Int=0 // 0 unknown, 1 Korean, 2 English, 3 both, 4 other
    var availableCount:Int=0;var koreanCount:Int=0;var englishCount:Int=0
    var queryMicros:Int=0;var queryClipped:Bool=false
    struct Query:Codable,Equatable {
        let site:Int;let status:Int;let current:Int;let target:Int
        let available:Int;let korean:Int;let english:Int;let micros:Int;let clipped:Bool
    }
    // External resolution may fall through to one legacy query (ambiguous
    // device/default binding). Preserve that first read, never retry it.
    var priorQuery:Query?=nil
    static func begin(_ trace:InputIncidentTrace,_ type:CGEventType,_ event:CGEvent)->Self? {
        guard trace.enabled,!trace.secureInput() else{return nil}
        let key=event.getIntegerValueField(.keyboardEventKeycode)
        let disabled=type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        guard disabled || ([CGEventType.flagsChanged,.keyDown,.keyUp].contains(type) && (key==54 || key==61)) else{return nil}
        var value=Self();value.role=disabled ? 0:(key==54 ? 1:2)
        value.eventType=disabled ? 4:(type == .flagsChanged ? 1:(type == .keyDown ? 2:3))
        value.incomingFlags=value.flags(event.flags);return value
    }
    func flags(_ flags:CGEventFlags)->Int {
        let command=role != 2,raw=flags.rawValue
        return (raw & (command ? 0x08:0x20) != 0 ? 1:0) | (raw & (command ? 0x10:0x40) != 0 ? 2:0) | (flags.contains(command ? .maskCommand:.maskAlternate) ? 4:0)
    }
    mutating func filter(before:Int,after:Int,flags:CGEventFlags,accepted:Bool,edge:String?,consumed:Bool,matching:Bool) {
        filterMeasured=true;filterBefore=before;filterAfter=after;filterFlags=self.flags(flags)
        filterAccepted=accepted;filterEdge=edge=="right-down" ? 1:(edge=="right-up" ? 2:0);filterConsumed=consumed
        filterReason=filterEdge==1 ? 1:(filterEdge==2 ? 2:(!matching ? 7:(filterFlags & 2==0 ? 3:(before & 1 != 0 ? 4:(!accepted ? 5:6)))))
    }
    mutating func query(site:Int,status:Int,current:Int,target:Int=0,available:Int=0,korean:Int=0,english:Int=0,began:Double) {
        if queryStatus>0,priorQuery==nil {
            priorQuery=Query(site:querySite,status:queryStatus,current:currentClass,target:targetClass,available:availableCount,korean:koreanCount,english:englishCount,micros:queryMicros,clipped:queryClipped)
        }
        querySite=site;queryStatus=status;currentClass=current;targetClass=target;availableCount=available;koreanCount=korean;englishCount=english
        let elapsed=max(0,ProcessInfo.processInfo.systemUptime-began)*1_000_000
        queryMicros=Int(min(60_000_000,elapsed));queryClipped=elapsed>60_000_000
    }
}

struct InputIncidentPreferences {
    static let key="inputIncidentDiagnosticsEnabled"
    static let archiveBeforePruningKey="inputIncidentArchiveBeforePruning"
    static let boundedDirectoryKey="inputIncidentBoundedDirectory"
    static var defaultDirectory:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("HanQ Diagnostics",isDirectory:true).appendingPathComponent("InputIncidents",isDirectory:true)
    }
    typealias Launch=(directory:URL,enabled:Bool,persistent:Bool,preserve:Bool,bounded:Bool,valid:Bool,legacy:[URL])
    // Foundation leaves a dangling directory alias unresolved. Walk links even
    // when their target/suffix does not yet exist; this is a read-only preflight,
    // not authority to bypass the writer's ownership/no-follow checks.
    static func namespacePath(_ value:String)->String? {
        guard value.hasPrefix("/"),!value.contains("\0") else{return nil}
        var pending=value.split(separator:"/").map(String.init),parts:[String]=[],links=0
        while !pending.isEmpty {
            let next=pending.removeFirst()
            if next=="."{continue}
            if next==".."{if !parts.isEmpty{parts.removeLast()};continue}
            let path="/"+(parts+[next]).joined(separator:"/");var info=stat()
            if lstat(path,&info)==0 {
                if info.st_mode&S_IFMT==S_IFLNK {
                    links+=1
                    guard links<=40,let target=try? FileManager.default.destinationOfSymbolicLink(atPath:path) else{return nil}
                    if target.hasPrefix("/"){parts=[]}
                    pending=target.split(separator:"/").map(String.init)+pending
                    continue
                }
                if !pending.isEmpty,info.st_mode&S_IFMT != S_IFDIR{return nil}
            }else if errno != ENOENT{return nil}
            parts.append(next)
        }
        return "/"+parts.joined(separator:"/")
    }
    static func boundedNamespaceIsSeparate(_ directory:URL,shared:URL=defaultDirectory.deletingLastPathComponent())->Bool {
        guard let path=namespacePath(directory.path)?.lowercased(),let shared=namespacePath(shared.path)?.lowercased() else{return false}
        return path != shared && !path.hasPrefix(shared+"/") && !shared.hasPrefix(path=="/" ? "/":path+"/")
    }
    static let legacyDirectoriesKey="inputIncidentLegacyDirectories"
    static func legacyDirectories(defaults:UserDefaults)->[URL]? {
        var values:[String]=[]
        if let stored=defaults.object(forKey:legacyDirectoriesKey){
            guard let list=stored as? [String] else{return nil};values=list
        }
        if let old=defaults.object(forKey:boundedDirectoryKey){
            guard let path=old as? String else{return nil};values.append(path)
        }
        guard values.count<=32 else{return nil}
        var seen=Set<String>(),result:[URL]=[]
        for value in values {
            guard value.hasPrefix("/"),!value.contains("\0") else{return nil}
            // Accept the macOS system aliases used by older launch tools,
            // without accepting arbitrary links into a different namespace.
            let path=value.hasPrefix("/tmp/") || value.hasPrefix("/var/") ? "/private"+value:value
            let url=URL(fileURLWithPath:path)
            guard boundedNamespaceIsSeparate(url),namespacePath(path)==url.path else{return nil}
            if seen.insert(url.path).inserted{result.append(url)}
        }
        return result
    }
    @discardableResult static func commitLegacyMigration(defaults:UserDefaults,expected:[URL])->Bool {
        // Never erase a concurrently changed or malformed preference. Record
        // the old location durably before retiring its write-mode selector.
        guard defaults.object(forKey:boundedDirectoryKey) != nil else{return true}
        guard legacyDirectories(defaults:defaults)?.map(\.path)==expected.map(\.path) else{return false}
        let paths=expected.map(\.path)
        defaults.set(paths,forKey:legacyDirectoriesKey)
        guard defaults.synchronize(),defaults.stringArray(forKey:legacyDirectoriesKey)==paths else{return false}
        defaults.removeObject(forKey:boundedDirectoryKey)
        return defaults.synchronize() && defaults.object(forKey:boundedDirectoryKey)==nil
    }
    static func launch(arguments:[String],defaults:UserDefaults)->Launch {
        // Retired flags must fail explicitly, never turn a bounded investigation
        // into an unbounded preserve run or silently choose a different folder.
        if arguments.contains(where:{$0.hasPrefix("--bounded-input-incidents")}) {
            return (defaultDirectory,false,true,false,false,false,[])
        }
        if let i=arguments.firstIndex(of:"--preserve-input-incidents"),i+1<arguments.count,arguments[i+1].hasPrefix("/") {
            return (URL(fileURLWithPath:arguments[i+1]),true,true,true,false,true,[])
        }
        if let i=arguments.firstIndex(of:"--diagnose-input-incidents"),i+1<arguments.count,!arguments[i+1].hasPrefix("--") {
            return (URL(fileURLWithPath:arguments[i+1]),true,false,true,false,true,[])
        }
        guard let previous=legacyDirectories(defaults:defaults) else{return (defaultDirectory,false,true,false,false,false,[])}
        return (defaultDirectory,defaults.bool(forKey:key),true,false,false,true,previous)
    }

}

// Fixed semantic hints, never proof of an editor's independent document model.
// Only this value crosses the diagnostic queue. Unsupported is distinct from a
// negative match. Raw AX strings/objects remain on the existing snapshot path.
struct InputIncidentAXEvidence:Codable,Equatable {
    var valueClass:Int=0 // 0 unknown, 1 empty, 2 newline-only, 3 whitespace-only, 4 nonblank, 5 bounded prefix only (full whitespace classification skipped)
    var placeholder:Int=0 // 0 unmeasured, 1 unsupported/error, 2 empty, 3 differs, 4 matches trimmed value
    var label:Int=0 // same codes, title/description is only a hint
    var characterCount:Int=0 // 0 unmeasured, 1 unsupported/invalid, 2 agrees, 3 disagrees
    var representation:Int=0 // 0 unmeasured, 1 raw AX value agrees with verified representation, 2 differs
    var route:Int=0 // 0 unknown, 1 system focus, 2 frontmost application fallback, 3 changed within read
    var owner:Int=0;var window:Int=0 // anonymous tokens; 0 unmeasured/unavailable
    var fieldRelation:Int=0 // 0 first/unknown, 1 CFEqual, 2 different
    var windowRelation:Int=0 // 0 unknown, 1 CFEqual, 2 different
    var identityEpoch:Int=0 // bounded registry eviction/generation resets cannot imply continuity
    static func same(_ a:String,_ b:String)->Bool {CFStringCompare(a as CFString,b as CFString,CFStringCompareFlags(rawValue:0)) == .compareEqualTo}
    // Unicode White_Space; format characters such as U+200B are content.
    private static let whitespace=CharacterSet(charactersIn:"\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{0085}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}")
    private static let nonWhitespace=whitespace.inverted as CFCharacterSet
    private static let nonNewline=CharacterSet.newlines.inverted as CFCharacterSet
    static func classify(_ value:String)->Int {
        if value.isEmpty{return 1}
        let text=value as CFString,length=CFStringGetLength(text)
        let range=CFRange(location:0,length:min(length,4096))
        if CFStringFindCharacterFromSet(text,nonWhitespace,range,[],nil){return 4}
        // Never scan an arbitrarily large whitespace document in a callback.
        // A nonblank prefix proves class 4; a blank prefix proves nothing else.
        guard length<=4096 else{return 5}
        return CFStringFindCharacterFromSet(text,nonNewline,range,[],nil) ? 3:2
    }
    static func match(_ value:String,_ attributes:[String?])->Int {
        var trimmed:String?
        return match(value,attributes,trimmed:&trimmed)
    }
    private static func match(_ value:String,_ attributes:[String?],trimmed:inout String?)->Int {
        var available=false,meaningful=false
        for attribute in attributes {
            guard let attribute else{continue};available=true
            let candidate=attribute.trimmingCharacters(in:whitespace)
            guard !candidate.isEmpty else{continue};meaningful=true
            if trimmed==nil{trimmed=value.trimmingCharacters(in:whitespace)}
            if same(trimmed!,candidate){return 4}
        }
        return meaningful ? 3:(available ? 2:1)
    }
    static func attributes(_ list:[AnyObject],value:String,verified:String,route:Int)->(InputIncidentAXEvidence,AXUIElement?) {
        var result=InputIncidentAXEvidence();result.route=route;result.representation=same(value,verified) ? 1:2
        if list.count==9 {
            var trimmed:String?
            result.placeholder=match(value,[list[4] as? String],trimmed:&trimmed)
            result.label=match(value,[list[5] as? String,list[6] as? String],trimmed:&trimmed)
        }else{result.placeholder=1;result.label=1}
        result.characterCount=1
        if list.count==9,let number=list[7] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.intValue>=0,number.doubleValue==Double(number.intValue) {
            result.characterCount=number.intValue==value.utf16.count ? 2:3
        }
        let window:AXUIElement? = list.count==9 && CFGetTypeID(list[8])==AXUIElementGetTypeID() ? (list[8] as! AXUIElement):nil
        return (result,window)
    }

}

// Fixed focus observations from existing reads only. No role strings, AX objects,
// PIDs, coordinates or content cross the diagnostic queue.
enum InputIncidentMarkedRange: Int, Codable {
    case skipped = 0, unavailable, empty, active

    static func classify(_ value: CFTypeRef?) -> Self {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .unavailable }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return .unavailable }
        return range.length == 0 ? .empty : .active
    }

    var label: String {
        switch self {
        case .skipped: return "조회 생략"
        case .unavailable: return "미지원·조회 불가"
        case .empty: return "빈 범위"
        case .active: return "활성 범위"
        }
    }
}

struct InputIncidentAXResult:Codable,Equatable {
    var system:Int32?,application:Int32?,attributes:Int32?
    var hasFailure:Bool{[system,application,attributes].compactMap{$0}.contains{$0 != 0}}
    mutating func focus(_ route:Int,_ code:AXError) {
        if route==1 {if system==nil || code != .success{system=code.rawValue}}
        else if route==2 {if application==nil || code != .success{application=code.rawValue}}
    }
    mutating func attribute(_ code:AXError){if attributes==nil || code != .success{attributes=code.rawValue}}
}

struct InputIncidentFocusEvidence:Codable,Equatable {
    var markedRangeState: InputIncidentMarkedRange? = nil
    let path:Int // 1 onset, 2 synchronous mismatch, 3 idle mismatch worker
    let role:Int // 0 unmeasured, 1 unavailable, 2 text area, 3 text field, 4 combo, 5 web area, 6 group, 7 button, 8 window, 9 application, 10 other
    let route:Int // 0 unmeasured, 1 system, 2 application fallback
    let ownerRelation:Int // 0 unmeasured, 1 target, 2 other, 3 unavailable
    let elementRelation:Int // 0 unavailable, 1 first/after gap, 2 same, 3 changed (same path only)
    let withinRead:Int // 0 single, 1 same, 2 changed, 3 some focus unavailable
    static func role(_ value:String?)->Int {
        guard let value else{return 1}
        return ["AXTextArea":2,"AXTextField":3,"AXComboBox":4,"AXWebArea":5,"AXGroup":6,"AXButton":7,"AXWindow":8,"AXApplication":9][value] ?? 10
    }
}
// Owned by each existing snapshot execution context. At most one previous AX
// reference is retained; no registry, lock, IPC or global identity is introduced.
final class InputIncidentFocusProbe {
    private var previous:AXUIElement?
    private var generation:Int32=0
    struct Read {
        let target:pid_t
        init(target:pid_t){self.target=target}
        private(set) var first:AXUIElement?,last:AXUIElement?,subject:AXUIElement?
        private(set) var route=0,ownerRelation=0,role=0
        private var lastRoute=0,lastOwnerRelation=0,reads=0,changed=false,missing=false
        private var observedOwner:pid_t?,subjectOwner:pid_t?
        var applications:DiagnosticApplicationPIDs{.init(target:target,owner:subject==nil ? observedOwner:subjectOwner)}
        mutating func observe(_ element:AXUIElement?,owner:pid_t?,route:Int) {
            reads+=1
            if let element {
                if let first {if !CFEqual(first,element){changed=true}}else{first=element}
            }else{missing=true}
            last=element;lastRoute=route;lastOwnerRelation=owner.map{$0==target ? 1:2} ?? 3
            // Fallback can report a frontmost PID even when no AX element was
            // read. It is not evidence of an observed element's owner.
            observedOwner=element == nil ? nil:owner
            if subject==nil {self.route=lastRoute;ownerRelation=lastOwnerRelation}
        }
        mutating func observedRole(_ value:String?) {
            role=InputIncidentFocusEvidence.role(value)
            subject=last;route=lastRoute;ownerRelation=lastOwnerRelation
            subjectOwner=observedOwner
        }
        fileprivate var element:AXUIElement? {subject ?? first}
        fileprivate var withinRead:Int {changed ? 2:(missing ? 3:(reads>1 ? 1:0))}
        fileprivate var measured:Bool {reads>0}
    }
    func finish(_ read:Read?,generation:Int32,path:Int)->InputIncidentFocusEvidence? {
        if self.generation != generation {previous=nil;self.generation=generation}
        guard generation>0,let read,read.measured else{previous=nil;return nil}
        let element=read.element
        let relation=element.map{value in previous.map{CFEqual($0,value) ? 2:3} ?? 1} ?? 0
        previous=read.withinRead>=2 ? nil:element
        return InputIncidentFocusEvidence(path:path,role:read.role,route:read.route,ownerRelation:read.ownerRelation,elementRelation:relation,withinRead:read.withinRead)
    }
}

// Main-thread owned, bounded AX references. CFHash alone never establishes
// identity. Monotonic tokens are not hashes, PIDs, names or object addresses.
final class InputIncidentFieldRegistry {
    private var generation:Int32=0,epoch=0,next:UInt=0
    private var fields:[(AXUIElement,pid_t,UInt)]=[],windows:[(AXUIElement,UInt)]=[],owners:[pid_t:UInt]=[:]
    private func token()->UInt {next+=1;return next}
    func identify(_ element:AXUIElement,owner:pid_t,window:AXUIElement?,generation:Int32)->(UInt,Int,Int,Int) {
        if self.generation != generation || fields.count>=64 || windows.count>=64 || owners.count>=64 {
            fields=[];windows=[];owners=[:];self.generation=generation;epoch+=1
        }
        if owners[owner]==nil{owners[owner]=token()}
        let field:UInt
        if let old=fields.first(where:{$0.1==owner && CFEqual($0.0,element)}){field=old.2}
        else{field=token();fields.append((element,owner,field))}
        var windowToken:UInt=0
        if let window {
            if let old=windows.first(where:{CFEqual($0.0,window)}){windowToken=old.1}
            else{windowToken=token();windows.append((window,windowToken))}
        }
        return (field,Int(owners[owner]!),Int(windowToken),epoch)
    }
}

// Main-thread snapshot comparison only. One copy-on-write String reference per
// engine, never captured by a diagnostic closure or encoded. No extra AX read,
// content hash, cursor coordinate or raw text enters the trace. UTF-16 equality
// detects equal-length substitutions (including canonically equivalent strings).
// Main-thread-only comparison of existing AX snapshots. One bounded owned text
// value stays in RAM; only revision numbers leave this object. No content hash.
final class InputIncidentShapeCorrelation {
    private var text:String?,field:UInt?,generation:Int32=0,window=0,identityEpoch=0
    private var activity:Int64=0,revision=0,previous:Int?
    func reset(){text=nil;field=nil;previous=nil}
    #if HANQ_DIAGNOSTIC_TESTING
    var retainedUTF16ForTest:Int{text?.utf16.count ?? 0}
    #endif
    func observe(_ value:String,field:UInt,generation:Int32,window:Int,identityEpoch:Int,activity:Int64)->(revision:Int,previous:Int?)? {
        // Reject large values before creating an additional Foundation bridge.
        guard value.utf16.count<=8192 else{reset();return nil}
        let sameIdentity=self.field==field && self.generation==generation && self.identityEpoch==identityEpoch && self.activity==activity
        // A path that did not read AXWindow reports 0. Retain the last known
        // window for this exact field/context; two different known windows
        // still break continuity, including when unmeasured reads intervene.
        let sameContext=sameIdentity && (self.window==0 || window==0 || self.window==window)
        let resolvedWindow=sameContext && window==0 ? self.window:window
        let sameText=text.map{CFStringCompare($0 as CFString,value as CFString,CFStringCompareFlags(rawValue:0)) == .compareEqualTo} ?? false
        if !sameContext || !sameText {
            previous=sameContext && text != nil ? revision:nil
            revision+=1
            // Own the small value, never retain a slice of a large AX string.
            text=String(decoding:Array(value.utf8),as:UTF8.self)
            self.field=field;self.generation=generation;self.identityEpoch=identityEpoch;self.activity=activity
        }
        self.window=resolvedWindow
        return (revision,previous)
    }
}

struct InputIncidentShapeProbe {
    private var text:String?,selection:NSRange?,field:UInt?,generation:Int32=0
    private var sample=0
    private var sharedRevision:Int?
    private var valueClass=0,priorWindow=0,priorEpoch=0,caretPrecedingClass=0
    private static func sameContent(_ a:String,_ b:String)->Bool {
        // Literal CF comparison handles native and AX/NSString-backed storage
        // without a per-code-unit Swift loop or a diagnostic content hash.
        CFStringCompare(a as CFString,b as CFString,CFStringCompareFlags(rawValue:0)) == .compareEqualTo
    }
    mutating func reset(){text=nil;selection=nil;field=nil;generation=0;sample=0;valueClass=0;priorWindow=0;priorEpoch=0;caretPrecedingClass=0;sharedRevision=nil}
    // One UTF-16 unit from the already verified snapshot; never exports a character.
    static func precedingClass(_ text:String,_ selection:NSRange)->Int {
        guard selection.length==0,selection.location>0,selection.location<=text.utf16.count else{return 0}
        switch CFStringGetCharacterAtIndex(text as CFString,selection.location-1) {
        case 65...90,97...122:return 1 // ASCII letter
        case 0xAC00...0xD7A3:return 2 // Hangul syllable
        case 0x1100...0x11FF,0x3130...0x318F,0xA960...0xA97F,0xD7B0...0xD7FF:return 3 // Jamo
        case 9,10,13,32:return 4 // whitespace
        default:return 5
        }
    }
    mutating func observe(identity:UInt,text:String,selection:NSRange,generation:Int32,ax:InputIncidentAXEvidence?=nil,correlation:InputIncidentShapeCorrelation?=nil,activity:Int64=0)->InputIncidentTrace.ShapeChange {
        if self.generation != generation{reset();self.generation=generation}
        let sameField=field==identity && self.text != nil
        let changedWindow=priorWindow>0 && (ax?.window ?? 0)>0 && priorWindow != ax!.window
        let known=sameField && !changedWindow
        let content=known && !Self.sameContent(self.text!,text)
        let cursor=known && self.selection != selection
        let motion:Int
        if !known{motion=0}
        else if !cursor{motion=1}
        else {
            // Only range scalars from existing snapshots; no scan on unchanged polling.
            let count=CFStringGetLength(text as CFString),priorCount=CFStringGetLength(self.text! as CFString)
            let valid=selection.location>=0 && selection.length>=0 && selection.location<=count && selection.length<=count-selection.location
            let prior=self.selection!
            let priorValid=prior.location>=0 && prior.length>=0 && prior.location<=priorCount && prior.length<=priorCount-prior.location
            if !valid || !priorValid{motion=7}
            else if prior.length==0 && selection.length>0{motion=4}
            else if prior.length>0 && selection.length==0{motion=5}
            else if selection.length>0{motion=6}
            else{motion=selection.location<prior.location ? 2:3}
        }
        var evidence=ax
        if evidence != nil {
            if valueClass==0 || !known || content{valueClass=InputIncidentAXEvidence.classify(text)}
            evidence!.valueClass=valueClass
            evidence!.fieldRelation=field==nil || priorEpoch != evidence!.identityEpoch ? 0:(sameField ? 1:2)
            priorEpoch=evidence!.identityEpoch
            let window=evidence!.window
            evidence!.windowRelation=priorWindow==0 || window==0 ? 0:(priorWindow==window ? 1:2)
            priorWindow=window
        }
        if !known || content || cursor{caretPrecedingClass=Self.precedingClass(text,selection)}
        let shared=correlation?.observe(text,field:identity,generation:generation,window:ax?.window ?? 0,identityEpoch:ax?.identityEpoch ?? 0,activity:activity)
        let transition=known && content && sharedRevision != nil && sharedRevision==shared?.previous ? shared?.revision:nil
        sharedRevision=shared?.revision
        sample+=1;self.text=text;self.selection=selection;field=identity
        return .init(sample:sample,known:known,content:content,selection:cursor,ax:evidence,caretPrecedingClass:caretPrecedingClass,selectionMotion:motion,transitionID:transition)
    }
}

// Typed, bounded incident metadata. Never accepts text, keycodes, clipboard,
// application names or arbitrary log messages. Capture is deliberately lossy:
// input callbacks never wait for the diagnostic lock or filesystem.
final class InputIncidentTrace {
    let fieldRegistry=InputIncidentFieldRegistry()
    let shapeCorrelation=InputIncidentShapeCorrelation()
    private var activitySequence:Int64=0
    var activityEpoch:Int64 {OSAtomicAdd64Barrier(0,&activitySequence)}
    private func noteActivity(){OSAtomicIncrement64Barrier(&activitySequence)}
    enum Lane:Int,Codable {case hid=1,main,onset,mismatch,boundary,onsetAX,mismatchAX,sourceBoundary}
    enum Kind:Int,Codable {case event=1,read,shape,marker,context,state,sourceBoundary,detectionDecision,observationWait,sourceEvidence,controlDecision,hud,onsetDecision,boundaryComparison,onsetObservation,modifierArrival}

    enum ModifierRole: Int {
        case shift = 1, rightCommand, rightOption

        init?(event: CGEvent) {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 56, 60: self = .shift
            case 54: self = .rightCommand
            case 61: self = .rightOption
            default: return nil
            }
        }

        var label: String {
            switch self {
            case .shift: return "Shift"
            case .rightCommand: return "우측 Command"
            case .rightOption: return "우측 Option"
            }
        }
    }

    enum ModifierStage: Int, Codable {
        case recipientHID = 1, switchHID, main

        var lane: Lane { self == .main ? .main : .hid }
        var label: String {
            switch self {
            case .recipientHID: return "수신 앱 확인 입구"
            case .switchHID: return "전환 감시 입구"
            case .main: return "본체 입력 처리 입구"
            }
        }
    }
    // AX samples only. Native input callbacks, DOM transactions and replacement
    // ranges are not observable from this process; coverage 1 states that limit.
    struct OnsetRuntime:Codable,Equatable {
        var receiverCoverage=1
        var markedResult=0 // 0 not read, 1 range, 2 unsupported, 3 cannotComplete, 4 noValue, 5 malformed, 6 other error
        var readOutcome=0,marked=0,markedTransition=0,markedAnchor=0,focusRelation=0
        var publicationWindow=0,publicationProof=0
        var observedKeys=0,heldKeys=0,pending=0,retainedCurrent=0,retainedPrevious=0,prefix=0
        var valueSubscription=0,selectionSubscription=0
        static let keys=Set(["markedResult","receiverCoverage","readOutcome","marked","markedTransition","markedAnchor","focusRelation","publicationWindow","publicationProof","observedKeys","heldKeys","pending","retainedCurrent","retainedPrevious","prefix","valueSubscription","selectionSubscription"])
        var valid:Bool {
            receiverCoverage==1 && (0...6).contains(markedResult) && (0...17).contains(readOutcome) && (0...3).contains(marked) &&
            (0...4).contains(markedTransition) && (0...3).contains(markedAnchor) && (0...3).contains(focusRelation) &&
            (1...2).contains(publicationWindow) && (0...2).contains(publicationProof) &&
            [observedKeys,heldKeys,pending,retainedCurrent,retainedPrevious,prefix].allSatisfy{(0...65535).contains($0)} &&
            (0...2).contains(valueSubscription) && (0...2).contains(selectionSubscription) &&
            (markedAnchor==0 || marked==3) &&
            (markedTransition==0 || (focusRelation==2 && (2...3).contains(marked))) &&
            (![1,4].contains(markedTransition) || marked==2) &&
            (![2,3].contains(markedTransition) || marked==3)
        }
        static func parse(_ object:[String:Any])->Self? {
            guard Set(object.keys)==keys,object.values.allSatisfy({value in
                guard let n=value as? NSNumber else{return false}
                return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue==Double(n.intValue)
            }),let data=try? JSONSerialization.data(withJSONObject:object),let value=try? JSONDecoder().decode(Self.self,from:data),value.valid else{return nil}
            return value
        }
        var summary:String {
            let results=["미측정","범위 조회됨","속성 미지원","조회 완료 불가","값 없음","범위 형식 오류","기타 조회 오류"]
            let marks=["판정 생략","미지원·조회 불가","빈 범위","활성 범위"]
            return "AX 조합 \(marks[marked])/\(results[markedResult]) · 첫 표시 기한 \(publicationWindow==1 ? "이내":"초과") · 통과 키 \(observedKeys)/누름 \(heldKeys) · 현재 보관 \(retainedCurrent)/이전 보관 \(retainedPrevious) · 편집기 내부 콜백 미관측"
        }
    }

    struct OnsetObservation:Codable,Equatable {
        // Fixed comparisons, not insertion provenance. No text, key values,
        // positions, hashes, application names or editor transaction payloads.
        var episode,phase,reason,keys,baseline,history,whole,draft,insertion,selection,unicode,samples,coalesced:Int
        var firstKeyAgeMicros:Int
        var firstEventTimestampMicros:Int
        var baselineAgeMicros:Int?
        var insertionEndRelation: Int? = nil
        var runtime: OnsetRuntime? = nil
        static let required=Set(["episode","phase","reason","keys","baseline","history","whole","draft","insertion","selection","unicode","samples","coalesced","firstKeyAgeMicros","firstEventTimestampMicros"])
        var valid:Bool {
            (1...1_000_000_000).contains(episode) && (1...3).contains(phase) &&
            (phase==1 ? reason==0:(phase==2 ? (1...4).contains(reason):(1...6).contains(reason))) &&
            (1...2).contains(keys) && (0...4).contains(baseline) && (1...2).contains(history) &&
            (0...7).contains(whole) && (0...3).contains(draft) && (0...7).contains(insertion) &&
            (0...5).contains(selection) && (0...6).contains(unicode) &&
            (1...1_000_000).contains(samples) && (0...samples).contains(coalesced) &&
            (0...60_000_000).contains(firstKeyAgeMicros) && (0...9_000_000_000_000_000).contains(firstEventTimestampMicros) &&
            (baselineAgeMicros.map{(0...60_000_000).contains($0)} ?? true) &&
            ((baseline==2 || baseline==3) == (baselineAgeMicros != nil)) &&
            (draft==2 || insertion==0) && (runtime?.valid ?? true) &&
            (insertionEndRelation.map { (0...3).contains($0) && ($0 == 0 || (draft == 2 && (1...3).contains(selection))) } ?? true)
        }
        func sameState(_ other:Self)->Bool {
            var a=self,b=other
            a.samples=0;b.samples=0;a.coalesced=0;b.coalesced=0
            a.firstKeyAgeMicros=0;b.firstKeyAgeMicros=0
            return a==b
        }
        static func parse(_ object:[String:Any])->Self? {
            if let raw=object["runtime"] {
                guard let fields=raw as? [String:Any],OnsetRuntime.parse(fields) != nil else{return nil}
            }
            guard Set(object.keys).subtracting(["baselineAgeMicros", "insertionEndRelation", "runtime"])==required,object.filter({$0.key != "runtime"}).values.allSatisfy({value in
                guard let n=value as? NSNumber else{return false}
                return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue==Double(n.intValue)
            }),let data=try? JSONSerialization.data(withJSONObject:object),let value=try? JSONDecoder().decode(Self.self,from:data),value.valid else{return nil}
            return value
        }
        var summary:String {
            let relation=["미측정","첫 키와 전체 일치","분리된 첫 두 키와 전체 일치","조합된 첫 두 키와 전체 일치","첫 키와 앞부분 일치","분리된 첫 두 키와 앞부분 일치","조합된 첫 두 키와 앞부분 일치","불일치"]
            let prior=["미확인","기록 없음","입력 전 기록 있음","입력 전 기록 오래됨","입력 후 기록만 있음"]
            let ends = ["판정 불가", "삽입 끝", "삽입 끝보다 한 UTF-16 단위 뒤", "그 밖의 위치"]
            let caret = insertionEndRelation.map { " · 커서 " + ends[$0] } ?? ""
            return "첫 입력 관측 #\(episode): 기준 \(prior[baseline]), 본문 \(relation[whole]), 추가 범위 \(relation[insertion])\(caret) · 삽입 주체 미확인" + (runtime.map{" · " + $0.summary} ?? "")
        }
    }
    struct BoundaryEvidence:Codable,Equatable {
        // Fixed relations only: never positions, selection lengths, body, keys or hashes.
        // phase: request/comparison/end; reason: none/success/deadline/context/other.
        var transaction,phase,reason,text,start,end,expected,reported,change,resolution:Int
        var seed,mutation,revision,observations,suppressed,coalesced,fieldRelation:Int
        var baselineAgeMicros,mutationAgeMicros,requestAgeMicros,sampleAgeMicros:Int?
        static let required=Set(["transaction","phase","reason","text","start","end","expected","reported","change","resolution","seed","mutation","revision","observations","suppressed","coalesced","fieldRelation"])
        static let ages=Set(["baselineAgeMicros","mutationAgeMicros","requestAgeMicros","sampleAgeMicros"])
        var valid:Bool {
            (1...1_000_000_000).contains(transaction) && (1...3).contains(phase) && (0...4).contains(reason) &&
            ((phase==3) == (reason>0)) && (0...5).contains(text) && (0...3).contains(start) && (0...3).contains(end) &&
            (0...2).contains(expected) && (0...2).contains(reported) && (0...4).contains(change) && (0...5).contains(resolution) &&
            (0...13).contains(seed) && (0...13).contains(mutation) && (0...2).contains(fieldRelation) &&
            [revision,observations,suppressed,coalesced].allSatisfy{(0...1_000_000).contains($0)} &&
            [baselineAgeMicros,mutationAgeMicros,requestAgeMicros,sampleAgeMicros].allSatisfy{$0.map{(0...60_000_000).contains($0)} ?? true} &&
            (phase != 1 || (observations==0 && text==0 && resolution==0)) &&
            (!(1...4).contains(resolution) || (fieldRelation==1 && (1...4).contains(text) && start==2 && end==2 && expected>0 && expected==reported))
        }
        var resolutionLabel:String {
            ["판단 근거 미확인","현재 비교 일치","예측 유지 중 앱 보고가 일치값에 도달","앱 보고 유지 중 예측이 일치값으로 변경","양쪽 변경 뒤 일치","불일치 지속·원인 미확정"][resolution]
        }
        static func parse(_ object:[String:Any])->Self? {
            guard Set(object.keys).subtracting(ages)==required,object.values.allSatisfy({value in
                guard let number=value as? NSNumber else{return false}
                return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue==Double(number.intValue)
            }),let data=try? JSONSerialization.data(withJSONObject:object),let value=try? JSONDecoder().decode(Self.self,from:data),value.valid else{return nil}
            return value
        }
    }
    enum OnsetSite:Int {case reservation=1,publication,history,claim}
    enum OnsetReason:Int {
        case baselineMissing=1,baselineAvailable,publicationBlocked,sourceChanged,representationMissing,representationUnchanged
        case publicationDeadline,historySize,layoutUnavailable,firstBodyMismatch,partialPrefixWaiting,publicationObserved
        case proofCurrent,proofUnavailable,historyWaiting,historyComplete,historyRejected,historyCandidate,keysStillDown
        case claimRejected,claimAccepted,guardFailed,fieldChanged,reservationReleased,selectionNotWritable
        case settledPrefixObserved,settledPrefixUnconfirmed
    }
    // Branch outcomes only; no identifiers, event timestamps, text or cursor positions.
    enum SwitchKeyCheck:Int {case unmeasured, matched, noSwitch, timestampMissing, firstNotSeen, firstDiffers, expired, appChanged, originalWindowMissing, currentWindowMissing, windowChanged, layoutNotReady, firstWindowMissing, firstWindowChanged, matchedPreSwitchWindow
        var allowsReplay:Bool {self == .matched || self == .matchedPreSwitchWindow}
    }
    enum DraftRead:Int {case unmeasured, recorded, attributesUnavailable, roleUnavailable, textUnavailable, textTooLarge, notEnabled, visibilityUnproven, windowUnproven, selectionUnreadable, contextUnproven, caretUnproven, deadline, observerMissing}
    enum DraftLookup:Int {case unmeasured, entry, outside, noFieldRecord, noPreKeyRecord, expired, windowUnavailable, windowChanged, unusable}
    enum InsertedSpan:Int {case unmeasured, anchorOrRangeInvalid, notRomanFirst, surroundingsChanged, keysDiffer, partial, matched}
    struct OnsetDetail:Codable {
        // Fixed branch outcomes only. Observation age is capped at 60s.
        let discovery,representation,lookup,history:Int
        let observationAgeMicros:Int?
        // All four are omitted in older captures / unrelated decisions.
        var switchKey:Int?,draftRead:Int?,draftLookup:Int?,insertedSpan:Int?
        var signature:Int {
            let base=(((discovery*14+representation)*13+lookup)*9+history)+1
            guard let key=switchKey,let read=draftRead,let stored=draftLookup,let span=insertedSpan else{return base}
            return 65536+(((base*15+key)*14+read)*9+stored)*7+span
        }
    }
    struct OnsetEvidence:Codable {
        // 0 keys = unmeasured. nil age = no first-key clock or out of range.
        let keys:Int
        let firstKeyAgeMicros:Int?
        var detail:OnsetDetail?=nil
    }
    enum HUDStage:Int {case requested=1,ordered,firstDraw,suppressed,unavailable}
    struct EventEvidence:Codable {
        let observedAtMicros:Int;let timestampMicros:Int;let keyClass:Int
        var creatorClass:Int?=nil // 1 unreported, 2 this HanQ, 3 another PID; never hardware proof
        var autoRepeat:Bool?=nil
        // Physical classes only. No letter identity, Unicode payload or raw flags.
        init(time:Double,origin:Double,type:CGEventType,event:CGEvent) {
            observedAtMicros=Int(max(0,min((time-origin)*1_000_000,9_000_000_000_000_000)))
            timestampMicros=Int(min(event.timestamp/1000,9_000_000_000_000_000))
            if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type){keyClass=5}
            else if type == .flagsChanged{keyClass=4}
            else {switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 49:keyClass=1 // space
            case 0...9,11...17,31,32,34,35,37,38,40,45,46:keyClass=2 // letter position
            case 36,48,51,53,76,117,123...126:keyClass=3 // editing/navigation
            default:keyClass=6 // other
            }}
            if keyClass==1 || keyClass==2 {
                let creator=event.getIntegerValueField(.eventSourceUnixProcessID)
                creatorClass=creator<=0 ? 1:(creator==Int64(getpid()) ? 2:3)
                autoRepeat=event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            }
        }
    }
    // Append-only fixed codes. No source IDs, key values or arbitrary messages.
    enum DecisionSite:Int {case event=1,sample,eligibility,handoff,repair}
    enum DecisionReason:Int {
        case romanSource=1,observationBlocked,preSwitchKey,snapshotUnavailable
        case candidateRejectedKey,candidateCancelledNavigation,candidateRecorded,noCandidate,candidateExpired,candidateTextMismatch
        case repairBlocked,repairSourceUnsupported,repairTextMismatch,selectionNotWritable
        case handoffBusy,handoffNotReady,handoffExternalEdit,handoffSelection,handoffField,handoffSource,handoffBoundary
        case handoffNoHistory,handoffExpired,handoffTextMismatch,handoffAccepted
        case manualEdit,keyboardCapture,onsetRepair,onsetReservation
        case handoffUninitialized,observationAllowed
    }
    enum Trigger:Int,Codable,CaseIterable {case manual=1,callbackDelay,axDelay,possibleShrink,boundaryInterrupted,recoveryStarted,spaceObservation,onsetObservation}
    enum BoundaryStage:Int {
        case waiting=1,queued,onsetWaiting,onsetConfirmed,onsetRetimed,retained,finished,deadline,focusChanged,failed,selection,sourceCommitted
        case snapshotWait,textWait,caretWait,repairWait,repairReceiptWait,onsetReceiptWait,replayReceiptWait,focusWait,selectionCommitWait,sourceCommitWait
        case inputResumed,editorStyleMatched,terminalLFMatched,terminalLFStyleMatched,pendingTextPrefix,sourceInitialBodyRemoved
        case manualEditStarted,manualEditVerified,manualEditUnverified
        case initialLayoutWait,initialLayoutReady,initialLayoutDeadline,initialContextChanged,initialSourceChanged,initialNativeBatchObserved,initialOriginalResumed
        case unfocusedLayoutConflict,unfocusedLayoutReady,unfocusedLayoutUnknown,unfocusedSourceChanged
        case initialTransportCompleted,editorDivergedInputResumed,nativeSelectAllDivergedInputResumed
        static func event(_ stage:String)->BoundaryStage? {
            switch stage {
            case "initial_original_resumed":return .initialOriginalResumed
            case "initial_native_batch_observed":return .initialNativeBatchObserved
            case "initial_layout_wait":return .initialLayoutWait
            case "initial_layout_ready":return .initialLayoutReady
            case "initial_layout_deadline":return .initialLayoutDeadline
            case "initial_context_changed":return .initialContextChanged
            case "initial_source_changed":return .initialSourceChanged
            case "manual_edit_started":return .manualEditStarted
            case "manual_edit_verified":return .manualEditVerified
            case "manual_edit_unverified":return .manualEditUnverified
            case "waiting_for_editor","waiting_for_select_all","select_all_waiting_for_repair":return .waiting
            case "key_queued":return .queued
            case "onset_delivery_waiting":return .onsetWaiting
            case "onset_delivery_confirmed":return .onsetConfirmed
            case "onset_delivery_retimed":return .onsetRetimed
            case "finished":return .finished
            case "deadline","repair_deadline":return .deadline
            case "focus_changed","recipient_changed":return .focusChanged
            case "delivery_limit","buffer_limit","context_interrupted","repair_not_verified","select_all_failed","select_all_commit_failed","switch_failed","allocation","input_stopped":return .failed
            case "select_all_applied","select_all_retried","select_all_committed":return .selection
            case "editor_confirmed_switch":return .sourceCommitted
            case "waiting_for_snapshot":return .snapshotWait
            case "waiting_for_text":return .textWait
            case "waiting_for_caret":return .caretWait
            case "waiting_for_repair":return .repairWait
            case "waiting_for_repair_receipt":return .repairReceiptWait
            case "waiting_for_onset_receipt":return .onsetReceiptWait
            case "waiting_for_replay_receipt":return .replayReceiptWait
            case "waiting_for_focus":return .focusWait
            case "waiting_for_selection_commit":return .selectionCommitWait
            case "waiting_for_source_commit":return .sourceCommitWait
            case "initial_transport_completed":return .initialTransportCompleted
            case "editor_diverged_input_resumed":return .editorDivergedInputResumed
            case "native_select_all_diverged_input_resumed":return .nativeSelectAllDivergedInputResumed
            case "editor_insertion_style_matched":return .editorStyleMatched
            case "editor_terminal_lf_matched":return .terminalLFMatched
            case "editor_terminal_lf_style_matched":return .terminalLFStyleMatched
            case "editor_text_prefix_pending":return .pendingTextPrefix
            case "source_initial_body_removed":return .sourceInitialBodyRemoved
            default:return nil
            }
        }
    }
    // Fixed detector branches, not root-cause or editor/IME truth assertions.
    enum RecoveryReason:Int {
        case romanMismatch=1,mixedInsertion,decomposedJamo,interruptedComposition,fragmentedComposition,verifiedReplacement
        case firstConsonant,lateSequence,committedLateSequence,unspecifiedMismatch
    }
    enum State:Int {
        case repairStarted=1,selection,replay,retained,finished,stopped,sourceChanged,buffered
        case focusCandidateUnavailable,focusSceneClipped,focusMultipleEditors,focusSceneScanning,focusGuardRejected,focusRequestUnconfirmed,focusConfirmed
        static func event(_ event:String)->State? {
            switch event {
            case "repair_started","mismatch_confirmed":return .repairStarted
            case "selection_requested":return .selection
            case "replay_started":return .replay
            case "pending_retained":return .retained
            case "recovery_finished":return .finished
            case "session_end":return .stopped
            case "source_change":return .sourceChanged
            case "key_buffered":return .buffered
            default:return nil
            }
        }
    }
    struct DecisionTiming:Codable {
        let queueMicros:Int;let lockWaitMicros:Int;let contended:Bool;let clipped:Bool
    }
    // Fixed lifecycle values, independent of input text and process identifiers.
    struct MonitorSample:Codable,Equatable {
        var observedAtMilliseconds=0
        var stage=0,reason=0,tapState=0
        var active=false,enabled=false,suspended=false,recovering=false,rollingBack=false,restartAllowed=false
        var pending=0,retained=0,attempts=0,failures=0,failureKind=0,stopReason=0,receivedEvents=0
        var lastEventAgeMicros:Int?=nil
        func sameState(as other:Self)->Bool {
            var left=self,right=other
            left.observedAtMilliseconds=0;right.observedAtMilliseconds=0
            left.lastEventAgeMicros=nil;right.lastEventAgeMicros=nil
            left.receivedEvents=0;right.receivedEvents=0
            return left==right
        }
    }
    struct MonitorStatus:Codable {var current:MonitorSample;var transitions:[MonitorSample];var discardedTransitions=0}
    struct DecisionWaitStats:Codable {
        var processed=0,contended=0,totalLockWaitMicros=0,maxLockWaitMicros=0,maxQueueMicros=0,clipped=0
    }
    enum SourceEvidenceAction:Int {case observed=1,requested,committed,deferred,resumed,rejected,romanSkipped}
    struct SourceEvidence:Codable {
        let selected:Int;let confirmed:Int;let target:Int
        let observedAtMilliseconds:Int;let targetEventMilliseconds:Int?;let ageClipped:Bool
        let confirmedAtMilliseconds:Int?;let targetAtMilliseconds:Int?
        let confirmedAgeMicros:Int?;let targetAgeMicros:Int?
        let committed:Bool;let deferred:Bool;let candidatePreserved:Bool;let historyPreserved:Bool
    }
    // Wall bounds and same-thread CPU only. Never stores a thread ID or event payload.
    struct WorkEvidence:Codable {
        let beganAtMicros:Int;let endedAtMicros:Int;let clockValid:Bool
        let cpuState:Int // 0 unmeasured(AX), 1 measured, 2 unavailable, 3 other thread, 4 counter reversed, 5 invalid wall
        let cpuMicros:Int?
        var checkpoints:[CallbackCheckpoint]?=nil
        var routingCheckpoints:[CallbackCheckpoint]?=nil
    }
    struct CallbackCheckpoint:Codable {
        let stage:Int,elapsedMicros:Int,cpuState:Int
        let cpuMicros:Int?
    }
    enum CallbackStage:Int {
        case processing=1,recipient,candidate,barrier,external,filters,routing,diagnostics
    }
    enum RoutingStage:Int {case source=1,focus,snapshot,ledger,delivery}
    static func callbackThreadCPU()->UInt64? {
        var value=timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID,&value)==0,value.tv_sec>=0,value.tv_nsec>=0 else{return nil}
        return UInt64(value.tv_sec)*1_000_000_000+UInt64(value.tv_nsec)
    }
    struct CallbackStart {
        fileprivate let began:Double,cpu:UInt64?,thread:pthread_t,generation:Int32
        fileprivate var checkpoints:[CallbackCheckpoint]=[]
        fileprivate var routingCheckpoints:[CallbackCheckpoint]=[]
    }
    private func workEvidence(began:Double,ended:Double,cpuState:Int=0,cpuMicros:Int?=nil)->WorkEvidence {
        let valid=began.isFinite && ended.isFinite && began>=origin && ended>=began && (ended-origin)*1_000_000<=9_000_000_000_000_000
        return WorkEvidence(beganAtMicros:valid ? Int((began-origin)*1_000_000):0,endedAtMicros:valid ? Int((ended-origin)*1_000_000):0,clockValid:valid,cpuState:valid ? cpuState:5,cpuMicros:valid ? cpuMicros:nil)
    }
    // Key down/up only. OFF/secure input returns before either clock.
    func beginCallback(_ type:CGEventType)->CallbackStart? {
        let generation=gate.generation
        guard generation>0,(type == .keyDown || type == .keyUp),!secureInput() else{return nil}
        let began=clock(),cpu=callbackCPU()
        return CallbackStart(began:began,cpu:cpu,thread:pthread_self(),generation:generation)
    }
    private func finishCallback(_ span:CallbackStart?)->WorkEvidence? {
        guard let span,gate.generation==span.generation else{return nil}
        let same=pthread_equal(span.thread,pthread_self()) != 0
        let endCPU=same ? callbackCPU():nil,ended=clock()
        var state=2,value:Int?
        if !same{state=3}
        else if let start=span.cpu,let end=endCPU {
            if end>=start{state=1;value=Int(min((end-start)/1000,9_000_000_000_000_000))}else{state=4}
        }
        var result=workEvidence(began:span.began,ended:ended,cpuState:state,cpuMicros:value)
        result.checkpoints=span.checkpoints.isEmpty ? nil:span.checkpoints
        result.routingCheckpoints=span.routingCheckpoints.isEmpty ? nil:span.routingCheckpoints
        return result
    }
    // Fixed main-callback boundaries, no input payload, lookup, queue or file I/O.
    // Cumulative points include instrumentation cost. Missing stages mean an
    // early return, not zero work. CPU complements wall time; it cannot identify
    // a particular lock or prove OS/IME scheduling as the cause of a wait.
    func checkpoint(_ stage:CallbackStage,_ span:inout CallbackStart?) {
        guard let current=span,gate.generation==current.generation,
              stage.rawValue>(current.checkpoints.last?.stage ?? 0),
              let work=finishCallback(current) else{return}
        span?.checkpoints.append(CallbackCheckpoint(stage:stage.rawValue,
            elapsedMicros:work.clockValid ? work.endedAtMicros-work.beganAtMicros:0,
            cpuState:work.cpuState,cpuMicros:work.cpuMicros))
    }
    // Nested routing points use the same callback origin, thread and privacy gate.
    // They never replace the stable outer stage codes.
    func routingCheckpoint(_ stage:RoutingStage,_ span:inout CallbackStart?) {
        guard let current=span,gate.generation==current.generation,!secureInput(),
              stage.rawValue>(current.routingCheckpoints.last?.stage ?? 0),
              let work=finishCallback(current) else{return}
        span?.routingCheckpoints.append(CallbackCheckpoint(stage:stage.rawValue,
            elapsedMicros:work.clockValid ? work.endedAtMicros-work.beganAtMicros:0,
            cpuState:work.cpuState,cpuMicros:work.cpuMicros))
    }
    struct ShapeChange {let sample:Int;let known:Bool;let content:Bool;let selection:Bool;var ax:InputIncidentAXEvidence?=nil;var caretPrecedingClass:Int?=nil;var selectionMotion:Int?=nil;var transitionID:Int?=nil}
    struct ShapeEvidence:Codable {
        // phase 1=new baseline, 2=checkpoint/current capture, 3=closed span.
        let phase:Int;let comparisonKnown:Bool;let contentChanged:Bool;let selectionChanged:Bool
        let editingChanged:Bool;let gap:Bool;let editing:Bool
        var firstMilliseconds:Int;var lastMilliseconds:Int;var observations:Int;var coalesced:Int
        var baselineSequence:Int
        var ax:InputIncidentAXEvidence?=nil
        var caretPrecedingClass:Int?=nil
        var selectionMotion:Int?=nil
        var applications:DiagnosticApplicationReferences?=nil
    }
    struct ShapePoint:Codable {let field:Int;let count:Int;let selected:Bool;var evidence:ShapeEvidence}
    struct ShapeBaseline:Codable {let lane:Lane;let active:Bool;let current:ShapePoint;let previous:ShapePoint?}
    struct Frame:Codable {
        let sequence:Int;var milliseconds:Int;let lane:Lane;let kind:Kind
        let event:Int;let edge:Int;let category:Int;let inputOrigin:Int;let consumed:Bool
        let durationMicros:Int;let count:Int;let selected:Bool;let field:Int
        let decisionTiming:DecisionTiming?
        let observationTiming:DecisionTiming?
        var sourceEvidence:SourceEvidence?=nil
        var shapeEvidence:ShapeEvidence?=nil
        var modifierStage:ModifierStage?=nil
        var controlEvidence:InputIncidentControl?=nil
        var eventEvidence:EventEvidence?=nil
        var workEvidence:WorkEvidence?=nil
        var readOutcome:ReadOutcome?=nil
        var focusEvidence:InputIncidentFocusEvidence?=nil
        var onsetEvidence:OnsetEvidence?=nil
        var boundaryEvidence:BoundaryEvidence?=nil
        var onsetObservation:OnsetObservation?=nil
        var applications:DiagnosticApplicationReferences?=nil
    }
    struct DecisionDelivery:Codable {let capacity:Int;let overflow:[Int:Int];let waits:[Int:DecisionWaitStats];var coalesced:[Int:Int]?=nil}
    // Fixed code: ((operation-1)*8+(lane-1))*32+detail. No arbitrary payload.
    enum Observation:Int {case event=1,readStart,readEnd,shape,state,context,boundary,marker,timer,capture}
    struct ObservationDelivery:Codable {
        let capacity:Int;let readCapacity:Int
        let processed:[Int:Int];let overflow:[Int:Int];let omitted:[Int:Int];let coalesced:[Int:Int]
        let waits:[Int:DecisionWaitStats]
    }
    struct CaptureRequest:Codable {
        let trigger:Int;let milliseconds:Int;let afterSequence:Int
        let lane:Int;let detail:Int;let event:Int;let inputOrigin:Int
        var requestID:String?=nil
        var correlationID:String?=nil
    }
    struct CapturePreservation:Codable {
        let deferred:Bool;let requests:[CaptureRequest]
        let postCapacity:Int;let postOmittedFrames:Int;let closed:Bool;let closedMilliseconds:Int?;let endedOnShutdown:Bool
    }
    struct CaptureBacklog:Codable {
        let automaticCapacity:Int;let manualCapacity:Int;let requestCapacityPerTrigger:Int;let requestsPerWindow:Int
        let pendingAutomatic:Int;let pendingManual:Int
        let requested:[Int:Int];let merged:[Int:Int];let deferred:[Int:Int]
        let requestOverflow:[Int:Int];let windowOverflow:[Int:Int];let postOverflow:[Int:Int];let discardedOnDisable:[Int:Int]
        let submittedWindows:Int;let completedWindows:Int
        var rateSuppressed:[Int:Int]?=nil
    }
    // Codes are persisted. Append new entries to preserve older recordings.
    struct RecoveryFailure:Codable {
        let milliseconds:Int, action:Int, stage:Int, condition:Int
        static let stages=[
            "unknown", "activation", "attemptRollback", "awaitKorean",
            "awaitSelection", "beginSourceMenu", "buffer_verification", "composition_resume",
            "cycleAndReplay", "deferRecovery", "delivery", "drain",
            "followFrontmost", "korean_verification", "pollExternalSource", "potentialCapsSourceSwitch",
            "pre_edit", "prepareFinalActivation", "processEvent", "recoverySnapshot",
            "releaseReplayHolds", "repairBufferedRoman", "replaceAndReplay", "replayCandidate",
            "replayPacedCandidate", "requestRecoverySnapshot", "restoreInterruptedSource", "resumeKoreanAfterSourceRestore",
            "resumeMenuAfterSelection", "retryKorean", "retry_korean", "rollback",
            "sample", "selection", "setUserSourceIntent", "source_wait",
            "stop", "suspend", "switchTarget", "verifyBuffered",
            "waitSource", "safariModifierRelease", "safariInputActivation",
            "safariReturnSelection", "onset.attemptRollback", "onset.automaticTick", "onset.awaitCompositionCommit",
            "onset.awaitPrefix", "onset.awaitSelection", "onset.beginCommittedCaretRestoration", "onset.beginRecovery",
            "onset.commitConsonantComposition", "onset.drain", "onset.event", "onset.finishCommittedReplacement",
            "onset.gateAcknowledged", "onset.pauseForContext", "onset.post", "onset.replaceAndReplay",
            "onset.replayPair", "onset.requestRepairSelection", "onset.sampleEarly", "onset.start",
            "onset.stop", "onset.tick", "onset.verifyCommittedCaretRestoration", "onset.verifyCommittedReplacement",
            "safariActivationRetry",
        ]
        static let conditions=[
            "unknown", "accessibility_permission", "activation_boundary_changed", "activation_context_changed",
            "activation_deadline", "another_edit_started", "buffer_allocation_failed", "buffer_limit",
            "buffer_repair_range_invalid", "buffer_repair_surroundings_changed", "buffer_result_not_verified", "buffer_roman_retry_unavailable",
            "candidate_caret_mismatch", "candidate_literal_mismatch", "candidate_not_ascii", "candidate_range_invalid",
            "candidate_roman_mismatch", "candidate_surroundings_changed", "candidate_without_letters", "caps_during_unsettled_source",
            "composition_resume_exhausted", "deadline", "delivery_deadline", "delivery_source_selection_failed",
            "delivery_source_timeout", "english_selection_failed", "event_allocation_failed", "expected_korean_unavailable",
            "external_source_context_changed", "external_source_deadline", "external_source_unsettled", "field_changed",
            "final_source_context_changed", "focus_changed_during_recovery", "focus_changed_during_snapshot", "frontmost_app_changed",
            "hanq_input_stopped", "input_unavailable", "korean_retry_exhausted", "korean_selection_failed",
            "menu_during_unsettled_source", "menu_source_restore_failed", "mouse_during_recovery", "not_supported_text_field",
            "observed_field_changed", "paced_replay_allocation_failed", "paced_replay_deadline", "paced_replay_source_changed",
            "paced_replay_unsafe_context", "partial_replay_retry_exhausted", "plan_field_missing", "pre_edit_field_changed",
            "recovery_deadline", "recovery_inactive", "replay_allocation_failed", "rollback_active",
            "rollback_caret_rejected", "rollback_caret_timeout", "rollback_delivery_context_changed", "rollback_plan_missing",
            "rollback_replay_started", "rollback_source_failed", "rollback_text_changed", "rollback_unexpected_selection",
            "secure_input", "secure_text_field", "select_all_context_changed", "select_all_failed",
            "selected_text_not_verified", "selection_context_changed", "selection_failed", "selection_not_applied",
            "selection_retry_failed", "snapshot_selection_changed", "snapshot_text_changed", "snapshot_timeout",
            "source_changed", "source_interaction_timeout", "source_interaction_work_limit", "source_menu_focus_changed",
            "source_restore_exhausted", "source_restore_failed", "source_switch_timeout", "source_wait_restore_exhausted",
            "source_wait_restore_failed", "switch_gate_disabled", "tap_disabled", "target_not_frontmost",
            "unsafe_context", "unsafe_context_during_recovery", "unsupported_buffered_edit", "unsupported_external_source",
            "user_stop", "retry_count_exhausted", "retry_time_insufficient",
            "previous_source_changed", "modifier_release_timeout", "shortcut_unavailable", "focus_changed", "recipient_changed",
            "input_stopped", "context_interrupted", "repair_deadline",
            "abc_layout_unconfirmed", "acknowledgment_gate_unavailable", "active_composition", "buffer_post_rejected",
            "committed_cancel_unverified", "committed_gate_closed", "committed_native_unconfirmed", "committed_pending_context_changed",
            "committed_result_changed", "committed_result_unreadable", "composition_commit_context_changed", "composition_commit_deadline",
            "composition_commit_rejected", "composition_commit_source_changed", "early_claim_failed", "early_context_changed",
            "early_field_changed", "early_field_unavailable", "early_selection_changed", "early_selection_not_writable",
            "early_source_changed", "event_tap_disabled", "focused_element_unreadable", "gate_lock_timeout",
            "hanq_input_unavailable", "hold_deadline", "layout_override_present", "manual_edit_busy",
            "observation_stale", "permission_revoked", "pointer_during_repair", "pre_edit_context_changed",
            "pre_edit_mismatch", "prefix_confirmation_context_lost", "prefix_not_visible", "prefix_post_rejected",
            "prefix_text_mismatch", "prefix_composition_unconfirmed", "prefix_composition_changed",
            "prefix_cancel_context_changed", "prefix_caret_context_changed", "prefix_caret_restore_failed", "prefix_caret_changed", "prefix_caret_timeout", "probe_running", "repair_context_lost", "replay_acknowledgment_timeout",
            "replay_target_changed", "role_unreadable", "rollback_context_not_intact", "rollback_source_changed",
            "round_trip_unconfirmed", "secure_field", "selection_deadline", "selection_field_changed",
            "selection_invalid", "selection_retry_rejected", "selection_source_changed", "selection_unreadable",
            "shortcut_during_repair", "snapshot_unavailable", "tap_create_failed", "target_changed",
            "text_unreadable", "unsafe_delete_payload_blocked", "unsupported_repair_plan", "web_editor_unconfirmed",
            "outbound_not_observed", "prefix_plan_missing", "prefix_undo_ticket_changed", "prefix_context_changed", "prefix_result_unreadable", "prefix_caret_refused", "prefix_body_changed", "prefix_result_timeout", "prefix_ticket_missing", "rollback_roman_input_retained"
        ]
    }
    struct KeyboardBurst: Codable {
        let firstSequence, deviceDown, quartzDown, repeatDown, reportedProcessDown, outcome: Int
    }
    struct KeyboardSample: Codable { let status: Int; let bursts: [KeyboardBurst] }
    // Set only by the production app, before the trace starts. Called on the metadata worker.
    var keyboardSample: (([Frame], Int) -> KeyboardSample?)?
    struct CaptureCoverage:Codable {
        let requestedFromMilliseconds:Int,requestedThroughMilliseconds:Int
        let firstAvailableMilliseconds:Int?,lastAvailableMilliseconds:Int?
        let frames:Int,sequenceGaps:Int,historyEvictions:Int,historyByteEvictions:Int,encodingFailures:Int
    }
    struct Capture:Encodable {
        var rightCommandLayouts:[DiagnosticSwitchLayout]?=nil
        var coverage:CaptureCoverage?=nil
        var keyboardOrigin: KeyboardSample? = nil
        let schema=1
        let runID:String
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "test"
        let bestEffort=true
        let appReceiptVerified=false
        let correlationIsHeuristic=true
        let lossCountersMayLag=true
        let skippedEvents:[Int:Int]
        let skippedAuxiliary:[Int:Int]
        let decisionDelivery:DecisionDelivery
        let observationDelivery:ObservationDelivery
        let captureTiming:DecisionTiming
        let trigger:Trigger;let incident:Int;let phase:Int;let discardedOldFrames:Int;var frames:DiagnosticFrameSelection
        // Prior completed writes only. The companion status includes this write.
        var storageBeforeWrite:DiagnosticLogStore.Status?=nil
        var shapeBaselines:[ShapeBaseline]?=nil
        var capturePreservation:CapturePreservation?=nil
        var captureBacklog:CaptureBacklog?=nil
        var clockOriginMicros:Int?=nil
        var recoveryFailures:[RecoveryFailure]?=nil
        var monitorStatus:MonitorStatus?=nil
        var applicationInfo:DiagnosticApplicationSnapshot?=nil
        // Conservative admission accounting for the captured dictionaries and
        // arrays, not an assertion about allocator/RSS bytes. Four slots per
        // entry cover hash-table spare capacity and value storage.
        var metadataMemoryCharge:Int {
            func dictionary<K,V>(_ value:[K:V])->Int{128+value.count*4*(MemoryLayout<K>.stride+MemoryLayout<V>.stride+16)}
            var result=MemoryLayout<Self>.stride+4096
            result+=dictionary(skippedEvents)+dictionary(skippedAuxiliary)+dictionary(decisionDelivery.overflow)+dictionary(decisionDelivery.waits)+dictionary(decisionDelivery.coalesced ?? [:])
            result+=dictionary(observationDelivery.processed)+dictionary(observationDelivery.overflow)+dictionary(observationDelivery.omitted)+dictionary(observationDelivery.coalesced)+dictionary(observationDelivery.waits)
            if let backlog=captureBacklog{for value in [backlog.requested,backlog.merged,backlog.deferred,backlog.requestOverflow,backlog.windowOverflow,backlog.postOverflow,backlog.discardedOnDisable,backlog.rateSuppressed ?? [:]]{result+=dictionary(value)}}
            result+=(rightCommandLayouts?.count ?? 0)*MemoryLayout<DiagnosticSwitchLayout>.stride*2
            result+=(shapeBaselines?.count ?? 0)*MemoryLayout<ShapeBaseline>.stride*2
            result+=(applicationInfo?.records.reduce(0){$0+$1.memoryCharge} ?? 0)+(applicationInfo?.unavailableReferences.count ?? 0)*16
            result+=(capturePreservation?.requests.count ?? 1)*(MemoryLayout<CaptureRequest>.stride+64)*2
            result+=(recoveryFailures?.count ?? 0)*MemoryLayout<RecoveryFailure>.stride*2
            result+=(keyboardOrigin?.bursts.count ?? 0)*MemoryLayout<KeyboardBurst>.stride*2
            result+=(monitorStatus?.transitions.count ?? 0)*MemoryLayout<MonitorSample>.stride*2
            return max(65536,result)
        }
    }
    // Carried by the existing bounded input-origin entry. Only the serial diagnostic
    // worker reads/writes the ID. The callback never waits for it or puts it on the event.
    final class ShiftArrival {
        fileprivate let runID: String
        fileprivate let generation: Int32
        fileprivate var identifier: Int?

        fileprivate init(runID: String, generation: Int32) {
            self.runID = runID
            self.generation = generation
        }
    }

    private struct Identity:Hashable {let token:UInt64;let type:UInt32;let domain:Int;var modifier:Int=0}
    // Scalar reference only: never retain/read a mutable CGEvent asynchronously.
    private struct EventReference {
        let timestamp:CGEventTimestamp;let type:CGEventType;let token:UInt64
        let modifier: Int
        init(_ event:CGEvent,_ type:CGEventType,modifierRole:ModifierRole?=nil){
            timestamp=event.timestamp;self.type=type;token=UInt64(bitPattern:event.getIntegerValueField(.eventSourceUserData))
            // Untagged events of different modifier roles can share an OS timestamp.
            // Retain only the allowlisted class in the in-memory correlation key.
            switch type {
            case .flagsChanged, .keyDown, .keyUp: modifier = (modifierRole ?? ModifierRole(event: event))?.rawValue ?? 0
            default: modifier = 0
            }
        }
    }
    private struct Shape {
        let field:UInt;let count:Int;let selected:Bool;let editing:Bool
        var active:Bool;var sample:Int?;var point:ShapePoint;let previous:ShapePoint?
        var checkpointAt:Double;var reportedObservations:Int
    }
    static let shared:InputIncidentTrace = {
        let option=InputIncidentPreferences.launch(arguments:ProcessInfo.processInfo.arguments,defaults:.standard)
        guard option.valid else{fputs("HanQ: retired --bounded-input-incidents option or invalid legacy diagnostic location; no logs were opened. Use --preserve-input-incidents only for explicitly preserved investigations.\n",stderr);_exit(64)}
        let archive = !option.bounded && UserDefaults.standard.bool(forKey:InputIncidentPreferences.archiveBeforePruningKey)
            ? InputIncidentPreferences.defaultDirectory.deletingLastPathComponent().appendingPathComponent("InvestigationArchives"):nil
        return InputIncidentTrace(destination:option.directory,initiallyEnabled:option.enabled,persistentOwnership:option.persistent,retention:option.preserve ? .investigation:.incidentDefault,archiveDirectory:archive,legacyDirectories:option.legacy,migration:option.legacy.isEmpty ? nil:{InputIncidentPreferences.commitLegacyMigration(defaults:.standard,expected:option.legacy)})
    }()
    private let runID=UUID().uuidString
    private var recentSwitchLayouts:[DiagnosticSwitchLayout]=[]
    private var recentRecoveryFailures:[RecoveryFailure]=[]
    private var monitorStatus:MonitorStatus?
    private var applicationRegistry=DiagnosticApplicationRegistry()
    private let gate:DiagnosticCollectionGate
    private var preparingQuit:Int32=0
    private var quitGeneration:Int32=0
    private let configured:Bool
    let destinationDirectory:URL?
    var enabled:Bool {gate.generation>0}
    var collectionGeneration:Int32 {gate.generation}
    let capacity:Int
    private let lock=NSLock()
    private let queue=DispatchQueue(label:"hanq.input.incident.writer",qos:.utility)
    private let decisionQueue=DispatchQueue(label:"hanq.input.incident.decisions",qos:.utility)
    private let observationCapacity:Int,readCapacity:Int
    private let eventCredits:DispatchSemaphore,metadataCredits:DispatchSemaphore,shapeCredits:DispatchSemaphore,readCredits:DispatchSemaphore
    private let observationOverflowSignals:[DispatchSemaphore],observationOmittedSignals:[DispatchSemaphore]
    private var lastKeyboardDownLoss: Double?
    private var observationProcessed:[Int:Int]=[:],observationOverflow:[Int:Int]=[:],observationOmitted:[Int:Int]=[:],observationCoalesced:[Int:Int]=[:]
    private let captureCredits=Trigger.allCases.map{_ in DispatchSemaphore(value:16)}
    private let captureOverflowSignals=Trigger.allCases.map{_ in DispatchSemaphore(value:0)}
    private var lastSpaceDown:[Int:Double]=[:]
    private var lastSpaceCapture:[Int:Double]=[:]
    // All window mutation is on decisionQueue under the metadata lock. Writer
    // closures receive value snapshots; a window slot is held through both writes.
    private final class CaptureWindow {
        var before:Capture;var after:Capture?
        var manualResult:DiagnosticManualCapture?
        var requests:[CaptureRequest];let deferred:Bool;let generation:Int32
        var post:[DiagnosticPackedFrame]=[];var postLease:DiagnosticCaptureLease?;var postOmitted=0;var revision=0;var closed=false;var submitted=false
        var closedMilliseconds:Int?;var endedOnShutdown=false
        init(_ before:Capture,_ request:CaptureRequest,deferred:Bool,generation:Int32){
            self.before=before;self.requests=[request];self.deferred=deferred;self.generation=generation
        }
    }
    private var windows:[Int:CaptureWindow]=[:]
    private let captureMemory=DiagnosticCaptureMemory()
    private var drainScheduled=false
    private var captureRequested:[Int:Int]=[:],captureMerged:[Int:Int]=[:],captureDeferred:[Int:Int]=[:]
    private var captureRequestOverflow:[Int:Int]=[:],captureWindowOverflow:[Int:Int]=[:],capturePostOverflow:[Int:Int]=[:],captureDiscarded:[Int:Int]=[:]
    private var submittedWindows=0,completedWindows=0
    private var captureRateSuppressed:[Int:Int]=[:]
    private let decisionCapacity:Int
    private let importantCredits:DispatchSemaphore,routineCredits:DispatchSemaphore
    // Fixed scalar counters avoid one async allocation per overflow. Only the
    // writer queue drains them, in bounded batches; counts may lag under floods.
    private let overflowSignals:[DispatchSemaphore]
    private var decisionOverflow:[Int:Int]=[:]
    private var decisionWaits:[Int:DecisionWaitStats]=[:]
    private var decisionCoalesced:[Int:Int]=[:]
    private let decisionClock:()->UInt64
    private let observationClock:()->UInt64
    private var observationWaits:[Int:DecisionWaitStats]=[:]
    private let storage:DiagnosticLogStore?
    private let sharedStore:DiagnosticSharedStore?
    let preservesDiagnostics:Bool
    private var storageRetryTimer:DispatchSourceTimer?
    // Capture scheduling only; production persistence always uses shared storage.
    private let eagerPreCapture:Bool
    private let clock:()->Double
    // Default remains the live OS security state; synthetic fixtures inject their state.
    fileprivate let secureInput:()->Bool
    private let callbackCPU:()->UInt64?
    private let origin:Double
    private var ring:DiagnosticFrameHistory
    private var position=0,stored=0,sequence=0,overwritten=0,eventSequence=0
    private var identities:[Identity:Int]=[:]
    private var lastDecisions:[DecisionSite:DecisionReason]=[:]
    private var lastOnsetDecisions:[Int:(first:Double,keys:Int,detail:Int)]=[:]
    private var lastSourceEvidence:[Int:Int]=[:]
    private var shapes:[Lane:Shape]=[:]
    private var fields:[UInt:Int]=[:]
    private var nextField=0,lastEdit = -Double.infinity,lastTrigger = -Double.infinity
    private var captures=0
    private var reads:[UUID:(id:Int,began:Double,lane:Lane,span:ReadSpan)]=[:]
    private var slowReads=Set<Int>()
    private var readSequence=0
    private var timer:DispatchSourceTimer?
    // The writer drains fixed overflow/omission signals into these legacy
    // aggregates. Input callers never wait for a metadata lock.
    private var skippedEvents:[Int:Int]=[:],skippedAuxiliary:[Int:Int]=[:]
    private let writer:((Capture)->Void)?
    private var storageObserver:(()->Void)?
    private var readinessRetryAt=0.0,readinessRetryDelay=1.0
    private var lastJournalIssues:[DiagnosticStorageIssue]=[]
    private var manualCapacityLimited=false // Writer queue; refresh only while admission is blocked.
    let legacyDirectories:[URL]
    private var migration:(()->Bool)?
    init(secureInput:@escaping ()->Bool={IsSecureEventInputEnabled()},destination:URL?,initiallyEnabled:Bool=true,persistentOwnership:Bool=false,capacity:Int=65536,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},retention:DiagnosticLogRetentionPolicy = .incidentDefault,archiveDirectory:URL?=nil,legacyDirectories:[URL]=[],migration:(()->Bool)?=nil,decisionCapacity:Int=4096,observationCapacity:Int=4096,readCapacity:Int=128,decisionClock:@escaping ()->UInt64={DispatchTime.now().uptimeNanoseconds},observationClock:@escaping ()->UInt64={DispatchTime.now().uptimeNanoseconds},callbackCPU:@escaping ()->UInt64?=InputIncidentTrace.callbackThreadCPU,sharedWriter:OperationalIO.Write?=nil,applicationResolver:((pid_t)->DiagnosticApplicationRegistry.Resolved?)?=nil,writer:((Capture)->Void)?=nil){
        self.secureInput=secureInput
        if let applicationResolver{applicationRegistry=DiagnosticApplicationRegistry(resolve:applicationResolver)}
        self.observationCapacity=max(4,min(observationCapacity,16384));self.readCapacity=max(1,min(readCapacity,128))
        eventCredits=DispatchSemaphore(value:self.observationCapacity/2)
        shapeCredits=DispatchSemaphore(value:max(1,self.observationCapacity/8))
        metadataCredits=DispatchSemaphore(value:self.observationCapacity-self.observationCapacity/2-max(1,self.observationCapacity/8))
        readCredits=DispatchSemaphore(value:self.readCapacity)
        let active=destination != nil || writer != nil
        observationOverflowSignals=active ? (0..<2560).map{_ in DispatchSemaphore(value:0)}:[]
        observationOmittedSignals=active ? (0..<2560).map{_ in DispatchSemaphore(value:0)}:[]
        self.observationClock=observationClock
        self.decisionClock=decisionClock
        self.decisionCapacity=max(2,min(decisionCapacity,16384))
        let important=max(1,self.decisionCapacity*3/4)
        importantCredits=DispatchSemaphore(value:important)
        routineCredits=DispatchSemaphore(value:self.decisionCapacity-important)
        overflowSignals=(destination != nil || writer != nil) ? (0..<310).map{_ in DispatchSemaphore(value:0)}:[]
        self.destinationDirectory=destination
        self.preservesDiagnostics=archiveDirectory != nil || retention.maximumAutomaticBytes==Int.max
        self.storage=destination.map{DiagnosticLogStore(directory:$0,policy:retention,persistentOwnership:persistentOwnership)}
        self.legacyDirectories=legacyDirectories;self.migration=migration
        self.sharedStore=writer==nil ? destination.map{DiagnosticSharedStore(directory:$0,preserve:archiveDirectory != nil || retention.maximumAutomaticBytes==Int.max,writer:sharedWriter ?? {Darwin.write($0,$1,$2)})}:nil
        self.eagerPreCapture=persistentOwnership && archiveDirectory==nil && retention.maximumAutomaticBytes != Int.max
        self.configured=destination != nil || writer != nil;self.gate=DiagnosticCollectionGate(self.configured && initiallyEnabled)
        self.capacity=max(1,min(capacity,65536));self.clock=clock;self.callbackCPU=callbackCPU;origin=clock();self.writer=writer
        ring=DiagnosticFrameHistory(capacity:self.configured && initiallyEnabled ? self.capacity:0)
        if enabled{decisionQueue.async{[self] in
            // Establish ownership and prove an actual write/read on the writer
            // before assigning any capture IDs or accepting test readiness.
            queue.sync {
                _ = storage?.verifyReadiness()
                let sharedReady=sharedStore?.prepare() ?? true
                if sharedReady,storage?.readiness.ready==true,migration?()==true{self.migration=nil}
                if sharedReady,let token=DiagnosticStorageStartup.token {
                    let receipt=try? JSONEncoder().encode(DiagnosticReadinessReceipt.make(token:token,runID:runID,bounded:false))
                    _ = storage?.verifyReadiness(receipt:receipt,name:DiagnosticReadinessReceipt.name(token))
                }
                captures=max(storage?.lastCaptureIncident ?? 0,sharedStore?.lastCaptureIncident ?? 0)

            }
        }}
        if sharedStore != nil {
            let retry=DispatchSource.makeTimerSource(queue:queue)
            retry.schedule(deadline:.now()+1,repeating:1)
            retry.setEventHandler{[weak self] in
                guard let self else{return}
                let journalIssues=self.destinationDirectory.map{OperationalDiagnostics.shared.storageIssues(for:$0)} ?? []
                let journalChanged=self.lastJournalIssues != journalIssues
                self.lastJournalIssues=journalIssues
                guard self.enabled || (self.sharedStore?.stats.pendingBytes ?? 0)>0 || journalChanged else{return}
                let previous=self.sharedStore?.stats.lastFailure
                let wasReady=self.storage?.readiness.ready
                _ = self.sharedStore?.drain()
                if self.sharedStore?.hasVerifiedWrite==true,self.migration?()==true{self.migration=nil}
                if self.enabled,let storage=self.storage,!storage.readiness.ready,
                   self.sharedStore?.hasVerifiedWrite != true,ProcessInfo.processInfo.systemUptime>=self.readinessRetryAt {
                    let ready=storage.verifyReadiness().ready
                    self.readinessRetryAt=ProcessInfo.processInfo.systemUptime+self.readinessRetryDelay
                    self.readinessRetryDelay=ready ? 1:min(60,self.readinessRetryDelay*2)
                }
                if (self.enabled && self.manualCapacityLimited) || journalChanged || previous != self.sharedStore?.stats.lastFailure || wasReady != self.storage?.readiness.ready{self.storageObserver?()}
            }
            storageRetryTimer=retry;retry.resume()
        }
    }
    func storageHealth(_ completion:@escaping(DiagnosticStorageHealth)->Void){
        decisionQueue.async{[self] in
            let generation=gate.generation
            lock.lock()
            let manualWindows=windows.values.filter{$0.before.trigger == .manual}
            let posts=manualWindows.filter{!$0.submitted}
            let now=Int(max(0,(clock()-origin)*1000))
            let metadata=snapshot(.manual,timing:DecisionTiming(queueMicros:0,lockWaitMicros:0,contended:false,clipped:false),incident:0,frames:[],sampleKeyboard:false).metadataMemoryCharge
            let frameBytes=ring.selectionMemoryCharge(from:max(0,now-60000),through:now)
            let windowSpace=manualWindows.count<4
            let postCount=posts.count,postBytes=posts.reduce(0){$0+$1.post.reduce(0){$0+$1.accountedBytes}+32768}
            lock.unlock()
            queue.async{[self] in
            let sharedPending=(sharedStore?.stats.pendingBytes ?? 0)>0
            let issues=currentStorageIssues()
            let baseReady=sharedStore?.hasVerifiedWrite == true ? .ready:(storage?.readiness ?? DiagnosticStorageReadiness.unavailable)
            let currentFailure=issues.first?.failure
            let readiness=issues.isEmpty ? baseReady:.unavailable
            let missing=(storage.map{$0.status.unavailable+$0.status.encodingFailures+$0.status.limited+$0.status.statusWriteFailures} ?? 0)+(sharedStore.map{$0.stats.failures+$0.stats.rejected+$0.stats.incompleteFiles} ?? 0)
            let budget=storage?.status.writeBudget
            let memorySpace=sharedStore==nil || frameBytes+2*metadata<=captureMemory.limit-captureMemory.status.manual
            let writerSpace=sharedStore?.canAcceptManualCapture(frameBytes:frameBytes,awaitingPosts:postCount,awaitingPostBytes:postBytes) ?? (writer != nil || storage?.readiness.ready==true)
            let available=enabled && OSAtomicAdd32Barrier(0,&preparingQuit)==0 && gate.generation==generation && windowSpace && memorySpace && writerSpace
            // Reuse the existing retry tick to recheck capacity while disabled.
            // Healthy menus add no polling, disk probes or capture copies.
            manualCapacityLimited=enabled && (!windowSpace || !memorySpace || (!writerSpace && sharedStore?.canRetry==true))
            completion(DiagnosticStorageHealth(readiness:readiness,missingWrites:missing,
                suppressedWrites:(budget?["suppressedAutomatic"] ?? 0)+(budget?["suppressedManual"] ?? 0),
                collectionEnabled:enabled,pendingWrites:sharedPending || issues.contains{$0.component != .detail && $0.component != .readiness},
                currentFailure:currentFailure,manualCaptureAvailable:available,issues:issues))
        }}
    }
    // Called on the writer queue by both the live UI and the export snapshot.
    // Keep real scheduling/permanent-stop state; an errno cannot imply a retry.
    private func currentStorageIssues()->[DiagnosticStorageIssue]{
        var issues=destinationDirectory.map{OperationalDiagnostics.shared.storageIssues(for:$0)} ?? []
        let pending=(sharedStore?.stats.pendingBytes ?? 0)>0
        if let issue=sharedStore?.storageIssue(retryScheduled:enabled || pending){issues.insert(issue,at:0)}
        let ready=sharedStore?.hasVerifiedWrite == true ? .ready:(storage?.readiness ?? DiagnosticStorageReadiness.unavailable)
        if !ready.ready,ready.reason != "not_checked",let issue=storage?.readinessIssue(retryScheduled:storageRetryTimer != nil && enabled){issues.append(issue)}
        return issues
    }
    func observeStorage(_ callback:@escaping()->Void){queue.async{[self] in storageObserver=callback}}
    func waitForStorageReadiness(timeout:Double=5)->DiagnosticStorageReadiness {
        let signal=DispatchSemaphore(value:0),lock=NSLock()
        var result=DiagnosticStorageReadiness.timeout
        storageHealth{health in lock.lock();result=health.readiness;lock.unlock();signal.signal()}
        guard signal.wait(timeout:.now()+timeout) == .success else{return .timeout}
        lock.lock();defer{lock.unlock()};return result
    }
    // Main-thread UI control. Preparation/draining stays on background queues.
    func setCollectionEnabled(_ active:Bool,completion:(()->Void)?=nil){
        shapeCorrelation.reset()
        let paused=gate.pause()
        timer?.cancel();timer=nil
        // The writer barrier queues reset after write-completion bookkeeping.
        // OFF counts cancelled protected requests even if publication was queued.
        decisionQueue.async{[self] in queue.async{[self] in
            guard gate.generation==paused else{DispatchQueue.main.async{completion?()};return}
            if active,configured{_ = storage?.verifyReadiness();if sharedStore?.prepare()==true,storage?.readiness.ready==true,migration?()==true{migration=nil}}
            else{storage?.withdrawReadiness()}
            let last=max(storage?.lastCaptureIncident ?? 0,sharedStore?.lastCaptureIncident ?? 0)
            decisionQueue.async{[self] in
                guard gate.generation==paused else{DispatchQueue.main.async{completion?()};return}
                lock.lock()
                for window in windows.values {
                    window.manualResult?.finish(.incomplete)
                    for request in window.requests{captureDiscarded[request.trigger,default:0]+=1}
                }
                windows.removeAll();drainScheduled=false
                ring=DiagnosticFrameHistory(capacity:configured && active ? capacity:0);position=0;stored=0
                reads.removeAll();slowReads.removeAll();shapes.removeAll();identities.removeAll();lastDecisions.removeAll();lastOnsetDecisions.removeAll();lastSourceEvidence.removeAll()
                fields.removeAll();lastEdit = -Double.infinity;lastTrigger = -Double.infinity
                lastSpaceDown.removeAll();lastSpaceCapture.removeAll()
                monitorStatus=nil
                recentRecoveryFailures.removeAll()
                recentSwitchLayouts.removeAll()
                applicationRegistry.reset()
                if active,configured{captures=max(captures,last);_ = gate.activate(paused)}
                lock.unlock()
                DispatchQueue.main.async{[weak self] in self?.start();completion?()}
            }
        }}
    }
    private func append(_ lane:Lane,_ kind:Kind,observedAt:Double?=nil,decisionTiming:DecisionTiming?=nil,observationTiming:DecisionTiming?=nil,event:Int=0,edge:Int=0,category:Int=0,inputOrigin:Int=0,consumed:Bool=false,duration:Double=0,count:Int=0,selected:Bool=false,field:Int=0,modifierStage:ModifierStage?=nil){
        preservePreviousFrame()
        ring.trim(now:Int(max(0,(clock()-origin)*1000)))
        sequence+=1
        ring[position]=Frame(sequence:sequence,milliseconds:Int(max(0,(observedAt ?? clock())-origin)*1000),lane:lane,kind:kind,event:event,edge:edge,category:category,inputOrigin:inputOrigin,consumed:consumed,durationMicros:Int(max(0,min(duration,60))*1_000_000),count:count,selected:selected,field:field,decisionTiming:decisionTiming,observationTiming:observationTiming,modifierStage:modifierStage)
        position=(position+1)%capacity
        if stored<capacity{stored+=1}else{overwritten+=1}
    }
    private func preservePreviousFrame(){
        guard let frame=ring[(position-1+capacity)%capacity],let packet=ring.packet(at:(position-1+capacity)%capacity) else{return}
        for window in windows.values where !window.closed {
            let after=window.requests.first?.afterSequence ?? 0
            guard frame.sequence>after,frame.milliseconds<=(window.requests.last?.milliseconds ?? 0)+3000 else{continue}
            if let previous=window.post.last,previous.sequence==frame.sequence {
                if previous.data != packet.data {
                    if sharedStore==nil || window.postLease?.grow(max(0,packet.accountedBytes-previous.accountedBytes))==true{window.post[window.post.count-1]=packet}
                    else{window.postOmitted+=1;capturePostOverflow[window.before.trigger.rawValue,default:0]+=1}
                }
                continue
            }
            if window.post.count<capacity,(sharedStore==nil || window.postLease?.grow(packet.accountedBytes)==true){window.post.append(packet)}else{window.postOmitted+=1;capturePostOverflow[window.before.trigger.rawValue,default:0]+=1}
        }
    }
    private func updatePreservedLastFrame(){preservePreviousFrame()}
    private func snapshot(_ reason:Trigger,timing:DecisionTiming,incident:Int,phase:Int=0,frames:[DiagnosticPackedFrame]?=nil,requestedFrom:Int?=nil,requestedThrough:Int?=nil,sampleKeyboard:Bool=true)->Capture {
        let now=Int(max(0,(clock()-origin)*1000))
        ring.trim(now:now)
        let selected=frames.map(DiagnosticFrameSelection.init) ?? ring.selection(from:max(0,now-(reason == .manual ? 60000:10000)),through:now)
        var value=Capture(runID:runID,skippedEvents:skippedEvents,skippedAuxiliary:skippedAuxiliary,decisionDelivery:DecisionDelivery(capacity:decisionCapacity,overflow:decisionOverflow,waits:decisionWaits,coalesced:decisionCoalesced),observationDelivery:observationSnapshot(),captureTiming:timing,trigger:reason,incident:incident,phase:phase,discardedOldFrames:ring.dropped,frames:selected,shapeBaselines:shapeSnapshot(),captureBacklog:backlogSnapshot())
        let sequenceGaps=zip(selected.packets,selected.packets.dropFirst()).reduce(0){$0+max(0,$1.1.sequence-$1.0.sequence-1)}
        value.coverage=CaptureCoverage(requestedFromMilliseconds:requestedFrom ?? max(0,now-(reason == .manual ? 60000:10000)),requestedThroughMilliseconds:requestedThrough ?? now,
            firstAvailableMilliseconds:selected.packets.first?.milliseconds,lastAvailableMilliseconds:selected.packets.last?.milliseconds,frames:selected.count,sequenceGaps:sequenceGaps,historyEvictions:ring.dropped,historyByteEvictions:ring.byteEvictions,encodingFailures:ring.encodingFailures)
        value.rightCommandLayouts=recentSwitchLayouts
        value.clockOriginMicros=Int(max(0,min(origin*1_000_000,9_000_000_000_000_000)))
        value.recoveryFailures=recentRecoveryFailures.isEmpty ? nil:recentRecoveryFailures
        if sampleKeyboard,reason == .manual, let origin = value.clockOriginMicros, let keyboardSample {
            // Counter drains may lag the loss. Restart comparison after the entire window ages out.
            let missing = lastKeyboardDownLoss.map { clock() - $0 <= 60 } ?? false
            value.keyboardOrigin = missing ? KeyboardSample(status: 5, bursts: []) : (try? value.frames.unpacked()).flatMap{keyboardSample($0,origin)} ?? KeyboardSample(status:5,bursts:[])
        }
        value.monitorStatus=monitorStatus
        var applicationIDs=Set<Int>()
        for packet in selected.packets{applicationIDs.formUnion(DiagnosticApplicationReferences.ids(packet.applicationReferences))}
        for baseline in value.shapeBaselines ?? [] {
            for point in [baseline.current,baseline.previous].compactMap({$0}){applicationIDs.formUnion(DiagnosticApplicationReferences.ids(point.evidence.applications?.packed ?? 0))}
        }
        value.applicationInfo=applicationRegistry.snapshot(applicationIDs)
        return value
    }
    private func criticalContext(incident:Int,episode:Int?=nil,observedTime:Double?=nil)->DiagnosticCriticalJournal.Context {
        let previous=ring.isEmpty ? nil:ring[(position-1+capacity)%capacity]
        var value=DiagnosticCriticalJournal.Context(trace:runID,incident:incident,sequence:sequence,lane:previous?.lane.rawValue ?? 0,
                     kind:previous?.kind.rawValue ?? 0,category:previous?.category ?? 0,count:previous?.count ?? 0,
                     episode:episode ?? previous?.onsetObservation?.episode ?? 0)
        value.observedMilliseconds=Int(max(0,((observedTime ?? clock())-origin)*1000))
        return value
    }
    func recoveryFailure(rollback:Bool,site:String,reason:String){
        recordFailure(action:rollback ? 1:2,site:site,reason:reason)
    }
    func recordFailure(action:Int,site:String,reason:String){
        let generation=gate.generation
        let detailed=generation>0 && !secureInput()
        let time=clock()
        let stage=String(site.prefix(while:{$0 != "("}))
        let condition=reason.hasPrefix(stage+"_") ? String(reason.dropFirst(stage.count+1)):reason
        let record=RecoveryFailure(milliseconds:Int(max(0,(time-origin)*1000)),action:action,
                                   stage:RecoveryFailure.stages.firstIndex(of:stage) ?? 0,
                                   condition:RecoveryFailure.conditions.firstIndex(of:reason) ?? RecoveryFailure.conditions.firstIndex(of:condition) ?? 0)
        // A terminal transition is rare and must survive a full event/observation queue.
        decisionQueue.async{[self] in
            if action != 4 {
                OperationalDiagnostics.shared.record(.policy(.recoveryFailure,action*100000+record.stage*1000+record.condition),context:detailed ? criticalContext(incident:0,observedTime:time):nil)
            }
            guard detailed,gate.generation==generation else{return}
            lock.lock();defer{lock.unlock()}
            // A normal direct switch can recur often. Keep only its latest
            // eligibility decision so it cannot evict a series of real failures.
            if action==4 { recentRecoveryFailures.removeAll { $0.action==4 } }
            if recentRecoveryFailures.count==16 {
                if let fallback=recentRecoveryFailures.firstIndex(where:{ $0.action==4 }) {
                    recentRecoveryFailures.remove(at:fallback)
                } else if action==4 {
                    return
                } else {
                    recentRecoveryFailures.removeFirst()
                }
            }
            recentRecoveryFailures.append(record)
        }
    }
    func monitor(_ sample:MonitorSample){
        guard enabled else{return}
        let time=clock()
        _ = submit(.context,.mismatch,31,observedAt:time){[self] _ in
            var current=sample
            current.observedAtMilliseconds=Int(max(0,min((time-origin)*1000,9_000_000_000_000_000)))
            var changes=monitorStatus?.transitions ?? []
            var discarded=monitorStatus?.discardedTransitions ?? 0
            if monitorStatus?.current.sameState(as:current) != true {
                changes.append(current)
                if changes.count>16{discarded+=changes.count-16;changes.removeFirst(changes.count-16)}
            }
            monitorStatus=MonitorStatus(current:current,transitions:changes,discardedTransitions:discarded)
        }
    }
    private func backlogSnapshot()->CaptureBacklog {
        CaptureBacklog(automaticCapacity:sharedStore==nil ? 16:128,manualCapacity:4,requestCapacityPerTrigger:16,requestsPerWindow:32,
            pendingAutomatic:windows.values.filter{$0.before.trigger != .manual}.count,pendingManual:windows.values.filter{$0.before.trigger == .manual}.count,
            requested:captureRequested,merged:captureMerged,deferred:captureDeferred,requestOverflow:captureRequestOverflow,windowOverflow:captureWindowOverflow,postOverflow:capturePostOverflow,discardedOnDisable:captureDiscarded,submittedWindows:submittedWindows,completedWindows:completedWindows,rateSuppressed:eagerPreCapture ? captureRateSuppressed:nil)
    }
    private func collectCaptureOverflow(){
        for (index,signal) in captureOverflowSignals.enumerated(){
            var count=0;while count<4096,signal.wait(timeout:.now()) == .success{count+=1}
            if count>0{captureRequestOverflow[index+1,default:0]+=count}
        }
    }
    private func collectDecisionOverflow(){
        // Decision worker only; drain bounded scalar counters before a snapshot.
        for (code,signal) in overflowSignals.enumerated(){
            var count=0
            while count<4096,signal.wait(timeout:.now()) == .success{count+=1}
            if count>0{decisionOverflow[code,default:0]+=count}
        }
    }
    private func observationSnapshot()->ObservationDelivery {
        ObservationDelivery(capacity:observationCapacity,readCapacity:readCapacity,processed:observationProcessed,overflow:observationOverflow,omitted:observationOmitted,coalesced:observationCoalesced,waits:observationWaits)
    }
    private func observationCode(_ operation:Observation,_ lane:Lane,_ detail:Int=0)->Int {((operation.rawValue-1)*8+lane.rawValue-1)*32+detail}
    // Worker-only metadata mutation; caller reserves bounded space without waiting.
    private func withObservation(_ operation:Observation,_ lane:Lane,_ detail:Int=0,observedAt:Double,enqueuedAt:UInt64,startedAt:UInt64?=nil,_ work:(DecisionTiming)->Void){
        let dequeuedAt=startedAt ?? observationClock()
        let contended = !lock.try()
        var waitNanos:UInt64=0
        if contended {
            let began=observationClock();lock.lock();let acquired=observationClock()
            waitNanos=acquired>=began ? acquired-began:0
        }
        defer{lock.unlock()}
        let queueNanos=dequeuedAt>=enqueuedAt ? dequeuedAt-enqueuedAt:0
        let timing=DecisionTiming(queueMicros:Int(min(queueNanos/1000,60_000_000)),lockWaitMicros:Int(min(waitNanos/1000,60_000_000)),contended:contended,clipped:queueNanos>60_000_000_000 || waitNanos>60_000_000_000)
        let code=observationCode(operation,lane,detail)
        observationProcessed[code,default:0]+=1
        var stats=observationWaits[code,default:DecisionWaitStats()]
        stats.processed+=1;if contended{stats.contended+=1}
        stats.totalLockWaitMicros+=timing.lockWaitMicros
        stats.maxLockWaitMicros=max(stats.maxLockWaitMicros,timing.lockWaitMicros)
        stats.maxQueueMicros=max(stats.maxQueueMicros,timing.queueMicros)
        if timing.clipped{stats.clipped+=1};observationWaits[code]=stats
        let importantWait=timing.contended || timing.clipped || timing.queueMicros>=50_000
        // Include capture waits before its snapshot, even when the request is
        // later throttled and therefore has no successful capture header.
        if operation == .capture,importantWait {
            append(lane,.observationWait,observedAt:observedAt,observationTiming:timing,edge:detail,category:operation.rawValue)
        }
        let before=sequence
        work(timing)
        // A timer, suppressed shape or unavailable endpoint may have no normal
        // frame. Preserve important measured waits without logging every tick.
        if operation != .capture,sequence==before,importantWait{
            append(lane,.observationWait,observedAt:observedAt,observationTiming:timing,edge:detail,category:operation.rawValue)
        }
    }
    private func submit(_ operation:Observation,_ lane:Lane,_ detail:Int=0,observedAt:Double?=nil,_ work:@escaping (DecisionTiming)->Void)->Bool {
        let generation=gate.generation;guard generation>0 else{return false}
        let code=observationCode(operation,lane,detail)
        let credits=operation == .event ? eventCredits:((operation == .shape || operation == .timer) ? shapeCredits:metadataCredits)
        guard credits.wait(timeout:.now()) == .success else{observationOverflowSignals[code].signal();return false}
        let time=observedAt ?? clock(),enqueued=observationClock()
        decisionQueue.async{[self] in
            defer{credits.signal()}
            guard gate.generation==generation else{return}
            withObservation(operation,lane,detail,observedAt:time,enqueuedAt:enqueued,work)
        }
        return true
    }
    private func collectObservationCounters()->([Int:Int],[Int:Int]){
        var over:[Int:Int]=[:],omissions:[Int:Int]=[:]
        for code in 0..<2560 {
            for omitted in [false,true] {
                let signal=omitted ? observationOmittedSignals[code]:observationOverflowSignals[code]
                var count=0
                while count<4096,signal.wait(timeout:.now()) == .success{count+=1}
                if count>0 {
                    if omitted{omissions[code]=count}else{over[code]=count}
                }
            }
        }
        return (over,omissions)
    }
    // Called under the measured capture lock only.
    private func mergeObservationCounters(_ counters:([Int:Int],[Int:Int])){
        let (over,omissions)=counters
        if [1, 5].contains(where: { over[observationCode(.event, .hid, $0)] != nil }) {
            lastKeyboardDownLoss = clock()
        }
        for (code,count) in over{observationOverflow[code,default:0]+=count}
        for (code,count) in omissions{observationOmitted[code,default:0]+=count}
        for (code,count) in over.merging(omissions,uniquingKeysWith:+){
            let op=code/(8*32)+1,lane=code/32%8+1
            if op==1{skippedEvents[lane,default:0]+=count}else{skippedAuxiliary[lane,default:0]+=count}
        }
    }
    private func requestCapture(_ reason:Trigger,lane:Lane = .main,detail:Int=0,event:CGEvent?=nil,episode:Int?=nil,duration:Double?=nil,manual:DiagnosticManualCapture?=nil,correlation:String?=nil){
        guard enabled else{manual?.finish(.unavailable);return}
        requestCapture(reason,lane:lane,detail:detail,reference:event.map{EventReference($0,$0.type)},time:clock(),episode:episode,duration:duration,manual:manual,correlation:correlation)
    }
    private func requestCapture(_ reason:Trigger,lane:Lane,detail:Int,reference:EventReference?,time:Double,episode:Int?=nil,duration:Double?=nil,manual:DiagnosticManualCapture?=nil,correlation:String?=nil){
        let generation=gate.generation;guard generation>0,OSAtomicAdd32Barrier(0,&preparingQuit)==0,reason != .onsetObservation else{manual?.finish(.unavailable);return}
        let requestID=UUID().uuidString
        var requestContext=DiagnosticCriticalJournal.Context(trace:runID,incident:0,sequence:0,lane:lane.rawValue,kind:reason.rawValue,category:detail,count:0,episode:episode ?? 0)
        requestContext.observedMilliseconds=Int(max(0,(time-origin)*1000));requestContext.requestID=requestID
        if let duration,duration.isFinite,duration>=0{requestContext.durationMicros=Int(min(duration,60)*1_000_000);requestContext.durationClipped=duration>60}
        OperationalDiagnostics.shared.record(.policy(.incidentTrigger,reason.rawValue),context:requestContext,observation:true)
        // Bounded admission only. The input caller never copies
        // a ring, encodes JSON, or performs file I/O.
        guard captureCredits[reason.rawValue-1].wait(timeout:.now()) == .success else{
            captureOverflowSignals[reason.rawValue-1].signal();OperationalDiagnostics.shared.record(.policy(.captureDisposition,6),context:requestContext,observation:true);manual?.finish(.incomplete);return
        }
        let enqueued=observationClock()
        decisionQueue.async{[self] in
            defer{captureCredits[reason.rawValue-1].signal()}
            guard gate.generation==generation else{manual?.finish(.incomplete);return}
            collectDecisionOverflow();collectCaptureOverflow();let counters=collectObservationCounters()
            withObservation(.capture,.main,reason.rawValue%8,observedAt:time,enqueuedAt:enqueued){timing in
                guard gate.generation==generation else{manual?.finish(.incomplete);return}
                mergeObservationCounters(counters)
                let (identifier,origin)=reference.map{eventIdentity($0)} ?? (0,0)
                var request=CaptureRequest(trigger:reason.rawValue,milliseconds:Int(max(0,time-self.origin)*1000),afterSequence:sequence,lane:lane.rawValue,detail:detail,event:identifier,inputOrigin:origin)
                request.requestID=requestID
                request.correlationID=correlation
                captureRequested[reason.rawValue,default:0]+=1
                if let correlation,reason == .axDelay || reason == .possibleShrink,
                   let window=windows.values.first(where:{!$0.closed && $0.before.trigger==reason && $0.requests.first?.correlationID==correlation && $0.requests.count<32 && $0.post.count<capacity}) {
                    window.requests.append(request);captureMerged[reason.rawValue,default:0]+=1
                    var linked=DiagnosticCriticalJournal.Context(trace:runID,incident:window.before.incident,sequence:sequence,lane:lane.rawValue,kind:reason.rawValue,category:detail,count:window.requests.count,episode:episode ?? 0)
                    linked.requestID=requestID;linked.observedMilliseconds=request.milliseconds
                    OperationalDiagnostics.shared.record(.policy(.captureDisposition,8),context:linked,observation:true)
                    scheduleClose(window);return
                }
                if sharedStore==nil,!eagerPreCapture,reason != .manual,reason != .recoveryStarted,let window=windows.values.filter({!$0.closed && $0.before.trigger != .manual && $0.requests.count<32 && $0.post.count<capacity && request.milliseconds-($0.requests.last?.milliseconds ?? 0)<1000}).max(by:{$0.before.incident<$1.before.incident}) {
                    window.requests.append(request);captureMerged[reason.rawValue,default:0]+=1
                    let code=reason == window.before.trigger ? reason.rawValue%8:reason.rawValue%8+8
                    observationOmitted[observationCode(.capture,.main,code),default:0]+=1
                    scheduleClose(window);return
                }
                captures+=1
                var coreContext=criticalContext(incident:captures,episode:episode,observedTime:time);coreContext.requestID=requestID
                // The request occurrence was recorded before detailed admission.
                let pending=windows.values.filter{($0.before.trigger == .manual)==(reason == .manual)}.count
                guard pending<(reason == .manual ? 4:(sharedStore==nil ? 16:128)) else{
                    captureWindowOverflow[reason.rawValue,default:0]+=1
                    OperationalDiagnostics.shared.record(.policy(.captureDisposition,6),context:coreContext,observation:true);manual?.finish(.incomplete);return
                }
                // An older frozen pre must reach the ordered store first. A newer
                // immediate pre would retire that older automatic incident.
                let intervalBlocked=clock()-lastTrigger<10
                let orderBlocked=windows.values.contains{$0.deferred && !$0.submitted}
                let deferred = sharedStore==nil && !eagerPreCapture && reason != .manual && (intervalBlocked || orderBlocked)
                if deferred{
                    captureDeferred[reason.rawValue,default:0]+=1
                    observationOmitted[observationCode(.capture,.main,reason.rawValue%8+8),default:0]+=1
                }else if reason != .manual{lastTrigger=clock()}
                let before=snapshot(reason,timing:timing,incident:captures)
                let preLease=sharedStore==nil ? nil:captureMemory.lease(before.frames.packets.reduce(before.metadataMemoryCharge){$0+$1.accountedBytes},manual:reason == .manual)
                let postLease=sharedStore==nil ? nil:captureMemory.lease(before.metadataMemoryCharge,manual:reason == .manual)
                guard sharedStore==nil || (preLease != nil && postLease != nil) else {
                    captureWindowOverflow[reason.rawValue,default:0]+=1
                    OperationalDiagnostics.shared.record(.policy(.captureDisposition,6),context:coreContext,observation:true);manual?.finish(.incomplete);return
                }
                let window=CaptureWindow(before,request,deferred:deferred,generation:generation)
                window.manualResult=manual
                window.postLease=postLease
                windows[captures]=window
                if !deferred {
                    var value=before;value.capturePreservation=preservation(window);value.captureBacklog=backlogSnapshot()
                    queue.async{[self] in if gate.generation==generation{write(value,lease:preLease,manual:manual)}else{manual?.finish(.incomplete)}}
                    if sharedStore != nil{window.before.frames=DiagnosticFrameSelection([])}
                }
                scheduleClose(window)
            }
        }
    }
    private func preservation(_ window:CaptureWindow)->CapturePreservation {
        CapturePreservation(deferred:window.deferred,requests:window.requests,postCapacity:capacity,postOmittedFrames:window.postOmitted,closed:window.closed,closedMilliseconds:window.closedMilliseconds,endedOnShutdown:window.endedOnShutdown)
    }
    private func scheduleClose(_ window:CaptureWindow){
        window.revision+=1
        let revision=window.revision,incident=window.before.incident,generation=window.generation
        decisionQueue.asyncAfter(deadline:.now()+3){[weak self] in
            guard let self else{return}
            guard gate.generation==generation,let current=windows[incident],!current.closed,current.revision==revision else{return}
            closeWindow(current)
        }
    }
    private func closeWindow(_ window:CaptureWindow){
        preservePreviousFrame()
        collectDecisionOverflow();collectCaptureOverflow();let counters=collectObservationCounters()
        let time=clock(),enqueued=observationClock()
        withObservation(.capture,.main,window.before.trigger.rawValue%8+24,observedAt:time,enqueuedAt:enqueued){timing in
            guard gate.generation==window.generation,windows[window.before.incident] === window else{return}
            mergeObservationCounters(counters);window.closed=true;window.closedMilliseconds=Int(max(0,clock()-origin)*1000)
            window.after=snapshot(window.before.trigger,timing:timing,incident:window.before.incident,phase:1,frames:window.post,requestedFrom:window.requests.first?.milliseconds,requestedThrough:window.requests.last.map{$0.milliseconds+3000})
            if window.deferred{drainDeferred()}else{submitWindow(window)}
        }
    }
    private func drainDeferred(){
        let pending=windows.values.filter{$0.deferred && !$0.submitted}.sorted{$0.before.incident<$1.before.incident}
        let ready=Array(pending.prefix(while:{$0.closed}))
        guard !ready.isEmpty else{return}
        let remaining=10-(clock()-lastTrigger)
        if remaining>0 {
            guard !drainScheduled else{return};drainScheduled=true
            let generation=gate.generation
            decisionQueue.asyncAfter(deadline:.now()+remaining){[self] in
                guard gate.generation==generation else{return}
                lock.lock();defer{lock.unlock()};drainScheduled=false;drainDeferred()
            }
            return
        }
        lastTrigger=clock()
        for window in ready{submitWindow(window)}
    }
    private func submitWindow(_ window:CaptureWindow){
        guard !window.submitted,var after=window.after else{return}
        window.submitted=true;submittedWindows+=1
        let manual=window.manualResult
        if window.postOmitted>0{manual?.finish(.incomplete)}
        var before=window.before
        let value=preservation(window),backlog=backlogSnapshot()
        before.capturePreservation=value;before.captureBacklog=backlog
        after.capturePreservation=value;after.captureBacklog=backlog
        if sharedStore != nil,window.postLease?.grow(after.metadataMemoryCharge) != true {
            capturePostOverflow[before.trigger.rawValue,default:0]+=max(1,after.frames.count)
            var context=DiagnosticCriticalJournal.Context(trace:runID,incident:before.incident,sequence:sequence,lane:0,kind:before.trigger.rawValue,category:1,count:after.frames.count,episode:0);context.requestID=window.requests.first?.requestID
            OperationalDiagnostics.shared.record(.policy(.captureDisposition,6),context:context,observation:true)
            manual?.finish(.incomplete)
            windows.removeValue(forKey:before.incident);return
        }
        let writeBefore=window.deferred,generation=window.generation,incident=before.incident,postLease=window.postLease
        queue.async{[self] in
            let attemptedPost=gate.generation==generation
            if !attemptedPost{manual?.finish(.incomplete)}
            if eagerPreCapture {
                if attemptedPost{write(after,lease:postLease,manual:manual)}
            }else {
                if writeBefore,attemptedPost{write(before,manual:manual)}
                if attemptedPost{write(after,lease:postLease,manual:manual)}
            }
            decisionQueue.async{[self] in
                lock.lock();defer{lock.unlock()}
                guard let current=windows[incident],current.generation==generation else{return}
                if attemptedPost{completedWindows+=1}else{
                    for request in current.requests{captureDiscarded[request.trigger,default:0]+=1}
                }
                windows.removeValue(forKey:incident)
            }
        }
    }
    private func write(_ capture:Capture,lease:DiagnosticCaptureLease?=nil,manual:DiagnosticManualCapture?=nil){
        if let writer{writer(capture);manual?.saved(phase:capture.phase);return}
        if let sharedStore {
            let phase=capture.phase
            _ = sharedStore.save(capture,lease:lease,completion:manual.map{receipt in {saved in
                if saved{receipt.saved(phase:phase)}else{receipt.finish(.incomplete)}
            }})
            if sharedStore.stats.lastFailure != nil{manual?.waiting(retry:sharedStore.canRetry)}
            storageObserver?()
            return
        }
        manual?.finish(.unavailable)
    }
    // No extra event tag, AX call, event copy, key post or source selection.
    func event(_ lane:Lane,_ type:CGEventType,_ event:CGEvent,consumed:Bool=false,duration:Double=0,started:CallbackStart?=nil){
        guard enabled,!secureInput() else{return}
        noteActivity()
        let work=finishCallback(started),workGeneration=started?.generation
        let time=clock(),reference=EventReference(event,type)
        let evidence = lane == .hid || lane == .main ? EventEvidence(time:time,origin:origin,type:type,event:event):nil
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        let isSpace=code==49 && (type == .keyDown || type == .keyUp)
        let editing=event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty == false || [36,48,51,53,76,117,123,124,125,126].contains(code)
        let pointer=type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let edge=type == .keyDown ? 1:(type == .keyUp ? 2:3)
        let category=pointer ? 4:(editing ? 2:(type == .flagsChanged ? 3:1))
        _ = submit(.event,lane,edge+(consumed ? 4:0),observedAt:time){[self] timing in
            if editing || pointer{lastEdit=time;invalidateShapes()}
            let (identifier,origin)=eventIdentity(reference)
            append(lane,.event,observedAt:time,observationTiming:timing,event:identifier,edge:edge,category:category,inputOrigin:origin,consumed:consumed,duration:duration)
            ring[(position-1+capacity)%capacity]?.workEvidence=workGeneration==gate.generation ? work:nil
            ring[(position-1+capacity)%capacity]?.eventEvidence=evidence
            updatePreservedLastFrame()
            // Metadata worker only. No new input tap, timer, AX/TIS call or key post.
            var reason=0
            if edge==1 && isSpace {
                if [Lane.hid,Lane.main].contains(lane) {
                    if let previous=lastSpaceDown[lane.rawValue],time>=previous,time-previous<=0.08 {reason=1}
                    lastSpaceDown[lane.rawValue]=time
                }
                if consumed {reason=2}
                if origin==2 {reason=3}
                if evidence?.autoRepeat==true {reason=4}
            } else if edge==1 || edge==3 {lastSpaceDown.removeValue(forKey:lane.rawValue)}
            if reason>0,time-(lastSpaceCapture[reason] ?? -Double.infinity)>=1 {
                lastSpaceCapture[reason]=time
                requestCapture(.spaceObservation,lane:lane,detail:reason,reference:reference,time:time)
            }
        }
        // Preserve the request even when event queue capacity was exhausted.
        if duration>=0.05{requestCapture(.callbackDelay,lane:lane,event:event,duration:duration)}
    }
    // Called only while holding the trace lock; never writes to the event.
    private func eventIdentity(_ event:CGEvent,type:CGEventType)->(Int,Int) {
        eventIdentity(EventReference(event,type))
    }
    private func eventIdentity(_ reference:EventReference, observedID:Int?=nil)->(Int,Int) {
        let raw=reference.token
        let physicalTag=(raw>>48)==0x4852 || (raw>>32)==0x48514556
        let inputOrigin=(raw>>32)==0x48414B53 ? 3:((raw>>32)==0x48414E51 ? 2:1)
        let timestampKey=Identity(token:reference.timestamp,type:reference.type.rawValue,domain:inputOrigin,modifier:reference.modifier)
        let taggedKey=physicalTag ? Identity(token:raw,type:reference.type.rawValue,domain:0):nil
        if identities.count>=capacity{identities.removeAll()}
        // A tagged Shift transition without a matching receipt can share a
        // timestamp with another key. Only its own tag can identify it.
        let taggedShift = taggedKey != nil && reference.type == .flagsChanged && reference.modifier == ModifierRole.shift.rawValue
        let timestampMatch = !taggedShift && reference.timestamp > 0 ? identities[timestampKey] : nil
        let known = observedID ?? taggedKey.flatMap { identities[$0] } ?? timestampMatch
        let identifier:Int
        if let known{identifier=known}else{eventSequence+=1;identifier=eventSequence}
        if reference.timestamp>0{identities[timestampKey]=identifier}
        if let taggedKey{identities[taggedKey]=identifier}
        return (identifier,inputOrigin)
    }
    func decision(_ site:DecisionSite,_ reason:DecisionReason,event:CGEvent?=nil) {
        let generation=gate.generation;guard generation>0,!secureInput() else{return}
        // Reserve 3/4 of the bounded queue for input decisions and non-routine
        // reasons. Repeated idle allowed/no-candidate/Roman calls cannot fill it.
        let routine=event==nil && (reason == .observationAllowed || reason == .noCandidate || reason == .romanSource)
        let credits=routine ? routineCredits:importantCredits
        guard credits.wait(timeout:.now()) == .success else{
            let code=((site.rawValue-1)*31+reason.rawValue-1)*2+(event==nil ? 0:1)
            overflowSignals[code].signal();return
        }
        let observedAt=clock(),reference=event.map{EventReference($0,$0.type)},enqueuedAt=decisionClock()
        decisionQueue.async{[self] in
            defer{credits.signal()}
            guard gate.generation==generation else{return}
            let dequeuedAt=decisionClock()
            let contended = !lock.try()
            var waitNanos:UInt64=0
            if contended {
                let began=decisionClock()
                lock.lock() // Background worker only; never the input caller.
                let acquired=decisionClock()
                waitNanos=acquired>=began ? acquired-began:0
            }
            defer{lock.unlock()}
            let queueNanos=dequeuedAt>=enqueuedAt ? dequeuedAt-enqueuedAt:0
            let timing=DecisionTiming(queueMicros:Int(min(queueNanos/1000,60_000_000)),lockWaitMicros:Int(min(waitNanos/1000,60_000_000)),contended:contended,clipped:queueNanos>60_000_000_000 || waitNanos>60_000_000_000)
            let code=((site.rawValue-1)*31+reason.rawValue-1)*2+(reference==nil ? 0:1)
            var stats=decisionWaits[code,default:DecisionWaitStats()]
            stats.processed+=1
            if contended{stats.contended+=1}
            stats.totalLockWaitMicros+=timing.lockWaitMicros
            stats.maxLockWaitMicros=max(stats.maxLockWaitMicros,timing.lockWaitMicros)
            stats.maxQueueMicros=max(stats.maxQueueMicros,timing.queueMicros)
            if timing.clipped{stats.clipped+=1}
            decisionWaits[code]=stats
            // A repeated idle reason still gets an individual frame when it
            // actually waited for this lock. Uncontended repeats remain counted.
            if reference==nil,lastDecisions[site]==reason,!contended,!timing.clipped,timing.queueMicros<50_000{decisionCoalesced[code,default:0]+=1;return}
            lastDecisions[site]=reason
            let (identifier,origin)=reference.map{eventIdentity($0)} ?? (0,0)
            append(.mismatch,.detectionDecision,observedAt:observedAt,decisionTiming:timing,event:identifier,edge:site.rawValue,category:reason.rawValue,inputOrigin:origin)
        }
    }
    // Existing snapshot guard results only. No AX values, coordinates or extra reads.
    enum ReadOutcome:Int,Codable,CaseIterable {
        case success=1,accessibilityPermission,secureInput,targetNotFrontmost,focusedElementUnreadable
        case secureField,roleUnreadable,unsupportedTextField,activeComposition,textUnreadable
        case selectionUnreadable,selectionInvalid,focusChanged,attributeBatchUnreadable,editorCoordinatesUnverified
        case metadataOnly,other
        static func snapshot(_ reason:String,includesContent:Bool=true)->ReadOutcome {
            switch reason {
            case "":return includesContent ? .success:.metadataOnly
            case "accessibility_permission":return .accessibilityPermission
            case "secure_input":return .secureInput
            case "target_not_frontmost":return .targetNotFrontmost
            case "focused_element_unreadable":return .focusedElementUnreadable
            case "secure_field","secure_text_field":return .secureField
            case "role_unreadable":return .roleUnreadable
            case "not_supported_text_field":return .unsupportedTextField
            case "active_composition":return .activeComposition
            case "text_unreadable":return .textUnreadable
            case "selection_unreadable":return .selectionUnreadable
            case "selection_invalid":return .selectionInvalid
            case "focus_changed_during_snapshot":return .focusChanged
            case "attribute_batch_unreadable":return .attributeBatchUnreadable
            case "editor_coordinates_unverified":return .editorCoordinatesUnverified
            default:return .other
            }
        }
        var label:String {
            switch self {
            case .success:return "본문·커서 조회 성공"
            case .accessibilityPermission:return "손쉬운 사용 권한 없음"
            case .secureInput:return "보안 입력으로 조회 생략"
            case .targetNotFrontmost:return "입력 대상이 현재 포커스와 다름"
            case .focusedElementUnreadable:return "포커스 요소 조회 불가"
            case .secureField:return "보안 입력칸으로 조회 중단"
            case .roleUnreadable:return "입력칸 역할 조회 불가"
            case .unsupportedTextField:return "지원하지 않는 입력칸 역할"
            case .activeComposition:return "편집기의 진행 중 조합으로 조회 중단"
            case .textUnreadable:return "본문 값 조회 불가"
            case .selectionUnreadable:return "커서·선택 범위 조회 불가"
            case .selectionInvalid:return "커서·선택 범위 유효성 확인 실패"
            case .focusChanged:return "조회 중 포커스 변경"
            case .attributeBatchUnreadable:return "AX 속성 일괄 조회 불가"
            case .editorCoordinatesUnverified:return "편집기 본문·범위 표현 확인 실패"
            case .metadataOnly:return "본문을 요청하지 않은 역할 조회"
            case .other:return "분류되지 않은 조회 중단"
            }
        }
    }
    enum ReadPurpose:Int,Codable {case unknown=0,background,active}
    static func compactRead(_ purpose:ReadPurpose,_ outcome:ReadOutcome?,activityUnchanged:Bool)->Bool {
        purpose == .background && activityUnchanged && outcome.map{[ReadOutcome.success,.unsupportedTextField,.focusChanged,.targetNotFrontmost].contains($0)} == true
    }
    final class ReadSpan {
        fileprivate let token=UUID(),began:Double
        fileprivate let generation:Int32
        fileprivate let purpose:ReadPurpose,activity:Int64
        fileprivate var watchdogCaptured=false // decisionQueue only
        private let credits:DispatchSemaphore
        private let endCredits=DispatchSemaphore(value:1)
        fileprivate func reserveEnd()->Bool {endCredits.wait(timeout:.now()) == .success}
        private var released=false
        fileprivate func finish(){if !released{released=true;credits.signal()}}
        fileprivate init(began:Double,credits:DispatchSemaphore,generation:Int32,purpose:ReadPurpose,activity:Int64){self.began=began;self.credits=credits;self.generation=generation;self.purpose=purpose;self.activity=activity}
        deinit {
            // Restore a claimed one-shot semaphore before libdispatch destroys it.
            _ = endCredits.wait(timeout:.now());endCredits.signal()
            if !released{credits.signal()}
        }
    }
    func beginRead(_ lane:Lane,purpose:ReadPurpose = .unknown,activityAtRequest:Int64?=nil)->ReadSpan? {
        let generation=gate.generation;guard generation>0 else{return nil}
        guard readCredits.wait(timeout:.now()) == .success else {
            observationOverflowSignals[observationCode(.readStart,lane)].signal();return nil
        }
        let span=ReadSpan(began:clock(),credits:readCredits,generation:generation,purpose:purpose,activity:activityAtRequest ?? activityEpoch)
        // One lease reserves both queued endpoints and an active read, independent
        // of event/shape floods. No AX object or CGEvent is retained.
        let enqueued=observationClock()
        decisionQueue.async{[self,span] in
            guard gate.generation==generation else{return}
            withObservation(.readStart,lane,observedAt:span.began,enqueuedAt:enqueued){timing in
            guard reads.count<readCapacity else {
                observationOverflow[observationCode(.readStart,lane),default:0]+=1;return
            }
            readSequence+=1;reads[span.token]=(readSequence,span.began,lane,span)
            append(lane,.read,observedAt:span.began,observationTiming:timing,event:readSequence,category:1)
            }
        }
        return span
    }
    func endRead(_ lane:Lane,_ span:ReadSpan?,outcome:ReadOutcome?=nil,focus:InputIncidentFocusEvidence?=nil,axResult:InputIncidentAXResult?=nil,applications:DiagnosticApplicationPIDs?=nil){
        guard let span else{if enabled{observationOmittedSignals[observationCode(.readEnd,lane)].signal()};return}
        guard span.reserveEnd() else{if gate.generation==span.generation{observationOmittedSignals[observationCode(.readEnd,lane)].signal()};return}
        let ended=clock(),duration=ended-span.began
        let unchanged=span.activity==activityEpoch
        let work=workEvidence(began:span.began,ended:ended)
        let applicationPIDs=secureInput() || [.secureInput,.secureField,.accessibilityPermission].contains(outcome) ? nil:applications
        let enqueued=observationClock()
        decisionQueue.async{[self,span] in
            defer{span.finish()}
            guard gate.generation==span.generation else{reads.removeValue(forKey:span.token);return}
            let applicationRefs=secureInput() ? nil:applicationRegistry.references(applicationPIDs)
            withObservation(.readEnd,lane,observedAt:ended,enqueuedAt:enqueued){timing in
            guard let read=reads.removeValue(forKey:span.token) else {
                observationOmitted[observationCode(.readEnd,lane),default:0]+=1;return
            }
            if duration>=0.05 {
                let compact = !span.watchdogCaptured && axResult?.hasFailure != true && Self.compactRead(span.purpose,outcome,activityUnchanged:unchanged)
                if slowReads.insert(read.id).inserted{recordSlowRead(id:read.id,lane:lane,began:read.began,observed:read.began,phase:1,span:span)}
                recordSlowRead(id:read.id,lane:lane,began:read.began,observed:ended,phase:2,outcome:outcome,span:span,unchanged:unchanged,compact:compact,axResult:axResult,applications:applicationRefs)
                if !compact{requestCapture(.axDelay,lane:lane,detail:outcome?.rawValue ?? 0,reference:nil,time:ended,duration:duration,correlation:span.token.uuidString)}
            }
            slowReads.remove(read.id)
            append(lane,.read,observedAt:ended,observationTiming:timing,event:read.id,category:2,duration:duration)
            ring[(position-1+capacity)%capacity]?.workEvidence=work
            ring[(position-1+capacity)%capacity]?.readOutcome=outcome
            ring[(position-1+capacity)%capacity]?.focusEvidence=focus
            ring[(position-1+capacity)%capacity]?.applications=applicationRefs
            updatePreservedLastFrame()
            }
        }
    }
    private func recordSlowRead(id:Int,lane:Lane,began:Double,observed:Double,phase:Int,outcome:ReadOutcome?=nil,span:ReadSpan?=nil,unchanged:Bool?=nil,compact:Bool=false,axResult:InputIncidentAXResult?=nil,applications:DiagnosticApplicationReferences?=nil){
        var context=DiagnosticCriticalJournal.Context(trace:runID,incident:0,sequence:sequence,lane:lane.rawValue,kind:Kind.read.rawValue,category:phase,count:1,episode:0)
        context.operationID=id;context.beganMilliseconds=Int(max(0,(began-origin)*1000));context.observedMilliseconds=Int(max(0,(observed-origin)*1000))
        let duration=max(0,observed-began);context.durationMicros=Int(min(duration,60)*1_000_000);context.durationClipped=duration>60;context.outcome=outcome?.rawValue
        context.readToken=span?.token.uuidString;context.readPurpose=span?.purpose.rawValue;context.activityUnchanged=unchanged;context.detailPolicy=phase==2 ? (compact ? 2:1):nil;context.axResult=axResult
        context.applicationReferences=applications
        // Standalone compact facts must remain interpretable after detailed
        // captures expire or are not selected. At most two bounded app records.
        context.applicationInfo=applicationRegistry.snapshot(DiagnosticApplicationReferences.ids(applications?.packed ?? 0))
        OperationalDiagnostics.shared.record(.policy(.slowRead,phase),context:context,observation:true)
    }
    func start(){
        guard enabled,timer==nil else{return}
        let generation=gate.generation
        let source=DispatchSource.makeTimerSource(queue:queue)
        source.schedule(deadline:.now()+0.1,repeating:.milliseconds(100))
        source.setEventHandler{[weak self] in
            guard let self,self.gate.generation==generation else{return}
            let time=self.clock()
            _ = self.submit(.timer,.main,observedAt:time){[self] _ in
                self.ring.trim(now:Int(max(0,(time-self.origin)*1000)))
                for read in self.reads.values where time-read.began>=0.1 && self.slowReads.insert(read.id).inserted {
                    self.recordSlowRead(id:read.id,lane:read.lane,began:read.began,observed:time,phase:1,span:read.span)
                }
                for read in self.reads.values where time-read.began>=0.1 && !read.span.watchdogCaptured {
                    read.span.watchdogCaptured=true
                    self.requestCapture(.axDelay,lane:read.lane,duration:time-read.began,correlation:read.span.token.uuidString)
                }
            }
        }
        timer=source;source.resume()
    }
    // Retain the final fixed metadata even when a context/edit boundary ends
    // its validity. Never use an inactive diagnostic baseline for shrink checks.
    private func invalidateShapes(){
        for lane in Array(shapes.keys) {
            guard var value=shapes[lane],value.active else{continue}
            if value.point.evidence.observations>value.reportedObservations {
                appendShape(lane,value.point,phase:3,time:origin+Double(value.point.evidence.lastMilliseconds)/1000)
            }
            value.active=false;value.reportedObservations=value.point.evidence.observations;shapes[lane]=value
        }
    }
    private func shapeSnapshot()->[ShapeBaseline] {
        shapes.keys.sorted{$0.rawValue<$1.rawValue}.map{lane in
            let shape=shapes[lane]!
            var current=shape.point
            current.evidence=shapeEvidence(current.evidence,phase:2)
            return ShapeBaseline(lane:lane,active:shape.active,current:current,previous:shape.previous)
        }
    }
    private func shapeEvidence(_ value:ShapeEvidence,phase:Int)->ShapeEvidence {
        ShapeEvidence(phase:phase,comparisonKnown:value.comparisonKnown,contentChanged:value.contentChanged,selectionChanged:value.selectionChanged,editingChanged:value.editingChanged,gap:value.gap,editing:value.editing,firstMilliseconds:value.firstMilliseconds,lastMilliseconds:value.lastMilliseconds,observations:value.observations,coalesced:value.coalesced,baselineSequence:value.baselineSequence,ax:value.ax,caretPrecedingClass:value.caretPrecedingClass,selectionMotion:value.selectionMotion,applications:value.applications)
    }
    private func appendShape(_ lane:Lane,_ point:ShapePoint,phase:Int,time:Double,timing:DecisionTiming?=nil){
        append(lane,.shape,observedAt:time,observationTiming:timing,count:point.count,selected:point.selected,field:point.field)
        ring[(position-1+capacity)%capacity]?.milliseconds=point.evidence.lastMilliseconds
        ring[(position-1+capacity)%capacity]?.shapeEvidence=shapeEvidence(point.evidence,phase:phase)
        updatePreservedLastFrame()
    }
    func shape(_ lane:Lane,identity:UInt,count:Int,selected:Bool,editing:Bool,change:ShapeChange?=nil,applications:DiagnosticApplicationPIDs?=nil){
        guard enabled else{return};let time=clock()
        let applicationPIDs=secureInput() ? nil:applications
        // Only fixed scalars are retained by submit. The probe's String stays
        // on the engine's snapshot path; input callbacks never take our lock.
        _ = submit(.shape,lane,observedAt:time){[self] timing in
            let applicationRefs=secureInput() ? nil:applicationRegistry.references(applicationPIDs)
            if fields.count>=256{fields.removeAll();invalidateShapes()}
            if fields[identity]==nil{nextField+=1;fields[identity]=nextField}
            let previous=shapes[lane]
            let sameField=previous?.active==true && previous?.field==identity
            let gap=change.map{value in
                if let sample=previous?.sample{return value.sample != sample+1}
                return value.known && previous==nil
            } ?? false
            let known=sameField && change?.known==true && !gap
            let changed = !sameField || previous?.count != count || previous?.selected != selected || previous?.editing != editing || change?.content==true || change?.selection==true || gap || previous?.point.evidence.ax != change?.ax || previous?.point.evidence.applications != applicationRefs
            let ms=Int(max(0,time-origin)*1000)
            if changed {
                // Close suppressed intervals before starting the new baseline.
                if let previous,previous.active,previous.point.evidence.observations>previous.reportedObservations {
                    appendShape(lane,previous.point,phase:3,time:origin+Double(previous.point.evidence.lastMilliseconds)/1000)
                }
                let evidence=ShapeEvidence(phase:1,comparisonKnown:known,contentChanged:known && change?.content==true,selectionChanged:known && change?.selection==true,editingChanged:sameField && previous?.editing != editing,gap:gap,editing:editing,firstMilliseconds:ms,lastMilliseconds:ms,observations:1,coalesced:0,baselineSequence:sequence+1,ax:change?.ax,caretPrecedingClass:change?.caretPrecedingClass,selectionMotion:change?.selectionMotion.map{known ? $0:0},applications:applicationRefs)
                let point=ShapePoint(field:fields[identity]!,count:count,selected:selected,evidence:evidence)
                appendShape(lane,point,phase:1,time:time,timing:timing)
                shapes[lane]=Shape(field:identity,count:count,selected:selected,editing:editing,active:true,sample:change?.sample,point:point,previous:previous.map{value in var point=value.point;point.evidence=shapeEvidence(point.evidence,phase:3);return point},checkpointAt:time,reportedObservations:1)
            } else if var current=previous {
                current.sample=change?.sample
                current.point.evidence.lastMilliseconds=ms;current.point.evidence.observations+=1
                let emit=timing.contended || timing.clipped || timing.queueMicros>=50_000 || time-current.checkpointAt>=1
                if emit {
                    appendShape(lane,current.point,phase:2,time:time,timing:timing)
                    current.checkpointAt=time;current.reportedObservations=current.point.evidence.observations
                } else {
                    observationCoalesced[observationCode(.shape,lane),default:0]+=1
                    current.point.evidence.coalesced+=1
                }
                shapes[lane]=current
            }
            let suspect=previous.map{$0.active && $0.field==identity && !$0.selected && !selected && count<$0.count} ?? false
            if suspect && !editing && time-lastEdit>0.4{requestCapture(.possibleShrink,lane:lane,correlation:change?.transitionID.map{"shape-\($0)"})}
        }
    }
    func state(_ lane:Lane,_ state:State,pending:Int=0){
        guard enabled else{return};let time=clock()
        noteActivity()
        _ = submit(.state,lane,state.rawValue,observedAt:time){[self] timing in
            if state != .buffered{lastEdit=time;invalidateShapes()}
            append(lane,.state,observedAt:time,observationTiming:timing,category:state.rawValue,count:pending)
        }
    }
    // Read-only focus decisions must not move the edit boundary or invalidate
    // shape baselines. The existing state() method is for actual edits.
    func focusHandoffObservation(_ state:State){
        guard enabled,!secureInput(),(9...15).contains(state.rawValue) else{return}
        let time=clock()
        _ = submit(.state,.onset,state.rawValue,observedAt:time){[self] timing in
            append(.onset,.state,observedAt:time,observationTiming:timing,category:state.rawValue)
        }
    }
    // Existing numeric branch results only. No additional AX/source query,
    // event objects, synchronous lock or file I/O on the caller.
    func onsetDecision(_ site:OnsetSite,_ reason:OnsetReason,firstTime:Double?=nil,keys:Int=0,detail:OnsetDetail?=nil){
        guard enabled,!secureInput() else{return}
        let time=clock(),count=max(0,min(keys,16))
        let age=firstTime.flatMap{first -> Int? in
            let elapsed=time-first
            return elapsed.isFinite && elapsed>=0 && elapsed<=60 ? Int(elapsed*1_000_000):nil
        }
        _ = submit(.context,.onset,16+site.rawValue,observedAt:time){[self] timing in
            let code=site.rawValue*32+reason.rawValue
            let signature=detail?.signature ?? 0
            if let firstTime,let prior=lastOnsetDecisions[code],prior.first==firstTime,prior.keys==count,prior.detail==signature {
                observationCoalesced[observationCode(.context,.onset,16+site.rawValue),default:0]+=1
                return
            }
            if let firstTime{lastOnsetDecisions[code]=(firstTime,count,signature)}
            append(.onset,.onsetDecision,observedAt:time,observationTiming:timing,edge:site.rawValue,category:reason.rawValue)
            ring[(position-1+capacity)%capacity]?.onsetEvidence=OnsetEvidence(keys:count,firstKeyAgeMicros:age,detail:detail)
            updatePreservedLastFrame()
        }
    }
    func onsetObservation(_ value:OnsetObservation,capture:Bool=false){
        guard enabled,!secureInput(),value.valid else{return}
        let time=clock()
        _ = submit(.context,.onset,22,observedAt:time){[self] timing in
            append(.onset,.onsetObservation,observedAt:time,observationTiming:timing)
            ring[(position-1+capacity)%capacity]?.onsetObservation=value
            updatePreservedLastFrame()
            if capture{requestCapture(.onsetObservation,lane:.onset,episode:value.episode)}
        }
    }
    // Each update is self-contained in case the commit-time queue slot was busy.
    func recordSwitchLayout(_ record: DiagnosticSwitchLayout, generation: Int32) {
        guard generation > 0, gate.generation == generation, !secureInput() else { return }
        _ = submit(.context, .main, 22) { [self] _ in
            guard gate.generation == generation else { return }
            if recentSwitchLayouts.last?.id == record.id {
                recentSwitchLayouts[recentSwitchLayouts.count - 1] = record
            } else {
                if recentSwitchLayouts.count == DiagnosticSwitchLayout.limit { recentSwitchLayouts.removeFirst() }
                recentSwitchLayouts.append(record)
            }
        }
    }
    func sourceEvidence(_ action:SourceEvidenceAction,_ value:SourceEvidence,event:CGEvent?=nil){
        guard enabled,!secureInput() else{return}
        let time=clock(),reference=event.map{EventReference($0,$0.type)}
        _ = submit(.context,.mismatch,action.rawValue,observedAt:time){[self] timing in
            let signature=value.selected+value.confirmed*8+value.target*64+(value.committed ? 512:0)+(value.deferred ? 1024:0)+(value.candidatePreserved ? 2048:0)+(value.historyPreserved ? 4096:0)
            if reference==nil,(action == .romanSkipped || action == .deferred),lastSourceEvidence[action.rawValue]==signature,!timing.contended,!timing.clipped,timing.queueMicros<50_000 {
                observationCoalesced[observationCode(.context,.mismatch,action.rawValue),default:0]+=1;return
            }
            lastSourceEvidence[action.rawValue]=signature
            let (identifier,origin)=reference.map{eventIdentity($0)} ?? (0,0)
            append(.mismatch,.sourceEvidence,observedAt:time,observationTiming:timing,event:identifier,edge:action.rawValue,category:value.selected,inputOrigin:origin)
            let index=(position-1+capacity)%capacity
            ring[index]?.sourceEvidence=value
            updatePreservedLastFrame()
        }
    }
    // Observe callback entry before the routing gate or keyboard-state mirror can return.
    // A flagsChanged event identifies a transition without asserting press or release.
    @discardableResult
    func modifierArrived(_ stage: ModifierStage, _ type: CGEventType, _ event: CGEvent,
                         from original: @autoclosure () -> ShiftArrival? = nil) -> ShiftArrival? {
        let generation = gate.generation
        guard generation > 0, type == .flagsChanged || type == .keyDown || type == .keyUp,
              stage != .recipientHID || type != .flagsChanged,
              let role = ModifierRole(event: event), !secureInput() else { return nil }
        let edge = type == .flagsChanged ? 3 : (type == .keyDown ? 1 : 2)
        let time = clock()
        let reference = EventReference(event, type, modifierRole: role)
        let untaggedShift = stage == .switchHID && role == .shift && reference.token == 0
        let receipt = untaggedShift ? ShiftArrival(runID: runID, generation: generation) : nil
        let previous = stage == .main && role == .shift ? original() : nil
        let submitted = submit(.event, stage.lane, 8 + role.rawValue, observedAt: time) { [self] timing in
            guard gate.generation == generation else { return }
            var observedID: Int?
            if receipt != nil && type == .flagsChanged {
                // This is the first callback for this edge. Two Shift edges can
                // carry the same timestamp before they get their distinct tags.
                eventSequence += 1
                observedID = eventSequence
            } else if let previous, previous.runID == runID, previous.generation == generation {
                observedID = previous.identifier
            }
            let (identifier, origin) = eventIdentity(reference, observedID: observedID)
            receipt?.identifier = identifier
            append(stage.lane, .modifierArrival, observedAt: time, observationTiming: timing,
                   event: identifier, edge: edge, category: role.rawValue, inputOrigin: origin,
                   modifierStage: stage)
        }
        return submitted ? receipt : nil
    }

    func control(_ lane:Lane,_ type:CGEventType,_ event:CGEvent?,_ value:InputIncidentControl,consumed:Bool=false){
        guard enabled,!secureInput() else{return}
        let time=clock(),reference=event.map{EventReference($0,type)}
        let evidence = lane == .hid || lane == .main ? event.map{EventEvidence(time:time,origin:origin,type:type,event:$0)}:nil
        _ = submit(.context,lane,8+value.role,observedAt:time){[self] timing in
            let (identifier,origin)=reference.map{eventIdentity($0)} ?? (0,0)
            append(lane,.controlDecision,observedAt:time,observationTiming:timing,event:identifier,edge:value.role,category:value.route,inputOrigin:origin,consumed:consumed)
            ring[(position-1+capacity)%capacity]?.controlEvidence=value
            ring[(position-1+capacity)%capacity]?.eventEvidence=evidence
            updatePreservedLastFrame()
        }
    }
    // Existing HUD work only: firstDraw is AppKit drawing, not compositor receipt.
    func hud(_ stage:HUDStage,sourceClass:Int,presentation:Int=0){
        guard enabled,!secureInput() else{return};let time=clock()
        _ = submit(.context,.main,16+stage.rawValue,observedAt:time){[self] timing in
            append(.main,.hud,observedAt:time,observationTiming:timing,event:max(0,presentation),edge:stage.rawValue,category:max(0,min(sourceClass,4)))
        }
    }
    func context(){
        guard enabled else{return};let time=clock()
        noteActivity()
        _ = submit(.context,.main,observedAt:time){[self] timing in lastEdit=time;invalidateShapes();append(.main,.context,observedAt:time,observationTiming:timing)}
    }
    func sourceBoundary(_ stage:BoundaryStage,queued:Int,awaitingOnset:Int){
        guard enabled else{return};let time=clock()
        noteActivity()
        // Accounting has 32 detail slots per lane. Keep each full stage on
        // the frame and use the reserved aggregate slot for appended stages.
        let detail=stage.rawValue<32 ? stage.rawValue:0
        _ = submit(.boundary,.sourceBoundary,detail,observedAt:time){[self] timing in
            append(.sourceBoundary,.sourceBoundary,observedAt:time,observationTiming:timing,event:awaitingOnset,category:stage.rawValue,count:queued)
        }
        if stage == .retained || stage == .deadline || stage == .focusChanged || stage == .failed || stage == .manualEditUnverified || stage == .inputResumed || stage == .editorDivergedInputResumed || stage == .nativeSelectAllDivergedInputResumed {requestCapture(.boundaryInterrupted,lane:.sourceBoundary,detail:stage.rawValue)}
        if stage == .initialTransportCompleted {
            var completed=DiagnosticCriticalJournal.Context(trace:runID,incident:0,sequence:0,lane:Lane.sourceBoundary.rawValue,kind:Kind.sourceBoundary.rawValue,category:stage.rawValue,count:queued,episode:0)
            completed.observedMilliseconds=Int(max(0,(time-origin)*1000));completed.detailPolicy=2
            OperationalDiagnostics.shared.record(.policy(.boundaryCompletion,stage.rawValue),context:completed,observation:true)
        }
    }
    func boundaryComparison(_ evidence:BoundaryEvidence){
        guard enabled,evidence.valid else{return};let time=clock()
        // The existing bounded metadata worker; no new timer, AX/TIS query or capture.
        _ = submit(.context,.sourceBoundary,observedAt:time){[self] timing in
            append(.sourceBoundary,.boundaryComparison,observedAt:time,observationTiming:timing)
            ring[(position-1+capacity)%capacity]?.boundaryEvidence=evidence
            updatePreservedLastFrame()
        }
    }
    // Own capture admission: ordinary observation overflow cannot erase the
    // detector reason. The serial worker freezes the pre-edit ring; storage
    // throttling defers publication, not preservation. No caller-side AX/I/O.
    func recoveryStarted(_ lane:Lane,reason:RecoveryReason){
        guard enabled,!secureInput(),
              (lane == .mismatch && ((1...6).contains(reason.rawValue) || reason == .unspecifiedMismatch)) ||
              (lane == .onset && (7...9).contains(reason.rawValue)) else{return}
        requestCapture(.recoveryStarted,lane:lane,detail:reason.rawValue)
    }
    func mark(completion:((DiagnosticManualCapture.Status)->Void)?=nil){
        let manual=completion.map{DiagnosticManualCapture(completion:$0)}
        guard enabled else{manual?.finish(.unavailable);return};let time=clock()
        _ = submit(.marker,.main,observedAt:time){[self] timing in append(.main,.marker,observedAt:time,observationTiming:timing)}
        requestCapture(.manual,manual:manual)
    }
    // Freeze the export's event boundary on the decision queue. New incidents
    // do not extend this wait; already requested post-captures finish first.
    func prepareLegacyExport(index:Int,to directory:URL,request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest(),completion:@escaping(Result<Void,Error>)->Void){
        queue.async{[self] in
            do {
                guard legacyDirectories.indices.contains(index) else{throw DiagnosticLogExport.Failure.unavailable}
                let previous=DiagnosticLogStore(directory:legacyDirectories[index],policy:.investigation,persistentOwnership:true,readOnly:true)
                try previous.copyExportSnapshot(to:directory,reviewMetadata:true,request:request)
                completion(.success(()))
            }catch{completion(.failure(error))}
        }
    }
    func prepareExport(to directory:URL,reviewMetadata:Bool=false,request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest(),completion:@escaping(Result<Void,Error>)->Void){
        decisionQueue.async{[self] in
            let incidents=Set(windows.keys)
            finishExport(incidents:incidents,to:directory,reviewMetadata:reviewMetadata,request:request,deadline:DispatchTime.now()+15,completion:completion)
        }
    }
    private func finishExport(incidents:Set<Int>,to directory:URL,reviewMetadata:Bool,request:DiagnosticSnapshotRequest,deadline:DispatchTime,completion:@escaping(Result<Void,Error>)->Void){
        do{try request.check()}catch{completion(.failure(error));return}
        let pending=windows.values.filter{incidents.contains($0.before.incident) && !$0.submitted}
        if !pending.isEmpty {
            request.report(.waiting,pending.count,incidents.count)
            guard DispatchTime.now()<deadline else{completion(.failure(DiagnosticLogExport.Failure.busy));return}
            decisionQueue.asyncAfter(deadline:.now()+0.05){[self] in finishExport(incidents:incidents,to:directory,reviewMetadata:reviewMetadata,request:request,deadline:deadline,completion:completion)}
            return
        }
        queue.async{[self] in
            do {
                guard let storage else{throw DiagnosticLogExport.Failure.noLogs}
                let sharedPresent=sharedStore.map{FileManager.default.fileExists(atPath:$0.directory.path)} ?? false
                if sharedPresent{
                    let previous=sharedStore?.stats.lastFailure
                    _ = sharedStore?.prepare()
                    if previous != sharedStore?.stats.lastFailure{storageObserver?()}
                }
                let hasSharedCaptures=(sharedStore?.lastCaptureIncident ?? 0)>0
                // Freeze unsaved journal events before copying disk segments;
                // a concurrent successful write may duplicate an event ID, but
                // must not create a gap between the memory and disk snapshots.
                let pendingJournal=try destinationDirectory.map{try OperationalDiagnostics.shared.pendingExport(for:$0)} ?? []
                let journal=destinationDirectory.flatMap{OperationalDiagnostics.shared.storageStatus(for:$0,flush:true)}
                let hasJournalState=journal.map{$0.pendingErrors>0 || $0.pendingObservations>0 || $0.droppedErrors>0 || $0.droppedObservations>0 || $0.writeFailures>0} ?? false
                var pendingExport=DiagnosticPendingExport()
                do{try storage.copyExportSnapshot(to:directory,reviewMetadata:reviewMetadata,request:request,includeEmpty:hasSharedCaptures || hasJournalState || (sharedStore?.stats.pendingBytes ?? 0)>0)}
                catch{
                    try request.check()
                    if let failure=error as? DiagnosticLogExport.Failure,[.noLogs,.insufficientSpace].contains(failure){throw error}
                    // copyExportSnapshot removes only its own incomplete copy.
                    // An inaccessible original must not prevent exporting data
                    // still held by this process to a new review directory.
                    guard !FileManager.default.fileExists(atPath:directory.path) else{throw error}
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                    try DiagnosticSharedStore.writeExport(Data("{\"schema\":1,\"status\":{}}".utf8),to:directory.appendingPathComponent("storage-status.json"))
                    if reviewMetadata{try DiagnosticSharedStore.writeExport(Data("{}".utf8),to:directory.appendingPathComponent("review-dates.json"))}
                    pendingExport.unavailableSources.append("legacy-and-journal")
                }
                if let sharedStore,sharedPresent || sharedStore.stats.pendingBytes>0 {
                    let shared=try sharedStore.copyReviewSnapshot(into:directory,request:request)
                    pendingExport.captures=shared.captures;pendingExport.unavailableSources+=shared.unavailableSources
                }
                for (name,data,count) in pendingJournal {
                    try request.check();try DiagnosticSharedStore.writeExport(data,to:directory.appendingPathComponent(name))
                    pendingExport.journalFiles[name]=count
                }
                try DiagnosticSharedStore.writeExport(try JSONEncoder().encode(pendingExport),to:directory.appendingPathComponent("pending-export.json"))
                if let journal {
                    let path=directory.appendingPathComponent("critical-storage-status.json")
                    try JSONEncoder().encode(journal).write(to:path,options:.withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
                }
                let issues=DiagnosticStorageIssueSnapshot(issues:currentStorageIssues())
                let path=directory.appendingPathComponent("storage-issues.json")
                try JSONEncoder().encode(issues).write(to:path,options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
                completion(.success(()))
            }catch{completion(.failure(error))}
        }
    }
    #if HANQ_DIAGNOSTIC_TESTING
    func replayFrameForTest(_ frame:Frame){decisionQueue.sync{
        preservePreviousFrame();ring.trim(now:frame.milliseconds);ring[position]=frame
        position=(position+1)%capacity;sequence=frame.sequence;stored=min(capacity,stored+1)
    }}
    func sharedStatsForTest()->DiagnosticSharedStore.Stats?{queue.sync{sharedStore?.stats}}
    func historyBytesForTest()->Int{decisionQueue.sync{ring.accountedBytes}}
    func captureMemoryForTest()->DiagnosticCaptureMemory.Status{captureMemory.status}
    func reserveManualMemoryForTest(_ bytes:Int)->DiagnosticCaptureLease?{captureMemory.lease(bytes,manual:true)}
    func captureForTest(_ reason:Trigger){requestCapture(reason)}
    func flushCaptureWorkerForTest(){decisionQueue.sync{}}
    func finishCaptureWindowsForTest(){decisionQueue.sync{for window in windows.values where !window.closed{closeWindow(window)}}}
    func drainCapturesForTest(){decisionQueue.sync{lock.lock();defer{lock.unlock()};drainDeferred()}}
    func withLockedMetadataForTest(_ work:()->Void){lock.lock();defer{lock.unlock()};work()}
    #endif
    // Used by deterministic tests and shutdown only; never from an input callback.
    func flush(){for _ in 0..<4{decisionQueue.sync{};queue.sync{}}}
    func prepareForQuit(completion:@escaping(DiagnosticQuitState)->Void){
        _ = OSAtomicCompareAndSwap32Barrier(0,1,&preparingQuit)
        let generation=OSAtomicIncrement32Barrier(&quitGeneration)
        decisionQueue.async{[self] in
            guard OSAtomicAdd32Barrier(0,&quitGeneration)==generation else{return}
            finishCaptureWindowsForQuit()
            queue.async{[self] in
                _ = sharedStore?.retryForQuit()
                _ = OperationalDiagnostics.shared.flushCritical(timeout:0.25,retryNow:true)
                let journal=destinationDirectory.flatMap{OperationalDiagnostics.shared.storageStatus(for:$0)}
                completion(DiagnosticQuitState(detailPhases:sharedStore?.pendingCount ?? 0,errors:journal?.pendingErrors ?? 0,observations:journal?.pendingObservations ?? 0))
            }
        }
    }
    func cancelQuitPreparation(){
        _ = OSAtomicIncrement32Barrier(&quitGeneration)
        _ = OSAtomicCompareAndSwap32Barrier(1,0,&preparingQuit)
        queue.async{[self] in storageObserver?()}
    }
    private func finishCaptureWindowsForQuit(){
        lock.lock();defer{lock.unlock()}
        preservePreviousFrame()
        for window in windows.values.sorted(by:{$0.before.incident<$1.before.incident}) where !window.submitted {
            if !window.closed {
                window.closed=true;window.closedMilliseconds=Int(max(0,clock()-origin)*1000);window.endedOnShutdown=true
                window.after=snapshot(window.before.trigger,timing:DecisionTiming(queueMicros:0,lockWaitMicros:0,contended:false,clipped:false),incident:window.before.incident,phase:1,frames:window.post,requestedFrom:window.requests.first?.milliseconds,requestedThrough:window.requests.last.map{$0.milliseconds+3000})
            }
            submitWindow(window)
        }
    }
    func stopAfterQuitPreparation(){timer?.cancel();timer=nil;storageRetryTimer?.cancel();storageRetryTimer=nil;_ = gate.pause()}
    // Normal application termination, after input hooks have stopped. Cancel
    // future observations and let an in-progress storage transaction complete.
    func stopAndFlush(){
        timer?.cancel();timer=nil
        decisionQueue.sync{finishCaptureWindowsForQuit()}
        flush();_ = gate.pause()
    }
    deinit{timer?.cancel();storageRetryTimer?.cancel()}
}
enum DiagnosticLogExport {
    enum Failure:LocalizedError {
        case noLogs,unavailable,busy,compression,cancelled,timedOut,insufficientSpace
        var errorDescription:String? {
            switch self {
            case .noLogs:return "내보낼 진단 로그가 없습니다."
            case .unavailable:return "진단 로그를 안전하게 읽을 수 없습니다. 기존 파일은 유지됩니다."
            case .busy:return "요청한 진단 기록의 저장이 아직 끝나지 않았습니다. 잠시 후 다시 시도해 주세요."
            case .compression:return "진단 로그를 압축하지 못했습니다."
            case .cancelled:return "진단 기록 준비를 취소했습니다. 원본은 유지됩니다."
            case .timedOut:return "진단 기록 준비 시간이 초과되었습니다. 원본은 유지됩니다. 창을 다시 열어 주세요."
            case .insufficientSpace:return "진단 기록을 준비할 여유 공간이 부족합니다. 원본은 유지됩니다. 공간을 확보한 후 다시 시도해 주세요."
            }
        }
    }
    private static let worker=DispatchQueue(label:"hanq.diagnostics.export",qos:.utility)
    static func compress(_ directory:URL,to archive:URL,request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest())throws {
        try request.check()
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-c","-k","--keepParent","--norsrc",directory.path,archive.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        do {
            while process.isRunning{try request.check();Thread.sleep(forTimeInterval:0.05)}
            process.waitUntilExit()
        }catch{
            if process.isRunning{kill(process.processIdentifier,SIGKILL)}
            process.waitUntilExit();throw error
        }
        guard process.terminationStatus==0 else{throw Failure.compression}
    }
    static func export(_ trace:InputIncidentTrace,to desktop:URL,date:Date=Date(),completion:@escaping(Result<URL,Error>)->Void){
        worker.async {
            let fm=FileManager.default
            let temporary=fm.temporaryDirectory.appendingPathComponent("HanQ-Diagnostics-"+UUID().uuidString,isDirectory:true)
            do{try fm.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
            catch{completion(.failure(error));return}
            let logs=temporary.appendingPathComponent("HanQ-Diagnostics",isDirectory:true)
            trace.prepareExport(to:logs){result in worker.async{
                let fm=FileManager.default
                defer{try? fm.removeItem(at:temporary)}
                do{
                    try result.get()
                    let archive=temporary.appendingPathComponent("diagnostics.zip")
                    try compress(logs,to:archive)
                    let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
                    formatter.calendar=Calendar(identifier:.gregorian);formatter.dateFormat="yyyyMMdd-HHmmss"
                    let name="HanQ-Diagnostics-"+formatter.string(from:date)
                    let publication=desktop.appendingPathComponent(".HanQ-Diagnostics-"+UUID().uuidString+".zip")
                    try fm.copyItem(at:archive,to:publication)
                    defer{try? fm.removeItem(at:publication)}
                    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:publication.path)
                    for suffix in 0..<10000 {
                        let destination=desktop.appendingPathComponent(name+(suffix==0 ? "":"-\(suffix+1)")+".zip")
                        if link(publication.path,destination.path)==0{completion(.success(destination));return}
                        guard errno==EEXIST else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
                    }
                    throw Failure.unavailable
                }catch{completion(.failure(error))}
            }}
        }
    }
}

// Reusable storage policy, separate from capture/trigger semantics and export UI.
// The caller supplies privacy-screened data and serializes all calls off input
// callbacks. Automatic and manual byte budgets rotate independently. Only
// verified managed files may be removed; investigation archives never rotate.
/// One review request owns its cancellation and bounded preparation time.
/// Progress runs on a worker queue; callers marshal it onto the UI queue.
final class DiagnosticSnapshotRequest {
    enum Phase:Int {case waiting,copying,listing}
    private let lock=NSLock()
    private var cancelled=false
    private let deadline:DispatchTime
    private let progress:(Phase,Int,Int)->Void
    private var lastProgress:(Int,Int,Int)?
    init(timeout:Double=45,progress:@escaping(Phase,Int,Int)->Void={_,_,_ in}){
        deadline = .now()+timeout;self.progress=progress
    }
    func cancel(){lock.lock();cancelled=true;lock.unlock()}
    func check()throws {
        lock.lock();let stopped=cancelled;lock.unlock()
        if stopped{throw DiagnosticLogExport.Failure.cancelled}
        if DispatchTime.now()>=deadline{throw DiagnosticLogExport.Failure.timedOut}
    }
    func report(_ phase:Phase,_ completed:Int,_ total:Int){
        if phase != .waiting && completed != 0 && completed != total && completed%64 != 0{return}
        lock.lock()
        let same=lastProgress.map{$0.0==phase.rawValue && $0.1==completed && $0.2==total} ?? false
        lastProgress=(phase.rawValue,completed,total);lock.unlock()
        if !same{progress(phase,completed,total)}
    }
}

/// Review-only catalog, built while the writer already has the capture bytes.
/// Original diagnostic JSON is never replaced with a serialization of this model.
struct DiagnosticReviewCaptureHeader:Codable,Equatable {
    let schema:Int,trigger:Int,incident:Int,phase:Int
    let runID:String?
    var valid:Bool{schema==1 && (1...8).contains(trigger) && incident>0 && (0...1).contains(phase) && (runID==nil || UUID(uuidString:runID!) != nil)}
    static func read(_ data:Data)->Self? {
        guard let value=try? JSONDecoder().decode(Self.self,from:data),value.valid else{return nil}
        return value
    }
}
struct DiagnosticReviewCatalog:Codable {
    struct Entry:Codable {let bytes:Int,digest:String,header:DiagnosticReviewCaptureHeader}
    var schema=1
    let files:[String:Entry]
}

struct DiagnosticLogRetentionPolicy {
    let maximumAutomaticFiles:Int
    let maximumAutomaticBytes:Int
    let maximumManualBytes:Int
    static let incidentDefault=Self(maximumAutomaticFiles:64,maximumAutomaticBytes:32*1024*1024)
    static let investigation=Self(maximumAutomaticFiles:Int.max,maximumAutomaticBytes:Int.max,maximumManualBytes:Int.max)
    init(maximumAutomaticFiles:Int,maximumAutomaticBytes:Int,maximumManualBytes:Int=16*1024*1024){
        precondition(maximumAutomaticFiles>0 && maximumAutomaticBytes>0 && maximumManualBytes>0)
        self.maximumAutomaticFiles=maximumAutomaticFiles;self.maximumAutomaticBytes=maximumAutomaticBytes;self.maximumManualBytes=maximumManualBytes
    }
}

enum DiagnosticStorageRecovery {
    static func transient(_ error:OperationalFailure)->Bool {
        // A denied or read-only destination can recover without replacing this
        // writer. Every retry still runs its ownership/identity checks. Never
        // reinterpret a policy failure (replacement, corruption, unsafe mode)
        // as a recoverable errno, even if the numeric values happen to match.
        guard error.domain != .policy else{return false}
        let code=Int32(clamping:error.domain == .posix ? error.code:error.underlyingPOSIX)
        if [ENOSPC,EDQUOT,EIO,EAGAIN,EINTR,EMFILE,ENFILE,ENOMEM,EBUSY,EACCES,EPERM,EROFS].contains(code){return true}
        return error.domain == .cocoa && [NSFileReadNoPermissionError,NSFileWriteNoPermissionError,NSFileWriteVolumeReadOnlyError].contains(error.code)
    }
}

final class DiagnosticLogStore {
    enum Result:Int,Equatable {case saved=1,limit,retired,unavailable}
    // Fixed numeric state: no paths, input content, keys or arbitrary messages.
    // Accessed exclusively by the serial writer; never by input callbacks.
    struct Status:Codable {
        var maximumAutomaticFiles:Int,maximumAutomaticBytes:Int
        var maximumManualBytes:Int?,manualFiles:Int?,manualBytes:Int?
        var automaticFiles=0,automaticBytes=0
        var attempts=0,saved=0,limited=0,retired=0,unavailable=0,encodingFailures=0
        var evictedGroups=0,evictedFiles=0,evictedBytes=0
        var lastIncident=0,lastPhase=0,lastAutomatic=false,lastResult=0,lastFailureStage=0,lastErrno=0
        var lastWriteMicros=0,maxWriteMicros=0,writeTimingClipped=0,statusWriteFailures=0
        var writeBudget:[String:Int]?=nil
    }
    struct StatusDocument:Encodable {
        let schema=1
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "test"
        let status:Status
    }
    struct Usage:Equatable {let files:Int;let bytes:Int}
    private struct File {
        let name:String;let phase:Int;let identity:stat
        let digest:String?
        let header:DiagnosticReviewCaptureHeader?
        init(name:String,phase:Int,identity:stat,digest:String?=nil,header:DiagnosticReviewCaptureHeader?=nil){
            self.name=name;self.phase=phase;self.identity=identity;self.digest=digest;self.header=header
        }
        var bytes:Int{Int(identity.st_size)}
    }
    private struct Group {let incident:Int;var files:[File];var key:String=""}
    private let directory:URL,policy:DiagnosticLogRetentionPolicy
    private let readOnly:Bool
    private var directoryIdentity:stat?
    private var groups:[Group]=[]
    private var manualGroups:[Group]=[]
    private(set) var status:Status
    private var statusName=".storage-"+UUID().uuidString+".status"
    private var statusFile:File?
    private var failureStage=0,failureErrno:Int32=0
    private let payloadWriter:OperationalIO.Write
    private let retryClock:()->Double
    private var retryAt=0.0,retryDelay=1.0,transientStorageFailure=false
    private(set) var actualWrittenBytes=0
    private(set) var readiness=DiagnosticStorageReadiness.notChecked
    private(set) var lastStorageFailure:OperationalFailure?
    private(set) var lastStorageFailureMilliseconds:Int64?
    func readinessIssue(retryScheduled:Bool)->DiagnosticStorageIssue {
        // A timer can still call verifyReadiness after an ownership guard has
        // permanently stopped it. That is not an actual storage retry.
        let stopped=ownershipPrepared && !ownershipHealthy && !transientStorageFailure
        return DiagnosticStorageIssue(component:.readiness,failure:lastStorageFailure,
            retry:stopped ? .stopped:(retryScheduled ? .automatic:.notScheduled),
            milliseconds:lastStorageFailureMilliseconds)
    }
    private var readinessReceipt:File?
    private func storageFault(_ stage:OperationalStage,_ code:Int32=0,policy:Int=1)->Bool {
        let failure:OperationalFailure=code == 0 ? .policy(stage,policy):.posix(stage,code)
        lastStorageFailure=failure;lastStorageFailureMilliseconds=Int64(Date().timeIntervalSince1970*1000)
        if DiagnosticStorageRecovery.transient(failure) {
            transientStorageFailure=true;retryAt=retryClock()+retryDelay;retryDelay=min(60,retryDelay*2)
        }
        OperationalDiagnostics.shared.record(failure);return false
    }
    private func failed(_ stage:Int,_ code:Int32=0)->Result {
        failureStage=stage;failureErrno=code
        let operation:OperationalStage
        switch stage {case 2:operation = .storagePrepare;case 3:operation = .storageOwnership
        case 4:operation = .storagePublish;case 5:operation = .storagePrune;case 6:operation = .storageEncode
        default:operation = .storageWrite}
        _ = storageFault(operation,code,policy:stage);return .unavailable
    }
    var usage:Usage {Usage(files:groups.reduce(0){$0+$1.files.count},bytes:groups.reduce(0){$0+$1.files.reduce(0){$0+$1.bytes}})}
    var manualUsage:Usage {Usage(files:manualGroups.reduce(0){$0+$1.files.count},bytes:manualGroups.reduce(0){$0+$1.files.reduce(0){$0+$1.bytes}})}
    init(directory:URL,policy:DiagnosticLogRetentionPolicy,persistentOwnership:Bool=false,archiveDirectory:URL?=nil,readOnly:Bool=false,
         retryClock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},
         writer:@escaping OperationalIO.Write={Darwin.write($0,$1,$2)}){
        self.payloadWriter=writer;self.retryClock=retryClock
        self.directory=directory;self.policy=policy;self.persistentOwnership=persistentOwnership
        self.readOnly=readOnly
        status=Status(maximumAutomaticFiles:policy.maximumAutomaticFiles,maximumAutomaticBytes:policy.maximumAutomaticBytes)
        status.maximumManualBytes=policy.maximumManualBytes;status.manualFiles=0;status.manualBytes=0
    }


    // This is a real filesystem proof using the same ownership guard and byte
    // writer as captures. It neither fabricates an incident nor consumes IDs.
    @discardableResult func verifyReadiness(receipt:Data?=nil,name:String?=nil)->DiagnosticStorageReadiness {
        readiness = .unavailable
        guard !readOnly else{return readiness}
        prepareOwnership()
        guard ownershipHealthy else {
            if lastStorageFailure==nil{_ = storageFault(.storageOwnership,policy:1)}
            return readiness
        }
        guard let dir=openDirectory() else{return readiness}
        defer{close(dir)}
        let keep=receipt != nil && name != nil
        guard (receipt==nil)==(name==nil) else{return readiness}
        let filename:String
        if let name {
            guard DiagnosticReadinessReceipt.validName(name) else{return readiness}
            filename=name
        }else{filename=".storage-check-"+UUID().uuidString}
        let data=receipt ?? Data(UUID().uuidString.utf8)
        guard data.count<=4096 else{return readiness}
        let fd=openat(dir,filename,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{_ = storageFault(.storagePrepare,errno);return readiness}
        var created=stat()
        guard fstat(fd,&created)==0 else{let code=errno;close(fd);_ = storageFault(.storagePrepare,code);return readiness}
        defer{
            close(fd)
            // Remove only this canary; never remove a replacement at its name.
            var current=stat()
            if !keep,fstatat(dir,filename,&current,AT_SYMLINK_NOFOLLOW)==0,
               current.st_dev==created.st_dev,current.st_ino==created.st_ino{unlinkat(dir,filename,0)}
        }
        guard writeAll(data,fd) else{return readiness}
        guard fsync(fd)==0 else{_ = storageFault(.storageWrite,errno);return readiness}
        let check=openat(dir,filename,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard check>=0 else{_ = storageFault(.storageRead,errno);return readiness}
        defer{close(check)}
        var info=stat()
        guard fstat(check,&info)==0 else{_ = storageFault(.storageRead,errno);return readiness}
        guard info.st_dev==created.st_dev,info.st_ino==created.st_ino,
              info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_mode&0o077==0,
              info.st_size==data.count else{_ = storageFault(.storageRead,policy:2);return readiness}
        do {
            guard try FileHandle(fileDescriptor:check,closeOnDealloc:false).read(upToCount:data.count+1)==data else{
                _ = storageFault(.storageRead,policy:3);return readiness
            }
        }catch{
            let failure=OperationalFailure.capture(error,stage:.storageRead)
            lastStorageFailure=failure;lastStorageFailureMilliseconds=Int64(Date().timeIntervalSince1970*1000)
            OperationalDiagnostics.shared.record(failure);return readiness
        }
        readiness = .ready
        lastStorageFailure=nil;lastStorageFailureMilliseconds=nil
        if keep{readinessReceipt=File(name:filename,phase:0,identity:info,digest:Self.digest(data))}
        return readiness
    }
    private func invalidateReadiness(){
        readiness = .unavailable
        if let receipt=readinessReceipt,let dir=openDirectory(){
            if owned(receipt,dir){unlinkat(dir,receipt.name,0)}
            close(dir)
        }
        readinessReceipt=nil
    }
    func withdrawReadiness(){invalidateReadiness()}

    // Device numbers and ctime are useful within one boot, not durable identity.
    // Schema 3 also binds the volume, creation times and exact stored bytes.
    private struct Record:Codable {
        let incident:Int,name:String,phase:Int,device:Int64,inode:UInt64,size:Int64
        let mtime:Int64,mtimeNanos:Int64,ctime:Int64,ctimeNanos:Int64
        var manualKey:String?=nil
        var birth:Int64?=nil,birthNanos:Int64?=nil,digest:String?=nil
        init(_ file:File,incident:Int,manualKey:String?=nil){
            self.manualKey=manualKey
            self.incident=incident;name=file.name;phase=file.phase
            let s=file.identity;device=Int64(s.st_dev);inode=s.st_ino;size=s.st_size
            mtime=Int64(s.st_mtimespec.tv_sec);mtimeNanos=Int64(s.st_mtimespec.tv_nsec)
            ctime=Int64(s.st_ctimespec.tv_sec);ctimeNanos=Int64(s.st_ctimespec.tv_nsec)
            birth=Int64(s.st_birthtimespec.tv_sec);birthNanos=Int64(s.st_birthtimespec.tv_nsec);digest=file.digest
        }
        func matches(_ s:stat)->Bool {
            device==Int64(s.st_dev) && inode==s.st_ino && size==s.st_size &&
            mtime==s.st_mtimespec.tv_sec && mtimeNanos==s.st_mtimespec.tv_nsec &&
            ctime==s.st_ctimespec.tv_sec && ctimeNanos==s.st_ctimespec.tv_nsec &&
            s.st_mode&S_IFMT==S_IFREG && s.st_uid==getuid() && s.st_mode&0o077==0
        }
        func matchesPersistent(_ s:stat)->Bool {
            inode==s.st_ino && size==s.st_size &&
            mtime==s.st_mtimespec.tv_sec && mtimeNanos==s.st_mtimespec.tv_nsec &&
            birth==Int64(s.st_birthtimespec.tv_sec) && birthNanos==Int64(s.st_birthtimespec.tv_nsec) &&
            s.st_mode&S_IFMT==S_IFREG && s.st_uid==getuid() && s.st_mode&0o077==0
        }
        // This check only authorizes preserving a whole legacy directory. It
        // never authorizes adopting, replacing or pruning an individual file.
        func matchesLegacyRemount(_ s:stat)->Bool {
            inode==s.st_ino && size==s.st_size &&
            mtime==s.st_mtimespec.tv_sec && mtimeNanos==s.st_mtimespec.tv_nsec &&
            s.st_mode&S_IFMT==S_IFREG && s.st_uid==getuid() && s.st_mode&0o077==0
        }
    }
    private struct Ownership:Codable {
        let schema:Int,device:Int64,inode:UInt64,lastIncident:Int
        let statusName:String,status:Status,files:[Record],statusFile:Record?
        var manualFiles:[Record]?=nil
        var volumeUUID:String?=nil,bootUUID:String?=nil
        var birth:Int64?=nil,birthNanos:Int64?=nil
        var writeBudgetRequired:Bool?=nil
    }
    private let persistentOwnership:Bool
    private var ownershipPrepared=false,ownershipHealthy=true
    private let ownershipName=".automatic-ownership-v1.index"
    private var ownershipFile:File?
    private var volumeUUID:String?
    private(set) var legacyArchive:URL?
    private static let bootUUID:String? = {
        var bytes=[CChar](repeating:0,count:128),size=128
        guard sysctlbyname("kern.bootsessionuuid",&bytes,&size,nil,0)==0,
              let uuid=UUID(uuidString:String(cString:bytes)) else{return nil}
        return uuid.uuidString
    }()
    private func prepareVolume(_ dir:Int32)->Bool {
        if volumeUUID != nil{return true}
        guard let raw=try? directory.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString,
              let uuid=UUID(uuidString:raw),Self.bootUUID != nil else{return false}
        var current=stat(),path=stat()
        guard fstat(dir,&current)==0,lstat(directory.path,&path)==0,
              current.st_dev==path.st_dev,current.st_ino==path.st_ino else{return false}
        volumeUUID=uuid.uuidString;return true
    }
    private func verifiedFile(_ entry:Record,_ dir:Int32,schema:Int,sameBoot:Bool)->File? {
        let fd=openat(dir,entry.name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{return nil};defer{close(fd)}
        var before=stat(),after=stat()
        guard fstat(fd,&before)==0,before.st_size>=0,before.st_size<=16*1024*1024,
              schema==3 ? entry.matchesPersistent(before):entry.matches(before),
              schema != 3 || !sameBoot || entry.matches(before),
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:Int(before.st_size)+1),
              data.count==before.st_size,fstat(fd,&after)==0,matches(before,after) else{return nil}
        let digest=Self.digest(data)
        guard schema != 3 || entry.digest==digest else{return nil}
        return File(name:entry.name,phase:entry.phase,identity:after,digest:digest,header:DiagnosticReviewCaptureHeader.read(data))
    }
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private(set) var lastCaptureIncident=0
    func prepareOwnership(){
        if ownershipPrepared,!ownershipHealthy,transientStorageFailure {
            guard retryClock()>=retryAt else{return}
            transientStorageFailure=false;ownershipPrepared=false
        }
        guard persistentOwnership,!ownershipPrepared else{return}
        ownershipPrepared=true;ownershipHealthy=false
        guard let dir=openDirectory() else{return};defer{close(dir)}
        guard prepareVolume(dir) else{return}
        var info=stat()
        if fstatat(dir,ownershipName,&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno==ENOENT else{_ = storageFault(.storageOwnership,errno);return}
            let names:[String]
            do{names=try FileManager.default.contentsOfDirectory(atPath:directory.path)}catch{_ = storageFault(.storageOwnership,Int32(clamping:OperationalFailure.capture(error,stage:.storageOwnership).underlyingPOSIX));return}
            guard !names.contains(where:{$0.hasPrefix("incident-") || $0.hasPrefix(".storage-")}) else{return}
            ownershipHealthy=true;return
        }
        let fd=openat(dir,ownershipName,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{_ = storageFault(.storageOwnership,errno);return};defer{close(fd)}
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_size>0,info.st_size<=8*1024*1024,
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:8*1024*1024+1),
              let index=try? JSONDecoder().decode(Ownership.self,from:data),(1...3).contains(index.schema),
              let identity=directoryIdentity,index.inode==identity.st_ino,
              index.status.maximumAutomaticFiles>0,index.status.maximumAutomaticBytes>0,
              index.files.count<=index.status.maximumAutomaticFiles,index.lastIncident>=0,
              validStatusName(index.statusName),validAttemptCounts(index.status) else{return}
        // Reading never adopts, rewrites, prunes or renames an old namespace.
        // Legacy indexes without persistent identity still fail closed after remount.
        if index.schema<3,index.device != Int64(identity.st_dev){return}
        let sameBoot=index.bootUUID==Self.bootUUID
        if index.schema==3 {
            guard index.volumeUUID==volumeUUID,let boot=index.bootUUID,UUID(uuidString:boot) != nil,
                  index.birth==Int64(identity.st_birthtimespec.tv_sec),index.birthNanos==Int64(identity.st_birthtimespec.tv_nsec),
                  !sameBoot || index.device==Int64(identity.st_dev) else{return}
        }else{guard index.device==Int64(identity.st_dev) else{return}}
        var restored:[Int:[File]]=[:],names=Set<String>(),total=0
        for entry in index.files {
            guard entry.incident>0,entry.incident<=index.lastIncident,(0...1).contains(entry.phase),
                  validCaptureName(entry.name,incident:entry.incident,phase:entry.phase),names.insert(entry.name).inserted else{return}
            guard let file=verifiedFile(entry,dir,schema:index.schema,sameBoot:sameBoot),
                  file.bytes<=index.status.maximumAutomaticBytes-total else{return}
            total+=file.bytes
            restored[entry.incident,default:[]].append(file)
        }
        guard restored.values.allSatisfy({validPair($0)}),index.status.automaticFiles==index.files.count,index.status.automaticBytes==total else{return}
        var restoredManual:[String:Group]=[:]
        for entry in index.manualFiles ?? [] {
            guard index.schema>=2,let key=entry.manualKey,!key.isEmpty,entry.incident>0,entry.incident<=index.lastIncident,
                  validCaptureName(entry.name,incident:entry.incident,phase:entry.phase),names.insert(entry.name).inserted else{return}
            guard let file=verifiedFile(entry,dir,schema:index.schema,sameBoot:sameBoot) else{return}
            if let previous=restoredManual[key],previous.incident != entry.incident{return}
            if restoredManual[key]==nil{restoredManual[key]=Group(incident:entry.incident,files:[],key:key)}
            restoredManual[key]!.files.append(file)
        }
        var previousStatus:File?
        if let entry=index.statusFile {
            guard entry.name==index.statusName,entry.size<=16*1024,
                  let file=verifiedFile(entry,dir,schema:index.schema,sameBoot:sameBoot) else{return}
            previousStatus=file
        }else{
            var current=stat()
            guard fstatat(dir,index.statusName,&current,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT else{return}
        }
        guard let diskNames=try? FileManager.default.contentsOfDirectory(atPath:directory.path) else{return}
        var last=index.lastIncident
        for name in diskNames.sorted() where name.hasPrefix("incident-") && !names.contains(name) {
            // Only the previous, verified index authorizes this one-time upgrade
            // of valid private manual captures. Unknown/orphan evidence blocks growth.
            guard index.schema==1,let legacy=readLegacyManual(name,dir) else{return}
            if restoredManual[legacy.key]==nil{restoredManual[legacy.key]=Group(incident:legacy.incident,files:[],key:legacy.key)}
            restoredManual[legacy.key]!.files.append(legacy.file);last=max(last,legacy.incident)
        }
        guard restoredManual.values.allSatisfy({validPair($0.files)}) else{return}
        let manualTotal=restoredManual.values.reduce(0){$0+$1.files.reduce(0){$0+$1.bytes}}
        if index.schema>=2 {
            guard index.status.manualFiles==index.manualFiles?.count,index.status.manualBytes==manualTotal,
                  let limit=index.status.maximumManualBytes,limit>0,manualTotal<=limit else{return}
        }
        groups=restored.keys.sorted().map{Group(incident:$0,files:restored[$0]!.sorted{$0.phase<$1.phase})}
        manualGroups=restoredManual.values.sorted{left,right in
            func first(_ group:Group)->(Int,Int){
                group.files.map{(Int($0.identity.st_mtimespec.tv_sec),Int($0.identity.st_mtimespec.tv_nsec))}.min(by:{$0<$1}) ?? (0,0)
            }
            let l=first(left),r=first(right)
            return l==r ? left.key<right.key:l<r
        }
        lastCaptureIncident=last;status=index.status
        statusName=index.statusName;statusFile=previousStatus;ownershipFile=File(name:ownershipName,phase:0,identity:info)
        updateUsage();ownershipHealthy=true
    }
    private func validCaptureName(_ name:String,incident:Int,phase:Int)->Bool {
        let prefix="incident-\(incident)-\(phase)-"
        return (0...1).contains(phase) && name.hasPrefix(prefix) && name.hasSuffix(".json") &&
            UUID(uuidString:String(name.dropFirst(prefix.count).dropLast(5))) != nil
    }
    private func validPair(_ files:[File])->Bool {
        !files.isEmpty && files.count<=2 && Set(files.map{$0.phase}).count==files.count && files.contains{$0.phase==0}
    }
    private func readLegacyManual(_ name:String,_ dir:Int32)->(key:String,incident:Int,file:File)? {
        let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{return nil};defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_size>0,info.st_size<=16*1024*1024,
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:16*1024*1024+1) else{return nil}
        struct Header:Decodable {let schema:Int,trigger:Int,runID:String,incident:Int,phase:Int}
        guard let header=try? JSONDecoder().decode(Header.self,from:data),header.schema==1,header.trigger==1,
              UUID(uuidString:header.runID) != nil,header.incident>0,validCaptureName(name,incident:header.incident,phase:header.phase) else{return nil}
        var after=stat()
        guard fstat(fd,&after)==0,matches(info,after) else{return nil}
        return (header.runID+":\(header.incident)",header.incident,File(name:name,phase:header.phase,identity:info,digest:Self.digest(data),header:DiagnosticReviewCaptureHeader.read(data)))
    }
    private func updateUsage(){
        status.automaticFiles=usage.files;status.automaticBytes=usage.bytes
        status.manualFiles=manualUsage.files;status.manualBytes=manualUsage.bytes
    }


    // Investigation opt-in: content-addressed evidence lives outside rotation.
    // Every file and its manifest are durable before any source is unlinked.


    private func validAttemptCounts(_ status:Status)->Bool {
        var remaining=status.attempts
        for count in [status.saved,status.limited,status.retired,status.unavailable,status.encodingFailures] {
            guard count>=0,count<=remaining else{return false};remaining-=count
        }
        return remaining==0
    }
    private func validStatusName(_ name:String)->Bool {
        name.hasPrefix(".storage-") && name.hasSuffix(".status") && UUID(uuidString:String(name.dropFirst(9).dropLast(7))) != nil
    }

    // Reserve both encoded phases before either becomes visible. Reservation
    // failures update memory only; there is no deferred catch-up write queue.

    private func writeAll(_ data:Data,_ fd:Int32)->Bool {
        if let failure=OperationalIO.writeAll(data,to:fd,stage:.storageWrite,write:{[self] fd,p,n in
            let count=payloadWriter(fd,p,n);if count>0{actualWrittenBytes+=count};return count
        }) {
            _ = storageFault(.storageWrite,Int32(clamping:failure.underlyingPOSIX))
            failureErrno=Int32(clamping:failure.underlyingPOSIX);errno=failureErrno
            return false
        }
        return true
    }
    private func openDirectory()->Int32? {
        guard !readOnly || InputIncidentPreferences.namespacePath(directory.path)==directory.path else{_ = failed(2);return nil}
        if persistentOwnership {
            let parent=directory.deletingLastPathComponent().path;var p=stat()
            if lstat(parent,&p) != 0 {
                guard !readOnly,errno==ENOENT else{_ = failed(2,errno);return nil}
                if mkdir(parent,S_IRWXU) != 0 && errno != EEXIST{_ = failed(2,errno);return nil}
            }
            guard lstat(parent,&p)==0 else{_ = failed(2,errno);return nil}
            guard p.st_mode&S_IFMT==S_IFDIR,p.st_uid==getuid(),p.st_mode&0o077==0 else{_ = failed(2);return nil}
        }
        var info=stat()
        if lstat(directory.path,&info) != 0 {
            guard !readOnly,errno==ENOENT,directoryIdentity==nil else{_ = failed(2,errno);return nil}
            if mkdir(directory.path,S_IRWXU) != 0 && errno != EEXIST{_ = failed(2,errno);return nil}
        } else {guard (info.st_mode & S_IFMT)==S_IFDIR,info.st_uid==getuid(),(info.st_mode & 0o077)==0 else{_ = failed(2);return nil}}
        let dir=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard dir>=0 else{_ = failed(2,errno);return nil}
        guard fstat(dir,&info)==0 else{_ = failed(2,errno);close(dir);return nil}
        guard info.st_uid==getuid(),(info.st_mode & 0o077)==0 else{_ = failed(2);close(dir);return nil}
        if let previous=directoryIdentity {
            guard previous.st_dev==info.st_dev,previous.st_ino==info.st_ino else{_ = failed(2);close(dir);return nil}
        } else {directoryIdentity=info}
        return dir
    }
    private func matches(_ left:stat,_ right:stat)->Bool {
        left.st_dev==right.st_dev && left.st_ino==right.st_ino && left.st_size==right.st_size &&
        left.st_mtimespec.tv_sec==right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec==right.st_mtimespec.tv_nsec &&
        left.st_ctimespec.tv_sec==right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec==right.st_ctimespec.tv_nsec &&
        (right.st_mode & S_IFMT)==S_IFREG && right.st_uid==getuid() && (right.st_mode & 0o077)==0
    }
    private func owned(_ file:File,_ fd:Int32)->Bool {
        var info=stat()
        return fstatat(fd,file.name,&info,AT_SYMLINK_NOFOLLOW)==0 && matches(file.identity,info)
    }
    func copyExportSnapshot(to destination:URL,reviewMetadata:Bool=false,request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest(),availableBytes:(()->UInt64?)?=nil,includeEmpty:Bool=false)throws {
        try request.check()
        prepareOwnership()
        guard ownershipHealthy,let dir=openDirectory() else{throw DiagnosticLogExport.Failure.unavailable}
        defer{close(dir)}
        let captures=(groups+manualGroups).flatMap{$0.files}
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var completed=false
        defer{if !completed{try? FileManager.default.removeItem(at:destination)}}
        let output=open(destination.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard output>=0 else{throw DiagnosticLogExport.Failure.unavailable}
        defer{close(output)}
        func checkSpace(_ bytes:Int)throws {
            var volume=statfs()
            let free:UInt64?
            if let availableBytes{free=availableBytes()}
            else if fstatfs(output,&volume)==0{free=UInt64(volume.f_bavail)*UInt64(volume.f_bsize)}
            else{free=nil}
            guard let free else{throw DiagnosticLogExport.Failure.unavailable}
            guard free>=UInt64(bytes)+256*1024*1024 else{throw DiagnosticLogExport.Failure.insufficientSpace}
        }
        request.report(.copying,0,captures.count)
        for (index,file) in captures.enumerated() {
            try request.check();try checkSpace(0)
            guard owned(file,dir) else{throw DiagnosticLogExport.Failure.unavailable}
            let fd=openat(dir,file.name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            guard fd>=0 else{throw DiagnosticLogExport.Failure.unavailable}
            defer{close(fd)}
            var info=stat()
            guard fstat(fd,&info)==0,matches(file.identity,info) else{throw DiagnosticLogExport.Failure.unavailable}
            let path=destination.appendingPathComponent(file.name)
            // APFS clones preserve an immutable byte snapshot without allocating
            // another full copy of a potentially large investigation store.
            if fclonefileat(fd,output,file.name,UInt32(CLONE_NOFOLLOW)) != 0 {
                let code=errno
                guard [ENOTSUP,EXDEV,EINVAL,ENOSYS].contains(code) else{
                    throw code==ENOSPC ? DiagnosticLogExport.Failure.insufficientSpace:DiagnosticLogExport.Failure.unavailable
                }
                try checkSpace(file.bytes)
                guard let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:file.bytes+1),data.count==file.bytes else{throw DiagnosticLogExport.Failure.unavailable}
                try request.check()
                try data.write(to:path,options:.withoutOverwriting)
            }
            guard fstat(fd,&info)==0,matches(file.identity,info) else{throw DiagnosticLogExport.Failure.unavailable}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            request.report(.copying,index+1,captures.count)
        }
        var criticalCount=0
        try DiagnosticCriticalJournal.forEachFile(dir){name,data in
            try request.check();try checkSpace(data.count);criticalCount+=1
            let path=destination.appendingPathComponent(name)
            try data.write(to:path,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        guard includeEmpty || !captures.isEmpty || criticalCount>0 else{throw DiagnosticLogExport.Failure.noLogs}
        if let data=try? JSONEncoder().encode(StatusDocument(status:status)) {
            let path=destination.appendingPathComponent("storage-status.json")
            try data.write(to:path,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        // Local review-only ordering metadata. These are source file creation
        // times (not claimed incident times); never exported as an ownership index.
        if reviewMetadata {
            let dates=Dictionary(uniqueKeysWithValues:captures.map{($0.name,Double($0.identity.st_birthtimespec.tv_sec)+Double($0.identity.st_birthtimespec.tv_nsec)/1_000_000_000)})
            let path=destination.appendingPathComponent("review-dates.json")
            try JSONEncoder().encode(dates).write(to:path,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            if captures.allSatisfy({$0.header != nil && $0.digest != nil}) {
                let catalog=DiagnosticReviewCatalog(files:Dictionary(uniqueKeysWithValues:captures.map{
                    ($0.name,.init(bytes:$0.bytes,digest:$0.digest!,header:$0.header!))
                }))
                let catalogPath=destination.appendingPathComponent("review-catalog.json")
                try JSONEncoder().encode(catalog).write(to:catalogPath,options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:catalogPath.path)
            }
        }
        try request.check();completed=true
    }


}

struct DiagnosticStorageReadiness: Codable, Equatable {
    let ready: Bool
    let reason: String
    static let ready = Self(ready:true,reason:"ready")
    static let unavailable = Self(ready:false,reason:"storage_unavailable")
    static let notChecked = Self(ready:false,reason:"not_checked")
    static let timeout = Self(ready:false,reason:"storage_check_timeout")
}

// Test preparation receipt, separate from incident data. It contains only the
// requested nonce and this HanQ process's identity, never an input target.
struct DiagnosticReadinessReceipt: Codable {
    let schema: Int
    let token: String
    let pid: Int32
    let build: String
    let runID: String
    let ready: Bool
    let bounded: Bool?
    let recoveryFromPID: Int32?
    static func make(token:String,runID:String,bounded:Bool=false)->Self {
        Self(schema:1,token:token,pid:getpid(),build:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "test",runID:runID,ready:true,bounded:bounded,recoveryFromPID:DiagnosticStorageStartup.recoveryFromPID(arguments:ProcessInfo.processInfo.arguments))
    }
    static func name(_ token:String,pid:Int32=getpid())->String {".preflight-\(token)-\(pid).json"}
    static func validName(_ name:String)->Bool {
        guard name.hasPrefix(".preflight-"),name.hasSuffix(".json") else{return false}
        let identity=String(name.dropFirst(11).dropLast(5))
        guard identity.count>37,identity[identity.index(identity.startIndex,offsetBy:36)]=="-",
              UUID(uuidString:String(identity.prefix(36))) != nil,
              let pid=Int32(identity.dropFirst(37)),pid>1 else{return false}
        return name==self.name(String(identity.prefix(36)),pid:pid)
    }
}

enum DiagnosticStorageStartup {
    static let tokenArgument="--diagnostic-readiness-token"
    static var explicit:Bool {
        explicitRequested(arguments:ProcessInfo.processInfo.arguments,defaults:.standard)
    }
    static func explicitRequested(arguments args:[String],defaults:UserDefaults)->Bool {
        let option=InputIncidentPreferences.launch(arguments:args,defaults:defaults)
        // An ordinary configured launch waits for the UI instance lock before
        // creating its writer. Test launches request an actual nonce proof.
        return args.contains("--preserve-input-incidents") || args.contains("--diagnose-input-incidents") || args.contains("--bounded-input-incidents") || (args.contains(tokenArgument) && option.bounded && option.enabled && option.valid)
    }
    static var token:String? {
        let args=ProcessInfo.processInfo.arguments
        guard let i=args.firstIndex(of:tokenArgument),i+1<args.count,UUID(uuidString:args[i+1]) != nil else{return nil}
        return args[i+1]
    }
    static func recoveryFromPID(arguments args:[String])->Int32? {
        guard args.contains("--permission-recovery"),
              args.filter({$0=="--permission-recovery-from"}).count==1,
              let i=args.firstIndex(of:"--permission-recovery-from"),i+1<args.count,
              let pid=Int32(args[i+1]),pid>1,pid != getpid() else{return nil}
        return pid
    }
    static func requireReadyIfRequested(){
        let args=ProcessInfo.processInfo.arguments
        guard explicit || args.contains(tokenArgument) else{return}
        guard explicit,!args.contains(tokenArgument) || token != nil else{_exit(64)}
        let result=InputIncidentTrace.shared.waitForStorageReadiness()
        guard result.ready else{
            fputs("HanQ: diagnostic storage verification failed; input test was not started (\(result.reason)).\n",stderr)
            _exit(74)
        }
    }
    static func runProbeIfRequested(){
        let args=ProcessInfo.processInfo.arguments
        guard let i=args.firstIndex(of:"--diagnostic-storage-probe") else{return}
        guard i+1<args.count,explicit else{_exit(64)}
        let directory=URL(fileURLWithPath:args[i+1])
        guard let workspace=PrivateProbeDirectory.open(directory,prefix:"hanq-storage-"),
              workspace.enter() else{_exit(64)}
        DispatchQueue.global().asyncAfter(deadline:.now()+8){_exit(71)}
        let result=InputIncidentTrace.shared.waitForStorageReadiness()
        let response=Response(token:directory.lastPathComponent,pid:getpid(),build:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",directory:InputIncidentTrace.shared.destinationDirectory?.standardizedFileURL.path ?? "",readiness:result,bounded:InputIncidentPreferences.launch(arguments:args,defaults:.standard).bounded)
        do {
            guard workspace.publish(try JSONEncoder().encode(response)) else{_exit(74)}
            _exit(0)
        }catch{_exit(74)}
    }
    private struct Response:Encodable {
        let token:String;let pid:Int32;let build:String;let directory:String;let readiness:DiagnosticStorageReadiness;let bounded:Bool
    }
}

/// Probe responses use a fresh private directory, independent of Foundation's
/// process-dependent temporaryDirectory. Never follow links or replace a result.
final class PrivateProbeDirectory {
    static let root=URL(fileURLWithPath:"/private/tmp",isDirectory:true)
    private let directory:URL
    private let fd:Int32
    private let identity:stat
    private init(_ directory:URL,_ fd:Int32,_ identity:stat){
        self.directory=directory;self.fd=fd;self.identity=identity
    }
    deinit{close(fd)}
    static func open(_ directory:URL,prefix:String)->PrivateProbeDirectory? {
        switch checkedOpen(directory,prefix:prefix) {
        case .success(let workspace):return workspace
        case .failure(let error):OperationalDiagnostics.shared.record(error);return nil
        }
    }
    static func checkedOpen(_ directory:URL,prefix:String)->Result<PrivateProbeDirectory,OperationalFailure> {
        guard ["hanq-permission-","hanq-storage-"].contains(prefix),
              directory.deletingLastPathComponent().path==root.path,
              directory.lastPathComponent.hasPrefix(prefix),
              directory.lastPathComponent.count>prefix.count,
              directory.lastPathComponent.count<=128 else{return .failure(.policy(.probeValidate,1))}
        // Foundation may abbreviate /private/tmp to /tmp even when no link is
        // traversed. Validate each real component with directory descriptors.
        let base=Darwin.open("/private",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard base>=0 else{return .failure(.posix(.probeOpen,errno))};defer{close(base)}
        let parent=openat(base,"tmp",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent>=0 else{return .failure(.posix(.probeOpen,errno))};defer{close(parent)}
        let fd=openat(parent,directory.lastPathComponent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{return .failure(.posix(.probeOpen,errno))}
        var info=stat()
        guard fstat(fd,&info)==0 else{let error=OperationalFailure.posix(.probeValidate,errno);close(fd);return .failure(error)}
        guard info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,
              info.st_mode&0o7777==0o700 else{close(fd);return .failure(.policy(.probeValidate,2))}
        let workspace=PrivateProbeDirectory(directory,fd,info)
        if let error=workspace.validationFailure{return .failure(error)}
        return .success(workspace)
    }
    private var validationFailure:OperationalFailure? {
        var info=stat()
        guard lstat(directory.path,&info)==0 else{return .posix(.probeValidate,errno)}
        guard info.st_dev==identity.st_dev,info.st_ino==identity.st_ino,
            info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,info.st_mode&0o7777==0o700 else{return .policy(.probeValidate,3)}
        return nil
    }
    func enter()->Bool {
        let failure=validationFailure ?? (fchdir(fd)==0 ? nil:.posix(.probeEnter,errno))
        if let failure{OperationalDiagnostics.shared.record(failure);return false}
        return true
    }
    func publish(_ data:Data)->Bool {
        if let failure=publishFailure(data){OperationalDiagnostics.shared.record(failure);return false}
        return true
    }
    func publishFailure(_ data:Data,write:OperationalIO.Write={Darwin.write($0,$1,$2)})->OperationalFailure? {
        guard data.count<=8192 else{return .policy(.probeEncode,1)}
        if let failure=validationFailure{return failure}
        let name=".result-"+UUID().uuidString
        let output=openat(fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard output>=0 else{return .posix(.probeOpen,errno)}
        defer{close(output);unlinkat(fd,name,0)}
        if let failure=OperationalIO.writeAll(data,to:output,stage:.probeWrite,write:write){return failure}
        if let failure=validationFailure{return failure}
        // Publish a complete private file atomically; EEXIST includes symlinks.
        guard linkat(fd,name,fd,"result.json",0)==0 else{return .posix(.probePublish,errno)}
        return nil
    }
    func readResult()->Result<Data?,OperationalFailure> {
        if let failure=validationFailure{return .failure(failure)}
        let input=openat(fd,"result.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard input>=0 else {
            let code=errno
            return code==ENOENT ? .success(nil):.failure(.posix(.probeRead,code))
        }
        defer{close(input)}
        var info=stat()
        guard fstat(input,&info)==0 else{return .failure(.posix(.probeRead,errno))}
        guard info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_size>0,info.st_size<=8192 else{return .failure(.policy(.probeRead,2))}
        var data=Data(count:Int(info.st_size)),offset=0
        let failure:OperationalFailure?=data.withUnsafeMutableBytes {bytes in
            while offset<bytes.count {
                let count=Darwin.read(input,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count<0 {let code=errno;if code==EINTR{continue};return .posix(.probeRead,code)}
                guard count>0 else{return .policy(.probeRead,3)}
                offset+=count
            }
            return nil
        }
        if let failure{return .failure(failure)}
        return .success(data)
    }
}

struct DiagnosticStorageIssue:Equatable,Codable {
    enum Component:String,Codable {case detail,readiness,criticalErrors,observations,termination
        var title:String {switch self {
        case .detail:return "전후 상세 기록"
        case .readiness:return "진단 저장 준비"
        case .criticalErrors:return "중요 오류 기록"
        case .observations:return "사건 관측 기록"
        case .termination:return "종료 사유 기록"
        }}
    }
    enum Retry:String,Codable {case automatic,stopped,notScheduled,unknown
        var message:String {switch self {
        case .automatic:return "자동으로 다시 시도하고 있습니다."
        case .stopped:return "자동 재시도가 중단되었습니다."
        case .notScheduled:return "현재 자동 재시도가 예약되어 있지 않습니다."
        case .unknown:return "자동 재시도 상태를 확인할 수 없습니다."
        }}
    }
    enum Cause:String {case space,permission,readOnly,missing,busy,io,resources,validation,encoding,unknown
        var title:String {switch self {
        case .space:return "진단 기록을 저장할 공간이 부족합니다"
        case .permission:return "진단 폴더에 접근할 권한이 없습니다"
        case .readOnly:return "진단 저장 위치가 읽기 전용입니다"
        case .missing:return "진단 저장 위치를 찾을 수 없습니다"
        case .busy:return "진단 저장 작업이 지연되고 있습니다"
        case .io:return "진단 기록을 읽거나 쓰지 못했습니다"
        case .resources:return "진단 저장에 필요한 자원이 부족합니다"
        case .validation:return "진단 기록의 안전한 저장을 확인하지 못했습니다"
        case .encoding:return "진단 기록을 저장 형식으로 만들지 못했습니다"
        case .unknown:return "진단 기록을 저장하지 못하고 있습니다"
        }}
        var guidance:String {switch self {
        case .space:return "저장 공간을 확보해 주세요."
        case .permission:return "진단 파일을 저장하는 폴더의 접근이 거부되었습니다."
        case .readOnly:return "현재 저장 위치에 파일을 쓸 수 없습니다."
        case .missing:return "기존 저장 위치가 그대로 있는지 확인이 필요합니다."
        case .busy:return "다른 저장 작업과의 충돌이나 일시적인 지연일 수 있습니다."
        case .io:return "입출력 실패가 확인됐습니다. 이 정보만으로 디스크 고장을 판단할 수는 없습니다."
        case .resources:return "파일을 열거나 메모리를 확보하는 데 필요한 자원이 부족합니다."
        case .validation:return "기존 기록을 안전하게 다룰 수 있는지 확인하지 못했습니다. 기존 기록을 삭제하지 말고 문의해 주세요."
        case .encoding:return "기록을 파일로 만드는 과정에서 오류가 발생했습니다. 계속되면 문의해 주세요."
        case .unknown:return "현재 정보로 원인을 분류하지 못했습니다. 계속되면 아래 오류 정보와 함께 문의해 주세요."
        }}
        var action:String {switch self {
        case .space:return "Mac의 저장 공간을 확보해 주세요."
        case .busy,.io,.resources:return "잠시 기다려 주세요. 문제가 계속되면 저장된 진단 기록을 첨부해 문의해 주세요."
        case .permission:return "가능하면 진단 기록을 첨부해\n피드백을 남겨 주세요."
        default:return "가능하면 진단 기록을 첨부해\n피드백을 남겨 주세요."
        }}
    }
    var component:Component
    let failure:OperationalFailure?
    var retry:Retry
    var milliseconds:Int64?=nil
    var pendingCount:Int?=nil
    var cause:Cause {
        guard let failure else{return .unknown}
        let code=failure.domain == .posix ? failure.code:failure.underlyingPOSIX
        switch Int32(clamping:code) {
        case ENOSPC,EDQUOT:return .space
        case EACCES,EPERM:return .permission
        case EROFS:return .readOnly
        case ENOENT,ENOTDIR,ENODEV:return .missing
        case EAGAIN,EINTR,EBUSY:return .busy
        case EIO:return .io
        case EMFILE,ENFILE,ENOMEM:return .resources
        default:break
        }
        if failure.domain == .cocoa {
            switch failure.code {
            case NSFileWriteOutOfSpaceError:return .space
            case NSFileReadNoPermissionError,NSFileWriteNoPermissionError:return .permission
            case NSFileWriteVolumeReadOnlyError:return .readOnly
            case NSFileNoSuchFileError,NSFileReadNoSuchFileError:return .missing
            default:break
            }
        }
        if failure.stage == .storageEncode{return .encoding}
        if failure.domain == .policy{return .validation}
        return .unknown
    }
}
// Export-only metadata. Older snapshots deliberately remain 'unknown' instead
// of deriving a promise to retry from a pending byte count or an errno.
struct DiagnosticStorageIssueSnapshot:Codable {
    let schema:Int
    let issues:[DiagnosticStorageIssue]
    init(issues:[DiagnosticStorageIssue]){schema=1;self.issues=issues}
    var isValid:Bool {
        schema==1 && issues.count<=5 && Set(issues.map(\.component)).count==issues.count &&
        issues.allSatisfy{($0.pendingCount ?? 0)>=0 && ($0.milliseconds ?? 0)>=0}
    }
    func exportAdvice(for components:Set<DiagnosticStorageIssue.Component>)->String {
        let relevant=issues.filter{components.contains($0.component)}
        guard !relevant.isEmpty else{return DiagnosticStorageIssue.Retry.unknown.message}
        return relevant.map{issue in
            let advice:String
            switch issue.retry {
            case .automatic:advice="자동으로 다시 시도하고 있습니다. 저장이 완료된 뒤 내보내기 창을 다시 열어 주세요."
            case .stopped:advice="자동 재시도가 중단되었습니다. 기다리거나 창을 다시 열어도 추가 저장되지 않습니다. ‘저장 문제 확인…’에서 안내를 확인해 주세요."
            case .notScheduled:advice="현재 자동 재시도가 예약되어 있지 않습니다. ‘저장 문제 확인…’에서 안내를 확인해 주세요."
            case .unknown:advice="이 자료만으로 자동 재시도 상태를 확인할 수 없습니다."
            }
            return relevant.count>1 ? issue.component.title+": "+advice:advice
        }.joined(separator:"\n")
    }
}
struct DiagnosticStorageProblemSummary {
    let cause:String,action:String,retry:String
}
struct DiagnosticStorageNotice:Equatable {
    let title:String,detail:String
    let needsDetails:Bool
    var message:String{title+"\n"+detail}
}
struct DiagnosticStorageHealth {
    let readiness:DiagnosticStorageReadiness
    let missingWrites:Int
    var suppressedWrites:Int=0
    var collectionEnabled:Bool=true
    var pendingWrites:Bool=false
    var currentFailure:OperationalFailure?=nil
    var manualCaptureAvailable:Bool=true
    var issues:[DiagnosticStorageIssue]=[]
    var activeIssues:[DiagnosticStorageIssue] {
        guard (collectionEnabled || pendingWrites),readiness.reason != "not_checked",!readiness.ready else{return []}
        // An errno alone cannot establish that a retry is actually scheduled.
        return issues.isEmpty ? [DiagnosticStorageIssue(component:.readiness,failure:currentFailure,retry:.unknown)]:issues
    }
    var notice:DiagnosticStorageNotice? {
        let all=activeIssues;guard let first=all.first else{return nil}
        let sameCause=all.allSatisfy{$0.cause==first.cause}
        let automatic=all.filter{$0.retry == .automatic}.count
        let title=sameCause ? first.cause.title:"진단 기록 저장에 여러 문제가 있습니다"
        let detail:String
        if automatic==all.count {
            detail=sameCause && first.cause == .space ? "공간을 확보해 주세요 · 자동 재시도 중":"자동으로 다시 시도하고 있습니다"
        }else if automatic>0 {detail="일부는 자동 재시도 중 · 문제 확인이 필요합니다"}
        else if all.allSatisfy({$0.retry == .stopped}) {detail="자동 재시도 중단 · 문제 확인이 필요합니다"}
        else if all.contains(where:{$0.retry == .unknown}) {detail="재시도 상태 미확인 · 문제를 확인해 주세요"}
        else {detail="자동 재시도 대기 없음 · 문제를 확인해 주세요"}
        return DiagnosticStorageNotice(title:title,detail:detail,needsDetails:automatic != all.count || !sameCause || first.cause != .space)
    }
    var menuMessage:String?{notice?.message}
    var problemSummary:DiagnosticStorageProblemSummary? {
        let all=activeIssues;guard let first=all.first else{return nil}
        let sameCause=all.allSatisfy{$0.cause==first.cause}
        let automatic=all.allSatisfy{$0.retry == .automatic}
        let cause=sameCause ? first.cause.title:all.map{$0.component.title+": "+$0.cause.title}.joined(separator:"\n")
        let action:String
        if sameCause && first.cause == .space {action=first.cause.action}
        else if sameCause && first.cause == .permission {action=first.cause.action}
        else if sameCause && automatic {action=first.cause.action}
        else {action="가능하면 진단 기록을 첨부해\n피드백을 남겨 주세요."}
        let sameRetry=all.allSatisfy{$0.retry==first.retry}
        let retry=sameRetry ? first.retry.message:all.map{$0.component.title+": "+$0.retry.message}.joined(separator:"\n")
        return DiagnosticStorageProblemSummary(cause:cause,action:action,retry:retry)
    }
    var detailMessage:String {
        let formatter=DateFormatter();formatter.dateStyle = .short;formatter.timeStyle = .medium
        let all=activeIssues
        return all.map {issue in
            var lines=all.count>1 ? [issue.component.title]:[String]()
            if let pending=issue.pendingCount,pending>0{lines.append("저장 대기: \(pending)개 기록 단계")}
            if let time=issue.milliseconds{lines.append("최근 실패: "+formatter.string(from:Date(timeIntervalSince1970:Double(time)/1000)))}
            if let error=issue.failure{lines.append("문의용 오류 정보: \(error.stage.rawValue)/\(error.domain.rawValue)/\(error.code)/\(error.underlyingPOSIX)")}
            return lines.isEmpty ? "추가 오류 정보가 없습니다.":lines.joined(separator:"\n")
        }.joined(separator:"\n\n")
    }
}

// One bounded receipt per user request, independent of the window/writer queue.
// Success requires both phases; a failed attempt is not permanent data loss.
final class DiagnosticManualCapture {
    enum Status:Equatable {
        case saved,waiting,incomplete,unavailable
        var message:String {
            switch self {
            case .saved:return "문제 기록을 저장했습니다."
            case .waiting:return "저장 상태가 회복되면\n자동으로 다시 시도합니다."
            case .incomplete:return "문제 기록의 일부 또는\n전부를 저장하지 못했습니다.\n이미 저장된 기록은 유지됩니다.\n‘진단 기록 내보내기’에서 보관된 내용을 확인할 수 있습니다."
            case .unavailable:return "진단 기록이 비활성화되어 있거나\n저장소를 사용할 수 없습니다."
            }
        }
    }
    private let lock=NSLock(),completion:(Status)->Void
    private var phases=Set<Int>(),last:Status?,terminal=false
    init(completion:@escaping(Status)->Void){self.completion=completion}
    func saved(phase:Int){
        lock.lock();defer{lock.unlock()}
        guard !terminal else{return};phases.insert(phase)
        if phases.contains(0),phases.contains(1){terminal=true;emit(.saved)}
    }
    func waiting(retry:Bool){if retry{lock.lock();defer{lock.unlock()};if !terminal{emit(.waiting)}}else{finish(.incomplete)}}
    func finish(_ status:Status){lock.lock();defer{lock.unlock()};guard !terminal else{return};terminal=true;emit(status)}
    private func emit(_ status:Status){guard last != status else{return};last=status;DispatchQueue.main.async{[completion] in completion(status)}}
}
