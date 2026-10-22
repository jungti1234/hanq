import Foundation
import Darwin
import CoreFoundation

enum RecorderError: Error, LocalizedError {
    case invalidDirectory, invalidTrace, limit, inactive
    var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "한Q의 사용자 전용 진단 폴더를 확인할 수 없습니다."
        case .invalidTrace: return "지원하는 입력 처리 진단 파일이 아닙니다."
        case .limit: return "이 구간의 저장 한도에 도달했습니다. 기록을 종료하고 새 구간을 시작하세요."
        case .inactive: return "먼저 기록을 시작하세요."
        }
    }
}

struct RecorderDecisionTiming: Codable {
    let queueMicros, lockWaitMicros: Int
    let contended, clipped: Bool
    var valid: Bool {(0...60_000_000).contains(queueMicros) && (0...60_000_000).contains(lockWaitMicros) && (contended || lockWaitMicros==0)}
}
struct RecorderEventEvidence:Codable {
    let observedAtMicros,timestampMicros,keyClass:Int
    static let keys=Set(["observedAtMicros","timestampMicros","keyClass"])
    var valid:Bool {[observedAtMicros,timestampMicros].allSatisfy{(0...9_000_000_000_000_000).contains($0)} && (1...6).contains(keyClass)}
}
struct RecorderDecisionWaitStats: Codable {
    let processed, contended, totalLockWaitMicros, maxLockWaitMicros, maxQueueMicros, clipped: Int
    var valid: Bool {
        processed>0 && (0...processed).contains(contended) && (0...processed).contains(clipped) &&
        totalLockWaitMicros>=0 && (0...60_000_000).contains(maxLockWaitMicros) && (0...60_000_000).contains(maxQueueMicros) &&
        maxLockWaitMicros<=totalLockWaitMicros && (contended>0 || totalLockWaitMicros==0)
    }
}
struct RecorderSourceEvidence:Codable {
    let selected,confirmed,target,observedAtMilliseconds:Int
    let targetEventMilliseconds:Int?
    let ageClipped:Bool
    let confirmedAtMilliseconds,targetAtMilliseconds,confirmedAgeMicros,targetAgeMicros:Int?
    let committed,deferred,candidatePreserved,historyPreserved:Bool
    static let required=Set(["selected","confirmed","target","committed","deferred","candidatePreserved","historyPreserved","observedAtMilliseconds","ageClipped"])
    static let optional=Set(["targetEventMilliseconds","confirmedAtMilliseconds","targetAtMilliseconds","confirmedAgeMicros","targetAgeMicros"])
    var valid:Bool {
        [selected,confirmed,target].allSatisfy{(0...7).contains($0)} &&
        [observedAtMilliseconds,targetEventMilliseconds,confirmedAtMilliseconds,targetAtMilliseconds].allSatisfy{$0.map{(0...9_000_000_000_000_000).contains($0)} ?? true} &&
        [confirmedAgeMicros,targetAgeMicros].allSatisfy{$0.map{(0...60_000_000).contains($0)} ?? true} &&
        (confirmedAtMilliseconds==nil)==(confirmedAgeMicros==nil) && (targetAtMilliseconds==nil)==(targetAgeMicros==nil)
    }
}
struct RecorderControlQuery:Codable {
    let site,status,current,target,available,korean,english,micros:Int
    let clipped:Bool
    static let keys=Set(["site","status","current","target","available","korean","english","micros","clipped"])
    var valid:Bool {(1...3).contains(site) && (1...5).contains(status) && (0...4).contains(current) && (0...4).contains(target) && (0...4096).contains(available) && (0...available).contains(korean) && (0...available).contains(english) && (0...60_000_000).contains(micros)}
}
struct RecorderControlEvidence:Codable {
    let priorQuery:RecorderControlQuery?
    let role,eventType,route,runtime,incomingFlags,filterFlags,filterBefore,filterAfter,filterEdge,filterReason,externalDevice,externalHandling,externalRole,hidAcceptance,querySite,queryStatus,currentClass,targetClass,availableCount,koreanCount,englishCount,queryMicros:Int
    let filterMeasured,filterAccepted,filterConsumed,queryClipped:Bool
    static let keys=Set(["role","eventType","route","runtime","incomingFlags","filterFlags","filterBefore","filterAfter","filterEdge","filterReason","externalDevice","externalHandling","externalRole","hidAcceptance","querySite","queryStatus","currentClass","targetClass","availableCount","koreanCount","englishCount","queryMicros","filterMeasured","filterAccepted","filterConsumed","queryClipped"])
    var valid:Bool {
        (priorQuery?.valid ?? true) && (priorQuery==nil || queryStatus>0) &&
        (0...4).contains(role) &&
        (0...4).contains(eventType) &&
        (0...31).contains(route) &&
        (0...127).contains(runtime) &&
        (0...7).contains(incomingFlags) &&
        (0...7).contains(filterFlags) &&
        (0...3).contains(filterBefore) &&
        (0...3).contains(filterAfter) &&
        (0...2).contains(filterEdge) &&
        (0...7).contains(filterReason) &&
        (0...6).contains(externalDevice) &&
        (0...4).contains(externalHandling) &&
        (0...4).contains(externalRole) &&
        (0...10).contains(hidAcceptance) &&
        (0...3).contains(querySite) &&
        (0...5).contains(queryStatus) &&
        (0...4).contains(currentClass) &&
        (0...4).contains(targetClass) &&
        (0...4096).contains(availableCount) &&
        (0...4096).contains(koreanCount) &&
        (0...4096).contains(englishCount) &&
        (0...60000000).contains(queryMicros) &&
        route>0 && (queryStatus != 0 || (querySite==0 && currentClass==0 && targetClass==0 && availableCount==0 && koreanCount==0 && englishCount==0 && queryMicros==0 && !queryClipped)) &&
        (filterMeasured || (filterBefore==0 && filterAfter==0 && filterEdge==0 && filterFlags==0 && filterReason==0 && !filterAccepted && !filterConsumed)) && koreanCount<=availableCount && englishCount<=availableCount
    }
}
struct RecorderAXEvidence:Codable {
    let valueClass,placeholder,label,characterCount,representation,route,owner,window,fieldRelation,windowRelation,identityEpoch:Int
    static let keys=Set(["valueClass","placeholder","label","characterCount","representation","route","owner","window","fieldRelation","windowRelation","identityEpoch"])
    var valid:Bool {(0...5).contains(valueClass) && (0...4).contains(placeholder) && (0...4).contains(label) && (0...3).contains(characterCount) && (0...2).contains(representation) && (0...3).contains(route) && owner>0 && window>=0 && (0...2).contains(fieldRelation) && (0...2).contains(windowRelation) && identityEpoch>0 && (window>0 || windowRelation==0)}
    static func fields(_ value:[String:Any])->Bool {
        Set(value.keys).subtracting(["ax","caretPrecedingClass"])==RecorderShapeEvidence.keys && (!value.keys.contains("caretPrecedingClass") || value["caretPrecedingClass"] is NSNumber) && (!value.keys.contains("ax") || (value["ax"] as? [String:Any]).map{Set($0.keys)==keys}==true)
    }
}
struct RecorderShapeEvidence:Codable {
    let phase:Int;let comparisonKnown:Bool;let contentChanged:Bool;let selectionChanged:Bool
    let editingChanged:Bool;let gap:Bool;let editing:Bool
    let firstMilliseconds:Int;let lastMilliseconds:Int;let observations:Int;let coalesced:Int;let baselineSequence:Int
    var ax:RecorderAXEvidence?=nil
    var caretPrecedingClass:Int?=nil
    static let keys=Set(["phase","comparisonKnown","contentChanged","selectionChanged","editingChanged","gap","editing","firstMilliseconds","lastMilliseconds","observations","coalesced","baselineSequence"])
    var valid:Bool {
        (caretPrecedingClass.map{(0...5).contains($0)} ?? true) && (ax?.valid ?? true) && (1...3).contains(phase) && firstMilliseconds>=0 && lastMilliseconds>=firstMilliseconds && lastMilliseconds<=9_000_000_000_000_000 && observations>0 && coalesced>=0 && coalesced<observations && baselineSequence>0 &&
        (comparisonKnown || (!contentChanged && !selectionChanged)) && (!gap || !comparisonKnown) &&
        (phase != 1 || (observations==1 && coalesced==0 && firstMilliseconds==lastMilliseconds))
    }
}
struct RecorderShapePoint:Codable {
    let field:Int;let count:Int;let selected:Bool;let evidence:RecorderShapeEvidence
    static let keys=Set(["field","count","selected","evidence"])
    var valid:Bool {field>0 && count>=0 && evidence.valid}
}
struct RecorderShapeBaseline:Codable {
    let lane:Int;let active:Bool;let current:RecorderShapePoint;let previous:RecorderShapePoint?
    var valid:Bool {(1...8).contains(lane) && current.valid && current.evidence.phase==2 &&
        (previous.map{$0.valid && $0.evidence.phase==3 && $0.evidence.lastMilliseconds<=current.evidence.firstMilliseconds && $0.evidence.baselineSequence<current.evidence.baselineSequence} ?? true)}
}

