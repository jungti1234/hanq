import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// Screen-only models cannot be serialized into replacement diagnostic files.
struct DiagnosticReviewField: Equatable {
    let label: String
    let value: String
}

struct DiagnosticReviewSection {
    let title: String
    let fields: [DiagnosticReviewField]
}

struct DiagnosticReviewDocument {
    let title: String
    let sections: [DiagnosticReviewSection]
    var exportWarnings:[String]
    init(_ title: String, _ sections: [DiagnosticReviewSection],exportWarnings:[String]=[]) {
        self.title = title; self.sections = sections;self.exportWarnings=exportWarnings
    }
    var readableText: String {
        ([title] + sections.map { section in
            section.title + "\n" + section.fields.map { "\($0.label)　\($0.value)" }.joined(separator: "\n")
        }).joined(separator: "\n\n")
    }
}

/// Supplemental current environment values, separate from the original logs
/// and from the Korean labels used to display them.
struct DiagnosticReviewEnvironment: Codable {
    enum KeyboardLayout: String, Codable, CaseIterable {
        case twoSet, threeSet, threeSet390, gongjinRoman, hancomRoman, unknownOrOther
        var title: String {
            switch self {
            case .twoSet: return "두벌식"
            case .threeSet: return "세벌식"
            case .threeSet390: return "세벌식 390"
            case .gongjinRoman: return "공진청 로마자"
            case .hancomRoman: return "한컴 로마자"
            case .unknownOrOther: return "지원 한국어 자판 이외 또는 미확인"
            }
        }
    }
    enum LoginItemState: String, Codable {
        case enabled, requiresApproval, notRegistered, unknown
        var title: String {
            switch self {
            case .enabled: return "켜짐"
            case .requiresApproval: return "승인 필요"
            case .notRegistered: return "꺼짐"
            case .unknown: return "미확인"
            }
        }
    }
    var schema = 1
    var collectedAt = Date()
    let appVersion: String
    let build: String
    let macOSVersion: String
    let modelIdentifier: String?
    let keyboardLayout: KeyboardLayout
    let koreanKeyEnabled: Bool
    let hanjaKeyEnabled: Bool
    let hudEnabled: Bool
    let capsLockSwitchEnabled: Bool?
    let loginItemState: LoginItemState
    let diagnosticsEnabled: Bool
    let inputMonitoringEnabled: Bool
    let cachedAccessibilityPermission: Bool
    let updateRestricted: Bool

    var preview: DiagnosticReviewDocument {
        func onOff(_ value: Bool) -> String { value ? "켜짐" : "꺼짐" }
        let date = DateFormatter(); date.locale = Locale(identifier: "ko_KR"); date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return DiagnosticReviewDocument("환경 정보", [
            .init(title: "앱 및 시스템", fields: [
                .init(label: "수집 시각", value: date.string(from: collectedAt)),
                .init(label: "한Q 버전", value: appVersion), .init(label: "빌드 번호", value: build),
                .init(label: "macOS 버전", value: macOSVersion), .init(label: "Mac 모델", value: modelIdentifier ?? "미확인"),
                .init(label: "현재 한국어 자판", value: keyboardLayout.title)]),
            .init(title: "기능 설정", fields: [
                .init(label: "한영키 설정", value: onOff(koreanKeyEnabled)), .init(label: "한자키 설정", value: onOff(hanjaKeyEnabled)),
                .init(label: "HUD 설정", value: onOff(hudEnabled)), .init(label: "Caps Lock 전환", value: capsLockSwitchEnabled.map(onOff) ?? "미확인"),
                .init(label: "로그인 자동 실행", value: loginItemState.title)]),
            .init(title: "실행 상태", fields: [
                .init(label: "진단 수집", value: onOff(diagnosticsEnabled)), .init(label: "입력 감시", value: onOff(inputMonitoringEnabled)),
                .init(label: "캐시된 손쉬운 사용 권한", value: cachedAccessibilityPermission ? "허용 상태" : "비허용 상태"),
                .init(label: "업데이트 정책 제한", value: onOff(updateRestricted))])])
    }
}

