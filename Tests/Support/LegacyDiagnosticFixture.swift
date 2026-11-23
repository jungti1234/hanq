import Foundation
import Carbon
import CryptoKit

// Frozen 437 writer used only to generate legacy compatibility fixtures. Not linked into HanQ.
final class LegacyFixtureWriteBudget {
    struct Limits {
        var automaticHour=64*1024*1024,automaticDay=256*1024*1024
        var manualHour=32*1024*1024,manualDay=128*1024*1024
        var automaticEventsHour=48,automaticEventsDay=192
    }
    private struct Ledger:Codable {
        var schema=1
        var hour:Double,day:Double,last:Double
        var automaticHour=0,automaticDay=0,manualHour=0,manualDay=0
        var eventsHour=0,eventsDay=0
    }
    private let limits:Limits,clock:()->Double
    private let writer:OperationalIO.Write
    private var ledger:Ledger?
    private var identity:stat?
    private var failed=false,permanentFailure=false
    private var retryAt=0.0,retryDelay=1.0
    private let retryClock:()->Double
    private let name:String,requiredMarker:String
    private(set) var lastFailure:OperationalFailure?
    private(set) var suppressedAutomatic=0,suppressedManual=0,persistenceFailures=0
    private(set) var actualBytes=0
    init(limits:Limits=Limits(),clock:@escaping ()->Double={Date().timeIntervalSince1970},
         retryClock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},
         name:String=".write-budget-v1.ledger",requiredMarker:String=".automatic-ownership-v1.index",
         writer:@escaping OperationalIO.Write={Darwin.write($0,$1,$2)}) {
        self.limits=limits;self.clock=clock;self.retryClock=retryClock;self.writer=writer
        self.name=name;self.requiredMarker=requiredMarker
    }
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
    var summary:[String:Int] {
        let v=ledger
        return ["automaticHourLimit":limits.automaticHour,"automaticDayLimit":limits.automaticDay,
                "manualHourLimit":limits.manualHour,"manualDayLimit":limits.manualDay,
                "automaticHour":v?.automaticHour ?? 0,"automaticDay":v?.automaticDay ?? 0,
                "manualHour":v?.manualHour ?? 0,"manualDay":v?.manualDay ?? 0,
                "eventsHour":v?.eventsHour ?? 0,"eventsDay":v?.eventsDay ?? 0,
                "suppressedAutomatic":suppressedAutomatic,"suppressedManual":suppressedManual,
                "persistenceFailures":persistenceFailures]
    }
    private func fault(_ error:OperationalFailure)->Bool {
        lastFailure=error
        failed=true;permanentFailure = !Self.transient(error)
        retryAt=retryClock()+retryDelay;retryDelay=min(60,retryDelay*2)
        persistenceFailures=min(persistenceFailures,Int.max-1)+1
        OperationalDiagnostics.shared.record(error);return false
    }
    private func prepare(_ dir:Int32)->Bool {
        if failed {
            guard !permanentFailure,retryClock()>=retryAt else{return false}
            failed=false
        }
        lastFailure=nil
        if ledger != nil{return true}
        let now=clock();guard now.isFinite,now>=0 else{return fault(.policy(.budgetPersistence,1))}
        let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        if fd<0 {
            let code=errno;guard code==ENOENT else{return fault(.posix(.budgetPersistence,code))}
            // A ledger missing from an upgraded store is damage, not new credit.
            let index=openat(dir,requiredMarker,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            if index>=0 {
                defer{close(index)}
                guard let data=try? FileHandle(fileDescriptor:index,closeOnDealloc:false).read(upToCount:8*1024*1024+1),
                      let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                      (object["writeBudgetRequired"] as? Bool != true && requiredMarker == ".automatic-ownership-v1.index") else{return fault(.policy(.budgetPersistence,2))}
            }else if errno != ENOENT{return fault(.posix(.budgetPersistence,errno))}
            ledger=Ledger(hour:now,day:now,last:now);return true
        }
        defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0 else{return fault(.posix(.budgetPersistence,errno))}
        guard info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o7777==0o600,info.st_size>0,info.st_size<=4096,
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:4097),
              let value=try? JSONDecoder().decode(Ledger.self,from:data),value.schema==1,
              [value.hour,value.day,value.last].allSatisfy({$0.isFinite && $0>=0}),value.hour<=value.last,value.day<=value.last,
              [value.automaticHour,value.automaticDay,value.manualHour,value.manualDay,value.eventsHour,value.eventsDay].allSatisfy({$0>=0 && $0<=Int.max/2})
        else{return fault(.policy(.budgetPersistence,3))}
        identity=info;ledger=value;return true
    }
    private func same(_ left:stat,_ right:stat)->Bool {
        left.st_dev==right.st_dev && left.st_ino==right.st_ino && left.st_size==right.st_size &&
        left.st_mtimespec.tv_sec==right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec==right.st_mtimespec.tv_nsec &&
        left.st_ctimespec.tv_sec==right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec==right.st_ctimespec.tv_nsec
    }
    var waitingForRecovery:Bool{failed && (permanentFailure || retryClock()<retryAt)}
    func rejectExhaustedEvent()->Bool {
        guard let value=ledger else{return false}
        let wall=clock();guard wall.isFinite,wall>=0 else{return false}
        let now=max(value.last,wall)
        let blocked=(now-value.hour<3600 && value.eventsHour>=limits.automaticEventsHour) ||
            (now-value.day<86400 && value.eventsDay>=limits.automaticEventsDay)
        if blocked{suppressedAutomatic=min(suppressedAutomatic,Int.max-1)+1}
        return blocked
    }
    func reserve(_ bytes:Int,automatic:Bool,event:Bool,dir:Int32)->Bool {
        guard bytes>=0,bytes<=Int.max-4096,prepare(dir) else{return false}
        var value=ledger!
        let wall=clock();guard wall.isFinite,wall>=0 else{return fault(.policy(.budgetPersistence,1))}
        // Clock rollback never grants another window, including across relaunch.
        let now=max(value.last,wall);value.last=now
        if now-value.hour>=3600{value.hour=now;value.automaticHour=0;value.manualHour=0;value.eventsHour=0}
        if now-value.day>=86400{value.day=now;value.automaticDay=0;value.manualDay=0;value.eventsDay=0}
        let charge=bytes+4096 // includes this <=4KiB atomic ledger replacement
        let hour=automatic ? value.automaticHour:value.manualHour,day=automatic ? value.automaticDay:value.manualDay
        let allowed=charge<=(automatic ? limits.automaticHour:limits.manualHour)-min(hour,automatic ? limits.automaticHour:limits.manualHour) &&
            charge<=(automatic ? limits.automaticDay:limits.manualDay)-min(day,automatic ? limits.automaticDay:limits.manualDay) &&
            (!automatic || !event || (value.eventsHour<limits.automaticEventsHour && value.eventsDay<limits.automaticEventsDay))
        guard allowed else {
            if automatic{suppressedAutomatic=min(suppressedAutomatic,Int.max-1)+1}else{suppressedManual=min(suppressedManual,Int.max-1)+1}
            ledger=value;return false
        }
        if automatic{value.automaticHour+=charge;value.automaticDay+=charge;if event{value.eventsHour+=1;value.eventsDay+=1}}
        else{value.manualHour+=charge;value.manualDay+=charge}
        guard let data=try? JSONEncoder().encode(value),data.count<=4096 else{return fault(.policy(.budgetPersistence,4))}
        if let identity {
            var current=stat()
            guard fstatat(dir,name,&current,AT_SYMLINK_NOFOLLOW)==0,same(identity,current) else{return fault(.policy(.budgetPersistence,5))}
        }
        // Charge the attempted transaction in memory BEFORE I/O. A failed or
        // partially written reservation is never refunded on a later retry.
        ledger=value
        let temporary=".budget-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return fault(.posix(.budgetPersistence,errno))}
        defer{close(fd);unlinkat(dir,temporary,0)}
        if let failure=OperationalIO.writeAll(data,to:fd,stage:.budgetPersistence,write:{[self] fd,p,n in
            let count=writer(fd,p,n);if count>0{actualBytes+=count};return count
        }){return fault(failure)}
        guard fsync(fd)==0 else{return fault(.posix(.budgetPersistence,errno))}
        if identity == nil {
            guard linkat(dir,temporary,dir,name,0)==0 else{return fault(.posix(.budgetPersistence,errno))}
        }else {
            guard renameat(dir,temporary,dir,name)==0 else{return fault(.posix(.budgetPersistence,errno))}
        }
        // Remember OUR published inode even if the directory sync fails. A
        // retry must neither mistake our replacement for tampering nor reload
        // older credit. External replacements still fail the identity check.
        if identity == nil{guard unlinkat(dir,temporary,0)==0 else{return fault(.posix(.budgetPersistence,errno))}}
        var info=stat();guard fstat(fd,&info)==0 else{return fault(.posix(.budgetPersistence,errno))}
        identity=info
        guard fsync(dir)==0 else{return fault(.posix(.budgetPersistence,errno))}
        ledger=value;lastFailure=nil;retryDelay=1;return true
    }
}

