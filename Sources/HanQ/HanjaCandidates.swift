import Foundation
import Darwin

/// Only a successful empty lookup may suppress Apple's candidate request.
enum HanjaCandidateAvailability: String, Codable {
    case available, none, unknown

    var shouldRequestCandidates: Bool { self != .none }
}

struct HanjaCandidateResult: Codable {
    let status: HanjaCandidateAvailability
    let candidates: [String]
    static let unknown = HanjaCandidateResult(status: .unknown, candidates: [])
    static let none = HanjaCandidateResult(status: .none, candidates: [])
}

enum HanjaCandidates {
    static let probeArgument = "--hanja-candidate-probe"
    static let listProbeArgument = "--hanja-candidates-list-probe"
    private static let queue = DispatchQueue(label: "taek.in.hanq.hanja-candidates")
    static var systemDictionary: URL {
        let root = URL(fileURLWithPath: "/System/Library/Input Methods/KoreanIM.app/Contents")
        let suffix = "Resources/HanjaTool.app/Contents/Resources/KoreanSystemDictionary.dictionary"
        let extensionURL = root.appendingPathComponent("PlugIns/KIM_Extension.appex/Contents/" + suffix)
        return FileManager.default.fileExists(atPath: extensionURL.path)
            ? extensionURL : root.appendingPathComponent(suffix)
    }
    static var userDictionary: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Dictionaries/KoreanHanjaUserIDXDictionary")
    }

    static func lookup(_ text: String, completion: @escaping (HanjaCandidateAvailability) -> Void) {
        let executable = Bundle.main.executableURL
        queue.async {
            let result = executable.map { probe(text, executable: $0) } ?? .unknown
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func lookupCandidates(_ text: String, completion: @escaping (HanjaCandidateResult) -> Void) {
        let executable = Bundle.main.executableURL
        queue.async {
            let result = executable.map { probeCandidates(text, executable: $0) } ?? .unknown
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func probeCandidates(_ text: String, executable: URL, timeout: TimeInterval = 0.75,
                                arguments: [String] = [listProbeArgument]) -> HanjaCandidateResult {
        guard let data = reply(text, executable: executable, timeout: timeout, arguments: arguments),
              let result = try? JSONDecoder().decode(HanjaCandidateResult.self, from: data),
              result.candidates.count <= 128,
              Set(result.candidates).count == result.candidates.count,
              result.candidates.allSatisfy({ !$0.isEmpty && $0 != text && $0.utf16.count <= 8_192 }),
              (result.status == .available) == !result.candidates.isEmpty else { return .unknown }
        return result
    }

    /// Private APIs run in an expendable child. Exceptions, signals, malformed
    /// replies and slow dictionaries must leave the normal IME path available.
    static func probe(_ text: String, executable: URL, timeout: TimeInterval = 0.75,
                      arguments: [String] = [probeArgument]) -> HanjaCandidateAvailability {
        guard let data = reply(text, executable: executable, timeout: timeout, arguments: arguments),
              let string = String(data: data, encoding: .utf8),
              let result = HanjaCandidateAvailability(rawValue: string) else { return .unknown }
        return result
    }

    private static func reply(_ text: String, executable: URL, timeout: TimeInterval,
                              arguments: [String]) -> Data? {
        guard validTarget(text), timeout > 0 else { return nil }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A failed child may close stdin before the request is written.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do { try process.run() } catch { return nil }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let data = try? output.fileHandleForReading.read(upToCount: 4_097),
              data.count <= 4_096 else { return nil }
        return data
    }

    static func validTarget(_ text: String) -> Bool {
        !text.isEmpty && text.utf16.count <= 64
            && text.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
    }

    static func runProbeIfRequested() {
        let argument = CommandLine.arguments.dropFirst().first
        guard argument == probeArgument || argument == listProbeArgument else { return }
        let data = FileHandle.standardInput.readData(ofLength: 513)
        let result: HanjaCandidateResult
        if data.count <= 512, let text = String(data: data, encoding: .utf8), validTarget(text) {
            result = HanjaDictionaryReader.candidates(text, system: systemDictionary, user: userDictionary)
        } else { result = .unknown }
        if argument == probeArgument {
            FileHandle.standardOutput.write(Data(result.status.rawValue.utf8))
        } else {
            let encoded = try? JSONEncoder().encode(result)
            let limited = encoded.flatMap { $0.count <= 4_096 && result.candidates.count <= 128 ? $0 : nil }
            FileHandle.standardOutput.write(limited ?? (try! JSONEncoder().encode(HanjaCandidateResult.unknown)))
        }
        exit(0)
    }
}

/// The private DictionaryServices IDX ABI is isolated here and in the child
/// process. No dictionary creation, registration, mutation or text logging.
enum HanjaDictionaryReader {
    private typealias Hit = @convention(c) (UnsafeRawPointer?, UnsafePointer<UInt8>?, Int, UInt8, UnsafeMutableRawPointer?) -> Void
    private typealias Create = @convention(c) (CFAllocator?, CFURL, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias SetSearch = @convention(c) (CFTypeRef, CFString, CFString) -> Bool
    private typealias Search = @convention(c) (CFTypeRef, Hit, UnsafeMutableRawPointer?) -> Void

    private final class Runtime {
        let handle: UnsafeMutableRawPointer
        let create: Create
        let setSearch: SetSearch
        let search: Search
        let exact: CFString
        init?() {
            guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW | RTLD_LOCAL) else { return nil }
            guard let create = dlsym(handle, "IDXCreateIndexObject"),
                  let setSearch = dlsym(handle, "IDXSetSearchString"),
                  let search = dlsym(handle, "IDXPerformSearch"),
                  let exact = dlsym(handle, "kIDXSearchExactMatch") else { dlclose(handle); return nil }
            self.handle = handle
            self.create = unsafeBitCast(create, to: Create.self)
            self.setSearch = unsafeBitCast(setSearch, to: SetSearch.self)
            self.search = unsafeBitCast(search, to: Search.self)
            self.exact = exact.assumingMemoryBound(to: CFString.self).pointee
        }
        deinit { dlclose(handle) }
    }

    private final class Matches {
        let original: String
        let user: Bool
        var candidates: [String] = []
        var valid = true
        init(_ original: String, user: Bool) { self.original = original; self.user = user }
    }

    private static let hit: Hit = { _, bytes, length, _, context in
        guard let context else { return }
        let matches = Unmanaged<Matches>.fromOpaque(context).takeUnretainedValue()
        guard let bytes, length > 0, length <= 16_384, length % 2 == 0,
              let record = String(data: Data(bytes: bytes, count: length), encoding: .utf16BigEndian) else {
            matches.valid = false; return
        }
        let candidate: String
        if matches.user {
            guard let separator = record.firstIndex(of: "\t"),
                  record[..<separator].utf8.elementsEqual(matches.original.utf8) else {
                matches.valid = false; return
            }
            candidate = String(record[record.index(after: separator)...])
        } else { candidate = record }
        guard !candidate.isEmpty else { matches.valid = false; return }
        if candidate != matches.original { matches.candidates.append(candidate) }
    }

    /// Compare file identities around a query so a simultaneous dictionary
    /// edit cannot turn an incomplete read into a confirmed empty result.
    private static func stamp(_ url: URL, allowMissing: Bool) throws -> [String: String]? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if allowMissing && errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadCorruptFile) }
        let contents = url.appendingPathComponent("Contents")
        let packageStamp = "\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        guard lstat(contents.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var enumerationFailed = false
        guard let files = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw CocoaError(.fileReadUnknown) }
        var result = ["package": packageStamp,
                      "Contents": "\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"]
        for case let file as URL in files {
            guard result.count < 128, lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { throw CocoaError(.fileReadCorruptFile) }
            if kind == S_IFREG {
                let handle = try FileHandle(forReadingFrom: file)
                try handle.close()
            }
            let relative = String(file.path.dropFirst(contents.path.count + 1))
            result[relative] = "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        }
        guard !enumerationFailed else { throw CocoaError(.fileReadUnknown) }
        let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard let metadata = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let indexes = metadata["IDXDictionaryIndexes"] as? [[String: Any]], !indexes.isEmpty,
              indexes.allSatisfy({ index in
                  guard let path = index["IDXIndexPath"] as? String,
                        path == (path as NSString).lastPathComponent,
                        result[path] != nil || result["Resources/" + path] != nil else { return false }
                  return true
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private static func search(_ text: String, index: CFTypeRef, user: Bool, runtime: Runtime) -> HanjaCandidateResult {
        guard runtime.setSearch(index, text as CFString, runtime.exact) else { return .unknown }
        let matches = Matches(text, user: user)
        runtime.search(index, hit, Unmanaged.passUnretained(matches).toOpaque())
        guard matches.valid else { return .unknown }
        return HanjaCandidateResult(status: matches.candidates.isEmpty ? .none : .available,
                                    candidates: matches.candidates)
    }

    static func lookup(_ text: String, system: URL, user: URL) -> HanjaCandidateAvailability {
        candidates(text, system: system, user: user).status
    }

    static func candidates(_ text: String, system: URL, user: URL) -> HanjaCandidateResult {
        guard HanjaCandidates.validTarget(text), let runtime = Runtime() else { return .unknown }
        do {
            let systemBefore = try stamp(system, allowMissing: false)
            let userBefore = try stamp(user, allowMissing: true)
            guard let systemIndex = runtime.create(nil, system as CFURL, nil)?.takeRetainedValue() else { return .unknown }
            // Search has no status return. A known nonempty system key checks
            // the engine before accepting an empty answer for this request.
            guard search("한", index: systemIndex, user: false, runtime: runtime).status == .available else { return .unknown }
            let systemResult = search(text, index: systemIndex, user: false, runtime: runtime)
            let userResult: HanjaCandidateResult
            if userBefore != nil {
                guard let userIndex = runtime.create(nil, user as CFURL, nil)?.takeRetainedValue() else { return .unknown }
                userResult = search(text, index: userIndex, user: true, runtime: runtime)
            } else { userResult = .none }
            guard systemBefore == (try stamp(system, allowMissing: false)),
                  userBefore == (try stamp(user, allowMissing: true)) else { return .unknown }
            if systemResult.status == .unknown || userResult.status == .unknown { return .unknown }
            var seen = Set<String>()
            let values = (systemResult.candidates + userResult.candidates).filter { seen.insert($0).inserted }
            return HanjaCandidateResult(status: values.isEmpty ? .none : .available, candidates: values)
        } catch { return .unknown }
    }
}
