import AppKit
import Foundation

// This fixture uses synthetic files and only the review window. It never loads
// AppDelegate, the real defaults domain, AX permission flows or input hooks.
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ title: String) {
    checks += 1
    if !value() { fputs("FAIL UI: \(title)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("hanq-review-ui-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: root) }
let store = DiagnosticLogStore(directory: root.appendingPathComponent("store"), policy: .incidentDefault)
let run = UUID().uuidString
for incident in 1...12 {
    for phase in 0...1 {
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "runID": run, "build": "296", "incident": incident, "phase": phase, "trigger": incident % 2 == 0 ? 1 : 3,
            "discardedOldFrames": 4,
            "frames": [["kind": 7, "category": 8], ["kind": 6, "category": 1], ["kind": 11, "controlEvidence": ["runtime": 3]]]] as [String: Any])
        check(store.save(data, incident: incident, phase: phase, automatic: incident % 2 != 0) == .saved, "synthetic capture")
    }
}
let snapshotURL = root.appendingPathComponent("snapshot")
try store.copyExportSnapshot(to: snapshotURL, reviewMetadata: true)
let snapshot = try DiagnosticReviewSnapshot(directory: snapshotURL)
let environment = DiagnosticReviewEnvironment(
    appVersion: "0.3.1-beta.1", build: "306", macOSVersion: "15.7.9", modelIdentifier: "Mac14,7", keyboardLayout: .twoSet,
    koreanKeyEnabled: true, hanjaKeyEnabled: true, hudEnabled: true, capsLockSwitchEnabled: true, loginItemState: .enabled,
    diagnosticsEnabled: true, inputMonitoringEnabled: true, cachedAccessibilityPermission: true, updateRestricted: false)
let controller = DiagnosticReviewController(environment: environment)
let window = controller.window!
window.appearance = NSAppearance(named: .aqua)
window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
controller.install(snapshot)
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let views = descendants(window.contentView!)
let tables = views.compactMap { $0 as? NSTableView }
check(tables.count == 2, "record list and included-file list")
check(!views.contains { $0 is NSTabView || $0 is NSSegmentedControl }, "no tabs or range selector")
let recordTable = tables.first { $0.numberOfColumns == 4 }!
let fileTable = tables.first { $0.numberOfColumns == 1 }!
let deadline = Date().addingTimeInterval(15)
while fileTable.numberOfRows == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
check(recordTable.numberOfRows == 12, "all records exist beyond five visible rows")
check(recordTable.enclosingScrollView?.hasVerticalScroller == true, "all records can scroll")
check(fileTable.numberOfRows == 5, "latest incident selected and all mandatory files included")
let selectionLabel = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "선택한 기록 1/5건" }
check(selectionLabel != nil, "one incident selected by default with persistent count")
check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "보관 중인 최근 기록" }, "agreed title")
fileTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
let preview = views.compactMap { $0 as? NSTextView }.first!
check(preview.string.contains("전환 대기 기한 초과"), "parsed readable preview")
check(!preview.string.contains("\"frames\"") && !preview.string.contains("{\n"), "no raw JSON editor")
fileTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(preview.string.contains("기록 수　1건") && preview.string.contains("발생 전·후 모두 있음")
      && !preview.string.contains("incident-"), "actual summary view uses the concise exported summary")
fileTable.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(preview.string.contains("보관 중인 파일") && preview.string.contains("기록된 내역 없음")
      && !preview.string.contains("저장 시도"), "actual storage view uses usage and meaningful issue state")