final class LegacyFixtureStore {
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
    private let archiveDirectory:URL?
    private let requiresBoundedPriorPolicy:Bool
    private var boundedWriterLock:Int32 = -1
    private var boundedNamespaceAccepted=false
    private var directoryIdentity:stat?
    private var groups:[Group]=[]
    private var manualGroups:[Group]=[]
    private var latestAutomatic=0
    private var latestManual=0
    private(set) var status:Status
    private var statusName=".storage-"+UUID().uuidString+".status"
    private var statusFile:File?
    private var failureStage=0,failureErrno:Int32=0
    private let writeBudget:LegacyFixtureWriteBudget?
    private let payloadWriter:OperationalIO.Write
    private let retryClock:()->Double
    private var retryAt=0.0,retryDelay=1.0,transientStorageFailure=false,repairOwnership=false
    private var writeCredit=0,budgetAutomatic=true,reservationActive=false
    private var reservationFailure:OperationalFailure?
    private(set) var actualWrittenBytes=0
    var limitsWrites:Bool{writeBudget != nil}
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
        if LegacyFixtureWriteBudget.transient(failure) {
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
    private(set) var lastResult:Result?
    init(directory:URL,policy:DiagnosticLogRetentionPolicy,persistentOwnership:Bool=false,archiveDirectory:URL?=nil,requiresBoundedPriorPolicy:Bool=false,writeBudget:LegacyFixtureWriteBudget?=nil,
         retryClock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},
         writer:@escaping OperationalIO.Write={Darwin.write($0,$1,$2)}){
        self.payloadWriter=writer;self.retryClock=retryClock
        self.directory=directory;self.policy=policy;self.persistentOwnership=persistentOwnership
        self.archiveDirectory=archiveDirectory
        self.requiresBoundedPriorPolicy=requiresBoundedPriorPolicy
        self.writeBudget=writeBudget ?? (requiresBoundedPriorPolicy && persistentOwnership && archiveDirectory==nil && policy.maximumAutomaticBytes != Int.max ? LegacyFixtureWriteBudget():nil)
        status=Status(maximumAutomaticFiles:policy.maximumAutomaticFiles,maximumAutomaticBytes:policy.maximumAutomaticBytes)
        status.maximumManualBytes=policy.maximumManualBytes;status.manualFiles=0;status.manualBytes=0
    }
    deinit {if boundedWriterLock>=0{close(boundedWriterLock)}}
    private func retainBoundedWriterLock(_ directoryFD:Int32)->Bool {
        if boundedWriterLock>=0{return true}
        guard flock(directoryFD,LOCK_EX|LOCK_NB)==0 else{_ = failed(3,errno);return false}
        let retained=dup(directoryFD)
        guard retained>=0 else{let code=errno;_ = flock(directoryFD,LOCK_UN);_ = failed(3,code);return false}
        guard fcntl(retained,F_SETFD,FD_CLOEXEC)==0 else{
            let code=errno;close(retained);_ = flock(directoryFD,LOCK_UN);_ = failed(3,code);return false
        }
        boundedWriterLock=retained;return true
    }

