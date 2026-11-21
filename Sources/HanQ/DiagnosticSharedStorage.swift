import Foundation
import Darwin
import CryptoKit
import Compression

struct DiagnosticPackedFrame:Codable {
    let sequence:Int,milliseconds:Int,data:Data
    init(_ frame:InputIncidentTrace.Frame)throws{sequence=frame.sequence;milliseconds=frame.milliseconds;data=try DiagnosticPackedCodec.shared.encode(frame)}
    func unpack()throws->InputIncidentTrace.Frame{try DiagnosticPackedCodec.shared.decode(InputIncidentTrace.Frame.self,from:data)}
    var accountedBytes:Int{data.count+MemoryLayout<Self?>.stride+32}
}

// A capture copies small Data references, not the large optional Swift value
// payloads. Array copies share their buffers until mutated. No decoding is
// required on the archive writer's path.
struct DiagnosticFrameSelection:Encodable {
    let packets:[DiagnosticPackedFrame]
    init(_ packets:[DiagnosticPackedFrame]){self.packets=packets}
    var count:Int{packets.count}
    var last:InputIncidentTrace.Frame?{packets.last.flatMap{try? $0.unpack()}}
    func unpacked()throws->[InputIncidentTrace.Frame]{try packets.map{try $0.unpack()}}
    func encode(to encoder:Encoder)throws {
        var values=encoder.unkeyedContainer()
        for packet in packets{try values.encode(packet.unpack())}
    }
}

#if HANQ_DIAGNOSTIC_TESTING
// Legacy capture fixtures inspect the decoded view. Shipping storage uses
// throwing expansion and never traps on an unreadable packed frame.
extension DiagnosticFrameSelection:RandomAccessCollection {
    typealias Index=Int
    var startIndex:Int{packets.startIndex};var endIndex:Int{packets.endIndex}
    subscript(_ position:Int)->InputIncidentTrace.Frame{try! packets[position].unpack()}
}
#endif

final class DiagnosticFrameHistory {
    private var slots:[DiagnosticPackedFrame?]
    private var latestIndex:Int?,latest:InputIncidentTrace.Frame?
    private var head=0,count=0,bytes=0
    private(set) var dropped=0,encodingFailures=0,byteEvictions=0
    let maximumBytes:Int
    init(capacity:Int,maximumBytes:Int=8*1024*1024){slots=Array(repeating:nil,count:capacity);self.maximumBytes=maximumBytes}
    var isEmpty:Bool{slots.isEmpty}
    var accountedBytes:Int{bytes+slots.count*MemoryLayout<DiagnosticPackedFrame?>.stride+MemoryLayout<InputIncidentTrace.Frame>.stride}
    var retainedCount:Int{count}
    private func seal(){
        guard let index=latestIndex,let frame=latest,slots[index]==nil else{return}
        do {let packet=try DiagnosticPackedFrame(frame);slots[index]=packet;bytes+=packet.data.count+32}
        catch{encodingFailures+=1;OperationalDiagnostics.shared.record(.policy(.storageEncode,3))}
    }
    subscript(_ index:Int)->InputIncidentTrace.Frame? {
        get {guard slots.indices.contains(index) else{return nil};if index==latestIndex{return latest};return slots[index].flatMap{try? $0.unpack()}}
        set {
            guard slots.indices.contains(index) else{return}
            if index==latestIndex {
                if let old=slots[index]{bytes-=old.data.count+32;slots[index]=nil};latest=newValue;return
            }
            seal()
            if let old=slots[index]{bytes-=old.data.count+32;slots[index]=nil;if count==slots.count{head=(head+1)%slots.count;count-=1;dropped+=1}}
            if count==0{head=index}
            latestIndex=index;latest=newValue;count+=1
        }
    }
    func selection(from minimum:Int,through maximum:Int)->DiagnosticFrameSelection {
        seal();var result:[DiagnosticPackedFrame]=[]
        for i in 0..<count {if let packet=slots[(head+i)%slots.count],packet.milliseconds>=minimum,packet.milliseconds<=maximum{result.append(packet)}}
        return DiagnosticFrameSelection(result)
    }
    // Menu admission only needs the charge, not another array of frame references.
    func selectionMemoryCharge(from minimum:Int,through maximum:Int)->Int {
        seal();var result=0
        for i in 0..<count {if let packet=slots[(head+i)%slots.count],packet.milliseconds>=minimum,packet.milliseconds<=maximum{result+=packet.accountedBytes}}
        return result
    }
    func packet(at index:Int)->DiagnosticPackedFrame? {seal();return slots.isEmpty ? nil:slots[index]}
    func trim(now:Int){
        seal()
        while count>1 {
            guard let packet=slots[head] else{head=(head+1)%slots.count;count-=1;continue}
            guard packet.milliseconds<now-60000 || accountedBytes>maximumBytes else{break}
            if accountedBytes>maximumBytes{byteEvictions+=1}
            bytes-=packet.data.count+32;slots[head]=nil;head=(head+1)%slots.count;count-=1;dropped+=1
        }
    }
}