struct RecorderFrame: Codable {
    let sequence, milliseconds, lane, kind, event, edge, category, inputOrigin: Int
    let consumed: Bool
    let durationMicros, count: Int
    let selected: Bool
    let field: Int
    let decisionTiming: RecorderDecisionTiming?
    let observationTiming: RecorderDecisionTiming?
    var sourceEvidence:RecorderSourceEvidence?=nil
    var shapeEvidence:RecorderShapeEvidence?=nil
    var controlEvidence:RecorderControlEvidence?=nil
    var eventEvidence:RecorderEventEvidence?=nil
}

struct RecorderDecisionDelivery: Codable {
    let capacity: Int
    let overflow: [String: Int]
    let waits: [String: RecorderDecisionWaitStats]?
    let coalesced:[String:Int]?
}

struct RecorderObservationDelivery: Codable {
    let capacity,readCapacity:Int
    let processed,overflow,omitted,coalesced:[String:Int]
    let waits:[String:RecorderDecisionWaitStats]?
    static func validCode(_ key:String)->Bool {
        guard let code=Int(key),String(code)==key,(0..<2560).contains(code) else{return false}
        let operation=code/256+1,detail=code%32
        switch operation {
        case 1:return [1,2,3,5,6,7].contains(detail)
        case 5:return (1...8).contains(detail)
        case 6:return detail==0 || (code/32%8==3 && (1...7).contains(detail)) || (code/32%8<3 && (8...12).contains(detail)) || (code/32%8==1 && (17...21).contains(detail))
        case 7:return (1...31).contains(detail)
        case 10:return (1...6).contains(detail) || (9...14).contains(detail) || detail==17 || (25...30).contains(detail)
        default:return detail==0
        }
    }
    var valid:Bool {
        (4...16384).contains(capacity) && (1...128).contains(readCapacity) &&
        [processed,overflow,omitted,coalesced].allSatisfy{$0.count<=2560 && $0.allSatisfy{Self.validCode($0.key) && $0.value>0}} &&
        coalesced.keys.allSatisfy{let code=Int($0)!;return code/256+1==4 || (code/256+1==6 && code/32%8==3 && code%32>0)} &&
        (waits.map{ stats in
            Set(stats.keys)==Set(processed.keys) && stats.allSatisfy { key,value in
                Self.validCode(key) && value.valid && processed[key]==value.processed &&
                (Int(key)!/256+1 != 10 || (1...6).contains(Int(key)!%32) || (25...30).contains(Int(key)!%32))
            }
        } ?? true)
    }
}

