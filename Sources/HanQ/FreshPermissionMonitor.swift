import AppKit
import ApplicationServices

// Positive allows input; a negative generation blocks it. Background failures
// close the gate before main-thread teardown. A late success cannot reopen it.
final class FreshPermissionGate {
    private var value:Int32=1
    var generation:Int32{OSAtomicAdd32Barrier(0,&value)}
    var allowsInput:Bool{generation>0}
    @discardableResult func block()->Int32 {
        while true {let old=generation,next = -(abs(old)%Int32.max+1)
            if OSAtomicCompareAndSwap32Barrier(old,next,&value){return next}}
    }
    @discardableResult func restore(_ expected:Int32)->Bool {
        expected<0 && OSAtomicCompareAndSwap32Barrier(expected,abs(expected),&value)
    }
}

/// Each answer still comes from a new LaunchServices instance of the same app.
/// Ordinary launch/transport failures are unknown permission, never denial.
final class FreshPermissionMonitor {
    typealias LaunchProbe = (URL, @escaping (Error?) -> Void) -> Void
    enum Update {case unavailable(OperationalFailure),granted}
    private let queue=DispatchQueue(label:"taek.in.hanq.fresh-permission")
    private let launchQueue=DispatchQueue(label:"taek.in.hanq.permission-launch")
    private let terminate:(String)->Void,changed:(Update)->Void
    private let launchProbe:LaunchProbe
    private let interval:UInt64,timeout:UInt64,retryBase:UInt64
    private var timer:DispatchSourceTimer?
    private struct Request {
        let directory:URL,channel:PermissionProbeChannel,started:UInt64
        var launchFailure:OperationalFailure?
    }
    private var pending:Request?
    private var nextCheck:UInt64=0,failures=0
    private var launchRunning=false,active=false
    private var notification:NSObjectProtocol?
    init(interval:TimeInterval=1,timeout:TimeInterval=2,retryBase:TimeInterval=1,
         launchProbe:@escaping LaunchProbe=FreshPermissionMonitor.launchProbe,
         changed:@escaping (Update)->Void={_ in},terminate:@escaping (String)->Void) {
        precondition(interval>0 && timeout>0 && retryBase>0)
        self.interval=UInt64(interval*1_000_000_000);self.timeout=UInt64(timeout*1_000_000_000)
        self.retryBase=UInt64(retryBase*1_000_000_000);self.launchProbe=launchProbe
        self.changed=changed;self.terminate=terminate
    }
    func start() {
        queue.async{[self] in
            guard !active else{return};active=true;nextCheck=0
            let timer=DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now(),repeating:.milliseconds(50))
            timer.setEventHandler{[weak self] in self?.tick()};self.timer=timer;timer.resume()
        }
        if notification==nil {
            notification=DistributedNotificationCenter.default().addObserver(forName:Notification.Name("com.apple.accessibility.api"),object:nil,queue:nil){[weak self] _ in
                self?.queue.async{[weak self] in if self?.failures==0{self?.nextCheck=0}}
            }
        }
    }
    func stop() {
        queue.async{[self] in active=false;timer?.cancel();timer=nil;cleanup()}
        if let notification{DistributedNotificationCenter.default().removeObserver(notification)};notification=nil
    }
    private func cleanup() {
        if let pending {
            do{try FileManager.default.removeItem(at:pending.directory)}
            catch{OperationalDiagnostics.shared.record(.capture(error,stage:.probeCleanup))}
        }
        pending=nil
    }
    private func unavailable(_ failure:OperationalFailure) {
        let now=DispatchTime.now().uptimeNanoseconds
        let elapsed=pending.map{Int((now-$0.started)/1_000_000)} ?? 0
        OperationalDiagnostics.shared.record(failure,elapsedMilliseconds:elapsed)
        // The callback first closes the atomic input gate. It does not wait for UI.
        changed(.unavailable(failure))
        cleanup();failures=min(failures+1,6)
        nextCheck=now+min(30_000_000_000,retryBase*UInt64(1<<(failures-1)))
        InputDiagnostics.shared.record("fresh.unavailable stage=\(failure.stage.rawValue) code=\(failure.code)")
    }
    private func tick() {
        guard active else{return}
        let now=DispatchTime.now().uptimeNanoseconds
        if let request=pending {
            guard now-request.started<timeout else {
                unavailable(request.launchFailure ?? .posix(.probeTimeout,ETIMEDOUT));return
            }
            switch request.channel.receive() {
            case .failure(let failure):unavailable(failure)
            case .success(nil):break
            case .success(let data?):
                let result:PermissionProbeResult
                do{result=try JSONDecoder().decode(PermissionProbeResult.self,from:data)}
                catch{unavailable(.capture(error,stage:.probeDecode));return}
                guard result.token==request.directory.lastPathComponent else{unavailable(.policy(.probeToken,1));return}
                guard result.pid>0,!result.post || result.ax != nil else{unavailable(.policy(.probeDecode,2));return}
                if !result.post || result.ax==false {
                    OperationalDiagnostics.shared.record(.policy(.permissionDenied,1),elapsedMilliseconds:Int((now-request.started)/1_000_000))
                    active=false;timer?.cancel();timer=nil;cleanup()
                    InputDiagnostics.shared.record("fresh.exit reason=permission-denied")
                    terminate("permission-denied");return
                }
                InputDiagnostics.shared.record("fresh.result pid=\(result.pid) ax=true post=true elapsedMS=\((now-request.started)/1_000_000)")
                cleanup();failures=0;nextCheck=now+interval;changed(.granted)
            }
            return
        }
        guard now>=nextCheck else{return}
        // A hung launch call owns the single slot until it returns. Retries never
        // enqueue more blocking launch work behind it.
        guard !launchRunning else{unavailable(.policy(.probeLaunch,1));return}
        let directory=PrivateProbeDirectory.root.appendingPathComponent("hanq-permission-"+UUID().uuidString)
        do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        catch{unavailable(.capture(error,stage:.probeDirectory));return}
        let channel:PermissionProbeChannel
        do{channel=try PermissionProbeChannel(directory:directory)}
        catch {
            let failure=(error as? OperationalFailure) ?? .capture(error,stage:.transport)
            try? FileManager.default.removeItem(at:directory);unavailable(failure);return
        }
        pending=Request(directory:directory,channel:channel,started:now)
        launchRunning=true
        launchQueue.async{[weak self] in
            guard let self else{return}
            self.launchProbe(directory){[weak self] error in
                guard let self,let error else{return}
                let failure=OperationalFailure.capture(error,stage:.probeLaunch)
                self.queue.async{[weak self] in
                    guard let self,self.active,self.pending?.directory==directory else{return}
                    // Keep listening: a fast valid reply can precede LS's error.
                    self.pending?.launchFailure=failure
                }
            }
            self.queue.async{[weak self] in self?.launchRunning=false}
        }
    }
    private static func launchProbe(directory:URL,completion:@escaping(Error?)->Void) {
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance=true
        configuration.allowsRunningApplicationSubstitution=false
        configuration.activates=false;configuration.addsToRecentItems=false;configuration.promptsUserIfNeeded=false
        configuration.arguments=["--permission-probe",directory.path]
        NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:configuration){_,error in completion(error)}
    }
}

