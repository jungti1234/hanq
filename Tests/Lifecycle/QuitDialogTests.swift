import AppKit

func quitViews(_ window: NSWindow) -> [NSView] {
    func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
    return children(window.contentView!)
}

func quitButton(_ title: String, in window: NSWindow) -> NSButton {
    guard let button = quitViews(window).compactMap({ $0 as? NSButton }).first(where: { $0.title == title })
    else { fatalError("Missing button \(title)") }
    return button
}

private func waitForQuitTest(_ description: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(20)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), description)
}

private final class QuitTestWriter {
    private let lock = NSLock()
    private var blocked = false
    func setBlocked(_ value: Bool) { lock.lock(); blocked = value; lock.unlock() }
    func write(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ size: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if blocked { errno = ENOSPC; return -1 }
        return Darwin.write(fd, bytes, size)
    }
}

func testDiagnosticQuitDialog() throws {
    let fm = FileManager.default
    guard let canonical = realpath(".", nil) else { fatalError("Cannot resolve test directory") }
    defer { free(canonical) }
    let path = String(cString: canonical)
    var info = stat()
    precondition((path as NSString).deletingLastPathComponent == "/private/tmp" &&
                 (path as NSString).lastPathComponent.hasPrefix("hanq-lifecycle.") &&
                 lstat(path, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700)
    let stage = URL(fileURLWithPath: path, isDirectory: true)
    let store = stage.appendingPathComponent("quit-dialog-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let journal = DiagnosticCriticalJournal(directory: store)
    OperationalDiagnostics.shared.installJournal(journal)
    journal.record(.posix(.probeRead, EIO))
    precondition(journal.flush(timeout: 2))
    let writer = QuitTestWriter()
    let trace = InputIncidentTrace(secureInput: { false }, destination: store, sharedWriter: writer.write)
    trace.mark(); trace.flush()
    writer.setBlocked(true) // The pre phase is on disk, the post phase will fail the final save.

    _ = NSApplication.shared.setActivationPolicy(.prohibited)
    let app = AppDelegate()
    app.diagnosticQuitPreparer = trace.prepareForQuit
    app.diagnosticQuitStateReader = trace.readQuitState
    app.diagnosticQuitResumer = trace.cancelQuitPreparation
    var shown: [NSWindow] = []
    var replies: [Bool] = []
    app.presentDiagnosticQuitWindow = { window in
        shown.append(window)
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderBack(nil)
    }
    app.diagnosticQuitReply = { replies.append($0) }
    precondition(app.applicationShouldTerminate(NSApp) == .terminateLater)
    waitForQuitTest("pending dialog appeared") { !shown.isEmpty }
    let window = shown[0], windowNumber = window.windowNumber
    let export = quitButton("대기 기록 내보내기…", in: window)
    precondition(window.isVisible && export.isEnabled && quitButton("저장하지 않고 종료", in: window).isEnabled)

    let environment = DiagnosticReviewEnvironment(appVersion: "fixture", build: "457", macOSVersion: "fixture",
        modelIdentifier: "fixture", keyboardLayout: .twoSet, koreanKeyEnabled: true, hanjaKeyEnabled: true,
        hudEnabled: false, capsLockSwitchEnabled: false, loginItemState: .notRegistered, diagnosticsEnabled: true,
        inputMonitoringEnabled: false, cachedAccessibilityPermission: false, updateRestricted: false)
    func reviewSnapshot() throws -> DiagnosticReviewSnapshot {
        let folder = stage.appendingPathComponent("review-" + UUID().uuidString)
        var result: Result<DiagnosticReviewSnapshot, Error>?
        DiagnosticReviewController.loadSnapshot(from: trace, directory: folder) { result = $0 }
        waitForQuitTest("review snapshot delivered") { result != nil }
        return try result!.get()
    }

    let pending = try reviewSnapshot()
    precondition(pending.hasPendingCopies && !pending.pendingIncidentIDs.isEmpty)
    let review = DiagnosticReviewController(environment: environment, allPending: true)
    review.install(pending)
    let saveButton = quitButton("내보내기…", in: review.window!)
    waitForQuitTest("pending export offers a real archive") { saveButton.isEnabled }

    writer.setBlocked(false) // Only the normal writer timer retries; reading the dialog cannot force a write.
    waitForQuitTest("the same quit dialog reports that the pending data was saved") {
        quitViews(window).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "지금 한Q를 종료할까요?" }
    }
    precondition(shown.count == 1 && window.isVisible && window.windowNumber == windowNumber && replies.isEmpty)
    precondition(!export.isEnabled && quitButton("한Q 종료", in: window).isEnabled)
    print("PASS: native quit window kept its identity, asked again after durable storage and disabled pending export without quitting")

    let saved = try reviewSnapshot()
    precondition(!saved.hasPendingCopies && saved.incidents.contains { $0.complete } && saved.critical != nil)
    review.install(saved)
    let regular = DiagnosticReviewController(environment: environment)
    regular.install(saved)
    waitForQuitTest("saved diagnostics remain exportable in the regular view") {
        quitButton("내보내기…", in: regular.window!).isEnabled
    }
    precondition(!saveButton.isEnabled && quitViews(review.window!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "내보낼 대기 기록이 없습니다." })
    do {
        _ = try saved.files(selected: [], environment: environment, allPending: true)
        preconditionFailure("Pending-only export accepted historical files")
    } catch DiagnosticReviewError.emptySelection {}
    let historical = try saved.files(selected: [], environment: environment)
    precondition(historical.contains { DiagnosticCriticalJournal.exportedName($0.path) })
    print("PASS: saved capture and journal on disk, empty pending view disabled at UI and archive entry, regular history export enabled")

    quitButton("한Q 종료", in: window).performClick(nil)
    waitForQuitTest("explicitly confirmed clean quit replied") { replies == [true] }
    precondition(!window.isVisible && shown.count == 1)
    // A real pending journal row is exportable even when the pending incident table is empty.
    let journalOnly = DiagnosticCriticalJournal(directory: store, writer: { _, _, _ in errno = ENOSPC; return -1 })
    OperationalDiagnostics.shared.installJournal(journalOnly)
    journalOnly.record(.posix(.probeDecode, EIO))
    _ = journalOnly.flush(timeout: 2)
    let memory = try reviewSnapshot()
    precondition(memory.pendingIncidentIDs.isEmpty && memory.pendingJournalCount > 0)
    review.install(memory)
    waitForQuitTest("journal-only rescue can still export") { saveButton.isEnabled }
    let memoryFiles = try memory.files(selected: [], environment: environment, allPending: true)
    precondition(memoryFiles.contains { memory.pendingExport?.journalFiles[$0.path] != nil })
    print("PASS: a pending journal alone enables export and includes its memory copy")
    trace.stopAfterQuitPreparation()
    print("PASS: AppDelegate replied to the original termination request once after explicit confirmation")
}