// Storage telemetry is bounded, typed metadata, independently reusable by collectors.
struct RecorderStorageStatus:Codable {
    let maximumAutomaticFiles,maximumAutomaticBytes,automaticFiles,automaticBytes,attempts,saved,limited,retired,unavailable,encodingFailures,evictedGroups,evictedFiles,evictedBytes,lastIncident,lastPhase,lastResult,lastFailureStage,lastErrno,lastWriteMicros,maxWriteMicros,writeTimingClipped,statusWriteFailures:Int
    let lastAutomatic:Bool
    static let keys=Set(["maximumAutomaticFiles", "maximumAutomaticBytes", "automaticFiles", "automaticBytes", "attempts", "saved", "limited", "retired", "unavailable", "encodingFailures", "evictedGroups", "evictedFiles", "evictedBytes", "lastIncident", "lastPhase", "lastAutomatic", "lastResult", "lastFailureStage", "lastErrno", "lastWriteMicros", "maxWriteMicros", "writeTimingClipped", "statusWriteFailures"])
    var valid:Bool {
        let values=[maximumAutomaticFiles,maximumAutomaticBytes,automaticFiles,automaticBytes,attempts,saved,limited,retired,unavailable,encodingFailures,evictedGroups,evictedFiles,evictedBytes,lastIncident,lastPhase,lastResult,lastFailureStage,lastErrno,lastWriteMicros,maxWriteMicros,writeTimingClipped,statusWriteFailures]
        guard values.allSatisfy({$0>=0}),maximumAutomaticFiles>0,maximumAutomaticBytes>0,
              automaticFiles<=maximumAutomaticFiles,automaticBytes<=maximumAutomaticBytes,
              saved<=attempts,limited<=attempts,retired<=attempts,unavailable<=attempts,encodingFailures<=attempts,
              evictedGroups<=evictedFiles,lastPhase<=1,lastResult<=5,lastFailureStage<=6,lastErrno<=Int(Int32.max),
              lastWriteMicros<=60_000_000,maxWriteMicros<=60_000_000,lastWriteMicros<=maxWriteMicros,
              writeTimingClipped<=attempts,statusWriteFailures<=attempts else{return false}
        var remaining=attempts
        for count in [saved,limited,retired,unavailable,encodingFailures]{guard count<=remaining else{return false};remaining-=count}
        guard remaining==0 else{return false}
        if attempts==0{return lastResult==0 && lastIncident==0 && lastFailureStage==0 && lastErrno==0 && automaticFiles==0 && automaticBytes==0 && evictedFiles==0 && evictedBytes==0}
        guard lastResult>0,lastIncident>0 else{return false}
        let counts=[saved,limited,retired,unavailable,encodingFailures]
        guard counts[lastResult-1]>0 else{return false}
        return lastResult==4 ? (1...5).contains(lastFailureStage):lastResult==5 ? lastFailureStage==6 && lastErrno==0:lastFailureStage==0 && lastErrno==0
    }
}
struct RecorderStorageDocument:Codable {
    let schema:Int,build:String,status:RecorderStorageStatus
    static func decode(_ data:Data)throws->RecorderStorageDocument {
        guard data.count<=16*1024,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys)==Set(["schema","build","status"]),
              let status=object["status"] as? [String:Any],Set(status.keys)==RecorderStorageStatus.keys else{throw RecorderError.invalidTrace}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.schema==1,value.build.range(of:"^(?:[0-9]{1,9}|test)$",options:.regularExpression) != nil,value.status.valid else{throw RecorderError.invalidTrace}
        return value
    }
}