    // This is a real filesystem proof using the same ownership guard and byte
    // writer as captures. It neither fabricates an incident nor consumes IDs.
    @discardableResult func verifyReadiness(receipt:Data?=nil,name:String?=nil)->DiagnosticStorageReadiness {
        readiness = .unavailable
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
            transientStorageFailure=false
            if repairOwnership {
                // Repair only this still-owned in-memory transaction. Reloading
                // an older index here would lose a published capture or refund
                // pruning. Changed/missing evidence is never adopted or erased.
                guard let dir=openDirectory() else{return};defer{close(dir)}
                guard groups.allSatisfy({$0.files.allSatisfy{owned($0,dir)}}),
                      manualGroups.allSatisfy({$0.files.allSatisfy{owned($0,dir)}}),
                      ownershipFile.map({owned($0,dir)}) ?? true,
                      statusFile.map({owned($0,dir)}) ?? true else{return}
                if requiresBoundedPriorPolicy{boundedNamespaceAccepted=true}
                guard reserveWrite(metadataAllowance(),automatic:budgetAutomatic,event:false) else{
                    if let failure=reservationFailure,LegacyFixtureWriteBudget.transient(failure){transientStorageFailure=true;retryAt=retryClock()+retryDelay;retryDelay=min(60,retryDelay*2)}
                    return
                }
                reservationActive=limitsWrites
                defer{reservationActive=false;writeCredit=0}
                guard writeStatus(),persistOwnership(dir) else{return}
                ownershipHealthy=true;repairOwnership=false;retryDelay=1
                return
            }
            ownershipPrepared=false
        }
        if requiresBoundedPriorPolicy && !persistentOwnership {
            ownershipPrepared=true;ownershipHealthy=false;return
        }
        guard persistentOwnership,!ownershipPrepared else{return}
        ownershipPrepared=true;ownershipHealthy=false
        defer{if requiresBoundedPriorPolicy && !ownershipHealthy{boundedNamespaceAccepted=false}}
        if requiresBoundedPriorPolicy {
            guard policy.maximumAutomaticFiles<=DiagnosticLogRetentionPolicy.incidentDefault.maximumAutomaticFiles,
                  policy.maximumAutomaticBytes<=DiagnosticLogRetentionPolicy.incidentDefault.maximumAutomaticBytes,
                  policy.maximumManualBytes<=DiagnosticLogRetentionPolicy.incidentDefault.maximumManualBytes,
                  archiveDirectory==nil else{return}
        }
        guard let dir=openDirectory() else{return};defer{close(dir)}
        if requiresBoundedPriorPolicy || limitsWrites {guard retainBoundedWriterLock(dir) else{return}}
        guard prepareVolume(dir) else{return}
        var info=stat()
        if fstatat(dir,ownershipName,&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno==ENOENT else{return}
            let names=(try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []
            guard !names.contains(where:{$0.hasPrefix("incident-") || $0.hasPrefix(".storage-")}) else{return}
            if requiresBoundedPriorPolicy{boundedNamespaceAccepted=true}
            ownershipHealthy=persistOwnership(dir);return
        }
        let fd=openat(dir,ownershipName,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{return};defer{close(fd)}
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_size>0,info.st_size<=8*1024*1024,
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:8*1024*1024+1),
              let index=try? JSONDecoder().decode(Ownership.self,from:data),(1...3).contains(index.schema),
              let identity=directoryIdentity,index.inode==identity.st_ino,
              index.status.maximumAutomaticFiles>0,index.status.maximumAutomaticBytes>0,
              index.files.count<=index.status.maximumAutomaticFiles,index.lastIncident>=0,
              validStatusName(index.statusName),validAttemptCounts(index.status) else{return}
        if requiresBoundedPriorPolicy {
            // Reject a preserved investigation root before trim, migration or
            // status/index writes. A new bound is not deletion authority.
            guard index.schema==3,
                  index.status.maximumAutomaticFiles<=DiagnosticLogRetentionPolicy.incidentDefault.maximumAutomaticFiles,
                  index.status.maximumAutomaticBytes<=DiagnosticLogRetentionPolicy.incidentDefault.maximumAutomaticBytes,
                  let manual=index.status.maximumManualBytes,
                  manual<=DiagnosticLogRetentionPolicy.incidentDefault.maximumManualBytes else{return}
        }
        if index.schema<3,index.device != Int64(identity.st_dev) {
            if preserveLegacyRemount(index,info,dir) {
                directoryIdentity=nil;volumeUUID=nil;ownershipPrepared=false
                prepareOwnership()
            }
            return
        }
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
        latestAutomatic=index.lastIncident;latestManual=last;lastCaptureIncident=last;status=index.status
        status.maximumAutomaticFiles=policy.maximumAutomaticFiles;status.maximumAutomaticBytes=policy.maximumAutomaticBytes
        status.maximumManualBytes=policy.maximumManualBytes
        statusName=index.statusName;statusFile=previousStatus;ownershipFile=File(name:ownershipName,phase:0,identity:info)
        if requiresBoundedPriorPolicy{boundedNamespaceAccepted=true}
        if limitsWrites,index.schema==3,index.writeBudgetRequired==true,
           index.status.maximumAutomaticFiles==policy.maximumAutomaticFiles,
           index.status.maximumAutomaticBytes==policy.maximumAutomaticBytes,
           index.status.maximumManualBytes==policy.maximumManualBytes {
            // Reopening an unchanged store is read-only. In particular an
            // exhausted automatic allowance cannot consume manual credit.
            updateUsage();ownershipHealthy=true;return
        }
        // Lowered limits and legacy manual data rotate before accepting new files.
        guard trimRestored(dir) else{return}
        updateUsage()
        guard writeStatus(),persistOwnership(dir) else{return}
        ownershipHealthy=true
    }
    // Legacy indexes contain neither a volume UUID nor content fingerprints.
    // After a remount they cannot prove ownership. Preserve the entire private
    // namespace with an exclusive, same-volume rename; never weaken the checks
    // used for resuming/deleting managed records. No legacy bytes are rewritten.
    private func preserveLegacyRemount(_ index:Ownership,_ indexIdentity:stat,_ dir:Int32)->Bool {
        let records=index.files+(index.manualFiles ?? [])
        var names=Set<String>(),pairs:[String:[Int]]=[:]
        for entry in records {
            guard entry.device==index.device,entry.incident>0,entry.incident<=index.lastIncident,
                  validCaptureName(entry.name,incident:entry.incident,phase:entry.phase),names.insert(entry.name).inserted else{return false}
            let manual=entry.manualKey
            guard manual==nil || (index.schema==2 && !manual!.isEmpty) else{return false}
            pairs[manual ?? "automatic:\(entry.incident)",default:[]].append(entry.phase)
            var current=stat()
            guard fstatat(dir,entry.name,&current,AT_SYMLINK_NOFOLLOW)==0,entry.matchesLegacyRemount(current) else{return false}
        }
        guard pairs.values.allSatisfy({$0.count<=2 && $0.contains(0) && Set($0).count==$0.count}) else{return false}
        if let entry=index.statusFile {
            var current=stat()
            guard entry.name==index.statusName,entry.device==index.device,entry.size<=16*1024,
                  fstatat(dir,entry.name,&current,AT_SYMLINK_NOFOLLOW)==0,entry.matchesLegacyRemount(current) else{return false}
        }else{
            var current=stat()
            guard fstatat(dir,index.statusName,&current,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT else{return false}
        }
        let parentURL=directory.deletingLastPathComponent(),base=directory.lastPathComponent
        guard base != "InvestigationArchives",base != ".",base != ".." else{return false}
        let parent=open(parentURL.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent>=0 else{return false};defer{close(parent)}
        var info=stat()
        guard fstat(parent,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0 else{return false}
        if mkdirat(parent,"InvestigationArchives",S_IRWXU) != 0,errno != EEXIST{return false}
        let archive=openat(parent,"InvestigationArchives",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard archive>=0 else{return false};defer{close(archive)}
        guard let identity=directoryIdentity,fstat(archive,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_dev==identity.st_dev,info.st_ino != identity.st_ino,
              fstatat(parent,base,&info,AT_SYMLINK_NOFOLLOW)==0,
              info.st_dev==identity.st_dev,info.st_ino==identity.st_ino,
              fstatat(dir,ownershipName,&info,AT_SYMLINK_NOFOLLOW)==0,matches(indexIdentity,info) else{return false}
        let name="Legacy-"+base+"-"+UUID().uuidString
        guard renameatx_np(parent,base,archive,name,UInt32(RENAME_EXCL))==0 else{return false}
        guard fsync(archive)==0,fsync(parent)==0 else{return false}
        legacyArchive=parentURL.appendingPathComponent("InvestigationArchives").appendingPathComponent(name)
        return true
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
    private func trimRestored(_ dir:Int32)->Bool {
        while usage.files>policy.maximumAutomaticFiles || usage.bytes>policy.maximumAutomaticBytes {
            guard let group=groups.first,removeGroup(group,manual:false,dir:dir) else{return false}
        }
        while manualUsage.bytes>policy.maximumManualBytes {
            guard let group=manualGroups.first,removeGroup(group,manual:true,dir:dir) else{return false}
        }
        return true
    }
    private func removeGroup(_ group:Group,manual:Bool,dir:Int32)->Bool {
        guard group.files.allSatisfy({owned($0,dir)}) else{_ = failed(3);return false}
        if let archiveDirectory {
            do{try archive(group.files,from:dir,to:archiveDirectory)}
            catch{OperationalDiagnostics.shared.record(.capture(error,stage:.storagePrune));_ = failed(5);return false}
        }
        for file in group.files {
            guard owned(file,dir) else{_ = failed(5);return false}
            guard unlinkat(dir,file.name,0)==0 else{_ = failed(5,errno);return false}
            status.evictedFiles+=1;status.evictedBytes+=file.bytes
            if manual {
                if let i=manualGroups.firstIndex(where:{$0.key==group.key}){manualGroups[i].files.removeAll{$0.name==file.name}}
            }else{
                if let i=groups.firstIndex(where:{$0.incident==group.incident}){groups[i].files.removeAll{$0.name==file.name}}
            }
        }
        groups.removeAll{$0.files.isEmpty};manualGroups.removeAll{$0.files.isEmpty};status.evictedGroups+=1
        return true
    }
    // Investigation opt-in: content-addressed evidence lives outside rotation.
    // Every file and its manifest are durable before any source is unlinked.
    private func archive(_ files:[File],from source:Int32,to destination:URL)throws {
        let fm=FileManager.default
        if !fm.fileExists(atPath:destination.path){try fm.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        let target=open(destination.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard target>=0 else{throw DiagnosticLogExport.Failure.unavailable};defer{close(target)}
        var info=stat()
        guard fstat(target,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0,
              directoryIdentity.map({$0.st_dev != info.st_dev || $0.st_ino != info.st_ino}) ?? false else{throw DiagnosticLogExport.Failure.unavailable}
        struct Entry:Encodable {let originalName:String,sha256:String,bytes:Int}
        var entries:[Entry]=[]
        for file in files {
            let fd=openat(source,file.name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            guard fd>=0 else{throw DiagnosticLogExport.Failure.unavailable};defer{close(fd)}
            guard fstat(fd,&info)==0,matches(file.identity,info),
                  let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:file.bytes+1),data.count==file.bytes,
                  fstat(fd,&info)==0,matches(file.identity,info) else{throw DiagnosticLogExport.Failure.unavailable}
            let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            let name=digest+".json"
            let prior=openat(target,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            if prior>=0 {
                defer{close(prior)}
                guard fstat(prior,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
                      let existing=try FileHandle(fileDescriptor:prior,closeOnDealloc:false).read(upToCount:data.count+1),existing==data else{throw DiagnosticLogExport.Failure.unavailable}
            }else{
                guard errno==ENOENT else{throw DiagnosticLogExport.Failure.unavailable}
                try publishArchive(data,name:name,dir:target)
            }
            entries.append(Entry(originalName:file.name,sha256:digest,bytes:data.count))
        }
        try publishArchive(JSONEncoder().encode(entries),name:"manifest-"+UUID().uuidString+".json",dir:target)
    }
    private func publishArchive(_ data:Data,name:String,dir:Int32)throws {
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{throw DiagnosticLogExport.Failure.unavailable}
        defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd),fsync(fd)==0,linkat(dir,temporary,dir,name,0)==0,fsync(dir)==0 else{throw DiagnosticLogExport.Failure.unavailable}
    }
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
    private func persistOwnership(_ dir:Int32)->Bool {
        guard let identity=directoryIdentity,prepareVolume(dir) else{return storageFault(.storageOwnership)}
        let index=Ownership(schema:3,device:Int64(identity.st_dev),inode:identity.st_ino,lastIncident:lastCaptureIncident,
            statusName:statusName,status:status,files:groups.flatMap{group in group.files.map{Record($0,incident:group.incident)}},
            statusFile:statusFile.map{Record($0,incident:0)},manualFiles:manualGroups.flatMap{group in group.files.map{Record($0,incident:group.incident,manualKey:group.key)}},
            volumeUUID:volumeUUID,bootUUID:Self.bootUUID,birth:Int64(identity.st_birthtimespec.tv_sec),birthNanos:Int64(identity.st_birthtimespec.tv_nsec),writeBudgetRequired:limitsWrites ? true:nil)
        let data:Data
        do{data=try JSONEncoder().encode(index)}catch{OperationalDiagnostics.shared.record(.capture(error,stage:.storageEncode));return false}
        guard data.count<=8*1024*1024 else{return storageFault(.storageOwnership,policy:2)}
        if let old=ownershipFile, !owned(old,dir){return storageFault(.storageOwnership,policy:3)}
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return storageFault(.storageOwnership,errno)};defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd) else{return false}
        guard fsync(fd)==0 else{return storageFault(.storageOwnership,errno)}
        if let old=ownershipFile {
            guard owned(old,dir) else{return storageFault(.storageOwnership,policy:3)}
            guard renameat(dir,temporary,dir,ownershipName)==0 else{return storageFault(.storageOwnership,errno)}
        }else{guard linkat(dir,temporary,dir,ownershipName,0)==0,unlinkat(dir,temporary,0)==0 else{return storageFault(.storageOwnership,errno)}}
        var info=stat();guard fstat(fd,&info)==0 else{return storageFault(.storageOwnership,errno)}
        ownershipFile=File(name:ownershipName,phase:0,identity:info)
        guard fsync(dir)==0 else{return storageFault(.storageOwnership,errno)}
        return true
    }

    func rejectBeforeEncoding(automatic:Bool,phase:Int)->Result? {
        if transientStorageFailure,retryClock()<retryAt{return .unavailable}
        if writeBudget?.waitingForRecovery==true{return .unavailable}
        if automatic,phase==0,writeBudget?.rejectExhaustedEvent()==true {
            status.writeBudget=writeBudget?.summary;lastResult = .limit;return .limit
        }
        return nil
    }
    @discardableResult func save(_ data:Data,incident:Int,phase:Int,automatic:Bool)->Result {
        if transientStorageFailure,retryClock()<retryAt{return rejectedRecoveryDelay(incident:incident,phase:phase,automatic:automatic)}
        budgetAutomatic=automatic
        if limitsWrites,!reservationActive {
            prepareOwnership()
            if !ownershipHealthy{return saveReserved(data,incident:incident,phase:phase,automatic:automatic)}
            guard reserveWrite(data.count+metadataAllowance(),automatic:automatic,event:phase==0) else{return rejectedReservation(incident:incident,phase:phase,automatic:automatic)}
            reservationActive=true
            defer{writeCredit=0;reservationActive=false}
            return saveReserved(data,incident:incident,phase:phase,automatic:automatic)
        }
        return saveReserved(data,incident:incident,phase:phase,automatic:automatic)
    }
    // Reserve both encoded phases before either becomes visible. Reservation
    // failures update memory only; there is no deferred catch-up write queue.
    @discardableResult func savePair(_ before:Data,_ after:Data,incident:Int,automatic:Bool)->Result {
        if transientStorageFailure,retryClock()<retryAt{return rejectedRecoveryDelay(incident:incident,phase:0,automatic:automatic)}
        prepareOwnership();budgetAutomatic=automatic
        guard ownershipHealthy else{lastResult = .unavailable;return .unavailable}
        let retainedLimit=automatic ? policy.maximumAutomaticBytes:policy.maximumManualBytes
        guard before.count<=retainedLimit,after.count<=retainedLimit-before.count,
              !automatic || policy.maximumAutomaticFiles>=2 else{lastResult = .limit;return .limit}
        guard before.count<=Int.max-after.count-2*metadataAllowance() else{return .limit}
        if limitsWrites {
            guard reserveWrite(before.count+after.count+2*metadataAllowance(),automatic:automatic,event:true) else{return rejectedReservation(incident:incident,phase:0,automatic:automatic)}
        }
        reservationActive=limitsWrites
        defer{writeCredit=0;reservationActive=false}
        let pre=saveReserved(before,incident:incident,phase:0,automatic:automatic)
        guard pre == .saved else{return pre}
        return saveReserved(after,incident:incident,phase:1,automatic:automatic)
    }
    private func metadataAllowance()->Int {
        // Each ownership record is <1KiB (fixed names/hashes/numeric fields).
        // Allow new pair records and a complete <=16KiB status replacement.
        32*1024+(groups.reduce(0){$0+$1.files.count}+manualGroups.reduce(0){$0+$1.files.count}+2)*1024
    }
    private func reserveWrite(_ bytes:Int,automatic:Bool,event:Bool)->Bool {
        reservationFailure=nil
        guard let writeBudget else{return true}
        guard let dir=openDirectory() else{reservationFailure = .posix(.budgetPersistence,failureErrno);return false};defer{close(dir)}
        guard retainBoundedWriterLock(dir) else{reservationFailure = .posix(.budgetPersistence,failureErrno);return false}
        let accepted=writeBudget.reserve(bytes,automatic:automatic,event:event,dir:dir)
        reservationFailure=writeBudget.lastFailure
        status.writeBudget=writeBudget.summary
        if accepted{writeCredit=bytes}
        return accepted
    }
    private func rejectedReservation(incident:Int,phase:Int,automatic:Bool)->Result {
        guard let failure=reservationFailure else{lastResult = .limit;return .limit}
        OperationalDiagnostics.shared.record(failure)
        failureStage=4;failureErrno=Int32(clamping:failure.underlyingPOSIX);lastResult = .unavailable
        finishAttempt(incident:incident,phase:phase,automatic:automatic,result:4,began:DispatchTime.now().uptimeNanoseconds,persist:false)
        invalidateReadiness();return .unavailable
    }
    private func rejectedRecoveryDelay(incident:Int,phase:Int,automatic:Bool)->Result {
        // Keep the actual failure from readiness/publishing visible during
        // backoff. This rejected request must not write status or reset errno.
        lastResult = .unavailable
        finishAttempt(incident:incident,phase:phase,automatic:automatic,result:4,began:DispatchTime.now().uptimeNanoseconds,persist:false)
        return .unavailable
    }
    private func saveReserved(_ data:Data,incident:Int,phase:Int,automatic:Bool)->Result {
        let began=DispatchTime.now().uptimeNanoseconds
        let previousStatusFailures=status.statusWriteFailures
        failureStage=0;failureErrno=0
        let result=publish(data,incident:incident,phase:phase,automatic:automatic)
        lastResult=result
        finishAttempt(incident:incident,phase:phase,automatic:automatic,result:result.rawValue,began:began)
        if result != .saved || !ownershipHealthy || status.statusWriteFailures>previousStatusFailures{
            invalidateReadiness()
            if result == .saved{lastResult = .unavailable;return .unavailable}
        }else{readiness = .ready;retryDelay=1;transientStorageFailure=false}
        return result
    }
    func encodingFailed(incident:Int,phase:Int,automatic:Bool){
        prepareOwnership()
        failureStage=6;failureErrno=0
        let persist = !limitsWrites || reserveWrite(metadataAllowance(),automatic:automatic,event:true)
        reservationActive=limitsWrites && persist
        defer{writeCredit=0;reservationActive=false}
        finishAttempt(incident:incident,phase:phase,automatic:automatic,result:5,began:DispatchTime.now().uptimeNanoseconds,persist:persist)
        invalidateReadiness()
    }
    private func finishAttempt(incident:Int,phase:Int,automatic:Bool,result:Int,began:UInt64,persist:Bool=true){
        status.writeBudget=writeBudget?.summary
        lastCaptureIncident=max(lastCaptureIncident,incident)
        status.attempts+=1
        switch result {
        case 1:status.saved+=1
        case 2:status.limited+=1
        case 3:status.retired+=1
        case 4:status.unavailable+=1
        default:status.encodingFailures+=1
        }
        updateUsage()
        status.lastIncident=incident;status.lastPhase=phase;status.lastAutomatic=automatic
        status.lastResult=result;status.lastFailureStage=failureStage;status.lastErrno=Int(failureErrno)
        let ended=DispatchTime.now().uptimeNanoseconds,elapsed=ended>=began ? ended-began:0
        status.lastWriteMicros=Int(min(elapsed/1000,60_000_000))
        status.maxWriteMicros=max(status.maxWriteMicros,status.lastWriteMicros)
        if elapsed>60_000_000_000{status.writeTimingClipped+=1}
        guard persist else{return}
        let statusFailed = !writeStatus()
        if statusFailed{status.statusWriteFailures+=1}
        if persistentOwnership,ownershipHealthy {
            var ownershipFailed=false
            if let dir=openDirectory(){
                ownershipFailed = !persistOwnership(dir);close(dir)
            }else{ownershipFailed=true}
            if ownershipFailed {
                ownershipHealthy=false;repairOwnership=true
                if let failure=writeBudget?.lastFailure,LegacyFixtureWriteBudget.transient(failure){
                    transientStorageFailure=true;retryAt=retryClock()+retryDelay;retryDelay=min(60,retryDelay*2)
                }
                if !statusFailed{status.statusWriteFailures+=1}
            }
        }
    }
    // One <=16KiB owner-only companion per store, excluded from the automatic
    // retention cap. Its bytes are included in the cumulative write budget.
    // Atomically replaces only this instance's own status file.
    // A wholly unwritable disk cannot persist its failure: keep the last good
    // status and report the accumulated failure on the next successful write.
    private func writeStatus()->Bool {
        if requiresBoundedPriorPolicy {
            guard boundedWriterLock>=0,boundedNamespaceAccepted else{return storageFault(.storageStatus)}
        }
        let previousStage=failureStage,previousErrno=failureErrno
        defer{failureStage=previousStage;failureErrno=previousErrno}
        let data:Data
        do{data=try JSONEncoder().encode(StatusDocument(status:status))}catch{OperationalDiagnostics.shared.record(.capture(error,stage:.storageEncode));return false}
        guard data.count<=16*1024 else{return storageFault(.storageStatus,policy:2)}
        guard let dir=openDirectory() else{return false}
        defer{close(dir)}
        if let old=statusFile {guard owned(old,dir) else{return storageFault(.storageStatus,policy:3)}}
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return storageFault(.storageStatus,errno)}
        defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd) else{return false}
        guard fsync(fd)==0 else{return storageFault(.storageStatus,errno)}
        if let old=statusFile {
            guard owned(old,dir) else{return storageFault(.storageStatus,policy:3)}
            guard renameat(dir,temporary,dir,statusName)==0 else{return storageFault(.storageStatus,errno)}
        } else {
            guard linkat(dir,temporary,dir,statusName,0)==0,unlinkat(dir,temporary,0)==0 else{return storageFault(.storageStatus,errno)}
        }
        var info=stat();guard fstat(fd,&info)==0 else{return storageFault(.storageStatus,errno)}
        statusFile=File(name:statusName,phase:0,identity:info,digest:Self.digest(data))
        guard fsync(dir)==0 else{return storageFault(.storageStatus,errno)}
        return true
    }
    private func writeAll(_ data:Data,_ fd:Int32)->Bool {
        let standalone=limitsWrites && !reservationActive
        defer{if standalone{writeCredit=0}}
        if limitsWrites {
            if standalone {guard reserveWrite(data.count,automatic:budgetAutomatic,event:false) else{
                if let failure=reservationFailure,LegacyFixtureWriteBudget.transient(failure){
                    transientStorageFailure=true;retryAt=retryClock()+retryDelay;retryDelay=min(60,retryDelay*2)
                }
                return false
            }}
            guard data.count<=writeCredit else{OperationalDiagnostics.shared.record(.policy(.storageWrite,1));return false}
            writeCredit-=data.count
        }
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
        if persistentOwnership {
            let parent=directory.deletingLastPathComponent().path;var p=stat()
            if lstat(parent,&p) != 0 {
                guard errno==ENOENT else{_ = failed(2,errno);return nil}
                if mkdir(parent,S_IRWXU) != 0 && errno != EEXIST{_ = failed(2,errno);return nil}
            }
            guard lstat(parent,&p)==0 else{_ = failed(2,errno);return nil}
            guard p.st_mode&S_IFMT==S_IFDIR,p.st_uid==getuid(),p.st_mode&0o077==0 else{_ = failed(2);return nil}
        }
        var info=stat()
        if lstat(directory.path,&info) != 0 {
            guard errno==ENOENT,directoryIdentity==nil else{_ = failed(2,errno);return nil}
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
    private func publish(_ data:Data,incident:Int,phase:Int,automatic:Bool)->Result {
        prepareOwnership()
        guard ownershipHealthy else{return failed(3)}
        guard incident>0,(0...1).contains(phase) else{return failed(1)}
        struct Header:Decodable {let runID:String}
        let run=(try? JSONDecoder().decode(Header.self,from:data).runID) ?? "current"
        let key=run+":\(incident)"
        let existing=automatic ? groups:manualGroups
        if phase==0 {
            guard incident>(automatic ? latestAutomatic:latestManual) else{return .retired}
            if automatic{latestAutomatic=incident}else{latestManual=incident}
        }else{
            guard existing.contains(where:{(automatic ? $0.incident==incident:$0.key==key) && $0.files.count==1 && $0.files[0].phase==0}) else{return .retired}
        }
        let current=existing.first(where:{automatic ? $0.incident==incident:$0.key==key})
        let limit=automatic ? policy.maximumAutomaticBytes:policy.maximumManualBytes
        let fileLimit=automatic ? policy.maximumAutomaticFiles:Int.max
        guard data.count<=limit,(current?.files.count ?? 0)<fileLimit,
              (current?.files.reduce(0){$0+$1.bytes} ?? 0)<=limit-data.count else{return .limit}
        let used=automatic ? usage:manualUsage
        var count=used.files+1,bytes=used.bytes+data.count,evictions:[Group]=[]
        for group in existing {
            if count<=fileLimit && bytes<=limit{break}
            // A delayed post never evicts a newer pre-capture.
            if group.incident>=incident{continue}
            evictions.append(group);count-=group.files.count;bytes-=group.files.reduce(0){$0+$1.bytes}
        }
        guard count<=fileLimit,bytes<=limit else{return .limit}
        guard let dir=openDirectory() else{return .unavailable};defer{close(dir)}
        guard existing.allSatisfy({$0.files.allSatisfy{owned($0,dir)}}) else{return failed(3)}
        let filename="incident-\(incident)-\(phase)-\(UUID().uuidString).json"
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return failed(4,errno)}
        defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd),fsync(fd)==0,linkat(dir,temporary,dir,filename,0)==0 else{return failed(4,errno)}
        var info=stat()
        guard unlinkat(dir,temporary,0)==0,fstat(fd,&info)==0 else{let code=errno;unlinkat(dir,filename,0);return failed(4,code)}
        let published=File(name:filename,phase:phase,identity:info,digest:Self.digest(data),header:DiagnosticReviewCaptureHeader.read(data))
        for group in evictions {
            guard removeGroup(group,manual:!automatic,dir:dir) else{
                let code=failureErrno
                if owned(published,dir){unlinkat(dir,filename,0)}
                return failed(5,code)
            }
        }
        if automatic {
            if let i=groups.firstIndex(where:{$0.incident==incident}){groups[i].files.append(published)}
            else{groups.append(Group(incident:incident,files:[published]))}
        }else{
            if let i=manualGroups.firstIndex(where:{$0.key==key}){manualGroups[i].files.append(published)}
            else{manualGroups.append(Group(incident:incident,files:[published],key:key))}
        }
        return .saved
    }

}