check(!preview.string.contains("검토 시점") && !preview.string.contains("선택한 기록의 결과 아님"), "storage heading has no explanatory suffixes")
fileTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(preview.string.contains("앱 및 시스템") && !preview.string.contains("항상 포함") && !preview.string.contains("해석"), "environment view shows values without fixed interpretation sections")
let previewTitle = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "diagnosticPreviewTitle" }!
check(!preview.isEditable && preview.isSelectable, "preview remains selectable and noneditable without a read-only caption")
window.contentView!.layoutSubtreeIfNeeded()
check(recordTable.enclosingScrollView!.frame.height == 232, "roughly five-row viewport")
check(recordTable.enclosingScrollView!.contentView.bounds.height / 41 >= 4.9 && recordTable.enclosingScrollView!.contentView.bounds.height / 41 < 6, "five rows remain visible")
check(preview.enclosingScrollView!.frame.width > 400 && preview.enclosingScrollView!.frame.height >= 170, "readable preview has usable space")
func settleLayout() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    window.contentView!.layoutSubtreeIfNeeded()
}
// Summary used to collapse after selection/appearance changes despite the
// surrounding stack filling the window. Exercise each document and resize.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearance)
    for size in [NSSize(width: 900, height: 740), NSSize(width: 1000, height: 850), NSSize(width: 1200, height: 950)] {
        window.setContentSize(size)
        for row in 0..<5 {
            fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            settleLayout()
            let content = window.contentView!
            let recordsRect = recordTable.enclosingScrollView!.convert(recordTable.enclosingScrollView!.bounds, to: content)
            let filesRect = fileTable.enclosingScrollView!.convert(fileTable.enclosingScrollView!.bounds, to: content)
            let previewScroll = preview.enclosingScrollView!
            let previewRect = previewScroll.convert(previewScroll.bounds, to: content)
            check(abs(previewRect.maxX - recordsRect.maxX) < 1 && abs(previewRect.minX - filesRect.maxX - 12) < 1,
                  "each readable document fills remaining width across window sizes and appearances")
            check(previewRect.width >= 580 && abs(preview.frame.width - previewScroll.contentView.bounds.width) < 1,
                  "text view follows clip width instead of narrow intrinsic title width")
            check(abs((preview.textContainer?.containerSize.width ?? 0) - (preview.frame.width - 2 * preview.textContainerInset.width)) < 1,
                  "wrapping width follows preview resizing")
        }
        for table in [recordTable, fileTable] {
            for column in 0..<table.numberOfColumns {
                let cell = table.view(atColumn: column, row: 0, makeIfNecessary: true)!
                cell.layoutSubtreeIfNeeded()
                let control = cell.subviews.first { $0 is NSTextField || $0 is NSButton }!
                check(abs(control.frame.midY - cell.bounds.midY) < 1, "all record/file cells vertically centered")
                if control is NSTextField {
                    let textRect = control.alignmentRect(forFrame: control.frame)
                    check(abs(textRect.minX - 10) < 1 && abs(cell.bounds.maxX - textRect.maxX - 10) < 1,
                          "record/file text cells have matching horizontal padding")
                }
            }
        }
    }
}
func render(_ name: String) throws {
    guard CommandLine.arguments.count > 1 else { return }
    settleLayout()
    let content = window.contentView!
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let output = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent(name)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
}
window.setContentSize(NSSize(width: 1000, height: 850))
fileTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
try render("review-dark-summary.png")
window.appearance = NSAppearance(named: .aqua)
fileTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
try render("review-light-environment.png")
// Actual table selection action (no global mouse/keyboard event synthesis).
func checkbox(_ row: Int) -> NSButton {
    descendants(recordTable.view(atColumn: 0, row: row, makeIfNecessary: true)!).compactMap { $0 as? NSButton }.first!
}
func awaitFiles(_ count: Int) {
    let until = Date().addingTimeInterval(15)
    while fileTable.numberOfRows != count && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}