struct RecorderCaptureRequest:Codable {
    let trigger:Int;let milliseconds:Int;let afterSequence:Int;let lane:Int;let detail:Int;let event:Int;let inputOrigin:Int
    var valid:Bool{
        (1...6).contains(trigger) && milliseconds>=0 && afterSequence>=0 && (1...8).contains(lane) && (0...31).contains(detail) && event>=0 && (0...3).contains(inputOrigin) &&
        (trigger != 6 || (event==0 && inputOrigin==0 && ((lane==4 && ((1...6).contains(detail) || detail==10)) || (lane==3 && (7...9).contains(detail)))))
    }
}
struct RecorderCapturePreservation:Codable {
    let deferred:Bool;let requests:[RecorderCaptureRequest];let postCapacity:Int;let postOmittedFrames:Int;let closed:Bool
    let closedMilliseconds:Int?;let endedOnShutdown:Bool
    var valid:Bool{!requests.isEmpty && requests.count<=32 && requests.allSatisfy{$0.valid} && (1...16384).contains(postCapacity) && postOmittedFrames>=0 && (closed == (closedMilliseconds != nil)) && (closedMilliseconds ?? 0)>=0 && (!endedOnShutdown || closed)}
}
struct RecorderCaptureBacklog:Codable {
    let automaticCapacity:Int;let manualCapacity:Int;let requestCapacityPerTrigger:Int;let requestsPerWindow:Int
    let pendingAutomatic:Int;let pendingManual:Int
    let requested:[String:Int];let merged:[String:Int];let deferred:[String:Int];let requestOverflow:[String:Int];let windowOverflow:[String:Int]
    let postOverflow:[String:Int];let discardedOnDisable:[String:Int];let submittedWindows:Int;let completedWindows:Int
    static let keys:Set<String>=["automaticCapacity","manualCapacity","requestCapacityPerTrigger","requestsPerWindow","pendingAutomatic","pendingManual","requested","merged","deferred","requestOverflow","windowOverflow","postOverflow","discardedOnDisable","submittedWindows","completedWindows"]
    var valid:Bool{
        automaticCapacity==16 && manualCapacity==4 && requestCapacityPerTrigger==16 && requestsPerWindow==32 && (0...16).contains(pendingAutomatic) && (0...4).contains(pendingManual) && submittedWindows>=0 && (0...submittedWindows).contains(completedWindows) && [requested,merged,deferred,requestOverflow,windowOverflow,postOverflow,discardedOnDisable].allSatisfy{d in d.count<=6 && d.allSatisfy{e in Int(e.key).map{(1...6).contains($0) && String($0)==e.key} == true && e.value>0}}
    }
}
struct RecorderTrace: Codable {
    let schema: Int
    let runID:String?
    let clockOriginMicros:Int?
    let build: String
    let bestEffort, appReceiptVerified, correlationIsHeuristic, lossCountersMayLag: Bool
    let skippedEvents, skippedAuxiliary: [String: Int]
    let decisionDelivery: RecorderDecisionDelivery?
    let observationDelivery: RecorderObservationDelivery?
    let captureTiming:RecorderDecisionTiming?
    let capturePreservation:RecorderCapturePreservation?
    let captureBacklog:RecorderCaptureBacklog?
    let storageBeforeWrite:RecorderStorageStatus?
    let shapeBaselines:[RecorderShapeBaseline]?
    let trigger, incident, phase, discardedOldFrames: Int
    let frames: [RecorderFrame]