struct DiagnosticReviewFile {
    let path: String
    let title: String
    private let inlineData: Data?
    private let source: DiagnosticReviewSource?
    var bytes:Int {source?.bytes ?? inlineData!.count}
    // Explicit readers may materialize one file; ZIP uses bounded copying.
    var data:Data {get throws{if let source{return try source.read()};return inlineData!}}
    let previewDocument: DiagnosticReviewDocument?
    var readableText: String {
        if let previewDocument { return previewDocument.readableText }
        if path.hasSuffix(".txt"),let inlineData { return String(data: inlineData, encoding: .utf8) ?? "내용을 읽을 수 없습니다." }
        return "이 형식의 내용을 표시할 수 없습니다."
    }
    init(environment: DiagnosticReviewEnvironment) throws {
        path = "environment.json"; title = "환경 정보"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(environment);inlineData=data;source=nil
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        previewDocument = try decoder.decode(DiagnosticReviewEnvironment.self, from: data).preview
    }
    /// Interpretation is for the screen only. Never re-encode original logs.
    init(_ path: String, _ title: String, original: Data, preview: DiagnosticReviewDocument) {
        self.path = path; self.title = title; inlineData = original;source=nil;previewDocument = preview
    }
    fileprivate init(_ path:String,_ title:String,source:DiagnosticReviewSource,preview:DiagnosticReviewDocument) {
        self.path=path;self.title=title;self.source=source;inlineData=nil;previewDocument=preview
    }
    func copy(to url:URL,request:DiagnosticSnapshotRequest)throws {
        if let source{try source.copy(to:url,request:request)}
        else{try inlineData!.write(to:url,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    }
    init(summary: DiagnosticReviewDocument) {
        path = "summary.txt"; title = "요약"; inlineData = Data(summary.readableText.utf8);source=nil;previewDocument = summary
    }
}

fileprivate final class DiagnosticReviewDirectory {
    let url:URL
    var owned=false
    init(_ url:URL){self.url=url}
    deinit{if owned{try? FileManager.default.removeItem(at:url)}}
}
fileprivate struct DiagnosticReviewSource {
    // Keep the owned snapshot alive through preview and export.
    let owner:DiagnosticReviewDirectory,url:URL,bytes:Int,digest:String
    func verify(_ request:DiagnosticSnapshotRequest)throws {
        let actual=try DiagnosticArchiveIO.scan(url,maximum:DiagnosticReviewSnapshot.maximumFileBytes,check:request.check)
        guard actual.bytes==bytes,actual.digest==digest else{throw DiagnosticReviewError.invalidCapture}
    }
    func read()throws->Data {
        let data=try DiagnosticReviewSnapshot.read(url)
        guard data.count==bytes,SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==digest else{throw DiagnosticReviewError.invalidCapture}
        return data
    }
    func copy(to destination:URL,request:DiagnosticSnapshotRequest)throws {
        try DiagnosticArchiveIO.copy(url,to:destination,bytes:bytes,digest:digest,check:request.check)
    }
}
struct DiagnosticReviewOriginal {
    fileprivate let owner:DiagnosticReviewDirectory
    let filename: String
    let url: URL
    let bytes: Int
    let digest: String
    let header: DiagnosticReviewCaptureHeader
    var shared:Bool{DiagnosticSharedStore.validName(filename)}
    fileprivate var source:DiagnosticReviewSource{.init(owner:owner,url:url,bytes:bytes,digest:digest)}
    func load() throws -> (Data, DiagnosticReviewDocument) {
        let result=try review();return (try source.read(),result.document)
    }
    func review(request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest())throws->(document:DiagnosticReviewDocument,dependencies:[String:DiagnosticArchiveReader.FileEvidence]) {
        try source.verify(request)
        if shared {
            let selection=try DiagnosticArchiveReader.selection(filename,in:owner.url)
            guard selection.header.runID==header.runID,selection.header.incident==header.incident,selection.header.phase==header.phase,selection.header.trigger==header.trigger else{throw DiagnosticReviewError.invalidCapture}
            let value=try DiagnosticReviewSnapshot.object(JSONEncoder().encode(selection.metadata))
            var dependencies:[String:DiagnosticArchiveReader.FileEvidence]=[:]
            var document=try DiagnosticReviewSnapshot.capture(value,phase:header.phase){visit in
                _ = try selection.visit(check:request.check,observe:{name,evidence in
                    guard dependencies[name].map({$0==evidence}) ?? true else{throw DiagnosticReviewError.invalidCapture}
                    dependencies[name]=evidence
                }){frame in
                    // Retain typed-field validation for one frame at a time.
                    _ = try JSONDecoder().decode(InputIncidentTrace.Frame.self,from:JSONSerialization.data(withJSONObject:frame))
                    try visit(frame)
                }
            }
            guard dependencies[filename] == .init(bytes:bytes,digest:digest) else{throw DiagnosticReviewError.invalidCapture}
            document.exportWarnings=DiagnosticReviewSnapshot.coverageWarnings(value,phase:header.phase)
            return (document,dependencies)
        }
        let data=try source.read()
        guard DiagnosticReviewCaptureHeader.read(data)==header else{throw DiagnosticReviewError.invalidCapture}
        let object=try DiagnosticReviewSnapshot.object(data)
        guard object["frames"] is [[String:Any]] else{throw DiagnosticReviewError.invalidCapture}
        var document=try DiagnosticReviewSnapshot.capture(object,phase:header.phase)
        document.exportWarnings=DiagnosticReviewSnapshot.coverageWarnings(object,phase:header.phase)
        return (document,[:])
    }
}

struct DiagnosticReviewIncident {
    let id: String
    let number: Int
    let savedAt: Date?
    let title: String
    let manual: Bool
    let originals: [Int: DiagnosticReviewOriginal]
    var documents: [Int: DiagnosticReviewDocument] { get throws {try originals.mapValues{try $0.review().document}} }
    var complete: Bool { originals[0] != nil && originals[1] != nil }
}

enum DiagnosticReviewError: LocalizedError {
    case invalidCapture, emptySelection, tooManySelections, invalidArchive
    var errorDescription: String? {
        switch self {
        case .invalidCapture: return "진단 기록의 형식을 확인할 수 없습니다. 원본은 유지됩니다."
        case .emptySelection: return "저장할 기록을 하나 이상 선택해 주세요."
        case .tooManySelections: return "최대 5건까지 선택할 수 있습니다. 같은 사건의 전후 기록은 1건으로 계산합니다."
        case .invalidArchive: return "검토한 ZIP의 내용을 확인할 수 없습니다. 다시 준비해 주세요."
        }
    }
}

/// Owns an immutable copy from the existing serial writer. Closing the review
/// only deletes this copy, never the rotating store or investigation archives.
final class DiagnosticReviewSnapshot {
    static let selectionLimit = 5
    let directory: URL
    private let owner: DiagnosticReviewDirectory
    let incidents: [DiagnosticReviewIncident]
    let storage: DiagnosticReviewDocument
    private let storageData: Data
    private let sharedStatus:DiagnosticReviewFile?
    private let criticalFiles:[DiagnosticReviewFile]
    let pendingExport:DiagnosticPendingExport?
    var pendingIncidentIDs:Set<String>{pendingExport?.incidentIDs ?? []}
    private var exportWarnings:[String]=[]
    let critical:DiagnosticReviewDocument?
    var hasRecords:Bool{!incidents.isEmpty || critical != nil}
    fileprivate static let maximumFileBytes = 32 * 1024 * 1024
    init(directory: URL, request: DiagnosticSnapshotRequest=DiagnosticSnapshotRequest()) throws {
        self.directory = directory
        owner=DiagnosticReviewDirectory(directory)
        try request.check()
        let datesURL = directory.appendingPathComponent("review-dates.json")
        let dates = try JSONDecoder().decode([String: Double].self, from: Self.read(datesURL))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { file in
                if DiagnosticSharedStore.validName(file.lastPathComponent){return try DiagnosticSharedStore.readHeader(file).0.role != 1}
                return file.lastPathComponent.hasPrefix("incident-") && file.pathExtension == "json"
            }
        let catalogURL=directory.appendingPathComponent("review-catalog.json")
        let catalog:DiagnosticReviewCatalog?
        if FileManager.default.fileExists(atPath:catalogURL.path) {
            let value=try JSONDecoder().decode(DiagnosticReviewCatalog.self,from:Self.read(catalogURL))
            guard value.schema==1,Set(value.files.keys)==Set(files.filter{!DiagnosticSharedStore.validName($0.lastPathComponent)}.map(\.lastPathComponent)) else{throw DiagnosticReviewError.invalidCapture}
            catalog=value
        }else{catalog=nil}
        var groups: [String: (Int, Date?, Int, [Int: DiagnosticReviewOriginal])] = [:]
        request.report(.listing,0,files.count)
        for (index,file) in files.enumerated() {
            try request.check()
            let header:DiagnosticReviewCaptureHeader,bytes:Int,digest:String
            if DiagnosticSharedStore.validName(file.lastPathComponent) {
                let (value,_)=try DiagnosticSharedStore.readHeader(file)
                header=DiagnosticReviewCaptureHeader(schema:1,trigger:value.trigger,incident:value.incident,phase:value.phase,runID:value.runID)
                let verified=try DiagnosticArchiveIO.scan(file,maximum:Self.maximumFileBytes,check:request.check)
                bytes=verified.bytes;digest=verified.digest
            }else if let entry=catalog?.files[file.lastPathComponent] {
                guard entry.header.valid,entry.bytes>=0,entry.bytes<=Self.maximumFileBytes,
                      entry.digest.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw DiagnosticReviewError.invalidCapture}
                var info=stat()
                guard lstat(file.path,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),
                      info.st_mode&0o077==0,info.st_size==entry.bytes else{throw DiagnosticReviewError.invalidCapture}
                header=entry.header;bytes=entry.bytes;digest=entry.digest
            }else{
                // Compatibility for older snapshots: inspect one capture at a
                // time, then release its full JSON instead of retaining it.
                let data=try Self.read(file),object=try Self.object(data)
                guard let value=DiagnosticReviewCaptureHeader.read(data),object["frames"] is [[String:Any]] else{throw DiagnosticReviewError.invalidCapture}
                header=value;bytes=data.count;digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            }
            let number=header.incident,phase=header.phase,trigger=header.trigger
            let run=header.runID.flatMap{UUID(uuidString:$0)?.uuidString} ?? "legacy"
            let id = run + ":\(number)"
            let seconds = dates[file.lastPathComponent] ?? (DiagnosticSharedStore.validName(file.lastPathComponent) ? (try? DiagnosticSharedStore.readHeader(file)).map{Double($0.0.milliseconds)/1000}:nil)
            let date = seconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            var group = groups[id] ?? (number, date, trigger, [:])
            guard group.2 == trigger, group.3[phase] == nil else { throw DiagnosticReviewError.invalidCapture }
            if phase == 0 { group.1 = date }
            group.3[phase] = DiagnosticReviewOriginal(owner:owner,filename:file.lastPathComponent,url:file,bytes:bytes,digest:digest,header:header)
            groups[id] = group
            if (index+1)%64==0 || index+1==files.count{request.report(.listing,index+1,files.count)}
        }
        incidents = groups.map { key, group in
            DiagnosticReviewIncident(id: key, number: group.0, savedAt: group.1,
                title: Self.triggerTitle(group.2), manual: group.2 == 1, originals: group.3)
        }.sorted {
            if $0.savedAt != $1.savedAt { return ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
            if $0.number != $1.number { return $0.number > $1.number }
            return $0.id > $1.id
        }
        let pendingURL=directory.appendingPathComponent("pending-export.json")
        let listedIncidents=incidents
        if FileManager.default.fileExists(atPath:pendingURL.path) {
            let pending=try JSONDecoder().decode(DiagnosticPendingExport.self,from:Self.read(pendingURL))
            guard pending.schema==1,pending.captures.count<=128,
                  Set(pending.captures.map(\.file)).count==pending.captures.count,
                  pending.captures.allSatisfy({ capture in
                      DiagnosticSharedStore.validName(capture.file) &&
                      listedIncidents.contains{incident in incident.id==capture.run+":"+String(capture.incident) && incident.originals[capture.phase]?.filename==capture.file}
                  }),pending.journalFiles.allSatisfy({DiagnosticCriticalJournal.exportedName($0.key) && $0.value>0}),
                  pending.unavailableSources.allSatisfy({["shared","legacy-and-journal"].contains($0)}) else{throw DiagnosticReviewError.invalidCapture}
            pendingExport=pending
        }else{pendingExport=nil}
        storageData = try Self.read(directory.appendingPathComponent("storage-status.json"))
        let status = try Self.object(storageData)
        guard Self.integer(status["schema"]) == 1, let values = status["status"] as? [String: Any] else { throw DiagnosticReviewError.invalidCapture }
        storage = Self.storageDocument(values)
        var criticalFiles:[DiagnosticReviewFile]=[],sections:[DiagnosticReviewSection]=[],notices:[String]=[]
        if let pendingExport {
            if !pendingExport.captures.isEmpty{notices.append("원래 저장소에 저장되지 않은 상세 구간 \(pendingExport.captures.count)개를 메모리에서 복사했습니다. 목록에서 선택한 사건의 사본만 ZIP에 포함합니다. 원래 저장소의 재시도 상태는 바뀌지 않습니다.")}
            if !pendingExport.journalFiles.isEmpty{notices.append("메모리에 남아 있던 사건 기록 \(pendingExport.journalFiles.values.reduce(0,+))개를 포함합니다. 저장 파일과 중복된 사건은 실행 ID와 사건 순번으로 구분할 수 있습니다.")}
            if !pendingExport.unavailableSources.isEmpty{notices.append("원래 저장소의 일부 파일을 안전하게 읽을 수 없어 포함하지 못했습니다. 메모리 사본과 읽을 수 있는 자료만 포함하며, 기존 원본은 변경하지 않았습니다.")}
        }
        let issuesURL=directory.appendingPathComponent("storage-issues.json")
        var storageIssues:DiagnosticStorageIssueSnapshot?
        if FileManager.default.fileExists(atPath:issuesURL.path) {
            let data=try Self.read(issuesURL),snapshot=try JSONDecoder().decode(DiagnosticStorageIssueSnapshot.self,from:data)
            guard snapshot.isValid else{throw DiagnosticReviewError.invalidCapture}
            storageIssues=snapshot
            let fields=snapshot.issues.isEmpty ? [DiagnosticReviewField(label:"상태",value:"확인된 저장 문제 없음")]:snapshot.issues.map{
                DiagnosticReviewField(label:$0.component.title,value:$0.cause.title+"\n"+$0.retry.message)
            }
            let section=DiagnosticReviewSection(title:"저장 재시도 상태 · 내보내기 준비 시점",fields:fields)
            criticalFiles.append(DiagnosticReviewFile("storage-issues.json","저장 재시도 상태",original:data,preview:DiagnosticReviewDocument("저장 재시도 상태",[section])))
            sections.append(section)
        }
        func retryAdvice(_ components:Set<DiagnosticStorageIssue.Component>)->String {
            storageIssues?.exportAdvice(for:components) ?? "이 자료만으로 자동 재시도 상태를 확인할 수 없습니다."
        }
        if let pendingExport,!pendingExport.captures.isEmpty || !pendingExport.journalFiles.isEmpty {
            let state=storageIssues?.issues.map{$0.component.title+": "+$0.retry.message}.joined(separator:"\n")
            if let state,!state.isEmpty{notices.append("원래 저장소의 상태:\n"+state)}
        }
        let criticalStatusURL=directory.appendingPathComponent("critical-storage-status.json")
        if FileManager.default.fileExists(atPath:criticalStatusURL.path) {
            let data=try Self.read(criticalStatusURL),status=try JSONDecoder().decode(DiagnosticCriticalJournal.Status.self,from:data)
            guard [status.pendingErrors,status.pendingObservations,status.droppedErrors,status.droppedObservations,status.writeFailures,status.lastErrno,status.lastPolicy,status.writtenBytes,status.rotations].allSatisfy({$0>=0}) else{throw DiagnosticReviewError.invalidCapture}
            if status.pendingErrors>0,pendingExport==nil{notices.append("중요 오류 기록이 아직 저장 대기 중입니다. 이 내보내기에 해당 오류의 전체 내용이 포함되지 않을 수 있습니다.\n"+retryAdvice([.criticalErrors,.termination]))}
            if status.pendingObservations>0,pendingExport==nil{notices.append("일반 사건 기록이 아직 저장 대기 중입니다. 이 내보내기에 전체 내용이 포함되지 않을 수 있습니다.\n"+retryAdvice([.observations]))}
            if status.droppedErrors>0{notices.append("오류 기록 대기 용량을 초과해 파일에 남지 못한 오류가 있습니다.")}
            if status.droppedObservations>0{notices.append("일반 관측 기록 대기 용량을 초과해 파일에 남지 못한 관측이 있습니다.")}
            let section=DiagnosticReviewSection(title:"사건 기록 저장 상태",fields:[
                .init(label:"저장 대기 중인 오류 · 일반 사건",value:"\(status.pendingErrors) · \(status.pendingObservations)"),
                .init(label:"대기 초과 오류 · 일반 사건 (누적)",value:"\(status.droppedErrors) · \(status.droppedObservations)"),
                .init(label:"저장 실패 시도 (누적)",value:"\(status.writeFailures)")])
            let document=DiagnosticReviewDocument("사건 기록 저장 상태",[section])
            criticalFiles.append(DiagnosticReviewFile("critical-storage-status.json","사건 기록 저장 상태",original:data,preview:document))
            sections.append(section)
        }
        let sharedURL=directory.appendingPathComponent("shared-storage-status.json")
        if FileManager.default.fileExists(atPath:sharedURL.path) {
            let data=try Self.read(sharedURL),stats=try JSONDecoder().decode(DiagnosticSharedStore.Stats.self,from:data)
            if stats.pendingBytes>0,pendingExport==nil{notices.append("아직 저장 대기 중인 상세 기록은 이 내보내기에 포함되지 않습니다.\n"+retryAdvice([.detail]))}
            if stats.rejected>0{notices.append("저장 대기 용량을 초과해 상세 기록을 받지 못한 이력이 있습니다. 모든 사건의 상세가 보관되어 있다고 보장할 수 없습니다.")}
            if stats.incompleteFiles>0{notices.append("완료되지 않은 저장 파일이 있습니다. 해당 파일은 완성된 상세 기록에 포함되지 않습니다.")}
            let document=DiagnosticReviewDocument("공유 상세 저장 상태",[.init(title:"저장과 중복 제거",fields:[
                .init(label:"완료 · 대기 바이트",value:"\(stats.saved) · \(stats.pendingBytes)"),
                .init(label:"새 관측 · 재사용 관측",value:"\(stats.storedFrames) · \(stats.reusedFrames)"),
                .init(label:"실패 · 대기 초과 · 부분 파일",value:"\(stats.failures) · \(stats.rejected) · \(stats.incompleteFiles)"),
                .init(label:"누적 파일 쓰기 바이트",value:"\(stats.writtenBytes)")])])
            sharedStatus=DiagnosticReviewFile("shared-storage-status.json","공유 상세 저장 상태",original:data,preview:document)
        }else{sharedStatus=nil}
        let snapshotOwner=owner
        for name in try FileManager.default.contentsOfDirectory(atPath:directory.path).filter(DiagnosticCriticalJournal.exportedName).sorted() {
            let url=directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath:url.path) else{continue}
            try request.check()
            try autoreleasepool {
            let data=try Self.read(url)
            let source=DiagnosticReviewSource(owner:snapshotOwner,url:url,bytes:data.count,digest:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined())
            var count=0,omitted=0,dropped=[1:0,2:0]
            var first:DiagnosticCriticalJournal.Event?,last:DiagnosticCriticalJournal.Event?
            var recent:[DiagnosticCriticalJournal.Event]=[]
            let scanned=DiagnosticCriticalLane.scan(data){event in
                count+=1;if first==nil{first=event};last=event
                if event.failure.stage == .captureDisposition && event.failure.code != 1{omitted+=1}
                if event.failure.stage == .journalOverflow,[1,2].contains(event.failure.code){dropped[event.failure.code,default:0]+=event.context?.count ?? 0}
                if recent.count==20{recent.removeFirst()};recent.append(event)
            }
            guard let decoded=scanned else{
                notices.append("해석할 수 없는 사건 기록이 있습니다. 해당 원본은 그대로 포함합니다.")
                let document=DiagnosticReviewDocument("불완전한 최소 사건 기록",[.init(title:"부분 저장",fields:[.init(label:"상태",value:"파일 머리말을 읽을 수 없습니다. 원본 바이트를 보존합니다.")])])
                criticalFiles.append(DiagnosticReviewFile(name,"불완전한 최소 사건 기록",source:source,preview:document));sections+=document.sections;return
            }
            var fields:[DiagnosticReviewField]=[.init(label:"개별 사건 수",value:"\(count)"),
                .init(label:"상세 저장 대기·실패 기록",value:"\(omitted)"),
                .init(label:"해석하지 못한 부분 기록",value:"\(decoded.incomplete)"),
                .init(label:"보관 구간 번호",value:"\(decoded.generation)")]
            if decoded.incomplete>0{notices.append("일부 사건 기록이 불완전합니다. 해석하지 못한 부분도 원본에 그대로 포함합니다.")}
            if let first,let last {
                fields.append(.init(label:"최초 · 최종 기록 시각 (UTC 밀리초)",value:"\(first.milliseconds) · \(last.milliseconds)"))
            }
            for code in [1,2] {
                let dropped=dropped[code,default:0]
                if dropped>0{notices.append(code==1 ? "오류 기록 대기 용량을 초과해 파일에 남지 못한 오류가 있습니다.":"일반 관측 기록 대기 용량을 초과해 파일에 남지 못한 관측이 있습니다.")}
                if dropped>0{fields.append(.init(label:code==1 ? "대기 용량 초과로 파일에 남지 못한 오류":"대기 용량 초과로 파일에 남지 못한 일반 관측",value:"\(dropped)"))}
            }
            let summary=DiagnosticReviewSection(title:"최소 사건 기록",fields:fields)
            sections.append(summary)
            let recentSections=recent.map{event in
                DiagnosticReviewSection(title:"사건 \(event.sequence) · 단계 \(event.failure.stage.rawValue)",fields:[
                    .init(label:"실행 · 시각",value:"\(event.run) · \(event.milliseconds)"),
                    .init(label:"영역 · 코드 · errno",value:"\(event.failure.domain.rawValue) · \(event.failure.code) · \(event.failure.underlyingPOSIX)"),
                    .init(label:"상세 사건 · 첫 입력 관측 구간",value:"\(event.context?.incident ?? 0) · \(event.context?.episode ?? 0)")])
            }
            let preview=DiagnosticReviewDocument("최소 사건 기록 · 최근 20건 미리보기",[summary]+recentSections)
            criticalFiles.append(DiagnosticReviewFile(name,"최소 사건 기록",source:source,preview:preview))
            }
        }
        self.criticalFiles=criticalFiles
        critical=sections.isEmpty ? nil:DiagnosticReviewDocument("최소 사건 기록",sections)
        self.exportWarnings=notices
        owner.owned=true
    }

    fileprivate static func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DiagnosticReviewError.invalidCapture }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximumFileBytes else { throw DiagnosticReviewError.invalidCapture }
        // A failed first journal write may leave a real zero-byte file. Keep
        // that original and show the incomplete-header notice instead of
        // hiding every other record behind a failed snapshot load.
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count == Int(info.st_size) else { throw DiagnosticReviewError.invalidCapture }
        return data
    }
    fileprivate static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiagnosticReviewError.invalidCapture
        }
        return value
    }
    static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 9_000_000_000_000_000,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.intValue
    }
    private static func field(_ label: String, _ value: Any?) -> DiagnosticReviewField {
        .init(label: label, value: integer(value).map(String.init) ?? "미측정")
    }
    static func triggerTitle(_ trigger: Int) -> String {
        [1: "방금 발생한 문제 기록", 2: "입력 처리 지연 관측", 3: "접근성 조회 지연 관측",
         4: "본문 길이 감소 관측", 5: "전환 대기 중단", 6: "자동 보정 시작", 7: "공백 처리 관측", 8: "첫 입력 상세 관측"][trigger] ?? "알 수 없는 기록"
    }
    fileprivate static func capture(_ object: [String: Any], phase: Int,
        enumerate: ((([String:Any])throws->Void)throws->Void)? = nil) throws -> DiagnosticReviewDocument {
        let enumerate = enumerate ?? {visit in
            guard let frames=object["frames"] as? [[String:Any]],frames.count<=65536 else{throw DiagnosticReviewError.invalidCapture}
            for frame in frames{try visit(frame)}
        }
        var counts: [String: Int] = [:]
        var maxCallback: Int?, maxRead: Int?
        var measuredCPU = 0, maxCPU = 0
        var permissions = Set<Bool>(), cpuStates: [Int: Int] = [:]
        var sources: [String: Set<Int>] = [:]
        let states = [1: "보정 시작", 2: "보정할 범위 선택", 3: "복구 입력 전달", 4: "미전달 입력 보관",
                      5: "복구 완료 확인", 6: "감시 구간 종료", 7: "입력 소스 변경", 8: "후속 입력 임시 보관",
                      9: "첫 입력 포커스 후보 없음", 10: "첫 입력 창 탐색 상한", 11: "첫 입력 편집기 여러 개",
                      12: "첫 입력 창 탐색 중", 13: "첫 입력 인계 조건 미충족", 14: "포커스 요청 후 미확인", 15: "첫 입력 포커스 인계 확인"]
        let boundaries = [1: "편집기 반영 대기", 2: "후속 입력 대기열 보관", 3: "첫 자음 전달 확인 대기", 4: "첫 자음 전달 확인",
                          5: "전달 시각 조정", 6: "미전달 입력 보관", 7: "전환 처리 완료", 8: "전환 대기 기한 초과",
                          9: "입력 대상 변경", 10: "전환 처리 중단", 11: "선택 범위 처리", 12: "입력 소스 선택 확인",
                          13: "본문 조회 대기", 14: "본문 반영 대기", 15: "커서 반영 대기", 16: "자동 보정 대기",
                          17: "보정 결과 확인 대기", 18: "첫 자음 결과 확인 대기", 19: "복구 전달 확인 대기",
                          20: "포커스 확인 대기", 21: "전체 선택 확정 대기", 22: "입력 소스 확정 대기",
                          23: "일반 입력 재개", 24: "편집기 대소문자 표현 일치", 25: "말단 줄바꿈 표현 일치",
                          26: "편집기 표현 일치", 27: "일부 본문 반영 대기", 28: "초기 안내 본문 소멸 확인",
                          29: "수동 변환 시작", 30: "수동 변환 결과 확인", 31: "수동 변환 결과 미확인",
                          32: "첫 키 자판 대기", 33: "첫 키 두벌식 자판 확인", 34: "첫 키 자판 대기 만료",
                          35: "첫 키 입력 대상 변경", 36: "첫 키 소스 변경", 37: "첫 키 묶음 반영 확인", 38: "원래 키 전달 재개",
                          39: "입력칸 밖 전환 후 두벌식 선택·ABC 자판·오버라이드 없음", 40: "입력칸 밖 전환 후 두벌식 자판 확인",
                          41: "입력칸 밖 전환 후 자판 판정 불가", 42: "입력칸 밖 전환 후 소스 변경"]
        let sourceActions = [1: "입력 소스 관측", 2: "입력 소스 전환 요청", 3: "입력 소스 선택 확인",
                             4: "소스 조회 상충으로 확인 보류", 5: "입력 소스 재확인 후 관측 재개", 6: "소스 상태 인계 거부", 7: "영문 소스에서 관측 생략"]
        let decisions = [1: "영문 소스에서 보정 생략", 2: "입력 관측 불허", 3: "전환 전 입력으로 분류", 4: "입력칸 조회 불가",
                         5: "보정 후보에 맞지 않는 키", 6: "탐색 입력으로 후보 취소", 7: "보정 후보 관측", 8: "보정 후보 없음",
                         9: "보정 후보 기한 초과", 10: "후보와 본문 불일치", 11: "안전 조건으로 보정 불허", 12: "지원하지 않는 보정 자판",
                         13: "보정 전 본문 불일치", 14: "선택 범위 변경 불가", 15: "진행 중인 작업으로 인계 보류", 16: "인계 준비 미완료",
                         17: "외부 편집으로 인계 불허", 18: "선택 변경으로 인계 불허", 19: "입력칸 변경으로 인계 불허", 20: "소스 변경으로 인계 불허",
                         21: "경계 변경으로 인계 불허", 22: "인계할 이력 없음", 23: "인계 기한 초과", 24: "본문 불일치로 인계 불허",
                         25: "검증한 상태 인계", 26: "수동 변환 중", 27: "키보드 설정 중", 28: "첫 자음 보정 중", 29: "첫 자음 처리 예약 중",
                         30: "초기 관측 미완료", 31: "입력 관측 허용"]
        let onsetReasons = [1:"입력 전 본문 관측 없음",2:"입력 전 본문 관측 있음",3:"다른 작업으로 첫 글자 확인 보류",4:"첫 입력 소스 변경",5:"이전 표시 관측 없음",6:"첫 글자 반영 대기",7:"첫 글자 확인 기한 초과",8:"첫 입력 이력 불일치",9:"첫 입력 자판 미확인",10:"첫 글자와 본문 불일치",11:"첫 글자 부분 반영 대기",12:"첫 글자 반영 확인",13:"첫 글자 확인 유지",14:"첫 글자 확인 무효화",15:"후속 본문 반영 대기",16:"정상 조합 확인",17:"후속 본문과 입력 이력 불일치",18:"후속 입력 복구 후보 확인",19:"누른 키의 놓음 대기",20:"복구 인수 거절",21:"복구 인수 확인",22:"복구 안전 조건 미충족",23:"첫 입력칸 변경",24:"편집 없는 첫 입력 예약 해제",25:"첫 입력 선택 변경 불가"]
        let onsetDetails:[(String,[String])]=[
            ("switchKey",["미측정","전환 직후 첫 키 확인","유효한 전환 기록 없음","첫 키 시각 없음","첫 키 미관측","다른 첫 키","전환 기한 초과","전면 앱 변경","전환 때 창 미확인","현재 창 미확인","전환 창 변경","재전송 전 자판 미준비","첫 키 때 창 미확인","첫 키 때 창 변경","전환 직전 창과 첫 키 확인"]),
            ("draftRead",["미측정","입력 전 초안·커서 관측","초안 속성 확인 불가","초안 역할·보안 조건","초안 값 확인 불가","초안 크기 상한","입력칸 활성 미확인","입력칸 표시 여부 미확인","초안 소속 창 미확인","초안 선택 조회 불가","초안 문맥 미확인","초안 커서 미확인","초안 조회 기한","초안 관측기 없음"]),
            ("draftLookup",["미측정","입력 전 기준 확인","같은 입력칸 초안 확인","같은 입력칸 초안 기록 없음","첫 키 이전 초안 기록 없음","초안 기록 기한 초과","초안 재확인 때 창 미확인","초안 재확인 때 창 변경","초안 비교 기준 부적합"]),
            ("insertedSpan",["미측정","삽입 범위·커서 조건","입력 시작이 영문 아님","삽입 앞뒤 초안 불일치","새 글자와 키 이력 불일치","일부 키 반영 대기","새 글자·앞뒤 초안 일치"]),
            ("discovery",["미측정","문맥 확인 불가","창 확인 불가","초점 확인 불가","탐색 진행 중","입력칸 미발견","단일 입력칸 탐색 완료","복수 입력칸","탐색 불완전","탐색 상한"]),
            ("representation",["미측정","표시 표본 저장","속성 묶음 조회 불가","역할·보안 조건","표시 값 조회 불가","빈 표시·크기 조건","문자 수 조회 불가","문자 수 불일치","시작 커서 조건","비활성·숨김","표시 창 조회 불가","표시 창 변경","표시 문맥 확인 불가","표시 조회 기한"]),
            ("lookup",["미측정","유효 표본 확인","같은 입력칸 표본 없음","입력 전 표본 없음","입력 전 표본 기한","시계 불일치","표본 보관 기한","준비 조건 상실","전면·소유 관계 변경","현재 창 조회 불가","현재 창 변경","조회 후 준비 조건 상실","조회 후 전면 변경"]),
            ("history",["미측정","이력 개수 조건","선택·범위 조건","이력 자판 미확인","첫 자음 조건","Shift 공백 제외","지원하지 않는 입력 위치","후속 모음 조건","전체 본문·커서 불일치"])
        ]
        if let coverage=object["coverage"] as? [String:Any] {
            counts["요청 구간(ms) \(integer(coverage["requestedFromMilliseconds"]) ?? 0)…\(integer(coverage["requestedThroughMilliseconds"]) ?? 0)",default:0]+=1
            counts["확보 관측",default:0]+=integer(coverage["frames"]) ?? 0
            counts["관측 순번 공백(키 누락 판정 아님)",default:0]+=integer(coverage["sequenceGaps"]) ?? 0
            counts["메모리 용량으로 만료한 과거 관측",default:0]+=integer(coverage["historyByteEvictions"]) ?? 0
        }
        var frameCount=0
        try enumerate { frame in
            frameCount+=1;guard frameCount<=65536 else{throw DiagnosticReviewError.invalidCapture}
            let kind = integer(frame["kind"]) ?? 0, code = integer(frame["category"]) ?? 0
            let duration = integer(frame["durationMicros"])
            let validWall = (frame["workEvidence"] as? [String: Any])?["clockValid"] as? Bool != false
            if kind == 1 {
                let state = (frame["workEvidence"] as? [String: Any]).flatMap { integer($0["cpuState"]) } ?? 0
                cpuStates[state, default: 0] += 1
                if validWall, let duration { maxCallback = max(maxCallback ?? 0, duration) }
                if let work = frame["workEvidence"] as? [String: Any], integer(work["cpuState"]) == 1,
                   let cpu = integer(work["cpuMicros"]) { measuredCPU += 1; maxCPU = max(maxCPU, cpu) }
            }
            // Read starts carry a placeholder zero; only completed, valid spans
            // can supply a duration. Legacy completed spans have no workEvidence.
            if kind == 2, code == 2, validWall, let duration { maxRead = max(maxRead ?? 0, duration) }
            if kind == 2,code == 2 {
                let label=integer(frame["readOutcome"]).flatMap{InputIncidentTrace.ReadOutcome(rawValue:$0)}?.label ?? "조회 결과 미측정"
                let lane=integer(frame["lane"]) == 6 ? "첫 자음" : "불일치"
                counts["\(lane) 조회: \(label)",default:0]+=1
                if let focus=frame["focusEvidence"] as? [String:Any] {
                    if let code = integer(focus["markedRangeState"]), integer(focus["path"]) == 1,
                       let state = InputIncidentMarkedRange(rawValue: code) {
                        counts["첫 자음 조합 범위 · " + state.label, default: 0] += 1
                    }
                    let roles=["역할 미측정","역할 조회 불가","텍스트 영역","텍스트 필드","콤보 상자","웹 영역","그룹","버튼","창","앱","기타 역할"]
                    let relations=["요소 미확인","첫 관측·관측 공백 뒤","같은 요소","다른 요소"]
                    if let role=integer(focus["role"]),roles.indices.contains(role),
                       let relation=integer(focus["elementRelation"]),relations.indices.contains(relation) {
                        let path=integer(focus["path"]) == 3 ? "불일치 유휴" : lane
                        counts["\(path) 포커스: \(roles[role]) · \(relations[relation])",default:0]+=1
                    }
                }
            }
            // Counts simplify the preview. The exported file retains all original
            // frames, times, links, classifications and other diagnostic evidence.
            if kind == 6 { counts[states[code] ?? "해석하지 못한 처리 상태", default: 0] += 1 }
            if kind == 7 { counts[boundaries[code] ?? "해석하지 못한 경계 상태", default: 0] += 1 }
            if kind == 15,let raw=frame["onsetObservation"] as? [String:Any],let evidence=InputIncidentTrace.OnsetObservation.parse(raw) {
                counts[evidence.summary,default:0]+=1
            }
            if kind == 14,let raw=frame["boundaryEvidence"] as? [String:Any],let evidence=InputIncidentTrace.BoundaryEvidence.parse(raw) {
                counts["전환 범위 비교: "+evidence.resolutionLabel,default:0]+=1
                if evidence.suppressed>0 {counts["전환 비교 변화 기록 상한 도달",default:0]+=1}
            }
            if kind == 8 { counts[decisions[code] ?? "해석하지 못한 판단 사유", default: 0] += 1 }
            if kind == 13 {
                counts[onsetReasons[code] ?? "해석하지 못한 첫 입력 판단", default: 0] += 1
                if let detail=(frame["onsetEvidence"] as? [String:Any])?["detail"] as? [String:Any] {
                    for (key,labels) in onsetDetails {
                        if let value=integer(detail[key]),value>0,labels.indices.contains(value){counts["첫 입력 세부: \(labels[value])",default:0]+=1}
                    }
                }
            }
            if kind == 10 {
                let action = integer(frame["edge"]) ?? 0
                counts[sourceActions[action] ?? "해석하지 못한 소스 관측", default: 0] += 1
                if let source = frame["sourceEvidence"] as? [String: Any] {
                    for key in ["selected", "confirmed", "target"] {
                        if let code = integer(source[key]) { sources[key, default: []].insert(code) }
                    }
                }
            }
            if let control = frame["controlEvidence"] as? [String: Any], let runtime = integer(control["runtime"]) {
                permissions.insert(runtime & 2 != 0)
            }
        }
        let permission = permissions.isEmpty ? "미측정" : permissions.count > 1 ? "허용·비허용 상태 모두 관측" : permissions.contains(true) ? "허용 상태 관측" : "비허용 상태 관측"
        let build = (object["build"] as? String).flatMap { $0.range(of: "^[0-9]{1,9}$", options: .regularExpression) != nil ? $0 : nil } ?? "미확인"
        var coverage = [DiagnosticReviewField(label: "기록 당시 앱 빌드", value: build),
                        .init(label: "캐시된 손쉬운 사용 권한", value: permission),
                        field("최근 관측 덮어쓰기 수", object["discardedOldFrames"])]
        if let sample = object["keyboardOrigin"] as? [String: Any], let status = integer(sample["status"]) {
            let names = [1: "조회 가능", 2: "입력 모니터링 권한 필요", 3: "내장 키보드 식별 불가",
                         4: "장치 열기 실패", 5: "관측 공백"]
            let bursts = sample["bursts"] as? [[String: Int]] ?? []
            coverage.append(.init(label: "내장 키보드 비교", value: names[status] ?? "미측정"))
            let unusual = bursts.filter { ($0["quartzDown"] ?? 0) > 1 || $0["deviceDown"] != $0["quartzDown"] }
            for burst in unusual.suffix(8) {
                guard let seq = burst["firstSequence"], let d = burst["deviceDown"], let q = burst["quartzDown"] else { continue }
                let verdict = [0: "판정 보류", 1: "횟수 일치", 2: "Quartz 쪽 추가 관측"][burst["outcome"] ?? 0] ?? "미측정"
                coverage.append(.init(label: "문자키 누름 #\(seq)", value: "내장 \(d)회 · Quartz \(q)회 · \(verdict) · 자동 반복 \(burst["repeatDown"] ?? 0)회 · 생성 프로세스 표기 \(burst["reportedProcessDown"] ?? 0)회"))
            }
        }
        if let preservation = object["capturePreservation"] as? [String: Any] {
            coverage.append(field("후속 관측 초과 수", preservation["postOmittedFrames"]))
            if let ended = preservation["endedOnShutdown"] as? Bool, ended {
                coverage.append(.init(label: "종료 상태", value: "앱 종료로 후속 기록 구간이 짧아졌습니다."))
            }
            let reasons = [1: "영문 결과 불일치", 2: "영문·한글 혼합 삽입", 3: "분리 자모", 4: "중단된 조합", 5: "조각난 조합",
                           6: "검증된 선택 대체", 7: "첫 자음 분리", 8: "지연된 첫 단어", 9: "확정 뒤 지연된 첫 단어", 10: "세부 사유 미측정"]
            if let requests = preservation["requests"] as? [[String: Any]],
               let request = requests.first(where: { integer($0["trigger"]) == 6 }), let detail = integer(request["detail"]) {
                coverage.append(.init(label: "최초 보정 감지 사유", value: reasons[detail] ?? "해석하지 못한 감지 사유"))
            }
            if let requests=preservation["requests"] as? [[String:Any]] {
                let labels=[1:"짧은 간격의 공백 누름",2:"공백 소비·보관 단서",3:"한Q 재전송 표식",4:"공백 반복 플래그"]
                let observed=Set(requests.filter{integer($0["trigger"])==7}.compactMap{integer($0["detail"])})
                if !observed.isEmpty {
                    coverage.append(.init(label:"공백 관측 조건",value:observed.sorted().compactMap{labels[$0]}.joined(separator:", ")))
                    coverage.append(.init(label:"해석 범위",value:"공백 처리 관측이며 중복 결과나 원인을 확정하지 않습니다."))
                }
            }
        }
        var sections = [DiagnosticReviewSection(title: "확인 범위", fields: coverage),
                        .init(title: "관측된 처리 상태", fields: counts.isEmpty ? [.init(label: "처리 상태", value: "기록된 내역 없음")] : counts.keys.sorted().map { .init(label: $0, value: "\(counts[$0]!)회") }),
                        .init(title: "처리 시간", fields: [
                            .init(label: "최대 입력 처리 시간", value: maxCallback.map { "\($0)µs (기록된 부분 구간·미계측 포함)" } ?? "미측정"),
                            .init(label: "최대 접근성 조회 시간", value: maxRead.map { "\($0)µs (완료된 조회 구간)" } ?? "미측정"),
                            .init(label: "같은 스레드 CPU 최대", value: measuredCPU == 0 ? "미측정" : "\(maxCPU)µs"),
                            .init(label: "CPU 미계측 관측 수", value: "\(cpuStates[0, default: 0])"),
                            .init(label: "CPU 조회 실패 관측 수", value: "\(cpuStates[2, default: 0])"),
                            .init(label: "스레드 변경 관측 수", value: "\(cpuStates[3, default: 0])"),
                            .init(label: "CPU 계수 역전 관측 수", value: "\(cpuStates[4, default: 0])"),
                            .init(label: "시각 역전 관측 수", value: "\(cpuStates[5, default: 0])")])]
        let sourceNames = [0: "미확인", 1: "두벌식", 2: "세벌식", 3: "세벌식 390", 4: "공진청 로마자", 5: "한컴 로마자", 6: "시스템 키보드 배열", 7: "기타 입력 소스"]
        if !sources.isEmpty {
            sections.append(.init(title: "기록 당시 관측한 입력 소스 분류", fields: [("selected", "조회값"), ("confirmed", "관찰기로 확인한 값"), ("target", "전환 목표")].map { key, label in
                .init(label: label, value: sources[key].map { $0.sorted().map { sourceNames[$0] ?? "미확인" }.joined(separator: " · ") } ?? "미측정")
            }))
        }
        if let failures=object["recoveryFailures"] as? [[String:Int]],!failures.isEmpty {
            let stageNames=["retryKorean":"한글 재시도", "retry_korean":"재시도 직전 편집기 조회",
                            "attemptRollback":"롤백", "awaitSelection":"선택 확인", "verifyBuffered":"후속 입력 확인",
                            "safariReturnSelection":"Safari 한국어 자판 복귀 경로 선택", "onset.awaitPrefix":"첫 자음 재입력 결과 확인",
                            "onset.drain":"첫 자음 후속 키 전달", "onset.gateAcknowledged":"첫 자음 키 통과 확인",
                            "onset.awaitSelection":"첫 자음 선택 반영 확인", "safariModifierRelease":"Safari 전환 키 놓음 확인", "safariInputActivation":"Safari 한국어 입력기 재활성화", "safariActivationRetry":"Safari 한국어 자판 재요청 결과 확인"]
            let conditionNames=["prefix_text_mismatch":"기한까지 편집기 본문에 예상 조합이 나타나지 않음", "snapshot_unavailable":"편집기 상태를 읽을 수 없음",
                                "replay_acknowledgment_timeout":"기한까지 재입력 이벤트 통과가 확인되지 않음",
                                "outbound_not_observed":"직전 Safari 한글→영어 전환 근거가 없음", "round_trip_unconfirmed":"직전 영어 전환 완료가 확인되지 않음", "abc_layout_unconfirmed":"ABC 자판을 확인할 수 없음",
                                "layout_override_present":"입력기 자판 오버라이드가 남아 있음", "web_editor_unconfirmed":"편집 가능한 웹 입력칸을 확인할 수 없음",
                                "snapshot_text_changed":"재조회한 본문이 달라짐", "snapshot_selection_changed":"재조회한 선택 범위가 달라짐",
                                "source_changed":"입력 소스가 복구 대상과 다름", "field_changed":"입력칸이 달라짐",
                                "candidate_caret_mismatch":"커서가 예상 위치와 다름", "candidate_surroundings_changed":"주변 본문이 달라짐",
                                "candidate_roman_mismatch":"입력 구간이 예상 영문과 다름", "candidate_literal_mismatch":"입력 구간이 확인된 문자열과 다름",
                                "deadline":"확인 기한 경과", "selection_failed":"선택 범위 설정 실패", "rollback_text_changed":"롤백 대상 본문이 달라짐",
                                "previous_source_changed":"시스템의 직전 입력 소스가 두벌식으로 확인되지 않음",
                                "modifier_release_timeout":"전환 중 보조 키가 계속 눌려 있음", "shortcut_unavailable":"입력 소스 전환 단축키를 시작할 수 없음",
                                "source_switch_timeout":"기한 안에 목표 입력 소스가 확인되지 않음", "focus_changed":"전환 중 입력칸이 달라짐",
                                "recipient_changed":"입력을 받을 앱이 달라짐", "input_unavailable":"입력 전달 권한 또는 보안 입력 조건 불충족"]
            let fields=failures.suffix(16).compactMap { row -> DiagnosticReviewField? in
                guard let time=row["milliseconds"],let action=row["action"],let stage=row["stage"],let condition=row["condition"],
                      InputIncidentTrace.RecoveryFailure.stages.indices.contains(stage),
                      InputIncidentTrace.RecoveryFailure.conditions.indices.contains(condition) else{return nil}
                let operation=[1:"롤백 시작", 2:"보관 후 중단", 3:"전환 보완 중단", 4:"기본 전환 사용"][action] ?? "중단"
                let step=InputIncidentTrace.RecoveryFailure.stages[stage],reason=InputIncidentTrace.RecoveryFailure.conditions[condition]
                let detail=conditionNames[reason].map{"\($0) (\(reason))"} ?? reason
                return .init(label:"기록 시작 후 \(time)ms · \(operation)",value:"\(stageNames[step] ?? step) · \(detail)")
            }
            if !fields.isEmpty {sections.append(.init(title:"최근 자동 복구 실패 단계와 조건",fields:fields))}
        }
        if let status=object["monitorStatus"] as? [String:Any],let current=status["current"] as? [String:Any] {
            let reasons=[0:"실행 가능",1:"감시 제어 꺼짐",2:"입력 사용 불가",3:"별도 시험 감시 실행 중",4:"손쉬운 사용 권한 없음",5:"보안 입력",6:"실행 옵션으로 꺼짐",7:"입력 탭 비활성",8:"재등록 횟수 제한",9:"안전 조건으로 재등록 보류",10:"감시 등록 실패",11:"재시도 간격 대기"]
            func state(_ key:String)->String{(current[key] as? Bool).map{$0 ? "예":"아니요"} ?? "미측정"}
            sections.append(.init(title:"자동 복구 감시",fields:[
                .init(label:"감시 등록",value:state("enabled")),.init(label:"감시 중단",value:state("suspended")),
                .init(label:"현재 판단",value:integer(current["reason"]).flatMap{reasons[$0]} ?? "미측정"),
                .init(label:"탭 상태",value:integer(current["tapState"]).flatMap{[0:"미확인",1:"활성",2:"비활성"][$0]} ?? "미측정"),
                field("감시 입력 수신 누적",current["receivedEvents"]),field("마지막 수신 경과 (µs, 최대 60초)",current["lastEventAgeMicros"]),
                field("감시 등록 시도",current["attempts"]),field("감시 중단 알림",current["failures"]),
                .init(label:"최근 중단 유형",value:integer(current["stopReason"]).flatMap{[0:"미측정",1:"입력 탭 장애",2:"전환 감시 장애",3:"입력 사용 불가",4:"입력 감시 종료",5:"기타 중단",6:"입력 보존을 위한 안전 중단"][$0]} ?? "미측정"),
                .init(label:"안전 재등록 허용",value:state("restartAllowed")),field("보관 입력",current["retained"]),
                field("대기 입력",current["pending"]),field("오래된 상태 전환 제외",status["discardedTransitions"])]))
        }
        for (key, title) in [("observationDelivery", "관측 전달 · 실행 누적"), ("decisionDelivery", "판단 전달 · 실행 누적"), ("captureBacklog", "저장 요청 · 실행 누적")] {
            guard let counters = object[key] as? [String: Any] else { continue }
            let names = [("overflow", "자리 부족"), ("omitted", "관측 생략"), ("coalesced", "반복 관측 묶음"),
                         ("requestOverflow", "요청 자리 부족"), ("windowOverflow", "보호 구간 초과"),
                         ("postOverflow", "후속 관측 초과"), ("discardedOnDisable", "수집 OFF로 취소")]
            let fields = names.compactMap { key, label -> DiagnosticReviewField? in
                guard let values = counters[key] as? [String: Any] else { return nil }
                let total = values.values.compactMap(integer).reduce(0) { min(9_000_000_000_000_000, $0 + $1) }
                return .init(label: label, value: "\(total)")
            }
            if !fields.isEmpty { sections.append(.init(title: title, fields: fields)) }
        }
        return DiagnosticReviewDocument(phase == 0 ? "발생 전 상태" : "발생 후 상태", sections)
    }
    private static func storageDocument(_ status: [String: Any]) -> DiagnosticReviewDocument {
        func usage(_ prefix: String) -> String {
            let count = integer(status[prefix + "Files"]).map { "\($0)개" } ?? "파일 수 미확인"
            let bytes = integer(status[prefix + "Bytes"]).map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "용량 미확인"
            return count + " · " + bytes
        }
        var issues = [("limited", "한도로 저장 생략"), ("retired", "기한 경과로 저장 생략"),
                      ("unavailable", "저장 불가"), ("encodingFailures", "진단 파일 생성 실패"),
                      ("statusWriteFailures", "저장 상태 기록 실패")].compactMap { key, label -> DiagnosticReviewField? in
            guard let count = integer(status[key]) else { return .init(label: label, value: "미확인") }
            return count > 0 ? .init(label: label, value: "\(count)회") : nil
        }
        if let budget=status["writeBudget"] as? [String:Any] {
            for (key,label) in [("suppressedAutomatic","누적 쓰기 한도로 자동 기록 생략"),
                                ("suppressedManual","누적 쓰기 한도로 수동 기록 생략"),
                                ("persistenceFailures","쓰기 예산 저장 실패")] {
                if let count=integer(budget[key]),count>0{issues.append(.init(label:label,value:"\(count)회"))}
            }
        }
        return DiagnosticReviewDocument("저장 상태", [
            .init(title: "보관 중인 파일", fields: [
                .init(label: "자동 기록", value: usage("automatic")), .init(label: "수동 기록", value: usage("manual"))]),
            .init(title: "저장 실패·생략 내역 (누적)", fields: issues.isEmpty
                ? [.init(label: "저장 실패·생략", value: "기록된 내역 없음")] : issues)])
    }
    func files(selected: Set<String>, environment: DiagnosticReviewEnvironment,request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest(),allPending:Bool=false) throws -> [DiagnosticReviewFile] {
        try request.check()
        let chosen = incidents.filter { selected.contains($0.id) }
        guard (!chosen.isEmpty || !criticalFiles.isEmpty), chosen.count == selected.count else { throw DiagnosticReviewError.emptySelection }
        guard allPending ? selected==pendingIncidentIDs:chosen.count <= Self.selectionLimit else { throw DiagnosticReviewError.tooManySelections }
        var warnings=exportWarnings
        if chosen.contains(where:{!$0.complete}){warnings.append("선택한 기록 중 발생 전 또는 후 기록이 없는 항목이 있습니다. 보관된 부분만 포함합니다.")}
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let preview = DiagnosticReviewDocument("요약", [
            .init(title: "선택한 기록", fields: [.init(label: "기록 수", value: "\(chosen.count)건")])
        ] + chosen.enumerated().map { index, incident in
            let phases = incident.complete ? "발생 전·후 모두 있음"
                : (incident.originals[0] == nil ? "발생 전 기록 없음" : "발생 후 기록 없음")
            return DiagnosticReviewSection(title: "기록 \(index + 1) · \(incident.title)", fields: [
                .init(label: "저장 시각", value: incident.savedAt.map(formatter.string) ?? "미확인"),
                .init(label: "전후 기록", value: phases)])
        })
        var files = [DiagnosticReviewFile(summary: preview), try DiagnosticReviewFile(environment: environment)]
        var dependencies:[String:DiagnosticArchiveReader.FileEvidence]=[:]
        for (index, incident) in chosen.enumerated() {
            for phase in [0, 1] {
                if let original = incident.originals[phase] {
                    try request.check()
                    let reviewed=try original.review(request:request)
                    warnings+=reviewed.document.exportWarnings
                    for (name,evidence) in reviewed.dependencies {
                        guard dependencies[name].map({$0==evidence}) ?? true else{throw DiagnosticReviewError.invalidCapture}
                        dependencies[name]=evidence
                    }
                    files.append(DiagnosticReviewFile(original.filename, "사건 \(index + 1) · \(reviewed.document.title)",
                        source:original.source,preview:reviewed.document))
                }
            }
        }
        var included=Set(files.map(\.path))
        for name in dependencies.keys.sorted() where included.insert(name).inserted {
            try request.check()
            let url=directory.appendingPathComponent(name)
            let verified=dependencies[name]!
            let source=DiagnosticReviewSource(owner:owner,url:url,bytes:verified.bytes,digest:verified.digest)
            try source.verify(request)
            files.append(DiagnosticReviewFile(name,"공유 전후 관측",source:source,preview:DiagnosticReviewDocument("공유 전후 관측",[.init(title:"함께 저장하는 자료",fields:[.init(label:"내용",value:"선택한 사건을 복원하는 공유 관측과 메타데이터입니다. 공유 구간과 공통 정보에 필요한 다른 사건의 일부 정보가 포함될 수 있습니다.")])])))
        }
        let selectedOriginals=chosen.flatMap{Array($0.originals.values)}.map(\.filename).sorted()
        let sharedDependencies=files.map(\.path).filter{DiagnosticSharedStore.validName($0) && !selectedOriginals.contains($0)}.sorted()
        if !sharedDependencies.isEmpty || selectedOriginals.contains(where:DiagnosticSharedStore.validName){
            let manifest=try JSONSerialization.data(withJSONObject:["schema":1,"captures":selectedOriginals,"sharedDependencies":sharedDependencies],options:[.sortedKeys])
            files.append(DiagnosticReviewFile("selection-manifest.json","선택한 원본과 공유 자료",original:manifest,preview:DiagnosticReviewDocument("선택한 원본과 공유 자료",[.init(title:"내보내기 구성",fields:[.init(label:"선택한 원본 파일",value:selectedOriginals.joined(separator:"\n")),.init(label:"공유 자료 수",value:"\(sharedDependencies.count)")])])))
        }
        if let sharedStatus{files.append(sharedStatus)}
        if var pending=pendingExport {
            let selectedNames=Set(selectedOriginals)
            pending.captures=pending.captures.filter{selectedNames.contains($0.file)}
            let data=try JSONEncoder().encode(pending)
            files.append(DiagnosticReviewFile("pending-export.json","메모리에서 복사한 기록",original:data,preview:DiagnosticReviewDocument("메모리에서 복사한 기록",[.init(title:"원래 저장소와 별도로 보존",fields:[
                .init(label:"선택한 상세 구간",value:"\(pending.captures.count)개"),
                .init(label:"메모리의 사건 기록",value:"\(pending.journalFiles.values.reduce(0,+))개"),
                .init(label:"원래 저장 상태",value:"내보내기는 별도 사본입니다. 원래 저장소의 저장 완료를 뜻하지 않습니다.")])])))
        }
        files.append(contentsOf:criticalFiles)
        files.append(DiagnosticReviewFile("storage-status.json", "저장 상태", original: storageData, preview: storage))
        var seen=Set<String>();warnings=warnings.filter{seen.insert($0).inserted}
        let notes=warnings.isEmpty ? []:[DiagnosticReviewSection(title:"포함 범위 안내",fields:warnings.map{.init(label:"확인된 제한",value:$0)})]
        files[0]=DiagnosticReviewFile(summary:DiagnosticReviewDocument(preview.title,notes+preview.sections,exportWarnings:warnings))
        return files
    }
    fileprivate static func coverageWarnings(_ value:[String:Any],phase:Int)->[String] {
        var result:[String]=[]
        if let p=value["capturePreservation"] as? [String:Any],phase==1 {
            if (integer(p["postOmittedFrames"]) ?? 0)>0{result.append("선택한 기록에 용량 제한으로 담지 못한 후속 관측이 있습니다.")}
            if p["endedOnShutdown"] as? Bool == true{result.append("앱 종료로 후속 기록 구간이 짧아진 항목이 있습니다.")}
        }
        if let coverage=value["coverage"] as? [String:Any],(integer(coverage["sequenceGaps"]) ?? 0)>0{result.append("선택한 기록의 관측 순번에 공백이 있습니다. 실제 키 입력의 누락을 뜻하지는 않습니다.")}
        return result
    }
}

