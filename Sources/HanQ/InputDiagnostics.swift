import ApplicationServices
import Foundation
import Darwin
import Carbon

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
        } else { descriptor = -1 }
    }

    var isEnabled:Bool {descriptor >= 0}

    func record(_ message: @autoclosure () -> String) {
        guard descriptor >= 0 else { return }
        let line = "\(Date().timeIntervalSince1970) mono=\(DispatchTime.now().uptimeNanoseconds) pid=\(getpid()) \(message())\n"
        line.withCString { pointer in _ = write(descriptor, pointer, strlen(pointer)) }
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

// Typed, bounded incident metadata. Never accepts text, keycodes, clipboard,
// application names or arbitrary log messages. Capture is deliberately lossy:
// input callbacks never wait for the diagnostic lock or filesystem.
final class InputIncidentTrace {
    enum Lane:Int,Codable {case hid=1,main,onset,mismatch,boundary,onsetAX,mismatchAX,sourceBoundary}
    enum Kind:Int,Codable {case event=1,read,shape,marker,context,state,sourceBoundary}
    enum Trigger:Int,Codable {case manual=1,callbackDelay,axDelay,possibleShrink,boundaryInterrupted}
    enum BoundaryStage:Int {
        case waiting=1,queued,onsetWaiting,onsetConfirmed,onsetRetimed,retained,finished,deadline,focusChanged,failed,selection,sourceCommitted
        case snapshotWait,textWait,caretWait,repairWait,repairReceiptWait,onsetReceiptWait,replayReceiptWait,focusWait,selectionCommitWait,sourceCommitWait
        case inputResumed,editorStyleMatched,terminalLFMatched,terminalLFStyleMatched,pendingTextPrefix,sourceInitialBodyRemoved
        static func event(_ stage:String)->BoundaryStage? {
            switch stage {
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
            case "editor_diverged_input_resumed":return .inputResumed
            case "editor_insertion_style_matched":return .editorStyleMatched
            case "editor_terminal_lf_matched":return .terminalLFMatched
            case "editor_terminal_lf_style_matched":return .terminalLFStyleMatched
            case "editor_text_prefix_pending":return .pendingTextPrefix
            case "source_initial_body_removed":return .sourceInitialBodyRemoved
            default:return nil
            }
        }
    }
    enum State:Int {
        case repairStarted=1,selection,replay,retained,finished,stopped,sourceChanged,buffered
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
    struct Frame:Codable {
        let sequence:Int;let milliseconds:Int;let lane:Lane;let kind:Kind
        let event:Int;let edge:Int;let category:Int;let inputOrigin:Int;let consumed:Bool
        let durationMicros:Int;let count:Int;let selected:Bool;let field:Int
    }
    struct Capture:Encodable {
        let schema=1
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "test"
        let bestEffort=true
        let appReceiptVerified=false
        let correlationIsHeuristic=true
        let lossCountersMayLag=true
        let skippedEvents:[Int:Int]
        let skippedAuxiliary:[Int:Int]
        let trigger:Trigger;let incident:Int;let phase:Int;let discardedOldFrames:Int;let frames:[Frame]
    }
    private struct Identity:Hashable {let token:UInt64;let type:UInt32;let domain:Int}
    private struct Shape {let field:UInt;let count:Int;let selected:Bool}
    static let shared:InputIncidentTrace = {
        let args=ProcessInfo.processInfo.arguments
        let path=args.firstIndex(of:"--diagnose-input-incidents").flatMap{$0+1<args.count ? args[$0+1]:nil}
        return InputIncidentTrace(destination:path.map{URL(fileURLWithPath:$0)})
    }()
    let enabled:Bool
    let capacity:Int
    private let lock=NSLock()
    private let queue=DispatchQueue(label:"hanq.input.incident.writer",qos:.utility)
    private let destination:URL?
    private let clock:()->Double
    private let origin:Double
    private var ring:[Frame?]
    private var position=0,stored=0,sequence=0,overwritten=0,eventSequence=0
    private var identities:[Identity:Int]=[:]
    private var shapes:[Lane:Shape]=[:]
    private var fields:[UInt:Int]=[:]
    private var nextField=0,lastEdit = -Double.infinity,lastTrigger = -Double.infinity
    private var captures=0,automaticCaptures=0,manualCaptures=0
    private var reads:[Int:Double]=[:]
    private var readSequence=0
    private var timer:DispatchSourceTimer?
    // Only the writer queue accesses these counters. Contended input callbacks
    // enqueue a scalar increment rather than waiting for a second lock.
    private var skippedEvents:[Int:Int]=[:],skippedAuxiliary:[Int:Int]=[:]
    private let writer:((Capture)->Void)?
    init(destination:URL?,capacity:Int=4096,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},writer:((Capture)->Void)?=nil){
        self.destination=destination;self.enabled=destination != nil || writer != nil
        self.capacity=max(1,min(capacity,16384));self.clock=clock;origin=clock();self.writer=writer
        ring=Array(repeating:nil,count:self.enabled ? self.capacity:0)
    }
    private func append(_ lane:Lane,_ kind:Kind,event:Int=0,edge:Int=0,category:Int=0,inputOrigin:Int=0,consumed:Bool=false,duration:Double=0,count:Int=0,selected:Bool=false,field:Int=0){
        sequence+=1
        ring[position]=Frame(sequence:sequence,milliseconds:Int(max(0,clock()-origin)*1000),lane:lane,kind:kind,event:event,edge:edge,category:category,inputOrigin:inputOrigin,consumed:consumed,durationMicros:Int(max(0,min(duration,60))*1_000_000),count:count,selected:selected,field:field)
        position=(position+1)%capacity
        if stored<capacity{stored+=1}else{overwritten+=1}
    }
    private func snapshot(_ reason:Trigger)->Capture? {
        let now=clock()
        guard reason == .manual ? manualCaptures<32:(automaticCaptures<32 && now-lastTrigger>=10) else{return nil}
        if reason == .manual{manualCaptures+=1}else{automaticCaptures+=1}
        captures+=1;lastTrigger=now
        let start=(position-stored+capacity)%capacity
        return Capture(skippedEvents:skippedEvents,skippedAuxiliary:skippedAuxiliary,trigger:reason,incident:captures,phase:0,discardedOldFrames:overwritten,frames:(0..<stored).compactMap{ring[(start+$0)%capacity]})
    }
    private func requestCapture(_ reason:Trigger){
        queue.async{[self] in
            lock.lock() // Background writer only; input callbacks still try-lock.
            let capture=snapshot(reason);lock.unlock();persist(capture)
        }
    }
    private func persist(_ capture:Capture?){
        guard let capture else{return}
        queue.async{[self] in self.write(capture) }
        queue.asyncAfter(deadline:.now()+1){[self] in
            lock.lock()
            let start=(position-stored+capacity)%capacity
            let after=Capture(skippedEvents:skippedEvents,skippedAuxiliary:skippedAuxiliary,trigger:capture.trigger,incident:capture.incident,phase:1,discardedOldFrames:overwritten,frames:(0..<stored).compactMap{ring[(start+$0)%capacity]})
            lock.unlock();write(after)
        }
    }
    private func write(_ capture:Capture){
            if let writer{writer(capture);return}
            guard let destination else{return}
            // Only an owned private directory is accepted. Publish complete
            // JSON atomically without replacing any file, mode 0700/0600.
            do {
                let directory=destination.path
                var info=stat()
                if lstat(directory,&info) != 0 {
                    guard errno==ENOENT,mkdir(directory,S_IRWXU)==0 else{return}
                } else {guard (info.st_mode & S_IFMT)==S_IFDIR,info.st_uid==getuid(),(info.st_mode & 0o077)==0 else{return}}
                let directoryFD=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard directoryFD>=0 else{return};defer{close(directoryFD)}
                guard fstat(directoryFD,&info)==0,info.st_uid==getuid(),(info.st_mode & 0o077)==0 else{return}
                let filename="incident-\(capture.incident)-\(capture.phase)-\(UUID().uuidString).json"
                let temporary=".partial-"+UUID().uuidString
                let fd=openat(directoryFD,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
                guard fd>=0 else{return}
                defer{close(fd);unlinkat(directoryFD,temporary,0)}
                let data=try JSONEncoder().encode(capture)
                try data.withUnsafeBytes { bytes in
                    var offset=0
                    while offset<bytes.count {
                        let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                        if n<0 && errno==EINTR{continue}
                        guard n>0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))};offset+=n
                    }
                }
                // linkat publishes only after the final byte and fails if the
                // random destination already exists; no overwrite or partial JSON.
                _ = linkat(directoryFD,temporary,directoryFD,filename,0)
            } catch { /* A diagnostic failure must never affect input. */ }
    }
    // No extra event tag, AX call, event copy, key post or source selection.
    func event(_ lane:Lane,_ type:CGEventType,_ event:CGEvent,consumed:Bool=false,duration:Double=0){
        guard enabled,!IsSecureEventInputEnabled() else{return}
        guard lock.try() else{skipped(lane,event:true);return}
        let time=clock()
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        let editing=event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty == false || [36,48,51,53,76,117,123,124,125,126].contains(code)
        let pointer=type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        if editing || pointer {lastEdit=time;shapes.removeAll()}
        let raw=UInt64(bitPattern:event.getIntegerValueField(.eventSourceUserData))
        // The origin token survives Quartz retimestamping, then the existing
        // mismatch engine clears it. Alias both timestamps while the token is
        // available; never add a tag or assume repair markers identify one key.
        let physicalTag=(raw>>48)==0x4852 || (raw>>32)==0x48514556
        let inputOrigin=(raw>>32)==0x48414B53 ? 3:((raw>>32)==0x48414E51 ? 2:1)
        let timestampKey=Identity(token:event.timestamp,type:type.rawValue,domain:inputOrigin)
        let taggedKey=physicalTag ? Identity(token:raw,type:type.rawValue,domain:0):nil
        if identities.count>=capacity{identities.removeAll()}
        let known=taggedKey.flatMap{identities[$0]} ?? (event.timestamp>0 ? identities[timestampKey]:nil)
        let identifier:Int
        if let known{identifier=known}else{eventSequence+=1;identifier=eventSequence}
        if event.timestamp>0{identities[timestampKey]=identifier}
        if let taggedKey{identities[taggedKey]=identifier}
        append(lane,.event,event:identifier,edge:type == .keyDown ? 1:(type == .keyUp ? 2:3),category:pointer ? 4:(editing ? 2:(type == .flagsChanged ? 3:1)),inputOrigin:inputOrigin,consumed:consumed,duration:duration)
        lock.unlock()
        if duration>=0.05{requestCapture(.callbackDelay)}
    }
    struct ReadSpan {let id:Int;let began:Double}
    func beginRead(_ lane:Lane)->ReadSpan? {
        guard enabled,lock.try() else{return nil}
        defer{lock.unlock()}
        readSequence+=1;let span=ReadSpan(id:readSequence,began:clock())
        if reads.count<128{reads[span.id]=span.began}
        append(lane,.read,event:span.id,category:1)
        return span
    }
    func endRead(_ lane:Lane,_ span:ReadSpan?){
        guard enabled,let span else{return}
        guard lock.try() else{
            queue.async{[self] in lock.lock();reads.removeValue(forKey:span.id);lock.unlock()}
            return
        }
        reads.removeValue(forKey:span.id)
        let duration=clock()-span.began
        append(lane,.read,event:span.id,category:2,duration:duration)
        lock.unlock()
        if duration>=0.05{requestCapture(.axDelay)}
    }
    func start(){
        guard enabled,timer==nil else{return}
        let source=DispatchSource.makeTimerSource(queue:queue)
        source.schedule(deadline:.now()+0.1,repeating:.milliseconds(100))
        source.setEventHandler{[weak self] in
            guard let self,self.lock.try() else{return}
            let delayed=self.reads.values.contains{self.clock()-$0>=0.1}
            let capture=delayed ? self.snapshot(.axDelay):nil
            self.lock.unlock();self.persist(capture)
        }
        timer=source;source.resume()
    }
    func shape(_ lane:Lane,identity:UInt,count:Int,selected:Bool,editing:Bool){
        guard enabled,lock.try() else{return}
        if fields.count>=256{fields.removeAll();shapes.removeAll()}
        if fields[identity]==nil{nextField+=1;fields[identity]=nextField}
        let previous=shapes[lane]
        let changed=previous?.field != identity || previous?.count != count || previous?.selected != selected
        if changed{append(lane,.shape,count:count,selected:selected,field:fields[identity]!)}
        let suspect=previous.map{$0.field==identity && !$0.selected && !selected && count<$0.count} ?? false
        shapes[lane]=Shape(field:identity,count:count,selected:selected)
        let trigger=suspect && !editing && clock()-lastEdit>0.4
        lock.unlock()
        if trigger{requestCapture(.possibleShrink)}
    }
    func state(_ lane:Lane,_ state:State,pending:Int=0){
        guard enabled,lock.try() else{return}
        if state != .buffered{lastEdit=clock();shapes.removeAll()}
        append(lane,.state,category:state.rawValue,count:pending)
        lock.unlock()
    }
    func context(){
        guard enabled,lock.try() else{return};lastEdit=clock();shapes.removeAll();append(.main,.context);lock.unlock()
    }
    private func skipped(_ lane:Lane,event:Bool){
        queue.async{[self] in
            if event{skippedEvents[lane.rawValue,default:0]+=1}
            else{skippedAuxiliary[lane.rawValue,default:0]+=1}
        }
    }
    func sourceBoundary(_ stage:BoundaryStage,queued:Int,awaitingOnset:Int){
        guard enabled else{return}
        if lock.try(){
            append(.sourceBoundary,.sourceBoundary,event:awaitingOnset,category:stage.rawValue,count:queued)
            lock.unlock()
        }else{skipped(.sourceBoundary,event:false)}
        if stage == .retained || stage == .deadline || stage == .focusChanged || stage == .failed || stage == .inputResumed {
            requestCapture(.boundaryInterrupted)
        }
    }
    func mark(){
        guard enabled else{return}
        if lock.try(){append(.main,.marker);lock.unlock()}else{skipped(.main,event:false)}
        requestCapture(.manual)
    }
    // Used by deterministic tests and shutdown only; never from an input callback.
    func flush(){queue.sync{};queue.sync{}}
    deinit{timer?.cancel()}
}