    private static func validFrame(_ row:RecorderFrame)->Bool {
                  guard row.sequence > 0 && row.milliseconds >= 0 && (1...8).contains(row.lane) && (1...12).contains(row.kind) && row.durationMicros >= 0 && row.count >= 0 && row.field >= 0 else{return false}
                  if let evidence=row.eventEvidence {
                      guard evidence.valid,[1,11].contains(row.kind),[1,2].contains(row.lane),row.event>0,evidence.observedAtMicros/1000==row.milliseconds else{return false}
                  }
                  if row.kind==12 {
                      return row.lane==2 && (1...5).contains(row.edge) && (0...4).contains(row.category) && row.event>=0 && row.inputOrigin==0 && !row.consumed && row.durationMicros==0 && row.count==0 && !row.selected && row.field==0 && row.observationTiming != nil && row.sourceEvidence==nil && row.shapeEvidence==nil && row.controlEvidence==nil
                  }
                  if let timing=row.decisionTiming {guard row.kind==8,timing.valid else{return false}}
                  if let timing=row.observationTiming {guard row.kind != 8,timing.valid else{return false}}
                  if let evidence=row.shapeEvidence {
                      guard row.kind==3,evidence.valid,row.field>0,evidence.baselineSequence<=row.sequence,
                            row.milliseconds==evidence.lastMilliseconds,
                            evidence.phase != 1 || evidence.baselineSequence==row.sequence else{return false}
                  }
                  if row.kind==11 {
                      guard let evidence=row.controlEvidence,evidence.valid,row.sourceEvidence==nil,row.shapeEvidence==nil,row.observationTiming != nil else{return false}
                      return [1,2,3].contains(row.lane) && row.edge==evidence.role && row.category==evidence.route && row.event>=0 && (0...3).contains(row.inputOrigin) && row.durationMicros==0 && row.count==0 && !row.selected && row.field==0
                  }
                  guard row.controlEvidence==nil else{return false}
                  if row.kind==10 {
                      guard let evidence=row.sourceEvidence,evidence.valid,row.observationTiming != nil else{return false}
                      return row.lane==4 && (1...7).contains(row.edge) && row.category==evidence.selected && row.event>=0 && (0...3).contains(row.inputOrigin) && !row.consumed && row.durationMicros==0 && row.count==0 && !row.selected && row.field==0
                  }
                  guard row.sourceEvidence==nil else{return false}
                  if row.kind==9 {
                      guard row.observationTiming != nil,(1...10).contains(row.category),(0...31).contains(row.edge) else{return false}
                      guard row.event==0,row.inputOrigin==0,!row.consumed,row.durationMicros==0,row.count==0,!row.selected,row.field==0 else{return false}
                      if row.category==10 {guard (1...6).contains(row.edge) || (25...30).contains(row.edge) else{return false}}
                      let code=((row.category-1)*8+row.lane-1)*32+row.edge
                      return RecorderObservationDelivery.validCode(String(code))
                  }
                  guard row.kind==8 else{return true}
                  return row.lane==4 && (1...5).contains(row.edge) && (1...31).contains(row.category) && row.event>=0 &&
                      (0...3).contains(row.inputOrigin) && !row.consumed && row.durationMicros==0 && row.count==0 && !row.selected && row.field==0
    }