enum DiagnosticOwnedIO {
    static func directory(_ url:URL,create:Bool=true)throws->Int32 {
        let parent=url.deletingLastPathComponent()
        for path in [parent.path,url.path] {
            var s=stat()
            if lstat(path,&s)<0 {
                guard create,errno==ENOENT else{throw OperationalFailure.posix(.storagePrepare,errno)}
                if mkdir(path,0o700)<0 && errno != EEXIST{throw OperationalFailure.posix(.storagePrepare,errno)}
                guard lstat(path,&s)==0 else{throw OperationalFailure.posix(.storagePrepare,errno)}
            }
            guard s.st_mode&S_IFMT==S_IFDIR,s.st_uid==getuid(),s.st_mode&0o077==0 else{throw OperationalFailure.policy(.storageOwnership,1)}
        }
        let fd=open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw OperationalFailure.posix(.storagePrepare,errno)}
        return fd
    }
    static func regular(_ fd:Int32,maximum:Int)throws->stat {
        var s=stat();guard fstat(fd,&s)==0 else{throw OperationalFailure.posix(.storageOwnership,errno)}
        guard s.st_mode&S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_mode&0o7777==0o600,s.st_nlink==1,s.st_size>=0,s.st_size<=maximum else{throw OperationalFailure.policy(.storageOwnership,2)}
        return s
    }
    static func same(_ a:stat,_ b:stat)->Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    static func read(_ url:URL,maximum:Int)throws->Data {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{throw OperationalFailure.posix(.storageRead,errno)}
        defer{close(fd)};let before=try regular(fd,maximum:maximum)
        guard let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:maximum+1),data.count==before.st_size,
              same(before,try regular(fd,maximum:maximum)) else{throw OperationalFailure.policy(.storageOwnership,3)}
        return data
    }
    static func names(_ dir:Int32)throws->[String] {
        let copy=dup(dir);guard copy>=0,let stream=fdopendir(copy) else{if copy>=0{close(copy)};throw OperationalFailure.posix(.storageRead,errno)}
        defer{closedir(stream)};rewinddir(stream);var result:[String]=[]
        while let entry=readdir(stream){let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}};if name != "." && name != ".."{result.append(name)}}
        return result
    }
}

// Memory admission is independent of disk retention and time-window budgets.
// A lease follows a frozen capture through the writer and retry queue, so a
// stalled filesystem cannot leave an unaccounted pile of queued snapshots.
final class DiagnosticCaptureMemory {
    struct Status {let automatic:Int,manual:Int,peakAutomatic:Int,peakManual:Int}
    private let lock=NSLock()
    private var automatic=0,manual=0,peakAutomatic=0,peakManual=0
    let limit=8*1024*1024
    func reserve(_ bytes:Int,manual isManual:Bool)->Bool {
        lock.lock();defer{lock.unlock()}
        guard bytes>=0,bytes<=limit-(isManual ? manual:automatic) else{return false}
        if isManual{manual+=bytes;peakManual=max(peakManual,manual)}else{automatic+=bytes;peakAutomatic=max(peakAutomatic,automatic)}
        return true
    }
    func release(_ bytes:Int,manual isManual:Bool){lock.lock();defer{lock.unlock()};if isManual{manual-=bytes}else{automatic-=bytes}}
    func lease(_ bytes:Int,manual:Bool)->DiagnosticCaptureLease?{
        guard reserve(bytes,manual:manual) else{return nil};return DiagnosticCaptureLease(self,manual:manual,bytes:bytes)
    }
    var status:Status {lock.lock();defer{lock.unlock()};return Status(automatic:automatic,manual:manual,peakAutomatic:peakAutomatic,peakManual:peakManual)}
}
final class DiagnosticCaptureLease {
    private let owner:DiagnosticCaptureMemory,manual:Bool
    private var bytes:Int
    fileprivate init(_ owner:DiagnosticCaptureMemory,manual:Bool,bytes:Int){self.owner=owner;self.manual=manual;self.bytes=bytes}
    func grow(_ amount:Int)->Bool{guard owner.reserve(amount,manual:manual) else{return false};bytes+=amount;return true}
    deinit{owner.release(bytes,manual:manual)}
}