checkbox(1).performClick(nil)
awaitFiles(7)
check(fileTable.numberOfRows == 7, "checkbox updates exact selected-file set")
let staleCheckbox = checkbox(5)
for row in 2...4 { checkbox(row).performClick(nil) }
awaitFiles(13)
check(fileTable.numberOfRows == 13, "five incidents export all ten pre/post documents")
check(selectionLabel?.stringValue == "선택한 기록 5/5건", "persistent selection count reaches five")
check((0...4).allSatisfy { checkbox($0).isEnabled && checkbox($0).state == .on }, "five selected checkboxes stay enabled for deselection")
check((5...11).allSatisfy { !checkbox($0).isEnabled && checkbox($0).state == .off }, "all unselected checkboxes disabled at five including offscreen rows")
check(checkbox(5).toolTip?.contains("최대 5건") == true, "disabled checkbox explains limit")
checkbox(5).performClick(nil)
check(selectionLabel?.stringValue == "선택한 기록 5/5건", "sixth checkbox cannot add an incident")
// A queued action from a previously enabled cell must obey the same limit.
app.sendAction(staleCheckbox.action!, to: staleCheckbox.target, from: staleCheckbox)
check(selectionLabel?.stringValue == "선택한 기록 5/5건" && fileTable.numberOfRows == 13, "stale action cannot bypass five-incident limit")
fileTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
recordTable.scrollRowToVisible(0)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
window.contentView!.layoutSubtreeIfNeeded()
let bitmap = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds)!
window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
if CommandLine.arguments.count > 1 { try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
checkbox(4).performClick(nil)
check(selectionLabel?.stringValue == "선택한 기록 4/5건", "deselection updates count immediately")
check(checkbox(11).isEnabled, "deselecting re-enables older unselected records")
checkbox(11).performClick(nil)
awaitFiles(13)
check(checkbox(11).state == .on && selectionLabel?.stringValue == "선택한 기록 5/5건", "older record can replace a selected incident")
for row in [0, 1, 2, 3, 11] { checkbox(row).performClick(nil) }
check(selectionLabel?.stringValue == "선택한 기록 0/5건" && fileTable.numberOfRows == 0, "all records can be deselected")
check(previewTitle.stringValue == "미리보기" && preview.string.isEmpty, "empty selection clears the previous file title and preview")
let saveButton = views.compactMap { $0 as? NSButton }.first { $0.title == "내보내기…" }!
check(!saveButton.isEnabled, "empty selection disables saving")
checkbox(0).performClick(nil)
awaitFiles(5)
check(fileTable.numberOfRows == 5 && saveButton.isEnabled && selectionLabel?.stringValue == "선택한 기록 1/5건", "new selection replaces stale async results and enables saving without capacity gate")
controller.close()
check(fm.fileExists(atPath: root.appendingPathComponent("store").path), "close preserves original store")

// A hidden/minimized review must still finish loading; visibility is not its lifetime.
let trace = InputIncidentTrace(destination: root.appendingPathComponent("trace"))
trace.mark(); trace.stopAndFlush()
let hidden = DiagnosticReviewController(environment: environment)
let hiddenTables = descendants(hidden.window!.contentView!).compactMap { $0 as? NSTableView }
let hiddenFiles = hiddenTables.first { $0.numberOfColumns == 1 }!
check(hidden.window!.isVisible == false, "hidden review fixture does not show or activate an app")
hidden.load(from: trace)
let hiddenDeadline = Date().addingTimeInterval(5)
while hiddenFiles.numberOfRows == 0 && Date() < hiddenDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
check(hiddenFiles.numberOfRows == 5, "loading survives hidden/minimized review and collection OFF")
hidden.close()
let cancelled = DiagnosticReviewController(environment: environment)
let cancelledTable = descendants(cancelled.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.numberOfColumns == 1 }!
var closes = 0
cancelled.onClose = { closes += 1 }
cancelled.load(from: trace)
cancelled.close()
trace.flush()
RunLoop.current.run(until: Date().addingTimeInterval(0.15))
check(closes == 1 && cancelled.numberOfRows(in: cancelledTable) == 0, "closing before load finishes does not install a late result")
cancelled.install(snapshot)
check(cancelled.numberOfRows(in: cancelledTable) == 0, "closed review cannot be resurrected by a late install")
print("PASS: standalone diagnostic review UI \(checks) checks (no hooks, no installed app)")
