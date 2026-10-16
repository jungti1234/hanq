import AppKit
import Darwin

struct AutoHanQContext {
    let source: URL
    let product: [String: Any]
    let application: NSRunningApplication
    static func discover() throws -> AutoHanQContext {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "taek.in.hanq").filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first, let url = app.bundleURL,
              let executable = app.executableURL,
              executable.standardizedFileURL == url.appendingPathComponent("Contents/MacOS/HanQ").standardizedFileURL else { throw RecorderError.invalidDirectory }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, app.processIdentifier], size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { throw RecorderError.invalidDirectory }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { throw RecorderError.invalidDirectory }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var offset = 4
        while offset < size && data[offset] != 0 { offset += 1 }
        while offset < size && data[offset] == 0 { offset += 1 }
        var args = [String]()
        for _ in 0..<max(0, min(Int(argc), 128)) {
            let begin = offset
            while offset < size && data[offset] != 0 { offset += 1 }
            args.append(String(decoding: data[begin..<offset], as: UTF8.self)); offset += 1
            if offset >= size { break }
        }
        guard let index = args.firstIndex(of: "--diagnose-input-incidents"), index + 1 < args.count else { throw RecorderError.invalidDirectory }
        let source = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath()
        let fd = try RecorderSession.directoryFD(source); close(fd)
        let infoData = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { throw RecorderError.invalidDirectory }
        return AutoHanQContext(source: source, product: ["pid": app.processIdentifier, "path": url.path, "version": version, "build": build, "launchTime": app.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""], application: app)
    }
}
