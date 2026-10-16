import Foundation
import Darwin

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

struct RecorderFrame: Codable {
    let sequence, milliseconds, lane, kind, event, edge, category, inputOrigin: Int
    let consumed: Bool
    let durationMicros, count: Int
    let selected: Bool
    let field: Int
}

struct RecorderTrace: Codable {
    let schema: Int
    let build: String
    let bestEffort, appReceiptVerified, correlationIsHeuristic, lossCountersMayLag: Bool
    let skippedEvents, skippedAuxiliary: [String: Int]
    let trigger, incident, phase, discardedOldFrames: Int
    let frames: [RecorderFrame]

    static func decode(_ data: Data) throws -> RecorderTrace {
        guard data.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "build", "bestEffort", "appReceiptVerified", "correlationIsHeuristic", "lossCountersMayLag", "skippedEvents", "skippedAuxiliary", "trigger", "incident", "phase", "discardedOldFrames", "frames"]),
              let rows = object["frames"] as? [[String: Any]], rows.count <= 16384 else { throw RecorderError.invalidTrace }
        let keys = Set(["sequence", "milliseconds", "lane", "kind", "event", "edge", "category", "inputOrigin", "consumed", "durationMicros", "count", "selected", "field"])
        guard rows.allSatisfy({ Set($0.keys) == keys }) else { throw RecorderError.invalidTrace }
        let value = try JSONDecoder().decode(RecorderTrace.self, from: data)
        guard value.schema == 1, value.build.range(of: "^(?:[0-9]{1,9}|test)$", options: .regularExpression) != nil,
              (1...5).contains(value.trigger), value.incident > 0, (0...1).contains(value.phase),
              value.discardedOldFrames >= 0,
              [value.skippedEvents, value.skippedAuxiliary].allSatisfy({ dict in
                  dict.count <= 8 && dict.allSatisfy { Int($0.key).map { (1...8).contains($0) } == true && $0.value >= 0 }
              }),
              value.frames.allSatisfy({ $0.sequence > 0 && $0.milliseconds >= 0 && (1...8).contains($0.lane) && (1...7).contains($0.kind) && $0.durationMicros >= 0 && $0.count >= 0 && $0.field >= 0 }) else { throw RecorderError.invalidTrace }
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
    func finish(scenario: String) throws {
        guard !ended else { return }
        do { try collect(scenario: scenario) }
        catch RecorderError.limit { collectionWarning = "storage_limit" }
        catch { collectionWarning = "source_or_file_unavailable" }
        try record("session_ended", scenario: scenario)
        try Self.writeJSON(["schema": 1, "finishedAt": ISO8601DateFormatter().string(from: Date()), "snapshots": copied, "rejectedFiles": rejected, "observations": observations, "bytes": bytes, "builds": builds.sorted(), "collectionComplete": collectionWarning == nil, "collectionWarning": collectionWarning ?? "none", "chatgptReceiptVerified": false], to: directory.appendingPathComponent("result.json"))
        ended = true
    }
    deinit { close(sourceFD) }
}