    static func decode(_ data: Data) throws -> RecorderTrace {
        guard data.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).subtracting(["decisionDelivery","observationDelivery","captureTiming","storageBeforeWrite","runID","clockOriginMicros","shapeBaselines","capturePreservation","captureBacklog"]) == Set(["schema", "build", "bestEffort", "appReceiptVerified", "correlationIsHeuristic", "lossCountersMayLag", "skippedEvents", "skippedAuxiliary", "trigger", "incident", "phase", "discardedOldFrames", "frames"]),
              let rows = object["frames"] as? [[String: Any]], rows.count <= 16384 else { throw RecorderError.invalidTrace }
        if let value=object["capturePreservation"] {
            guard let v=value as? [String:Any],Set(v.keys).subtracting(["closedMilliseconds"])==Set(["deferred","requests","postCapacity","postOmittedFrames","closed","endedOnShutdown"]),let requests=v["requests"] as? [[String:Any]],requests.allSatisfy({Set($0.keys)==Set(["trigger","milliseconds","afterSequence","lane","detail","event","inputOrigin"])}) else{throw RecorderError.invalidTrace}
        }
        if let value=object["captureBacklog"] {
            guard let v=value as? [String:Any],Set(v.keys)==RecorderCaptureBacklog.keys else{throw RecorderError.invalidTrace}
        }
        if object.keys.contains("runID") {
            guard let id=object["runID"] as? String,id.count==36,UUID(uuidString:id) != nil else{throw RecorderError.invalidTrace}
        }
        if object.keys.contains("clockOriginMicros") {
            guard let n=object["clockOriginMicros"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue>=0,n.doubleValue<=9_000_000_000_000_000,n.doubleValue==Double(n.int64Value) else{throw RecorderError.invalidTrace}
        }
        if object.keys.contains("decisionDelivery") {
            guard let delivery=object["decisionDelivery"] as? [String:Any],Set(delivery.keys).subtracting(["waits","coalesced"])==Set(["capacity","overflow"]) else{throw RecorderError.invalidTrace}
            if delivery.keys.contains("waits") {
                guard let waits=delivery["waits"] as? [String:Any],waits.count<=310,
                      waits.values.allSatisfy({ ($0 as? [String:Any]).map{Set($0.keys)==Set(["processed","contended","totalLockWaitMicros","maxLockWaitMicros","maxQueueMicros","clipped"])} == true }) else{throw RecorderError.invalidTrace}
            }
        }
        if object.keys.contains("observationDelivery") {
            guard let delivery=object["observationDelivery"] as? [String:Any],Set(delivery.keys).subtracting(["waits"])==Set(["capacity","readCapacity","processed","overflow","omitted","coalesced"]) else{throw RecorderError.invalidTrace}
            if delivery.keys.contains("waits") {
                guard let waits=delivery["waits"] as? [String:Any],waits.count<=2560,waits.values.allSatisfy({($0 as? [String:Any]).map{Set($0.keys)==Set(["processed","contended","totalLockWaitMicros","maxLockWaitMicros","maxQueueMicros","clipped"])} == true}) else{throw RecorderError.invalidTrace}
            }
        }
        if object.keys.contains("captureTiming") {
            guard let timing=object["captureTiming"] as? [String:Any],Set(timing.keys)==Set(["queueMicros","lockWaitMicros","contended","clipped"]) else{throw RecorderError.invalidTrace}
        }
        if object.keys.contains("storageBeforeWrite") {
            guard let storage=object["storageBeforeWrite"] as? [String:Any],Set(storage.keys)==RecorderStorageStatus.keys else{throw RecorderError.invalidTrace}
        }
        let keys = Set(["sequence", "milliseconds", "lane", "kind", "event", "edge", "category", "inputOrigin", "consumed", "durationMicros", "count", "selected", "field"])
        guard rows.allSatisfy({ row in
            guard Set(row.keys).subtracting(["decisionTiming","observationTiming","sourceEvidence","shapeEvidence","controlEvidence","eventEvidence"])==keys else{return false}
            if row.keys.contains("eventEvidence") {
                guard let value=row["eventEvidence"] as? [String:Any],Set(value.keys)==RecorderEventEvidence.keys else{return false}
            }
            if row.keys.contains("controlEvidence") {
                guard let value=row["controlEvidence"] as? [String:Any],Set(value.keys).subtracting(["priorQuery"])==RecorderControlEvidence.keys else{return false}
                if value.keys.contains("priorQuery") {guard let query=value["priorQuery"] as? [String:Any],Set(query.keys)==RecorderControlQuery.keys else{return false}}
            }
            if row.keys.contains("shapeEvidence") {
                guard let value=row["shapeEvidence"] as? [String:Any],RecorderAXEvidence.fields(value) else{return false}
            }
            if row.keys.contains("sourceEvidence") {
                guard let evidence=row["sourceEvidence"] as? [String:Any],
                      Set(evidence.keys).subtracting(RecorderSourceEvidence.optional)==RecorderSourceEvidence.required,
                      RecorderSourceEvidence.optional.allSatisfy({!evidence.keys.contains($0) || evidence[$0] is NSNumber}) else{return false}
            }
            return ["decisionTiming","observationTiming"].allSatisfy { name in
                !row.keys.contains(name) || (row[name] as? [String:Any]).map{Set($0.keys)==Set(["queueMicros","lockWaitMicros","contended","clipped"])} == true
            }
        }) else { throw RecorderError.invalidTrace }
        if object.keys.contains("shapeBaselines") {
            func point(_ raw:Any?)->Bool {
                guard let value=raw as? [String:Any],Set(value.keys)==RecorderShapePoint.keys,
                      let evidence=value["evidence"] as? [String:Any],RecorderAXEvidence.fields(evidence) else{return false}
                return true
            }
            guard let values=object["shapeBaselines"] as? [[String:Any]],values.count<=8,
                  values.allSatisfy({value in
                      Set(value.keys).subtracting(["previous"])==Set(["lane","active","current"]) && point(value["current"]) && (!value.keys.contains("previous") || point(value["previous"]))
                  }) else{throw RecorderError.invalidTrace}
        }
        let value = try JSONDecoder().decode(RecorderTrace.self, from: data)
        guard value.schema == 1, value.build.range(of: "^(?:[0-9]{1,9}|test)$", options: .regularExpression) != nil,
              (1...6).contains(value.trigger), value.incident > 0, (0...1).contains(value.phase),
              value.discardedOldFrames >= 0,
              [value.skippedEvents, value.skippedAuxiliary].allSatisfy({ dict in
                  dict.count <= 8 && dict.allSatisfy { Int($0.key).map { (1...8).contains($0) } == true && $0.value >= 0 }
              }),
              value.frames.allSatisfy(Self.validFrame) else { throw RecorderError.invalidTrace }
        if let baselines=value.shapeBaselines {
            guard baselines.count<=8,Set(baselines.map{$0.lane}).count==baselines.count,baselines.allSatisfy({$0.valid}) else{throw RecorderError.invalidTrace}
        }
        if let delivery=value.decisionDelivery {
            guard (2...16384).contains(delivery.capacity),delivery.overflow.count<=310,
                  delivery.overflow.allSatisfy({ entry in Int(entry.key).map{(0..<310).contains($0) && String($0)==entry.key} == true && entry.value>0 }) else{throw RecorderError.invalidTrace}
            if let coalesced=delivery.coalesced {
                guard coalesced.count<=310,coalesced.allSatisfy({entry in Int(entry.key).map{(0..<310).contains($0) && String($0)==entry.key} == true && entry.value>0}) else{throw RecorderError.invalidTrace}
            }
            if let waits=delivery.waits {
                guard waits.count<=310,waits.allSatisfy({ entry in Int(entry.key).map{(0..<310).contains($0) && String($0)==entry.key} == true && entry.value.valid }) else{throw RecorderError.invalidTrace}
            }
        }
        if let delivery=value.observationDelivery {guard delivery.valid else{throw RecorderError.invalidTrace}}
        if let timing=value.captureTiming {guard timing.valid else{throw RecorderError.invalidTrace}}
        if let storage=value.storageBeforeWrite {guard storage.valid else{throw RecorderError.invalidTrace}}
        if let preserved=value.capturePreservation{guard preserved.valid else{throw RecorderError.invalidTrace}}
        if let backlog=value.captureBacklog{guard backlog.valid else{throw RecorderError.invalidTrace}}
        return value
    }
}

