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

// A fixed atomic generation: callers never wait for a settings/trace lock.
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
        guard trace.enabled,!IsSecureEventInputEnabled() else{return nil}
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
    static var defaultDirectory:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("HanQ Diagnostics",isDirectory:true).appendingPathComponent("InputIncidents",isDirectory:true)
    }
    static func launch(arguments:[String],defaults:UserDefaults)->(directory:URL,enabled:Bool,persistent:Bool) {
        if let i=arguments.firstIndex(of:"--diagnose-input-incidents"),i+1<arguments.count,!arguments[i+1].hasPrefix("--") {
            return (URL(fileURLWithPath:arguments[i+1]),true,false)
        }
        return (defaultDirectory,defaults.bool(forKey:key),true)
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
        let available=attributes.compactMap{$0};guard !available.isEmpty else{return 1}
        let meaningful=available.filter{!$0.trimmingCharacters(in:whitespace).isEmpty}
        guard !meaningful.isEmpty else{return 2}
        let trimmed=value.trimmingCharacters(in:whitespace)
        return meaningful.contains{same(trimmed,$0.trimmingCharacters(in:whitespace))} ? 4:3
    }
    static func attributes(_ list:[AnyObject],value:String,verified:String,route:Int)->(InputIncidentAXEvidence,AXUIElement?) {
        var result=InputIncidentAXEvidence();result.route=route;result.representation=same(value,verified) ? 1:2
        result.placeholder=list.count==9 ? match(value,[list[4] as? String]):1
        result.label=list.count==9 ? match(value,[list[5] as? String,list[6] as? String]):1
        result.characterCount=1
        if list.count==9,let number=list[7] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.intValue>=0,number.doubleValue==Double(number.intValue) {
            result.characterCount=number.intValue==value.utf16.count ? 2:3
        }
        let window:AXUIElement? = list.count==9 && CFGetTypeID(list[8])==AXUIElementGetTypeID() ? (list[8] as! AXUIElement):nil
        return (result,window)
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
struct InputIncidentShapeProbe {
    private var text:String?,selection:NSRange?,field:UInt?,generation:Int32=0
    private var sample=0
    private var valueClass=0,priorWindow=0,priorEpoch=0
    private static func sameContent(_ a:String,_ b:String)->Bool {
        // Literal CF comparison handles native and AX/NSString-backed storage
        // without a per-code-unit Swift loop or a diagnostic content hash.
        CFStringCompare(a as CFString,b as CFString,CFStringCompareFlags(rawValue:0)) == .compareEqualTo
    }
    mutating func reset(){text=nil;selection=nil;field=nil;generation=0;sample=0;valueClass=0;priorWindow=0;priorEpoch=0}
    mutating func observe(identity:UInt,text:String,selection:NSRange,generation:Int32,ax:InputIncidentAXEvidence?=nil)->InputIncidentTrace.ShapeChange {
        if self.generation != generation{reset();self.generation=generation}
        let sameField=field==identity && self.text != nil
        let changedWindow=priorWindow>0 && (ax?.window ?? 0)>0 && priorWindow != ax!.window
        let known=sameField && !changedWindow
        let content=known && !Self.sameContent(self.text!,text)
        let cursor=known && self.selection != selection
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
        sample+=1;self.text=text;self.selection=selection;field=identity
        return .init(sample:sample,known:known,content:content,selection:cursor,ax:evidence)
    }
}

// Typed, bounded incident metadata. Never accepts text, keycodes, clipboard,
// application names or arbitrary log messages. Capture is deliberately lossy:
// input callbacks never wait for the diagnostic lock or filesystem.
final class InputIncidentTrace {
    let fieldRegistry=InputIncidentFieldRegistry()
    enum Lane:Int,Codable {case hid=1,main,onset,mismatch,boundary,onsetAX,mismatchAX,sourceBoundary}
    enum Kind:Int,Codable {case event=1,read,shape,marker,context,state,sourceBoundary,detectionDecision,observationWait,sourceEvidence,controlDecision}
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
    enum Trigger:Int,Codable {case manual=1,callbackDelay,axDelay,possibleShrink,boundaryInterrupted}
    enum BoundaryStage:Int {
        case waiting=1,queued,onsetWaiting,onsetConfirmed,onsetRetimed,retained,finished,deadline,focusChanged,failed,selection,sourceCommitted
        case snapshotWait,textWait,caretWait,repairWait,repairReceiptWait,onsetReceiptWait,replayReceiptWait,focusWait,selectionCommitWait,sourceCommitWait
        case inputResumed,editorStyleMatched,terminalLFMatched,terminalLFStyleMatched,pendingTextPrefix,sourceInitialBodyRemoved
        case manualEditStarted,manualEditVerified,manualEditUnverified
        static func event(_ stage:String)->BoundaryStage? {
            switch stage {
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
    struct DecisionTiming:Codable {
        let queueMicros:Int;let lockWaitMicros:Int;let contended:Bool;let clipped:Bool
    }
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
    struct ShapeChange {let sample:Int;let known:Bool;let content:Bool;let selection:Bool;var ax:InputIncidentAXEvidence?=nil}
    struct ShapeEvidence:Codable {
        // phase 1=new baseline, 2=checkpoint/current capture, 3=closed span.
        let phase:Int;let comparisonKnown:Bool;let contentChanged:Bool;let selectionChanged:Bool
        let editingChanged:Bool;let gap:Bool;let editing:Bool
        var firstMilliseconds:Int;var lastMilliseconds:Int;var observations:Int;var coalesced:Int
        var baselineSequence:Int
        var ax:InputIncidentAXEvidence?=nil
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
        var controlEvidence:InputIncidentControl?=nil
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
    }
    struct Capture:Encodable {
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
        let trigger:Trigger;let incident:Int;let phase:Int;let discardedOldFrames:Int;let frames:[Frame]
        // Prior completed writes only. The companion status includes this write.
        var storageBeforeWrite:DiagnosticLogStore.Status?=nil
        var shapeBaselines:[ShapeBaseline]?=nil
        var capturePreservation:CapturePreservation?=nil
        var captureBacklog:CaptureBacklog?=nil
    }
    private struct Identity:Hashable {let token:UInt64;let type:UInt32;let domain:Int}
    // Scalar reference only: never retain/read a mutable CGEvent asynchronously.
    private struct EventReference {
        let timestamp:CGEventTimestamp;let type:CGEventType;let token:UInt64
        init(_ event:CGEvent,_ type:CGEventType){
            timestamp=event.timestamp;self.type=type;token=UInt64(bitPattern:event.getIntegerValueField(.eventSourceUserData))
        }
    }
    private struct Shape {
        let field:UInt;let count:Int;let selected:Bool;let editing:Bool
        var active:Bool;var sample:Int?;var point:ShapePoint;let previous:ShapePoint?
        var checkpointAt:Double;var reportedObservations:Int
    }
    static let shared:InputIncidentTrace = {
        let option=InputIncidentPreferences.launch(arguments:ProcessInfo.processInfo.arguments,defaults:.standard)
        return InputIncidentTrace(destination:option.directory,initiallyEnabled:option.enabled,persistentOwnership:option.persistent)
    }()
    private let runID=UUID().uuidString
    private let gate:DiagnosticCollectionGate
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
    private var observationProcessed:[Int:Int]=[:],observationOverflow:[Int:Int]=[:],observationOmitted:[Int:Int]=[:],observationCoalesced:[Int:Int]=[:]
    private let captureCredits=(0..<5).map{_ in DispatchSemaphore(value:16)}
    private let captureOverflowSignals=(0..<5).map{_ in DispatchSemaphore(value:0)}
    // All window mutation is on decisionQueue under the metadata lock. Writer
    // closures receive value snapshots; a window slot is held through both writes.
    private final class CaptureWindow {
        var before:Capture;var after:Capture?
        var requests:[CaptureRequest];let deferred:Bool;let generation:Int32
        var post:[Frame]=[];var postOmitted=0;var revision=0;var closed=false;var submitted=false
        var closedMilliseconds:Int?;var endedOnShutdown=false
        init(_ before:Capture,_ request:CaptureRequest,deferred:Bool,generation:Int32){
            self.before=before;self.requests=[request];self.deferred=deferred;self.generation=generation
        }
    }
    private var windows:[Int:CaptureWindow]=[:]
    private var drainScheduled=false
    private var captureRequested:[Int:Int]=[:],captureMerged:[Int:Int]=[:],captureDeferred:[Int:Int]=[:]
    private var captureRequestOverflow:[Int:Int]=[:],captureWindowOverflow:[Int:Int]=[:],capturePostOverflow:[Int:Int]=[:],captureDiscarded:[Int:Int]=[:]
    private var submittedWindows=0,completedWindows=0
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
    private let clock:()->Double
    private let origin:Double
    private var ring:[Frame?]
    private var position=0,stored=0,sequence=0,overwritten=0,eventSequence=0
    private var identities:[Identity:Int]=[:]
    private var lastDecisions:[DecisionSite:DecisionReason]=[:]
    private var lastSourceEvidence:[Int:Int]=[:]
    private var shapes:[Lane:Shape]=[:]
    private var fields:[UInt:Int]=[:]
    private var nextField=0,lastEdit = -Double.infinity,lastTrigger = -Double.infinity
    private var captures=0,manualCaptures=0
    private var reads:[UUID:(id:Int,began:Double)]=[:]
    private var readSequence=0
    private var timer:DispatchSourceTimer?
    // The writer drains fixed overflow/omission signals into these legacy
    // aggregates. Input callers never wait for a metadata lock.
    private var skippedEvents:[Int:Int]=[:],skippedAuxiliary:[Int:Int]=[:]
    private let writer:((Capture)->Void)?
    init(destination:URL?,initiallyEnabled:Bool=true,persistentOwnership:Bool=false,capacity:Int=4096,clock:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},retention:DiagnosticLogRetentionPolicy = .incidentDefault,decisionCapacity:Int=4096,observationCapacity:Int=4096,readCapacity:Int=128,decisionClock:@escaping ()->UInt64={DispatchTime.now().uptimeNanoseconds},observationClock:@escaping ()->UInt64={DispatchTime.now().uptimeNanoseconds},writer:((Capture)->Void)?=nil){
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
        self.storage=destination.map{DiagnosticLogStore(directory:$0,policy:retention,persistentOwnership:persistentOwnership)}
        self.configured=destination != nil || writer != nil;self.gate=DiagnosticCollectionGate(self.configured && initiallyEnabled)
        self.capacity=max(1,min(capacity,16384));self.clock=clock;origin=clock();self.writer=writer
        ring=Array(repeating:nil,count:self.configured ? self.capacity:0)
        if enabled{storage?.prepareOwnership();captures=storage?.lastCaptureIncident ?? 0}
    }
    // Main-thread UI control. Preparation/draining stays on background queues.
    func setCollectionEnabled(_ active:Bool,completion:(()->Void)?=nil){
        let paused=gate.pause()
        timer?.cancel();timer=nil
        // The writer barrier queues reset after write-completion bookkeeping.
        // OFF counts cancelled protected requests even if publication was queued.
        decisionQueue.async{[self] in queue.async{[self] in
            guard gate.generation==paused else{DispatchQueue.main.async{completion?()};return}
            if active,configured{storage?.prepareOwnership()}
            let last=storage?.lastCaptureIncident ?? 0
            decisionQueue.async{[self] in
                guard gate.generation==paused else{DispatchQueue.main.async{completion?()};return}
                lock.lock()
                for window in windows.values {
                    for request in window.requests{captureDiscarded[request.trigger,default:0]+=1}
                }
                windows.removeAll();drainScheduled=false
                ring=Array(repeating:nil,count:configured ? capacity:0);position=0;stored=0
                reads.removeAll();shapes.removeAll();identities.removeAll();lastDecisions.removeAll();lastSourceEvidence.removeAll()
                fields.removeAll();lastEdit = -Double.infinity;lastTrigger = -Double.infinity
                if active,configured{captures=max(captures,last);_ = gate.activate(paused)}
                lock.unlock()
                DispatchQueue.main.async{[weak self] in self?.start();completion?()}
            }
        }}
    }
    private func append(_ lane:Lane,_ kind:Kind,observedAt:Double?=nil,decisionTiming:DecisionTiming?=nil,observationTiming:DecisionTiming?=nil,event:Int=0,edge:Int=0,category:Int=0,inputOrigin:Int=0,consumed:Bool=false,duration:Double=0,count:Int=0,selected:Bool=false,field:Int=0){
        sequence+=1
        ring[position]=Frame(sequence:sequence,milliseconds:Int(max(0,(observedAt ?? clock())-origin)*1000),lane:lane,kind:kind,event:event,edge:edge,category:category,inputOrigin:inputOrigin,consumed:consumed,durationMicros:Int(max(0,min(duration,60))*1_000_000),count:count,selected:selected,field:field,decisionTiming:decisionTiming,observationTiming:observationTiming)
        position=(position+1)%capacity
        if stored<capacity{stored+=1}else{overwritten+=1}
        let frame=ring[(position-1+capacity)%capacity]!
        for window in windows.values where !window.closed {
            if window.post.count<capacity{window.post.append(frame)}else{
                window.postOmitted+=1;capturePostOverflow[window.before.trigger.rawValue,default:0]+=1
            }
        }
    }
    private func updatePreservedLastFrame(){
        guard let frame=ring[(position-1+capacity)%capacity] else{return}
        for window in windows.values where !window.closed && window.post.last?.sequence==frame.sequence {
            window.post[window.post.count-1]=frame
        }
    }
    private func snapshot(_ reason:Trigger,timing:DecisionTiming,incident:Int,phase:Int=0,frames:[Frame]?=nil)->Capture {
        let start=(position-stored+capacity)%capacity
        return Capture(runID:runID,skippedEvents:skippedEvents,skippedAuxiliary:skippedAuxiliary,decisionDelivery:DecisionDelivery(capacity:decisionCapacity,overflow:decisionOverflow,waits:decisionWaits,coalesced:decisionCoalesced),observationDelivery:observationSnapshot(),captureTiming:timing,trigger:reason,incident:incident,phase:phase,discardedOldFrames:overwritten,frames:frames ?? (0..<stored).compactMap{ring[(start+$0)%capacity]},shapeBaselines:shapeSnapshot(),captureBacklog:backlogSnapshot())
    }
    private func backlogSnapshot()->CaptureBacklog {
        CaptureBacklog(automaticCapacity:16,manualCapacity:4,requestCapacityPerTrigger:16,requestsPerWindow:32,
            pendingAutomatic:windows.values.filter{$0.before.trigger != .manual}.count,pendingManual:windows.values.filter{$0.before.trigger == .manual}.count,
            requested:captureRequested,merged:captureMerged,deferred:captureDeferred,requestOverflow:captureRequestOverflow,windowOverflow:captureWindowOverflow,postOverflow:capturePostOverflow,discardedOnDisable:captureDiscarded,submittedWindows:submittedWindows,completedWindows:completedWindows)
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
        for (code,count) in over{observationOverflow[code,default:0]+=count}
        for (code,count) in omissions{observationOmitted[code,default:0]+=count}
        for (code,count) in over.merging(omissions,uniquingKeysWith:+){
            let op=code/(8*32)+1,lane=code/32%8+1
            if op==1{skippedEvents[lane,default:0]+=count}else{skippedAuxiliary[lane,default:0]+=count}
        }
    }
    private func requestCapture(_ reason:Trigger,lane:Lane = .main,detail:Int=0,event:CGEvent?=nil){
        let generation=gate.generation;guard generation>0 else{return}
        // Bounded admission only. The input caller never waits for a lock, copies
        // a ring, encodes JSON, or performs file I/O.
        guard captureCredits[reason.rawValue-1].wait(timeout:.now()) == .success else{
            captureOverflowSignals[reason.rawValue-1].signal();return
        }
        let time=clock(),enqueued=observationClock(),reference=event.map{EventReference($0,$0.type)}
        decisionQueue.async{[self] in
            defer{captureCredits[reason.rawValue-1].signal()}
            guard gate.generation==generation else{return}
            collectDecisionOverflow();collectCaptureOverflow();let counters=collectObservationCounters()
            withObservation(.capture,.main,reason.rawValue,observedAt:time,enqueuedAt:enqueued){timing in
                guard gate.generation==generation else{return}
                mergeObservationCounters(counters)
                let (identifier,origin)=reference.map{eventIdentity($0)} ?? (0,0)
                let request=CaptureRequest(trigger:reason.rawValue,milliseconds:Int(max(0,time-self.origin)*1000),afterSequence:sequence,lane:lane.rawValue,detail:detail,event:identifier,inputOrigin:origin)
                captureRequested[reason.rawValue,default:0]+=1
                if reason == .manual,manualCaptures>=32 {
                    observationOmitted[observationCode(.capture,.main,17),default:0]+=1;return
                }
                if reason != .manual,let window=windows.values.filter({!$0.closed && $0.before.trigger != .manual && $0.requests.count<32 && $0.post.count<capacity && request.milliseconds-($0.requests.last?.milliseconds ?? 0)<1000}).max(by:{$0.before.incident<$1.before.incident}) {
                    window.requests.append(request);captureMerged[reason.rawValue,default:0]+=1
                    let code=reason == window.before.trigger ? reason.rawValue:reason.rawValue+8
                    observationOmitted[observationCode(.capture,.main,code),default:0]+=1
                    scheduleClose(window);return
                }
                let pending=windows.values.filter{($0.before.trigger == .manual)==(reason == .manual)}.count
                guard pending<(reason == .manual ? 4:16) else{
                    captureWindowOverflow[reason.rawValue,default:0]+=1;return
                }
                // An older frozen pre must reach the ordered store first. A newer
                // immediate pre would retire that older automatic incident.
                let intervalBlocked=clock()-lastTrigger<10
                let orderBlocked=windows.values.contains{$0.deferred && !$0.submitted}
                let deferred=reason != .manual && (intervalBlocked || orderBlocked)
                if deferred{
                    captureDeferred[reason.rawValue,default:0]+=1
                    observationOmitted[observationCode(.capture,.main,reason.rawValue+8),default:0]+=1
                }else if reason != .manual{lastTrigger=clock()}
                if reason == .manual{manualCaptures+=1}
                captures+=1
                let before=snapshot(reason,timing:timing,incident:captures)
                let window=CaptureWindow(before,request,deferred:deferred,generation:generation)
                windows[captures]=window
                if !deferred {
                    var value=before;value.capturePreservation=preservation(window);value.captureBacklog=backlogSnapshot()
                    queue.async{[self] in if gate.generation==generation{write(value)}}
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
        decisionQueue.asyncAfter(deadline:.now()+1){[self] in
            guard gate.generation==generation,let current=windows[incident],!current.closed,current.revision==revision else{return}
            closeWindow(current)
        }
    }
    private func closeWindow(_ window:CaptureWindow){
        collectDecisionOverflow();collectCaptureOverflow();let counters=collectObservationCounters()
        let time=clock(),enqueued=observationClock()
        withObservation(.capture,.main,window.before.trigger.rawValue+24,observedAt:time,enqueuedAt:enqueued){timing in
            guard gate.generation==window.generation,windows[window.before.incident] === window else{return}
            mergeObservationCounters(counters);window.closed=true;window.closedMilliseconds=Int(max(0,clock()-origin)*1000)
            window.after=snapshot(window.before.trigger,timing:timing,incident:window.before.incident,phase:1,frames:window.post)
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
        var before=window.before
        let value=preservation(window),backlog=backlogSnapshot()
        before.capturePreservation=value;before.captureBacklog=backlog
        after.capturePreservation=value;after.captureBacklog=backlog
        let writeBefore=window.deferred,generation=window.generation,incident=before.incident
        queue.async{[self] in
            if writeBefore,gate.generation==generation{write(before)}
            let attemptedPost=gate.generation==generation
            if attemptedPost{write(after)}
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
    private func write(_ capture:Capture){
        if let writer{writer(capture);return}
        guard let storage else{return}
        var annotated=capture;annotated.storageBeforeWrite=storage.status
        do {
            let data=try JSONEncoder().encode(annotated)
            _ = storage.save(data,incident:capture.incident,phase:capture.phase,automatic:capture.trigger != .manual)
        } catch {storage.encodingFailed(incident:capture.incident,phase:capture.phase,automatic:capture.trigger != .manual)}
    }
    // No extra event tag, AX call, event copy, key post or source selection.
    func event(_ lane:Lane,_ type:CGEventType,_ event:CGEvent,consumed:Bool=false,duration:Double=0){
        guard enabled,!IsSecureEventInputEnabled() else{return}
        let time=clock(),reference=EventReference(event,type)
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        let editing=event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty == false || [36,48,51,53,76,117,123,124,125,126].contains(code)
        let pointer=type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let edge=type == .keyDown ? 1:(type == .keyUp ? 2:3)
        let category=pointer ? 4:(editing ? 2:(type == .flagsChanged ? 3:1))
        _ = submit(.event,lane,edge+(consumed ? 4:0),observedAt:time){[self] timing in
            if editing || pointer{lastEdit=time;invalidateShapes()}
            let (identifier,origin)=eventIdentity(reference)
            append(lane,.event,observedAt:time,observationTiming:timing,event:identifier,edge:edge,category:category,inputOrigin:origin,consumed:consumed,duration:duration)
        }
        // Preserve the request even when event queue capacity was exhausted.
        if duration>=0.05{requestCapture(.callbackDelay,lane:lane,event:event)}
    }
    // Called only while holding the trace lock; never writes to the event.
    private func eventIdentity(_ event:CGEvent,type:CGEventType)->(Int,Int) {
        eventIdentity(EventReference(event,type))
    }
    private func eventIdentity(_ reference:EventReference)->(Int,Int) {
        let raw=reference.token
        let physicalTag=(raw>>48)==0x4852 || (raw>>32)==0x48514556
        let inputOrigin=(raw>>32)==0x48414B53 ? 3:((raw>>32)==0x48414E51 ? 2:1)
        let timestampKey=Identity(token:reference.timestamp,type:reference.type.rawValue,domain:inputOrigin)
        let taggedKey=physicalTag ? Identity(token:raw,type:reference.type.rawValue,domain:0):nil
        if identities.count>=capacity{identities.removeAll()}
        let known=taggedKey.flatMap{identities[$0]} ?? (reference.timestamp>0 ? identities[timestampKey]:nil)
        let identifier:Int
        if let known{identifier=known}else{eventSequence+=1;identifier=eventSequence}
        if reference.timestamp>0{identities[timestampKey]=identifier}
        if let taggedKey{identities[taggedKey]=identifier}
        return (identifier,inputOrigin)
    }
    func decision(_ site:DecisionSite,_ reason:DecisionReason,event:CGEvent?=nil) {
        let generation=gate.generation;guard generation>0,!IsSecureEventInputEnabled() else{return}
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
    final class ReadSpan {
        fileprivate let token=UUID(),began:Double
        fileprivate let generation:Int32
        private let credits:DispatchSemaphore
        private let endCredits=DispatchSemaphore(value:1)
        fileprivate func reserveEnd()->Bool {endCredits.wait(timeout:.now()) == .success}
        private var released=false
        fileprivate func finish(){if !released{released=true;credits.signal()}}
        fileprivate init(began:Double,credits:DispatchSemaphore,generation:Int32){self.began=began;self.credits=credits;self.generation=generation}
        deinit {
            // Restore a claimed one-shot semaphore before libdispatch destroys it.
            _ = endCredits.wait(timeout:.now());endCredits.signal()
            if !released{credits.signal()}
        }
    }
    func beginRead(_ lane:Lane)->ReadSpan? {
        let generation=gate.generation;guard generation>0 else{return nil}
        guard readCredits.wait(timeout:.now()) == .success else {
            observationOverflowSignals[observationCode(.readStart,lane)].signal();return nil
        }
        let span=ReadSpan(began:clock(),credits:readCredits,generation:generation)
        // One lease reserves both queued endpoints and an active read, independent
        // of event/shape floods. No AX object or CGEvent is retained.
        let enqueued=observationClock()
        decisionQueue.async{[self,span] in
            guard gate.generation==generation else{return}
            withObservation(.readStart,lane,observedAt:span.began,enqueuedAt:enqueued){timing in
            guard reads.count<readCapacity else {
                observationOverflow[observationCode(.readStart,lane),default:0]+=1;return
            }
            readSequence+=1;reads[span.token]=(readSequence,span.began)
            append(lane,.read,observedAt:span.began,observationTiming:timing,event:readSequence,category:1)
            }
        }
        return span
    }
    func endRead(_ lane:Lane,_ span:ReadSpan?){
        guard let span else{if enabled{observationOmittedSignals[observationCode(.readEnd,lane)].signal()};return}
        guard span.reserveEnd() else{if gate.generation==span.generation{observationOmittedSignals[observationCode(.readEnd,lane)].signal()};return}
        let ended=clock(),duration=ended-span.began
        let enqueued=observationClock()
        decisionQueue.async{[self,span] in
            defer{span.finish()}
            guard gate.generation==span.generation else{reads.removeValue(forKey:span.token);return}
            withObservation(.readEnd,lane,observedAt:ended,enqueuedAt:enqueued){timing in
            guard let read=reads.removeValue(forKey:span.token) else {
                observationOmitted[observationCode(.readEnd,lane),default:0]+=1;return
            }
            append(lane,.read,observedAt:ended,observationTiming:timing,event:read.id,category:2,duration:duration)
            }
        }
        if gate.generation==span.generation,duration>=0.05{requestCapture(.axDelay,lane:lane)}
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
                if self.reads.values.contains(where:{time-$0.began>=0.1}){self.requestCapture(.axDelay)}
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
        ShapeEvidence(phase:phase,comparisonKnown:value.comparisonKnown,contentChanged:value.contentChanged,selectionChanged:value.selectionChanged,editingChanged:value.editingChanged,gap:value.gap,editing:value.editing,firstMilliseconds:value.firstMilliseconds,lastMilliseconds:value.lastMilliseconds,observations:value.observations,coalesced:value.coalesced,baselineSequence:value.baselineSequence,ax:value.ax)
    }
    private func appendShape(_ lane:Lane,_ point:ShapePoint,phase:Int,time:Double,timing:DecisionTiming?=nil){
        append(lane,.shape,observedAt:time,observationTiming:timing,count:point.count,selected:point.selected,field:point.field)
        ring[(position-1+capacity)%capacity]?.milliseconds=point.evidence.lastMilliseconds
        ring[(position-1+capacity)%capacity]?.shapeEvidence=shapeEvidence(point.evidence,phase:phase)
        updatePreservedLastFrame()
    }
    func shape(_ lane:Lane,identity:UInt,count:Int,selected:Bool,editing:Bool,change:ShapeChange?=nil){
        guard enabled else{return};let time=clock()
        // Only fixed scalars are retained by submit. The probe's String stays
        // on the engine's snapshot path; input callbacks never take our lock.
        _ = submit(.shape,lane,observedAt:time){[self] timing in
            if fields.count>=256{fields.removeAll();invalidateShapes()}
            if fields[identity]==nil{nextField+=1;fields[identity]=nextField}
            let previous=shapes[lane]
            let sameField=previous?.active==true && previous?.field==identity
            let gap=change.map{value in
                if let sample=previous?.sample{return value.sample != sample+1}
                return value.known && previous==nil
            } ?? false
            let known=sameField && change?.known==true && !gap
            let changed = !sameField || previous?.count != count || previous?.selected != selected || previous?.editing != editing || change?.content==true || change?.selection==true || gap || previous?.point.evidence.ax != change?.ax
            let ms=Int(max(0,time-origin)*1000)
            if changed {
                // Close suppressed intervals before starting the new baseline.
                if let previous,previous.active,previous.point.evidence.observations>previous.reportedObservations {
                    appendShape(lane,previous.point,phase:3,time:origin+Double(previous.point.evidence.lastMilliseconds)/1000)
                }
                let evidence=ShapeEvidence(phase:1,comparisonKnown:known,contentChanged:known && change?.content==true,selectionChanged:known && change?.selection==true,editingChanged:sameField && previous?.editing != editing,gap:gap,editing:editing,firstMilliseconds:ms,lastMilliseconds:ms,observations:1,coalesced:0,baselineSequence:sequence+1,ax:change?.ax)
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
            if suspect && !editing && time-lastEdit>0.4{requestCapture(.possibleShrink,lane:lane)}
        }
    }
    func state(_ lane:Lane,_ state:State,pending:Int=0){
        guard enabled else{return};let time=clock()
        _ = submit(.state,lane,state.rawValue,observedAt:time){[self] timing in
            if state != .buffered{lastEdit=time;invalidateShapes()}
            append(lane,.state,observedAt:time,observationTiming:timing,category:state.rawValue,count:pending)
        }
    }
    func sourceEvidence(_ action:SourceEvidenceAction,_ value:SourceEvidence,event:CGEvent?=nil){
        guard enabled,!IsSecureEventInputEnabled() else{return}
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
    func control(_ lane:Lane,_ type:CGEventType,_ event:CGEvent?,_ value:InputIncidentControl,consumed:Bool=false){
        guard enabled,!IsSecureEventInputEnabled() else{return}
        let time=clock(),reference=event.map{EventReference($0,type)}
        _ = submit(.context,lane,8+value.role,observedAt:time){[self] timing in
            let (identifier,origin)=reference.map{eventIdentity($0)} ?? (0,0)
            append(lane,.controlDecision,observedAt:time,observationTiming:timing,event:identifier,edge:value.role,category:value.route,inputOrigin:origin,consumed:consumed)
            ring[(position-1+capacity)%capacity]?.controlEvidence=value
            updatePreservedLastFrame()
        }
    }
    func context(){
        guard enabled else{return};let time=clock()
        _ = submit(.context,.main,observedAt:time){[self] timing in lastEdit=time;invalidateShapes();append(.main,.context,observedAt:time,observationTiming:timing)}
    }
    func sourceBoundary(_ stage:BoundaryStage,queued:Int,awaitingOnset:Int){
        guard enabled else{return};let time=clock()
        _ = submit(.boundary,.sourceBoundary,stage.rawValue,observedAt:time){[self] timing in
            append(.sourceBoundary,.sourceBoundary,observedAt:time,observationTiming:timing,event:awaitingOnset,category:stage.rawValue,count:queued)
        }
        if stage == .retained || stage == .deadline || stage == .focusChanged || stage == .failed || stage == .manualEditUnverified || stage == .inputResumed {requestCapture(.boundaryInterrupted,lane:.sourceBoundary,detail:stage.rawValue)}
    }
    func mark(){
        guard enabled else{return};let time=clock()
        _ = submit(.marker,.main,observedAt:time){[self] timing in append(.main,.marker,observedAt:time,observationTiming:timing)}
        requestCapture(.manual)
    }
    #if HANQ_DIAGNOSTIC_TESTING
    func captureForTest(_ reason:Trigger){requestCapture(reason)}
    func flushCaptureWorkerForTest(){decisionQueue.sync{}}
    func finishCaptureWindowsForTest(){decisionQueue.sync{for window in windows.values where !window.closed{closeWindow(window)}}}
    func drainCapturesForTest(){decisionQueue.sync{lock.lock();defer{lock.unlock()};drainDeferred()}}
    func withLockedMetadataForTest(_ work:()->Void){lock.lock();defer{lock.unlock()};work()}
    #endif
    // Used by deterministic tests and shutdown only; never from an input callback.
    func flush(){for _ in 0..<4{decisionQueue.sync{};queue.sync{}}}
    // Normal application termination, after input hooks have stopped. Cancel
    // future observations and let an in-progress storage transaction complete.
    func stopAndFlush(){
        timer?.cancel();timer=nil
        decisionQueue.sync{
            lock.lock();defer{lock.unlock()}
            for window in windows.values.sorted(by:{$0.before.incident<$1.before.incident}) where !window.submitted {
                if !window.closed {
                    window.closed=true;window.closedMilliseconds=Int(max(0,clock()-origin)*1000);window.endedOnShutdown=true
                    window.after=snapshot(window.before.trigger,timing:DecisionTiming(queueMicros:0,lockWaitMicros:0,contended:false,clipped:false),incident:window.before.incident,phase:1,frames:window.post)
                }
                submitWindow(window)
            }
        }
        flush();_ = gate.pause()
    }
    deinit{timer?.cancel()}
}
// Reusable storage policy, separate from capture/trigger semantics and export UI.
// The caller supplies privacy-screened data and serializes all calls off input
// callbacks. Limits cover this store's automatic files and, in persistent mode,
// its verified ownership index. Unmanaged files and manual captures are protected.
struct DiagnosticLogRetentionPolicy {
    let maximumAutomaticFiles:Int
    let maximumAutomaticBytes:Int
    static let incidentDefault=Self(maximumAutomaticFiles:64,maximumAutomaticBytes:64*1024*1024)
    init(maximumAutomaticFiles:Int,maximumAutomaticBytes:Int){
        precondition(maximumAutomaticFiles>0 && maximumAutomaticBytes>0)
        self.maximumAutomaticFiles=maximumAutomaticFiles;self.maximumAutomaticBytes=maximumAutomaticBytes
    }
}

final class DiagnosticLogStore {
    enum Result:Int,Equatable {case saved=1,limit,retired,unavailable}
    // Fixed numeric state: no paths, input content, keys or arbitrary messages.
    // Accessed exclusively by the serial writer; never by input callbacks.
    struct Status:Codable {
        var maximumAutomaticFiles:Int,maximumAutomaticBytes:Int
        var automaticFiles=0,automaticBytes=0
        var attempts=0,saved=0,limited=0,retired=0,unavailable=0,encodingFailures=0
        var evictedGroups=0,evictedFiles=0,evictedBytes=0
        var lastIncident=0,lastPhase=0,lastAutomatic=false,lastResult=0,lastFailureStage=0,lastErrno=0
        var lastWriteMicros=0,maxWriteMicros=0,writeTimingClipped=0,statusWriteFailures=0
    }
    struct StatusDocument:Encodable {
        let schema=1
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "test"
        let status:Status
    }
    struct Usage:Equatable {let files:Int;let bytes:Int}
    private struct File {
        let name:String;let phase:Int;let identity:stat
        var bytes:Int{Int(identity.st_size)}
    }
    private struct Group {let incident:Int;var files:[File]}
    private let directory:URL,policy:DiagnosticLogRetentionPolicy
    private var directoryIdentity:stat?
    private var groups:[Group]=[]
    private var latestAutomatic=0
    private(set) var status:Status
    private var statusName=".storage-"+UUID().uuidString+".status"
    private var statusFile:File?
    private var failureStage=0,failureErrno:Int32=0
    private func failed(_ stage:Int,_ code:Int32=0)->Result {failureStage=stage;failureErrno=code;return .unavailable}
    var usage:Usage {Usage(files:groups.reduce(0){$0+$1.files.count},bytes:groups.reduce(0){$0+$1.files.reduce(0){$0+$1.bytes}})}
    private(set) var lastResult:Result?
    init(directory:URL,policy:DiagnosticLogRetentionPolicy,persistentOwnership:Bool=false){
        self.directory=directory;self.policy=policy;self.persistentOwnership=persistentOwnership
        status=Status(maximumAutomaticFiles:policy.maximumAutomaticFiles,maximumAutomaticBytes:policy.maximumAutomaticBytes)
    }

    // Only this opt-in persistent namespace resumes its own indexed automatic
    // files. Historical CLI folders and all manual files remain unadopted.
    private struct Record:Codable {
        let incident:Int,name:String,phase:Int,device:Int64,inode:UInt64,size:Int64
        let mtime:Int64,mtimeNanos:Int64,ctime:Int64,ctimeNanos:Int64
        init(_ file:File,incident:Int){
            self.incident=incident;name=file.name;phase=file.phase
            let s=file.identity;device=Int64(s.st_dev);inode=s.st_ino;size=s.st_size
            mtime=Int64(s.st_mtimespec.tv_sec);mtimeNanos=Int64(s.st_mtimespec.tv_nsec)
            ctime=Int64(s.st_ctimespec.tv_sec);ctimeNanos=Int64(s.st_ctimespec.tv_nsec)
        }
        func matches(_ s:stat)->Bool {
            device==Int64(s.st_dev) && inode==s.st_ino && size==s.st_size &&
            mtime==s.st_mtimespec.tv_sec && mtimeNanos==s.st_mtimespec.tv_nsec &&
            ctime==s.st_ctimespec.tv_sec && ctimeNanos==s.st_ctimespec.tv_nsec &&
            s.st_mode&S_IFMT==S_IFREG && s.st_uid==getuid() && s.st_mode&0o077==0
        }
    }
    private struct Ownership:Codable {
        let schema:Int,device:Int64,inode:UInt64,lastIncident:Int
        let statusName:String,status:Status,files:[Record],statusFile:Record?
    }
    private let persistentOwnership:Bool
    private var ownershipPrepared=false,ownershipHealthy=true
    private let ownershipName=".automatic-ownership-v1.index"
    private var ownershipFile:File?
    private(set) var lastCaptureIncident=0
    func prepareOwnership(){
        guard persistentOwnership,!ownershipPrepared else{return}
        ownershipPrepared=true;ownershipHealthy=false
        guard let dir=openDirectory() else{return};defer{close(dir)}
        var info=stat()
        if fstatat(dir,ownershipName,&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno==ENOENT else{return}
            // Lost metadata never authorizes adoption/deletion of old evidence.
            let names=(try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []
            guard !names.contains(where:{$0.hasPrefix("incident-") || $0.hasPrefix(".storage-")}) else{return}
            ownershipHealthy=persistOwnership(dir);return
        }
        let fd=openat(dir,ownershipName,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{return};defer{close(fd)}
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_size>0,info.st_size<=128*1024,
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:128*1024+1),
              let index=try? JSONDecoder().decode(Ownership.self,from:data),index.schema==1,
              let identity=directoryIdentity,index.device==Int64(identity.st_dev),index.inode==identity.st_ino,
              index.status.maximumAutomaticFiles==policy.maximumAutomaticFiles,index.status.maximumAutomaticBytes==policy.maximumAutomaticBytes,
              index.files.count<=policy.maximumAutomaticFiles,index.lastIncident>=0,
              validStatusName(index.statusName) else{return}
        var restored:[Int:[File]]=[:],names=Set<String>(),total=0
        for entry in index.files {
            guard entry.incident>0,entry.incident<=index.lastIncident,(0...1).contains(entry.phase),
                  entry.name.hasPrefix("incident-\(entry.incident)-\(entry.phase)-"),entry.name.hasSuffix(".json"),
                  UUID(uuidString:String(entry.name.dropFirst("incident-\(entry.incident)-\(entry.phase)-".count).dropLast(5))) != nil,
                  names.insert(entry.name).inserted else{return}
            var current=stat()
            guard fstatat(dir,entry.name,&current,AT_SYMLINK_NOFOLLOW)==0,entry.matches(current),current.st_size>=0,
                  current.st_size<=policy.maximumAutomaticBytes-total else{return}
            total+=Int(current.st_size)
            restored[entry.incident,default:[]].append(File(name:entry.name,phase:entry.phase,identity:current))
        }
        for values in restored.values {
            guard values.count<=2,Set(values.map{$0.phase}).count==values.count,values.contains(where:{$0.phase==0}) else{return}
        }
        var previousStatus:File?
        if let entry=index.statusFile {
            var current=stat()
            guard entry.name==index.statusName,fstatat(dir,entry.name,&current,AT_SYMLINK_NOFOLLOW)==0,entry.matches(current),current.st_size<=16*1024 else{return}
            previousStatus=File(name:entry.name,phase:0,identity:current)
        } else {
            var current=stat()
            guard fstatat(dir,index.statusName,&current,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT else{return}
        }
        let old=index.status
        guard old.automaticFiles==index.files.count,old.automaticBytes==total,old.attempts>=0,old.saved>=0,
              old.limited>=0,old.retired>=0,old.unavailable>=0,old.encodingFailures>=0,
              validAttemptCounts(old) else{return}
        // An interrupted publication may leave a complete automatic file outside
        // the last index. Refuse growth; never adopt or delete ambiguous evidence.
        guard let diskNames=try? FileManager.default.contentsOfDirectory(atPath:directory.path) else{return}
        for name in diskNames where name.hasPrefix("incident-") && !names.contains(name) {
            guard isUntrackedManual(name,dir) else{return}
        }
        groups=restored.keys.sorted().map{Group(incident:$0,files:restored[$0]!.sorted{$0.phase<$1.phase})}
        latestAutomatic=index.lastIncident;lastCaptureIncident=index.lastIncident;status=old
        statusName=index.statusName;statusFile=previousStatus
        ownershipFile=File(name:ownershipName,phase:0,identity:info);ownershipHealthy=true
    }
    private func validAttemptCounts(_ status:Status)->Bool {
        var remaining=status.attempts
        for count in [status.saved,status.limited,status.retired,status.unavailable,status.encodingFailures] {
            guard count>=0,count<=remaining else{return false};remaining-=count
        }
        return remaining==0
    }
    private func isUntrackedManual(_ name:String,_ dir:Int32)->Bool {
        let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{return false};defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_size>0,info.st_size<=16*1024*1024,
              let data=try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:16*1024*1024+1) else{return false}
        struct Header:Decodable {let schema:Int,trigger:Int}
        guard let header=try? JSONDecoder().decode(Header.self,from:data) else{return false}
        return header.schema==1 && header.trigger==1
    }
    private func validStatusName(_ name:String)->Bool {
        name.hasPrefix(".storage-") && name.hasSuffix(".status") && UUID(uuidString:String(name.dropFirst(9).dropLast(7))) != nil
    }
    private func persistOwnership(_ dir:Int32)->Bool {
        guard let identity=directoryIdentity else{return false}
        let index=Ownership(schema:1,device:Int64(identity.st_dev),inode:identity.st_ino,lastIncident:lastCaptureIncident,
            statusName:statusName,status:status,files:groups.flatMap{group in group.files.map{Record($0,incident:group.incident)}},
            statusFile:statusFile.map{Record($0,incident:0)})
        guard let data=try? JSONEncoder().encode(index),data.count<=128*1024 else{return false}
        if let old=ownershipFile, !owned(old,dir){return false}
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return false};defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd) else{return false}
        if let old=ownershipFile {
            guard owned(old,dir),renameat(dir,temporary,dir,ownershipName)==0 else{return false}
        }else{guard linkat(dir,temporary,dir,ownershipName,0)==0,unlinkat(dir,temporary,0)==0 else{return false}}
        var info=stat();guard fstat(fd,&info)==0 else{return false}
        ownershipFile=File(name:ownershipName,phase:0,identity:info);return true
    }

    @discardableResult func save(_ data:Data,incident:Int,phase:Int,automatic:Bool)->Result {
        let began=DispatchTime.now().uptimeNanoseconds
        failureStage=0;failureErrno=0
        let result=publish(data,incident:incident,phase:phase,automatic:automatic)
        lastResult=result
        finishAttempt(incident:incident,phase:phase,automatic:automatic,result:result.rawValue,began:began)
        return result
    }
    func encodingFailed(incident:Int,phase:Int,automatic:Bool){
        prepareOwnership()
        failureStage=6;failureErrno=0
        finishAttempt(incident:incident,phase:phase,automatic:automatic,result:5,began:DispatchTime.now().uptimeNanoseconds)
    }
    private func finishAttempt(incident:Int,phase:Int,automatic:Bool,result:Int,began:UInt64){
        lastCaptureIncident=max(lastCaptureIncident,incident)
        status.attempts+=1
        switch result {
        case 1:status.saved+=1
        case 2:status.limited+=1
        case 3:status.retired+=1
        case 4:status.unavailable+=1
        default:status.encodingFailures+=1
        }
        status.automaticFiles=usage.files;status.automaticBytes=usage.bytes
        status.lastIncident=incident;status.lastPhase=phase;status.lastAutomatic=automatic
        status.lastResult=result;status.lastFailureStage=failureStage;status.lastErrno=Int(failureErrno)
        let ended=DispatchTime.now().uptimeNanoseconds,elapsed=ended>=began ? ended-began:0
        status.lastWriteMicros=Int(min(elapsed/1000,60_000_000))
        status.maxWriteMicros=max(status.maxWriteMicros,status.lastWriteMicros)
        if elapsed>60_000_000_000{status.writeTimingClipped+=1}
        let statusFailed = !writeStatus()
        if statusFailed{status.statusWriteFailures+=1}
        if persistentOwnership,ownershipHealthy {
            var ownershipFailed=false
            if let dir=openDirectory(){
                ownershipFailed = !persistOwnership(dir);close(dir)
            }else{ownershipFailed=true}
            if ownershipFailed {
                ownershipHealthy=false
                if !statusFailed{status.statusWriteFailures+=1}
            }
        }
    }
    // One <=16KiB owner-only companion per store, excluded from the automatic
    // capture budget. Atomically replaces only this instance's own status file.
    // A wholly unwritable disk cannot persist its failure: keep the last good
    // status and report the accumulated failure on the next successful write.
    private func writeStatus()->Bool {
        let previousStage=failureStage,previousErrno=failureErrno
        defer{failureStage=previousStage;failureErrno=previousErrno}
        guard let data=try? JSONEncoder().encode(StatusDocument(status:status)),data.count<=16*1024,
              let dir=openDirectory() else{return false}
        defer{close(dir)}
        if let old=statusFile {guard owned(old,dir) else{return false}}
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return false}
        defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd) else{return false}
        if let old=statusFile {
            guard owned(old,dir),renameat(dir,temporary,dir,statusName)==0 else{return false}
        } else {
            guard linkat(dir,temporary,dir,statusName,0)==0,unlinkat(dir,temporary,0)==0 else{return false}
        }
        var info=stat();guard fstat(fd,&info)==0 else{return false}
        statusFile=File(name:statusName,phase:0,identity:info)
        return true
    }
    private func writeAll(_ data:Data,_ fd:Int32)->Bool {
        data.withUnsafeBytes { bytes->Bool in
            var offset=0
            while offset<bytes.count {
                let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if n<0 && errno==EINTR{continue}
                guard n>0 else{return false};offset+=n
            }
            return true
        }
    }
    private func openDirectory()->Int32? {
        if persistentOwnership {
            let parent=directory.deletingLastPathComponent().path;var p=stat()
            if lstat(parent,&p) != 0 {
                guard errno==ENOENT,mkdir(parent,S_IRWXU)==0 else{_ = failed(2,errno);return nil}
            }
            guard lstat(parent,&p)==0,p.st_mode&S_IFMT==S_IFDIR,p.st_uid==getuid(),p.st_mode&0o077==0 else{_ = failed(2);return nil}
        }
        var info=stat()
        if lstat(directory.path,&info) != 0 {
            guard errno==ENOENT,directoryIdentity==nil,mkdir(directory.path,S_IRWXU)==0 else{_ = failed(2,errno);return nil}
        } else {guard (info.st_mode & S_IFMT)==S_IFDIR,info.st_uid==getuid(),(info.st_mode & 0o077)==0 else{_ = failed(2);return nil}}
        let dir=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard dir>=0 else{_ = failed(2,errno);return nil}
        guard fstat(dir,&info)==0,info.st_uid==getuid(),(info.st_mode & 0o077)==0 else{_ = failed(2,errno);close(dir);return nil}
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
    private func publish(_ data:Data,incident:Int,phase:Int,automatic:Bool)->Result {
        prepareOwnership()
        guard !automatic || ownershipHealthy else{return failed(3)}
        guard incident>0,(0...1).contains(phase) else{return failed(1)}
        var evictions:[Group]=[]
        if automatic {
            if phase==0 {
                guard incident>latestAutomatic else{return .retired}
                // Even a failed pre-capture cannot be resurrected by its post.
                latestAutomatic=incident
            } else {guard groups.contains(where:{$0.incident==incident && $0.files.count==1 && $0.files[0].phase==0}) else{return .retired}}
            let current=groups.first(where:{$0.incident==incident})
            guard data.count<=policy.maximumAutomaticBytes,
                  (current?.files.count ?? 0)+1<=policy.maximumAutomaticFiles,
                  (current?.files.reduce(0){$0+$1.bytes} ?? 0)<=policy.maximumAutomaticBytes-data.count else{return .limit}
            var count=usage.files+1,bytes=usage.bytes+data.count
            for group in groups where group.incident < incident {
                if count<=policy.maximumAutomaticFiles && bytes<=policy.maximumAutomaticBytes{break}
                evictions.append(group);count-=group.files.count;bytes-=group.files.reduce(0){$0+$1.bytes}
            }
            guard count<=policy.maximumAutomaticFiles,bytes<=policy.maximumAutomaticBytes else{return .limit}
        }
        guard let dir=openDirectory() else{return .unavailable};defer{close(dir)}
        var info=stat()
        // A changed or replaced file is no longer ours to remove. Refuse a new
        // automatic file instead of growing beyond the bound on pruning error.
        guard !automatic || groups.allSatisfy({$0.files.allSatisfy{owned($0,dir)}}) else{return failed(3)}
        let filename="incident-\(incident)-\(phase)-\(UUID().uuidString).json"
        let temporary=".partial-"+UUID().uuidString
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return failed(4,errno)}
        defer{close(fd);unlinkat(dir,temporary,0)}
        guard writeAll(data,fd),linkat(dir,temporary,dir,filename,0)==0 else{return failed(4,errno)}
        // Capture identity after publication (link changes ctime). Close the
        // temporary link before recording ctime, too.
        guard unlinkat(dir,temporary,0)==0,fstat(fd,&info)==0 else{unlinkat(dir,filename,0);return failed(4,errno)}
        let published=File(name:filename,phase:phase,identity:info)
        for group in evictions {
            for file in group.files {
                guard owned(file,dir),unlinkat(dir,file.name,0)==0 else {
                    // Roll back only our complete new file. Any surviving old
                    // file remains tracked; partial cleanup never expands use.
                    if owned(published,dir){unlinkat(dir,filename,0)}
                    return failed(5,errno)
                }
                status.evictedFiles+=1;status.evictedBytes+=file.bytes
                if let index=groups.firstIndex(where:{$0.incident==group.incident}) {
                    groups[index].files.removeAll{$0.name==file.name}
                    if groups[index].files.isEmpty{groups.remove(at:index);status.evictedGroups+=1}
                }
            }
        }
        if automatic {
            if let index=groups.firstIndex(where:{$0.incident==incident}){groups[index].files.append(published)}
            else{groups.append(Group(incident:incident,files:[published]))}
        }
        return .saved
    }
}
