import Foundation

// Read only appended bytes. Long idle sessions must not make the AppKit timer
// reparse hours of health pulses or block retry buttons.
struct TrialTrace {
    static let readLimit = 65_536
    static let retainedLimit = 1_048_576
    private(set) var offset: UInt64 = 0
    private(set) var text = ""
    private(set) var valid = true
    private(set) var caughtUp = false
    private var pending = Data()

    mutating func begin(_ url: URL?) {
        self = TrialTrace()
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { valid = false; return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { valid = false; return }
        offset = size
        caughtUp = true
    }

    @discardableResult mutating func refresh(_ url: URL?) -> Int {
        guard valid, let url, let handle = try? FileHandle(forReadingFrom: url) else { valid = false; return 0 }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size >= offset else { valid = false; return 0 }
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: Self.readLimit) ?? Data()
            offset += UInt64(bytes.count)
            caughtUp = offset == size
            pending.append(bytes)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                if line.contains(" mismatch.") {
                    guard text.utf8.count + line.utf8.count + 1 <= Self.retainedLimit else { valid = false; break }
                    text += line + "\n"
                }
            }
            if pending.count > Self.readLimit { valid = false }
            return bytes.count
        } catch { valid = false; return 0 }
    }
}