final class DiagnosticReviewArchive {
    let directory: URL
    let url: URL
    let files: [DiagnosticReviewFile]
    let bytes: Int
    let sourceBytes: Int
    var warningMessage:String? {
        let warnings=files.first?.previewDocument?.exportWarnings ?? []
        return warnings.isEmpty ? nil:warnings.joined(separator:"\n")
    }
    private let digest: String
    init(files: [DiagnosticReviewFile],request:DiagnosticSnapshotRequest=DiagnosticSnapshotRequest()) throws {
        try request.check()
        guard !files.isEmpty, Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ file in
                  !file.path.hasPrefix("/") && !file.path.hasSuffix("/") &&
                  file.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
              }) else { throw DiagnosticReviewError.invalidArchive }
        self.files = files; sourceBytes = files.reduce(0) { $0 + $1.bytes }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HanQ-Review-ZIP-" + UUID().uuidString)
        url = directory.appendingPathComponent("진단기록.zip")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let space=try fm.attributesOfFileSystem(forPath:directory.path)[.systemFreeSize] as? NSNumber
            guard let space,space.uint64Value>=UInt64(sourceBytes)*2+256*1024*1024 else{throw DiagnosticLogExport.Failure.insufficientSpace}
            let contents = directory.appendingPathComponent("HanQ-Diagnostics")
            try fm.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in files {
                try request.check()
                let target = contents.appendingPathComponent(file.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try file.copy(to:target,request:request)
            }
            try DiagnosticLogExport.compress(contents, to: url,request:request)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let verified=try DiagnosticArchiveIO.scan(url,maximum:Int.max,check:request.check)
            bytes=verified.bytes;digest=verified.digest
        } catch { try? fm.removeItem(at: directory); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    /// Publish the already-reviewed ZIP, not a fresh read of the live store.
    func save(to destination: URL) throws {
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".HanQ-Review-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        guard bytes>0 else{throw DiagnosticReviewError.invalidArchive}
        try DiagnosticArchiveIO.copy(url,to:temporary,bytes:bytes,digest:digest)
        guard rename(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