// Every file is immutable after publication. Frame references point directly to
// a file's own payload; resolving one never requires that file's capture window.
// Metadata chains checkpoint after 32 captures or one hour. Retention follows
// those two dependency kinds separately, preventing an endless reference chain.
final class DiagnosticSharedStore {
    static let retentionSeconds:Double=72*60*60
    static let directoryName="Shared-v1"
    static let maximumFileBytes=16*1024*1024
    typealias FrameRange=DiagnosticArchiveReader.FrameRange
    typealias Header=DiagnosticArchiveReader.Header
    struct Payload:Codable {let fields:[String],frames:[DiagnosticPackedFrame],changes:[DiagnosticJSON.Change]}
    struct Input {let metadata:DiagnosticJSON,frames:[DiagnosticPackedFrame],run:String,incident:Int,phase:Int,trigger:Int,milliseconds:Int64;var lease:DiagnosticCaptureLease?=nil;var completion:((Bool)->Void)?=nil}
    struct Stats:Codable {
        var submitted=0,saved=0,failures=0,rejected=0,writtenBytes=0,writeCalls=0,fsyncCalls=0
        var suppliedFrames=0,storedFrames=0,reusedFrames=0,retiredFiles=0,pendingBytes=0,incompleteFiles=0,cachedFrameBytes=0
        var lastFailure:OperationalFailure?=nil
    }
    private struct Record {let header:Header,identity:stat}
    private struct Cached {let packet:DiagnosticPackedFrame,file:String,index:Int}
    private final class Pending {
        let name:String,temporary:String,chunks:[Data],input:Input,header:Header,newFrames:[DiagnosticPackedFrame]
        let bytes:Int
        var fd:Int32 = -1,offset=0,linked=false,temporaryRemoved=false
        var chunkIndex=0,chunkOffset=0
        var identity:stat?
        var metadataPending:Pending?
        var metadataName:String?,metadataCheckpoint=false
        init(name:String,chunks:[Data],input:Input,header:Header,newFrames:[DiagnosticPackedFrame]){
            self.name=name;temporary=".shared-partial-"+UUID().uuidString;self.chunks=chunks;bytes=chunks.reduce(0){$0+$1.count};self.input=input;self.header=header;self.newFrames=newFrames
        }
        deinit{if fd>=0{close(fd)}}
    }
    let directory:URL
    private let preserve:Bool,clock:()->Double,retryClock:()->Double,writer:OperationalIO.Write
    private let lock=NSRecursiveLock()
    private var directoryIdentity:stat?,owner:String?,ownerIdentity:stat?,lockFD:Int32 = -1,lockIdentity:stat?
    private var records:[String:Record]=[:],cache:[Int:Cached]=[:],cacheRun=""
    static let maximumFrameCacheBytes=8*1024*1024
    private var metadata:DiagnosticJSON?,metadataFile:String?,metadataDepth=0,lastSavedAt=0.0
    private var pending:Pending?,waiting:[Input]=[],waitingBytes=0
    private var retryAt=0.0,retryDelay=1.0,blocked=false,lastPruned=0.0,loaded=false
    private var failureMilliseconds:Int64?
    private var counters=Stats()
    private(set) var hasVerifiedWrite=false
    var canRetry:Bool{lock.lock();defer{lock.unlock()};return !blocked}
    func storageIssue(retryScheduled:Bool)->DiagnosticStorageIssue? {
        lock.lock();defer{lock.unlock()}
        guard let failure=counters.lastFailure else{return nil}
        return DiagnosticStorageIssue(component:.detail,failure:failure,
            retry:blocked ? .stopped:(retryScheduled ? .automatic:.notScheduled),
            milliseconds:failureMilliseconds,pendingCount:waiting.count+(pending==nil ? 0:1))
    }
    func canAcceptManualCapture(frameBytes:Int,awaitingPosts:Int,awaitingPostBytes:Int)->Bool {
        lock.lock();defer{lock.unlock()}
        guard !blocked else{return false}
        // A healthy writer drains each phase. During an outage, leave room for
        // the open windows' posts and both phases of the proposed new request.
        if counters.lastFailure==nil,pending==nil,waiting.isEmpty{return true}
        let manual=waiting.filter{$0.trigger==1}
        let bytes=manual.reduce(0){$0+$1.frames.reduce(0){$0+$1.accountedBytes}+32768}
        return manual.count+awaitingPosts+2<=4 && bytes+awaitingPostBytes+frameBytes+2*32768<=8*1024*1024
    }
    init(directory:URL,preserve:Bool=false,clock:@escaping ()->Double={Date().timeIntervalSince1970},
         retryClock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},writer:@escaping OperationalIO.Write={Darwin.write($0,$1,$2)}){
        self.directory=directory.appendingPathComponent(Self.directoryName,isDirectory:true);self.preserve=preserve
        self.clock=clock;self.retryClock=retryClock;self.writer=writer
    }
    deinit{if lockFD>=0{close(lockFD)}}
    var stats:Stats {lock.lock();defer{lock.unlock()};var s=counters;s.pendingBytes=(pending?.bytes ?? 0)+(pending?.metadataPending?.bytes ?? 0)+waitingBytes;s.cachedFrameBytes=cache.values.reduce(0){$0+$1.packet.accountedBytes+128};return s}
    var lastCaptureIncident:Int {lock.lock();defer{lock.unlock()};return records.values.filter{($0.header.role ?? 0)==0}.map{$0.header.incident}.max() ?? 0}
    static func validName(_ name:String)->Bool {name.hasPrefix("shared-") && name.hasSuffix(".hqdiag") && UUID(uuidString:String(name.dropFirst(7).dropLast(7))) != nil}
    private func fail(_ error:Error){
        let failure=(error as? OperationalFailure) ?? OperationalFailure.capture(error,stage:.storageWrite)
        counters.failures+=1;counters.lastFailure=failure
        failureMilliseconds=Int64(clock()*1000)
        if !DiagnosticWriteBudget.transient(failure),failure.domain != .cocoa{blocked=true}
        if blocked {
            // A later retry can become unsafe. Keep its evidence queued, but
            // do not leave a manual request promising retries that have stopped.
            pending?.input.completion?(false)
            for input in waiting{input.completion?(false)}
        }
        retryAt=retryClock()+retryDelay;retryDelay=min(60,retryDelay*2)
        OperationalDiagnostics.shared.record(failure)
    }
    private func openDirectory()throws->Int32 {
        let fd=try DiagnosticOwnedIO.directory(directory)
        do {
            var s=stat();guard fstat(fd,&s)==0 else{throw OperationalFailure.posix(.storagePrepare,errno)}
            if let prior=directoryIdentity,prior.st_dev != s.st_dev || prior.st_ino != s.st_ino{throw OperationalFailure.policy(.storageOwnership,4)}
            directoryIdentity=s
            if lockFD<0 {
                let file=openat(fd,"writer.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0o600)
                guard file>=0 else{throw OperationalFailure.posix(.storageOwnership,errno)}
                do {let state=try DiagnosticOwnedIO.regular(file,maximum:4096);guard flock(file,LOCK_EX|LOCK_NB)==0 else{throw OperationalFailure.posix(.storageOwnership,errno)};lockFD=file;lockIdentity=state}
                catch{close(file);throw error}
            }else {
                var s=stat();guard let previous=lockIdentity,fstatat(fd,"writer.lock",&s,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(previous,s) else{throw OperationalFailure.policy(.storageOwnership,5)}
            }
            let ownerName="owner-v1.json"
            if owner==nil {
                let url=directory.appendingPathComponent(ownerName)
                var existing=stat()
                if fstatat(fd,ownerName,&existing,AT_SYMLINK_NOFOLLOW)<0 {
                    guard errno==ENOENT else{throw OperationalFailure.posix(.storageOwnership,errno)}
                    let temporary=".owner-partial-"+UUID().uuidString
                    let file=openat(fd,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                    guard file>=0 else{throw OperationalFailure.posix(.storageOwnership,errno)};defer{close(file)}
                    let data=try JSONEncoder().encode(["schema":"1","owner":UUID().uuidString])
                    if let error=writeAll(data,to:file){throw error}
                    counters.fsyncCalls+=1;guard fsync(file)==0 else{throw OperationalFailure.posix(.storageWrite,errno)}
                    guard linkat(fd,temporary,fd,ownerName,0)==0 else{throw OperationalFailure.posix(.storagePublish,errno)}
                    guard unlinkat(fd,temporary,0)==0 else{throw OperationalFailure.posix(.storagePublish,errno)}
                    counters.fsyncCalls+=1;guard fsync(fd)==0 else{throw OperationalFailure.posix(.storageWrite,errno)}
                }
                let data=try DiagnosticOwnedIO.read(url,maximum:4096)
                let value=try JSONDecoder().decode([String:String].self,from:data)
                guard value["schema"]=="1",let id=value["owner"],UUID(uuidString:id) != nil else{throw OperationalFailure.policy(.storageOwnership,6)}
                var info=stat();guard fstatat(fd,ownerName,&info,AT_SYMLINK_NOFOLLOW)==0 else{throw OperationalFailure.posix(.storageOwnership,errno)}
                owner=id;ownerIdentity=info
            }else {
                var info=stat();guard let old=ownerIdentity,fstatat(fd,ownerName,&info,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(old,info) else{throw OperationalFailure.policy(.storageOwnership,6)}
            }
            if !loaded {
                for name in try DiagnosticOwnedIO.names(fd) {
                    if name.hasPrefix(".shared-partial-") || name.hasPrefix(".owner-partial-"){counters.incompleteFiles+=1;continue}
                    guard Self.validName(name) else{continue}
                    let (header,state)=try Self.readHeader(directory.appendingPathComponent(name))
                    guard header.owner==owner else{throw OperationalFailure.policy(.storageOwnership,7)}
                    records[name]=Record(header:header,identity:state)
                };loaded=true
            }
            return fd
        }catch{close(fd);throw error}
    }
    private func writeAll(_ data:Data,to fd:Int32)->OperationalFailure? {
        OperationalIO.writeAll(data,to:fd,stage:.storageWrite,write:{[self] fd,p,n in
            counters.writeCalls+=1;let count=writer(fd,p,n);if count>0{counters.writtenBytes+=count};return count
        })
    }
    @discardableResult func prepare()->Bool {
        lock.lock();defer{lock.unlock()}
        guard !blocked,retryClock()>=retryAt else{return false}
        do {
            let dir=try openDirectory();defer{close(dir)};try prune(dir)
            // Merely opening an export window cannot prove failed writes recovered.
            if counters.lastFailure != nil {
                guard pending==nil,waiting.isEmpty else{return false}
                try verifyRecoveryWrite(dir)
            }
            counters.lastFailure=nil;retryAt=0;retryDelay=1;return true
        }catch{fail(error);return false}
    }
    @discardableResult func save(_ capture:InputIncidentTrace.Capture,lease:DiagnosticCaptureLease?=nil,completion:((Bool)->Void)?=nil)->Bool {
        do {
            var header=capture;header.frames=DiagnosticFrameSelection([])
            let value=try JSONDecoder().decode(DiagnosticJSON.self,from:JSONEncoder().encode(header))
            return submit(Input(metadata:value,frames:capture.frames.packets,run:capture.runID,incident:capture.incident,phase:capture.phase,trigger:capture.trigger.rawValue,milliseconds:Int64(clock()*1000),lease:lease,completion:completion))
        }catch{lock.lock();fail(error);lock.unlock();completion?(false);return false}
    }
    @discardableResult func submit(_ input:Input)->Bool {
        lock.lock();defer{lock.unlock()};counters.submitted+=1
        let cost=input.frames.reduce(0){$0+$1.accountedBytes}+32768
        let kind=waiting.filter{($0.trigger==1)==(input.trigger==1)}
        let sameKind=kind.reduce(0){$0+$1.frames.reduce(0){$0+$1.accountedBytes}+32768}
        guard kind.count<(input.trigger==1 ? 4:64),sameKind+cost<=8*1024*1024 else{counters.rejected+=1;disposition(input,6);input.completion?(false);return false}
        waiting.append(input);waitingBytes+=cost
        _ = drain()
        let completed=pending==nil && waiting.isEmpty && counters.lastFailure==nil
        if !completed{disposition(input,8)}
        return completed
    }
    @discardableResult func drain()->Bool {
        lock.lock();defer{lock.unlock()}
        guard !blocked,retryClock()>=retryAt else{return false}
        do {
            let dir=try openDirectory();defer{close(dir)}
            if counters.lastFailure != nil,pending==nil,waiting.isEmpty{try verifyRecoveryWrite(dir)}
            while pending != nil || !waiting.isEmpty {
                if pending==nil {pending=try plan(waiting[0]);waiting.removeFirst();waitingBytes=waiting.reduce(0){$0+$1.frames.reduce(0){$0+$1.accountedBytes}+32768}}
                guard let p=pending else{break}
                try publish(p,dir:dir)
                disposition(p.input,1)
                pending=nil;counters.saved+=1;counters.lastFailure=nil;hasVerifiedWrite=true;retryAt=0;retryDelay=1
                p.input.completion?(true)
            }
            if clock()-lastSavedAt>65{cache.removeAll()}
            try prune(dir);counters.lastFailure=nil;return true
        }catch{fail(error);return false}
    }
    // Only after a failure with no queued payload. Healthy timer ticks never
    // write probes. Use the same injected writer and preserve unrelated files.
    private func verifyRecoveryWrite(_ dir:Int32)throws {
        let name=".storage-check-"+UUID().uuidString
        let fd=openat(dir,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw OperationalFailure.posix(.storageWrite,errno)}
        var created=stat()
        guard fstat(fd,&created)==0 else{close(fd);throw OperationalFailure.posix(.storageWrite,errno)}
        defer{
            var current=stat()
            if fstatat(dir,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==created.st_dev,current.st_ino==created.st_ino{unlinkat(dir,name,0)}
            close(fd)
        }
        let data=Data(UUID().uuidString.utf8)
        if let error=writeAll(data,to:fd){throw error}
        counters.fsyncCalls+=1
        guard fsync(fd)==0,lseek(fd,0,SEEK_SET)==0 else{throw OperationalFailure.posix(.storageWrite,errno)}
        guard try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:data.count+1)==data else{throw OperationalFailure.policy(.storageRead,1)}
        hasVerifiedWrite=true
    }
    private func disposition(_ input:Input,_ code:Int){
        var context=DiagnosticCriticalJournal.Context(trace:input.run,incident:input.incident,sequence:input.frames.last?.sequence ?? 0,lane:0,kind:input.trigger,category:input.phase,count:input.frames.count,episode:0)
        if case .object(let root)=input.metadata,case .object(let preservation)?=root["capturePreservation"],case .array(let requests)?=preservation["requests"],case .object(let first)?=requests.first,case .string(let id)?=first["requestID"]{context.requestID=id}
        OperationalDiagnostics.shared.record(.policy(.captureDisposition,code),context:context,observation:true)
    }
    private func plan(_ input:Input)throws->Pending {
        if cacheRun != input.run{metadata=nil;metadataFile=nil;metadataDepth=0}
        if cacheRun != input.run || clock()-lastSavedAt>65{cache.removeAll();cacheRun=input.run}
        if let newest=input.frames.map(\.milliseconds).max(){cache=cache.filter{$0.value.packet.milliseconds>=newest-65000 && records[$0.value.file] != nil}}
        let name="shared-"+UUID().uuidString+".hqdiag"
        var frames:[DiagnosticPackedFrame]=[],ranges:[FrameRange]=[]
        for packet in input.frames {
            let file:String,index:Int
            if let prior=cache[packet.sequence],prior.packet.data==packet.data {file=prior.file;index=prior.index}
            else {file=name;index=frames.count;frames.append(packet)}
            if let last=ranges.last,last.file==file,last.first+last.count==index{ranges[ranges.count-1].count+=1}
            else{ranges.append(FrameRange(file:file,first:index,count:1))}
        }
        let base=(metadataDepth<32 && clock()-lastSavedAt<3600 && metadataFile.flatMap{records[$0]} != nil) ? metadataFile:nil
        let changes=DiagnosticJSON.changes(from:base==nil ? .object([:]):metadata ?? .object([:]),to:input.metadata)
        let metadataName="shared-"+UUID().uuidString+".hqdiag"
        let meta=try makePending(name:metadataName,input:input,frames:[],ranges:[],changes:changes,base:base,role:1)
        let result=try makePending(name:name,input:input,frames:frames,ranges:ranges,changes:[],base:metadataName,role:0)
        result.metadataPending=meta;result.metadataName=metadataName;result.metadataCheckpoint=base==nil
        return result
    }
    private func makePending(name:String,input:Input,frames:[DiagnosticPackedFrame],ranges:[FrameRange],changes:[DiagnosticJSON.Change],base:String?,role:Int)throws->Pending {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let payload=try DiagnosticPayloadStream.encode(fields:role==1 ? []:DiagnosticPackedCodec.shared.fields,frames:frames,changes:changes)
        var hash=SHA256();for chunk in payload.chunks{hash.update(data:chunk)}
        var header=Header(schema:1,owner:owner!,runID:input.run,incident:input.incident,phase:input.phase,trigger:input.trigger,
            milliseconds:input.milliseconds,metadataBase:base,ranges:ranges,frameCount:role==1 ? 0:input.frames.count,ownFrameCount:frames.count,
            rawBytes:payload.rawBytes,compressed:payload.compressed,digest:hash.finalize().map{String(format:"%02x",$0)}.joined())
        header.role=role
        let h=try encoder.encode(header);guard h.count<=1024*1024 else{throw DiagnosticPackedError.oversized}
        var size=UInt32(h.count).littleEndian,prefix=Data("HQSHR001".utf8)
        withUnsafeBytes(of:&size){prefix.append(contentsOf:$0)}
        guard prefix.count+h.count+payload.bytes<=Self.maximumFileBytes else{throw DiagnosticPackedError.oversized}
        return Pending(name:name,chunks:[prefix,h]+payload.chunks,input:input,header:header,newFrames:frames)
    }
    private func publish(_ p:Pending,dir:Int32)throws {
        if let meta=p.metadataPending{try publishBytes(meta,dir:dir);p.metadataPending=nil}
        try publishBytes(p,dir:dir)
        for (index,packet) in p.newFrames.enumerated(){cache[packet.sequence]=Cached(packet:packet,file:p.name,index:index)}
        // This lookup is an optimization, not retained evidence. Keep it bounded
        // even when 65 seconds of high-rate observations exceed the history
        // budget; an evicted lookup merely stores that frame again next time.
        var cacheBytes=cache.values.reduce(0){$0+$1.packet.accountedBytes+128}
        if cacheBytes>Self.maximumFrameCacheBytes {
            for entry in cache.sorted(by:{$0.value.packet.milliseconds==$1.value.packet.milliseconds ? $0.key<$1.key:$0.value.packet.milliseconds<$1.value.packet.milliseconds}) {
                guard cacheBytes>Self.maximumFrameCacheBytes else{break}
                cacheBytes-=entry.value.packet.accountedBytes+128;cache.removeValue(forKey:entry.key)
            }
        }
        metadata=p.input.metadata;metadataFile=p.metadataName;metadataDepth=p.metadataCheckpoint ? 1:metadataDepth+1;lastSavedAt=clock()
        counters.suppliedFrames+=p.input.frames.count;counters.storedFrames+=p.newFrames.count;counters.reusedFrames+=p.input.frames.count-p.newFrames.count
    }
    private func publishBytes(_ p:Pending,dir:Int32)throws {
        if p.fd<0 {
            p.fd=openat(dir,p.temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard p.fd>=0 else{throw OperationalFailure.posix(.storagePublish,errno)}
        }
        var actual=stat()
        guard fstat(p.fd,&actual)==0,actual.st_mode&S_IFMT==S_IFREG,actual.st_uid==getuid(),actual.st_mode&0o7777==0o600,
              actual.st_nlink==(p.linked && !p.temporaryRemoved ? 2:1),actual.st_size==p.offset else{throw OperationalFailure.policy(.storageOwnership,10)}
        if let previous=p.identity, !DiagnosticOwnedIO.same(previous,actual){throw OperationalFailure.policy(.storageOwnership,10)}
        var named=stat()
        guard fstatat(dir,p.temporaryRemoved ? p.name:p.temporary,&named,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(actual,named) else{throw OperationalFailure.policy(.storageOwnership,10)}
        if p.linked{guard fstatat(dir,p.name,&named,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(actual,named) else{throw OperationalFailure.policy(.storageOwnership,10)}}
        defer{var state=stat();if fstat(p.fd,&state)==0{p.identity=state}}
        while p.chunkIndex<p.chunks.count {
            let chunk=p.chunks[p.chunkIndex]
            let result=chunk.withUnsafeBytes{b in writer(p.fd,b.baseAddress!.advanced(by:p.chunkOffset),b.count-p.chunkOffset)}
            counters.writeCalls+=1
            if result<0{if errno==EINTR{continue};throw OperationalFailure.posix(.storageWrite,errno)}
            guard result>0,result<=chunk.count-p.chunkOffset else{throw OperationalFailure.policy(.storageWrite,1)}
            p.offset+=result;p.chunkOffset+=result;counters.writtenBytes+=result
            if p.chunkOffset==chunk.count{p.chunkIndex+=1;p.chunkOffset=0}
        }
        counters.fsyncCalls+=1;guard fsync(p.fd)==0 else{throw OperationalFailure.posix(.storageWrite,errno)}
        if !p.linked {guard linkat(dir,p.temporary,dir,p.name,0)==0 else{throw OperationalFailure.posix(.storagePublish,errno)};p.linked=true}
        if !p.temporaryRemoved{guard unlinkat(dir,p.temporary,0)==0 else{throw OperationalFailure.posix(.storagePublish,errno)};p.temporaryRemoved=true}
        counters.fsyncCalls+=1;guard fsync(dir)==0 else{throw OperationalFailure.posix(.storagePublish,errno)}
        let state=try DiagnosticOwnedIO.regular(p.fd,maximum:Self.maximumFileBytes)
        records[p.name]=Record(header:p.header,identity:state)
    }
    private func prune(_ dir:Int32)throws {
        guard !preserve,clock()-lastPruned>=60 || lastPruned==0 else{return}
        let now=Int64(clock()*1000),age=Int64(Self.retentionSeconds*1000)
        var latest:[String:Int64]=[:]
        for record in records.values{let h=record.header,key=h.runID+":"+String(h.incident);latest[key]=max(latest[key] ?? 0,h.milliseconds)}
        let roots=records.filter{let h=$0.value.header,end=latest[h.runID+":"+String(h.incident)]!;return (h.role ?? 0)==0 && (now<end || now-end<age)}.map(\.key)
        var keep=Set(roots),metadataNeeded=Set(roots),work=roots
        for (name,record) in records where record.header.role==1 && now-record.header.milliseconds<age {keep.insert(name);metadataNeeded.insert(name);work.append(name)}
        // Frame dependencies do not recursively retain unrelated capture data.
        for root in roots{for r in records[root]!.header.ranges{keep.insert(r.file)}}
        while let name=work.popLast(){if let base=records[name]?.header.metadataBase,metadataNeeded.insert(base).inserted{keep.insert(base);work.append(base)}}
        for (name,record) in records where !keep.contains(name) {
            var actual=stat();guard fstatat(dir,name,&actual,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(record.identity,actual) else{throw OperationalFailure.policy(.storageOwnership,8)}
            guard unlinkat(dir,name,0)==0 else{throw OperationalFailure.posix(.storagePrune,errno)}
            records.removeValue(forKey:name);counters.retiredFiles+=1
        }
        lastPruned=clock()
    }
    static func readHeader(_ url:URL)throws->(Header,stat) {
        do{return try DiagnosticArchiveReader.readHeader(url)}
        catch{throw (error as? OperationalFailure) ?? OperationalFailure.capture(error,stage:.storageRead)}
    }
    struct Expanded {let header:Header,metadata:DiagnosticJSON,frames:[InputIncidentTrace.Frame],dependencies:Set<String>}
    static func expand(_ name:String,in directory:URL,includeFrames:Bool=true)throws->Expanded {
        let result=try DiagnosticArchiveReader.expand(name,in:directory,includeFrames:includeFrames)
        let frames=try result.frames.map{try JSONDecoder().decode(InputIncidentTrace.Frame.self,from:JSONSerialization.data(withJSONObject:$0))}
        return Expanded(header:result.header,metadata:result.metadata,frames:frames,dependencies:result.dependencies)
    }
    func copySnapshot(into destination:URL)throws {
        lock.lock();defer{lock.unlock()}
        _ = drain();let dir=try openDirectory();defer{close(dir)}
        for (name,record) in records {
            var actual=stat();guard fstatat(dir,name,&actual,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(actual,record.identity) else{throw OperationalFailure.policy(.storageOwnership,9)}
            let source=directory.appendingPathComponent(name),target=destination.appendingPathComponent(name)
            try FileManager.default.copyItem(at:source,to:target)
            let sourceHash=try DiagnosticArchiveIO.scan(source,maximum:Self.maximumFileBytes)
            let targetHash=try DiagnosticArchiveIO.scan(target,maximum:Self.maximumFileBytes)
            guard sourceHash.bytes==targetHash.bytes,sourceHash.digest==targetHash.digest,fstatat(dir,name,&actual,AT_SYMLINK_NOFOLLOW)==0,DiagnosticOwnedIO.same(actual,record.identity) else{throw DiagnosticPackedError.invalid}
        }
        let data=try JSONEncoder().encode(stats);let path=destination.appendingPathComponent("shared-storage-status.json")
        try data.write(to:path,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
}

/// Produces the existing JSON/zlib payload in bounded working buffers. The
/// retained output is only the final bytes needed for a retry, in <=64KiB
/// chunks; there is no whole raw JSON, oversized destination or final copy.
enum DiagnosticPayloadStream {
    struct Result {
        let chunks:[Data],rawBytes:Int,compressed:Bool
        var bytes:Int{chunks.reduce(0){$0+$1.count}}
    }
    private final class Sink {
        static let size=64*1024
        let compressed:Bool
        private let destination=UnsafeMutablePointer<UInt8>.allocate(capacity:size)
        private var stream:compression_stream
        private var initialized=false,buffer=Data(),chunks:[Data]=[]
        private(set) var rawBytes=0
        init(compressed:Bool) {
            self.compressed=compressed
            stream=compression_stream(dst_ptr:destination,dst_size:Self.size,src_ptr:UnsafePointer(destination),src_size:0,state:nil)
            if compressed {
                initialized=compression_stream_init(&stream,COMPRESSION_STREAM_ENCODE,COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR
            }
            buffer.reserveCapacity(Self.size)
        }
        deinit{if initialized{compression_stream_destroy(&stream)};destination.deallocate()}
        func append(_ data:Data)throws {
            guard data.count<=DiagnosticSharedStore.maximumFileBytes-rawBytes else{throw DiagnosticPackedError.oversized}
            rawBytes+=data.count
            try data.withUnsafeBytes{source in
                var offset=0
                while offset<source.count {
                    let count=min(Self.size-buffer.count,source.count-offset)
                    buffer.append(contentsOf:source[offset..<offset+count]);offset+=count
                    if buffer.count==Self.size{try flush(final:false)}
                }
            }
        }
        private func flush(final:Bool)throws {
            if !compressed {
                if !buffer.isEmpty{chunks.append(buffer);buffer=Data();buffer.reserveCapacity(Self.size)}
                return
            }
            guard initialized else{throw DiagnosticPackedError.invalid}
            try buffer.withUnsafeBytes{source in
                stream.src_ptr=source.bindMemory(to:UInt8.self).baseAddress ?? UnsafePointer(destination)
                stream.src_size=source.count
                repeat {
                    stream.dst_ptr=destination;stream.dst_size=Self.size
                    let previous=stream.src_size
                    let status=compression_stream_process(&stream,final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue):0)
                    guard status != COMPRESSION_STATUS_ERROR else{throw DiagnosticPackedError.invalid}
                    let count=Self.size-stream.dst_size
                    if count>0{chunks.append(Data(bytes:destination,count:count))}
                    if status==COMPRESSION_STATUS_END {
                        guard final,stream.src_size==0 else{throw DiagnosticPackedError.invalid};break
                    }
                    guard previous != stream.src_size || count>0 || (!final && stream.src_size==0) else{throw DiagnosticPackedError.invalid}
                }while final || stream.src_size>0
            }
            buffer.removeAll(keepingCapacity:true)
        }
        func finish()throws->Result {
            try flush(final:true)
            return Result(chunks:chunks,rawBytes:rawBytes,compressed:compressed)
        }
    }
    static func encode(fields:[String],frames:[DiagnosticPackedFrame],changes:[DiagnosticJSON.Change])throws->Result {
        func build(_ compressed:Bool)throws->Result {
            let sink=Sink(compressed:compressed),encoder=JSONEncoder()
            encoder.outputFormatting=[.sortedKeys]
            func token(_ value:String)throws{try sink.append(Data(value.utf8))}
            // Strings can be long metadata values; escape bytes without a
            // second complete encoded string allocation.
            func string(_ value:String)throws {
                try token("\"");var escaped=Data();escaped.reserveCapacity(Sink.size)
                let hex=Array("0123456789abcdef".utf8)
                for byte in value.utf8 {
                    switch byte {
                    case 34,47,92:escaped.append(92);escaped.append(byte)
                    case 8:escaped.append(contentsOf:[92,98])
                    case 9:escaped.append(contentsOf:[92,116])
                    case 10:escaped.append(contentsOf:[92,110])
                    case 12:escaped.append(contentsOf:[92,102])
                    case 13:escaped.append(contentsOf:[92,114])
                    case 0...31:escaped.append(contentsOf:[92,117,48,48,hex[Int(byte>>4)],hex[Int(byte&15)]])
                    default:escaped.append(byte)
                    }
                    if escaped.count>=Sink.size-6{try sink.append(escaped);escaped.removeAll(keepingCapacity:true)}
                }
                try sink.append(escaped);try token("\"")
            }
            func json(_ value:DiagnosticJSON,_ depth:Int=0)throws {
                guard depth<=512 else{throw DiagnosticPackedError.invalid}
                switch value {
                case .null:try token("null")
                case .bool(let v):try token(v ? "true":"false")
                case .integer(let v):try token(String(v))
                case .real(let v):try sink.append(encoder.encode(v))
                case .string(let v):try string(v)
                case .array(let values):
                    try token("[")
                    for (i,v) in values.enumerated(){if i>0{try token(",")};try json(v,depth+1)}
                    try token("]")
                case .object(let values):
                    try token("{")
                    for (i,key) in values.keys.sorted().enumerated(){if i>0{try token(",")};try string(key);try token(":");try json(values[key]!,depth+1)}
                    try token("}")
                }
            }
            func strings(_ values:[String])throws {
                try token("[");for (i,value) in values.enumerated(){if i>0{try token(",")};try string(value)};try token("]")
            }
            try token("{\"changes\":[")
            for (i,change) in changes.enumerated(){
                if i>0{try token(",")};try token("{\"path\":");try strings(change.path)
                if let value=change.value{try token(",\"value\":");try json(value)}
                try token("}")
            }
            try token("],\"fields\":");try strings(fields);try token(",\"frames\":[")
            for (i,frame) in frames.enumerated(){
                if i>0{try token(",")}
                // A packet is bounded to 64KiB by the packed codec. Retain the
                // exact Codable fields/base64 encoding of the existing format.
                try autoreleasepool{try sink.append(encoder.encode(frame))}
            }
            try token("]}");return try sink.finish()
        }
        var compressed:Result?=try build(true)
        if compressed!.bytes<compressed!.rawBytes{return compressed!}
        // Rare incompressible payload: discard compressed output before a
        // second in-memory pass. Never spool raw JSON to disk.
        compressed=nil;return try build(false)
    }
}

// Errors, ordinary incident facts, and termination records have independent
// queues, descriptors and age retention. A blocked ordinary writer cannot hold
// the termination writer. The flush deadline bounds the caller, not the kernel.
final class DiagnosticCriticalJournal {
    typealias Context=DiagnosticCriticalLane.Context
    typealias Event=DiagnosticCriticalLane.Event
    typealias Header=DiagnosticCriticalLane.Header
    typealias Decoded=DiagnosticCriticalLane.Decoded
    typealias Status=DiagnosticCriticalLane.Status
    static let filenames=DiagnosticCriticalLane.filenames // read-only v2 compatibility
    static let maximumSegmentBytes=DiagnosticCriticalLane.maximumSegmentBytes
    static let laneDirectories=["CriticalErrors-v3","CriticalObservations-v3","CriticalTerminal-v3"]
    private let errors:DiagnosticCriticalLane,observations:DiagnosticCriticalLane,terminal:DiagnosticCriticalLane
    private let lock=NSLock(),run=UUID().uuidString
    private var sequence=0
    private let wallClock:()->Double
    let directory:URL
    init(directory:URL,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},
         segmentBytes:Int=maximumSegmentBytes,preserve:Bool=false,wallClock:@escaping ()->Double={Date().timeIntervalSince1970},
         writer:@escaping OperationalIO.Write={Darwin.write($0,$1,$2)}) {
        self.wallClock=wallClock;self.directory=directory.standardizedFileURL
        errors=DiagnosticCriticalLane(directory:directory.appendingPathComponent(Self.laneDirectories[0]),clock:clock,segmentBytes:segmentBytes,lane:"errors",preserve:preserve,wallClock:wallClock,writer:writer)
        observations=DiagnosticCriticalLane(directory:directory.appendingPathComponent(Self.laneDirectories[1]),clock:clock,segmentBytes:segmentBytes,lane:"observations",preserve:preserve,wallClock:wallClock,writer:writer)
        terminal=DiagnosticCriticalLane(directory:directory.appendingPathComponent(Self.laneDirectories[2]),clock:clock,segmentBytes:segmentBytes,lane:"terminal",preserve:preserve,wallClock:wallClock,writer:writer)
    }
    func record(_ failure:OperationalFailure,context:Context?=nil,observation:Bool=false) {
        lock.lock();sequence+=1;let id=sequence;lock.unlock()
        record(Event(run:run,sequence:id,milliseconds:Int64(wallClock()*1000),failure:failure,context:context),observation:observation)
    }
    func record(_ event:Event,observation:Bool=false) {
        if event.failure.stage == .termination{terminal.record(event)}
        else if observation{observations.record(event,observation:true)}
        else{errors.record(event)}
    }
    @discardableResult func flush(timeout:Double=0.25)->Bool {
        let deadline=ProcessInfo.processInfo.systemUptime+max(0,timeout)
        var success=true
        for lane in [terminal,errors,observations]{let result=lane.flush(timeout:max(0,deadline-ProcessInfo.processInfo.systemUptime));success=result && success}
        return success
    }
    func status()->Status {
        let a=errors.status(),b=observations.status(),c=terminal.status(),all=[a,b,c]
        return Status(pendingErrors:a.pendingErrors+c.pendingErrors,pendingObservations:b.pendingObservations,
            droppedErrors:a.droppedErrors+c.droppedErrors,droppedObservations:b.droppedObservations,
            writeFailures:all.reduce(0){$0+$1.writeFailures},lastErrno:all.last{$0.lastErrno != 0}?.lastErrno ?? 0,
            lastPolicy:all.last{$0.lastPolicy != 0}?.lastPolicy ?? 0,writtenBytes:all.reduce(0){$0+$1.writtenBytes},rotations:all.reduce(0){$0+$1.rotations})
    }
    func storageIssues()->[DiagnosticStorageIssue] {
        [errors.storageIssue(component:.criticalErrors),observations.storageIssue(component:.observations),terminal.storageIssue(component:.termination)].compactMap{$0}
    }
    static func decode(_ data:Data)->Decoded? {DiagnosticCriticalLane.decode(data)}
    static func exportedName(_ name:String)->Bool {
        filenames.map{String($0.dropFirst())}.contains(name) || DiagnosticCriticalLane.validName("."+name)
    }
    static func forEachFile(_ dir:Int32,_ body:(String,Data)throws->Void)throws {
        try DiagnosticCriticalLane.forEachFile(dir,body)
        for name in laneDirectories {
            let fd=openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            if fd<0{if errno==ENOENT{continue};throw DiagnosticLogExport.Failure.unavailable};defer{close(fd)}
            var info=stat();guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw DiagnosticLogExport.Failure.unavailable}
            try DiagnosticCriticalLane.forEachFile(fd,body)
        }
    }
    static func readFiles(_ dir:Int32)throws->[(String,Data)] {
        var files:[(String,Data)]=[]
        try forEachFile(dir){files.append(($0,$1))};return files
    }
}