// Only reads HanQ's opt-in metadata directory. No event taps, key synthesis,
// accessibility, clipboard, ChatGPT API, or input-source selection.
final class RecorderSession {
    let directory: URL
    let source: URL
    private let sourceFD: Int32
    private let started = Date()
    private var seen = Set<String>()
    private(set) var copied = 0, rejected = 0, observations = 0
    private(set) var collectionWarning: String?
    private(set) var builds = Set<String>()
    private var bytes = 0, events = 0
    private var ended = false
    private(set) var storageStatuses=0, rejectedStorageStatuses=0
    private let baseline: Set<String>

    static func directoryFD(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecorderError.invalidDirectory }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw RecorderError.invalidDirectory
        }
        return fd
    }

    init(source: URL, outputRoot: URL, product: [String: Any]) throws {
        self.source = source
        sourceFD = try Self.directoryFD(source)
        baseline = Set((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [])
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let rootFD = try Self.directoryFD(outputRoot); close(rootFD)
            directory = outputRoot.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
            guard mkdir(directory.path, 0o700) == 0 else { throw RecorderError.invalidDirectory }
            guard mkdir(directory.appendingPathComponent("incidents").path, 0o700) == 0 else { throw RecorderError.invalidDirectory }
            let selfTest = product["recorderSelfTest"] as? Bool ?? false
            let automatic = product["automaticInputTest"] as? Bool ?? false
            try Self.writeJSON(["schema": 1, "startedAt": ISO8601DateFormatter().string(from: started), "startedUptime": ProcessInfo.processInfo.systemUptime, "target": "com.openai.codex", "inputMethod": selfTest ? "recorder-ui-self-test" : (automatic ? "user-started-automatic" : "user-operated"), "selfTest": selfTest, "typedTextCollected": false, "keyValuesCollected": false, "clipboardCollected": false, "chatgptReceiptVerified": false, "sourceDirectory": source.path, "hanq": product, "preexistingFilesExcluded": baseline.count], to: directory.appendingPathComponent("session.json"))
        } catch { close(sourceFD); throw error }
        try record("session_started", scenario: "ordinary")
    }

    static func writeJSON(_ value: [String: Any], to url: URL) throws {
        try write(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), to: url)
    }
    static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecorderError.invalidDirectory }; defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RecorderError.invalidDirectory }; offset += count
            }
        }
    }
    func record(_ kind: String, scenario: String) throws {
        let kinds = ["session_started", "trial_started", "observed_normal", "observed_loss", "hanq_manual_snapshot", "product_exited", "session_ended"]
        let scenarios = ["ordinary", "reentry", "append", "overwrite", "switch"]
        guard !ended, kinds.contains(kind), scenarios.contains(scenario), events < 512 || kind == "session_ended" else { throw RecorderError.limit }
        events += 1
        if kind == "observed_normal" || kind == "observed_loss" { observations += 1 }
        try Self.writeJSON(["schema": 1, "index": events, "kind": kind, "scenario": scenario, "time": ISO8601DateFormatter().string(from: Date()), "uptime": ProcessInfo.processInfo.systemUptime, "millisecondsSinceStart": Int(Date().timeIntervalSince(started) * 1000)], to: directory.appendingPathComponent(String(format: "event-%03d.json", events)))
    }
    func collect(scenario: String) throws {
        guard !ended else { throw RecorderError.inactive }
        // Detect directory replacement without following a new path.
        let verify = try Self.directoryFD(source); defer { close(verify) }
        var old = stat(), current = stat()
        guard fstat(sourceFD, &old) == 0, fstat(verify, &current) == 0, old.st_dev == current.st_dev, old.st_ino == current.st_ino else { throw RecorderError.invalidDirectory }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            guard name.range(of: "^incident-[0-9]+-[01]-[0-9A-Fa-f-]{36}\\.json$", options: .regularExpression) != nil,
                  !baseline.contains(name), !seen.contains(name) else { continue }
            guard copied < 128, bytes < 64 * 1024 * 1024 else { throw RecorderError.limit }
            let fd = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { seen.insert(name); rejected += 1; continue }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_size > 0, info.st_size <= 4 * 1024 * 1024 else { seen.insert(name); rejected += 1; continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            let trace: RecorderTrace
            do { trace = try RecorderTrace.decode(data) }
            catch { seen.insert(name); rejected += 1; continue }
            let sanitized = try JSONEncoder().encode(trace)
            guard bytes + sanitized.count <= 64 * 1024 * 1024 else { throw RecorderError.limit }
            try Self.write(sanitized, to: directory.appendingPathComponent("incidents").appendingPathComponent(name))
            seen.insert(name); copied += 1; bytes += sanitized.count
            builds.insert(trace.build)
            if trace.trigger == 1 && trace.phase == 0 { try record("hanq_manual_snapshot", scenario: scenario) }
        }
    }
    private func collectStorageStatuses()throws {
        let verify=try Self.directoryFD(source);defer{close(verify)}
        var old=stat(),current=stat()
        guard fstat(sourceFD,&old)==0,fstat(verify,&current)==0,old.st_dev==current.st_dev,old.st_ino==current.st_ino else{throw RecorderError.invalidDirectory}
        let names=try FileManager.default.contentsOfDirectory(atPath:source.path).filter{
            $0.range(of:"^\\.storage-[0-9A-Fa-f-]{36}\\.status$",options:.regularExpression) != nil
        }.sorted()
        // A status describes cumulative writes, including failures without a new
        // capture. It is separate from new event observations/baseline captures.
        guard names.count<=16 else{throw RecorderError.limit}
        for name in names {
            let fd=openat(sourceFD,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            guard fd>=0 else{rejectedStorageStatuses+=1;continue};defer{close(fd)}
            var info=stat()
            guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid==getuid(),info.st_mode & 0o077==0,info.st_size>0,info.st_size<=16*1024 else{rejectedStorageStatuses+=1;continue}
            let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:16*1024+1) ?? Data()
            guard let value=try? RecorderStorageDocument.decode(data) else{rejectedStorageStatuses+=1;continue}
            try Self.write(try JSONEncoder().encode(value),to:directory.appendingPathComponent("storage-"+String(name.dropFirst(9).dropLast(7))+".json"))
            storageStatuses+=1
        }
    }
    func finish(scenario: String) throws {
        guard !ended else { return }
        do { try collect(scenario: scenario) }
        catch RecorderError.limit { collectionWarning = "storage_limit" }
        catch { collectionWarning = "source_or_file_unavailable" }
        do {try collectStorageStatuses()} catch {collectionWarning=collectionWarning ?? "storage_status_unavailable"}
        try record("session_ended", scenario: scenario)
        try Self.writeJSON(["schema": 1, "finishedAt": ISO8601DateFormatter().string(from: Date()), "snapshots": copied, "rejectedFiles": rejected, "observations": observations, "bytes": bytes, "builds": builds.sorted(), "collectionComplete": collectionWarning == nil, "collectionWarning": collectionWarning ?? "none", "chatgptReceiptVerified": false, "storageStatuses":storageStatuses, "rejectedStorageStatuses":rejectedStorageStatuses], to: directory.appendingPathComponent("result.json"))
        ended = true
    }
    deinit { close(sourceFD) }
}