struct PermissionProbeResult:Codable {
    let token:String,pid:Int32,ax:Bool?,post:Bool
}
enum PermissionProbe {
    static func runIfRequested() {
        let arguments=ProcessInfo.processInfo.arguments
        guard let index=arguments.firstIndex(of:"--permission-probe") else{return}
        guard index+1<arguments.count else{OperationalDiagnostics.shared.record(.policy(.probeValidate,1));_exit(64)}
        let directory=URL(fileURLWithPath:arguments[index+1])
        guard let workspace=PrivateProbeDirectory.open(directory,prefix:"hanq-permission-"),workspace.enter() else{_exit(64)}
        DispatchQueue.global().asyncAfter(deadline:.now()+2){OperationalDiagnostics.shared.record(.posix(.probeTimeout,ETIMEDOUT));_exit(71)}
        // Never create a tap, show a prompt, or query AX when posting is denied.
        let post=CGPreflightPostEventAccess()
        let result=PermissionProbeResult(token:directory.lastPathComponent,pid:getpid(),ax:post ? AXIsProcessTrusted():nil,post:post)
        do {
            let data:Data
            do{data=try JSONEncoder().encode(result)}catch{throw OperationalFailure.capture(error,stage:.probeEncode)}
            try PermissionProbeChannel.send(data,to:directory)
            _exit(0)
        }catch {
            OperationalDiagnostics.shared.record((error as? OperationalFailure) ?? .capture(error,stage:.transport));_exit(74)
        }
    }
}
