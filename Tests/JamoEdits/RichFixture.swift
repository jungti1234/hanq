import AppKit
import Carbon
import CryptoKit

final class ClipboardObservedTextView: NSTextView {
    var beforePaste: (() -> Void)?
    override func paste(_ sender: Any?) {
        beforePaste?()
        super.paste(sender)
    }
}

final class RichFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let root: URL
    let view = ClipboardObservedTextView(frame: NSRect(x: 0, y: 0, width: 850, height: 260))
    var window: NSWindow!
    var timer: Timer?
    var prior: NSRunningApplication?
    var index = 0, stage = 0
    var deadline = 0.0, settled = 0.0
    var initial = NSAttributedString(string: ""), expected = ""
    var plannedEdits: [JamoComposer.Edit] = []
    var expectedFinalCaret = 0
    var expectedRedoCaret: NSRange?
    var controlGeneration: Int?
    var rows: [[String: Any]] = [], current: [String: Any] = [:]
    var savedClipboard: [[(NSPasteboard.PasteboardType, Data)]] = []
    let marker = "HanQ issue4 owned clipboard marker"
    let names: [String]
    let nativeControl: Bool
    let clipboardProtection: Bool
    var seededClipboard: [[NSPasteboard.PasteboardType: Data]] = []
    let nativeExpected: [[String: Any]]
    var rejected = false, changed = false, clipboardInjected = false
    var observer: NSObjectProtocol?
    var textObserver: NSObjectProtocol?
    var startupRetried = false
    let externalMarker = "HanQ issue4 simulated external copy"
    init(_ root: URL) {
        self.root = root
        nativeControl = FileManager.default.fileExists(atPath: root.appendingPathComponent("native-control").path)
        clipboardProtection = FileManager.default.fileExists(atPath: root.appendingPathComponent("clipboard-protection").path)
        let common = ["single", "separated", "selected", "nfd", "emoji", "laughter"] + (clipboardProtection ? ["roman"] : [])
        names = nativeControl ? common : common + ["late-clipboard", "rejected-multi", "context-change"]
        let data = try? Data(contentsOf: root.appendingPathComponent("native-expected.json"))
        let result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        nativeExpected = result?["cases"] as? [[String: Any]] ?? []
    }
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func write(_ name: String, _ object: Any) {
        do { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(name), options: .atomic) }
        catch { fputs("fixture result write failed\n", stderr); exit(1) }
    }
    func request(_ key: Int, command: Bool = false, shift: Bool = false) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("done.json"))
        write("request.json", ["pid": getpid(), "keys": [["code": key, "rightCommand": false, "commandChord": command, "shift": shift, "gap": 0.0]]])
    }
    func completed() -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("done.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return false }
        return value["passed"] == true
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        prior = NSWorkspace.shared.frontmostApplication
        let menu = NSMenu(), item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit; menu.addItem(item); NSApp.mainMenu = menu
        savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        seedClipboard()
        view.beforePaste = { [weak self] in self?.observeTemporaryClipboard() }
        view.isRichText = true; view.importsGraphics = true; view.allowsUndo = true; view.font = .systemFont(ofSize: 20)
        view.isAutomaticLinkDetectionEnabled = false
        view.backgroundColor = .white; view.textColor = .black; view.appearance = NSAppearance(named: .aqua)
        observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: view, queue: .main) { [weak self] _ in
            guard let self, self.index < self.names.count, self.stage == 1, self.view.selectedRanges.count > 1 else { return }
            if self.names[self.index] == "rejected-multi", !self.rejected {
                self.rejected = true; self.settled = self.now(); self.view.setSelectedRange(self.view.selectedRanges[0].rangeValue)
            } else if self.names[self.index] == "context-change", !self.changed {
                self.changed = true; self.settled = self.now(); self.view.textStorage?.insert(NSAttributedString(string: "사용자변경 "), at: 0)
            }
        }
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: view, queue: .main) { [weak self] _ in
            guard let self, self.index < self.names.count, self.names[self.index] == "late-clipboard",
                  self.stage == 1 || self.stage == 2, !self.clipboardInjected,
                  self.view.string.utf8.elementsEqual(self.expected.utf8) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.externalMarker, forType: .string)
            self.clipboardInjected = true
        }
        window = NSWindow(contentRect: NSRect(x: 150, y: 220, width: 850, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HanQ #4 — owned rich-text reproduction"; window.contentView = view; window.delegate = self
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); NSApp.activate(ignoringOtherApps: true)
        deadline = now() + 8; stage = -1
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
    }
    func applicationDidBecomeActive(_ note: Notification) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
    }
    func sample(_ name: String) -> NSAttributedString {
        let prefix = name == "emoji" ? "앞😀👩‍👩‍👧‍👦é 굵은앞 링크앞 " : "굵은앞 링크앞 "
        let value = NSMutableAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
        value.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: 3))
        value.addAttribute(.link, value: URL(string: "https://example.invalid/before")!, range: (value.string as NSString).range(of: "링크앞"))
        let jamo = name == "roman" ? "dkssud" : name == "nfd" ? "각" : name == "laughter" ? "ㅇㅏㅋㅋㅋㄴㅏ" : "ㅇㅏㄴㄴㅕㅇ"
        value.append(NSAttributedString(string: jamo + " ", attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]))
        if name == "laughter" {
            let laugh = (value.string as NSString).range(of: "ㅋㅋㅋ")
            value.addAttribute(.link, value: URL(string: "https://example.invalid/laughter")!, range: NSRange(location: laugh.location + 1, length: 2))
        }
        if ["separated", "rejected-multi", "context-change"].contains(name) { value.append(NSAttributedString(string: "가운데링크 ", attributes: [.link: URL(string: "https://example.invalid/middle")!])) }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill(); image.unlockFocus()
        let attachment = NSTextAttachment()
        if let tiff = image.tiffRepresentation { attachment.fileWrapper = FileWrapper(regularFileWithContents: tiff); attachment.fileWrapper?.preferredFilename = "owned-blue-square.tiff" }
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        value.append(NSAttributedString(attachment: attachment))
        if ["separated", "rejected-multi", "context-change"].contains(name) { value.append(NSAttributedString(string: " ㅂㅏㄴㄱㅏㅇㅝ")) }
        value.append(NSAttributedString(string: " 링크뒤 굵은뒤", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)]))
        value.addAttribute(.link, value: URL(string: "https://example.invalid/after")!, range: (value.string as NSString).range(of: "링크뒤"))
        let styled = (value.string as NSString).range(of: "링크앞")
        value.addAttributes([.font: NSFontManager.shared.convert(.systemFont(ofSize: 20), toHaveTrait: .italicFontMask),
            .foregroundColor: NSColor.systemBlue, .backgroundColor: NSColor.systemYellow,
            .underlineStyle: NSUnderlineStyle.single.rawValue], range: styled)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4; paragraph.paragraphSpacing = 6
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        return value
    }
    func metrics(_ value: NSAttributedString) -> [String: Any] {
        var attachments = 0, links = 0, boldUnits = 0
        var attachmentHashes: [String] = [], linkValues: [String] = []
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                attachments += 1
                if let data = attachment.fileWrapper?.regularFileContents {
                    attachmentHashes.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                }
            }
            if let value = attributes[.link] { links += range.length; linkValues.append(String(describing: value)) }
            if let font = attributes[.font] as? NSFont, NSFontManager.shared.traits(of: font).contains(.boldFontMask) { boldUnits += range.length }
        }
        return ["attachments": attachments, "attachmentSHA256": attachmentHashes, "linkValues": linkValues,
                "linkedUTF16": links, "boldUTF16": boldUnits, "utf16": value.length]
    }
    func stableAttributes(_ value: NSAttributedString, at index: Int) -> NSDictionary {
        let keys: Set<NSAttributedString.Key> = [.font, .foregroundColor, .backgroundColor, .underlineStyle,
            .strikethroughStyle, .link, .attachment, .paragraphStyle, .baselineOffset, .kern, .ligature, .superscript, .shadow]
        return value.attributes(at: index, effectiveRange: nil).filter { keys.contains($0.key) } as NSDictionary
    }
    func unchangedFormatting() -> Bool {
        let current = view.textStorage!
        var cursor = 0, delta = 0
        for edit in plannedEdits + [JamoComposer.Edit(range: NSRange(location: initial.length, length: 0), replacement: "")] {
            for index in cursor..<edit.range.location {
                guard index + delta >= 0, index + delta < current.length,
                      stableAttributes(initial, at: index).isEqual(stableAttributes(current, at: index + delta)) else { return false }
            }
            cursor = NSMaxRange(edit.range); delta += edit.replacement.utf16.count - edit.range.length
        }
        return true
    }
    func originalFormatting() -> Bool {
        guard view.textStorage!.length == initial.length else { return false }
        return (0..<initial.length).allSatisfy { stableAttributes(initial, at: $0).isEqual(stableAttributes(view.textStorage!, at: $0)) }
    }
    func saveView(_ suffix: String) {
        let base = root.appendingPathComponent(names[index] + "-" + suffix)
        let attributed = NSAttributedString(attributedString: view.textStorage!)
        if let wrapper = try? attributed.fileWrapper(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) { try? wrapper.write(to: base.appendingPathExtension("rtfd"), options: .atomic, originalContentsURL: nil) }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: base.appendingPathExtension("png")) } }
    }
    func begin() {
        guard index < names.count else { finish(true, "all synthetic rich-text cases observed"); return }
        let board = NSPasteboard.general
        guard board.string(forType: .string) == marker || board.string(forType: .string) == externalMarker else { finish(false, "clipboard changed outside owned test"); return }
        if clipboardProtection || board.string(forType: .string) == externalMarker { seedClipboard() }
        rejected = false; changed = false; clipboardInjected = false
        initial = sample(names[index]); view.textStorage?.setAttributedString(initial); view.undoManager?.removeAllActions()
        let selection = names[index] == "roman" ? (view.string as NSString).range(of: "dkssud") : names[index] == "selected" ? (view.string as NSString).range(of: "ㅇㅏㄴㄴㅕㅇ") : NSRange(location: 1, length: 0)
        view.setSelectedRange(selection); window.makeFirstResponder(view)
        let range = JamoComposer.targetRange(in: view.string, selection: selection)!
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        initial = NSAttributedString(attributedString: view.textStorage!)
        if names[index] == "roman" {
            let remembered = UserDefaults(suiteName: "taek.in.hanq")?.string(forKey: "lastKoreanSourceID")
            let source = KoreanEnglishSwitch.romanSourceID(current: InputSourceSnapshot.read(), available: InputSourceSnapshot.available(), rememberedKorean: remembered)
            guard let replacement = JamoComposer.selectedRomanReplacement(in: view.string, selection: selection, layout: KoreanKeyboardLayout.resolve(sourceID: source)),
                  replacement != "dkssud" else { finish(false, "roman fixture cannot resolve converted text"); return }
            plannedEdits = [JamoComposer.Edit(range: selection, replacement: replacement)]
            expected = (view.string as NSString).replacingCharacters(in: selection, with: replacement)
        } else {
            plannedEdits = JamoComposer.edits(in: view.string, range: range)!
            expected = (view.string as NSString).replacingCharacters(in: range, with: JamoComposer.compose((view.string as NSString).substring(with: range)))
        }
        expectedFinalCaret = plannedEdits[0].range.location + plannedEdits[0].replacement.utf16.count
        expectedRedoCaret = nil
        if !nativeControl, !["rejected-multi", "context-change"].contains(names[index]) {
            let name = names[index] == "late-clipboard" ? "single" : names[index]
            guard let row = nativeExpected.first(where: { $0["name"] as? String == name }),
                  let value = row["syntheticAfter"] as? String, value.utf8.elementsEqual(expected.utf8),
                  let caret = row["redoCaret"] as? [Int], caret.count == 2 else {
                finish(false, "native Command-paste/Undo/Redo control missing"); return
            }
            expectedRedoCaret = NSRange(location: caret[0], length: caret[1])
        }
        current = ["name": names[index], "before": metrics(initial), "syntheticOriginal": initial.string, "expected": expected, "originalSelection": [selection.location, selection.length]]
        saveView("before"); stage = 0; settled = now(); deadline = now() + 8
    }
    func tick() {
        guard now() < deadline else { finish(false, "stage timeout \(stage), case \(index)"); return }
        if stage == -1 {
            if NSApp.isActive, window.firstResponder === view { begin() }
            else if !startupRetried, deadline - now() < 7 {
                startupRetried = true; window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view); NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        guard NSApp.isActive, window.firstResponder === view else { finish(false, "owned focus changed"); return }
        if stage == 0, now() - settled > 0.3 {
            if nativeControl {
                guard let payload = JamoPasteboard.make(plannedEdits.map(\.replacement)) else { finish(false, "native payload failed"); return }
                view.selectedRanges = plannedEdits.map { NSValue(range: $0.range) }
                let board = NSPasteboard.general; board.clearContents()
                board.setString(payload.string, forType: .string)
                if let data = payload.multipleSelection { board.setData(data, forType: .multipleTextSelection) }
                controlGeneration = board.changeCount
                stage = 1; request(9, command: true)
            } else { stage = 1; request(61) }
            return
        }
        if stage == 1, (rejected || changed), completed(), now() - settled > 0.6 {
            let wanted = changed ? "사용자변경 " + initial.string : initial.string
            guard view.string.utf8.elementsEqual(wanted.utf8), NSPasteboard.general.string(forType: .string) == marker else { finish(false, "unsafe edit after rejected selection/context change"); return }
            current["safeNoPaste"] = true; current["selectionAcknowledgmentRejected"] = rejected; current["changedContextPreserved"] = changed
            if clipboardProtection {
                current["clipboardFormatsRestored"] = clipboardSnapshot() == seededClipboard
                current["temporaryPayloadNotPublished"] = current["temporaryProtectionObserved"] == nil
            }
            current["after"] = metrics(view.textStorage!); rows.append(current); index += 1; begin(); return
        }
        if stage == 1, completed(), view.string.utf8.elementsEqual(expected.utf8) {
            if nativeControl {
                let board = NSPasteboard.general
                guard board.changeCount == controlGeneration else { finish(false, "native control clipboard ownership changed"); return }
                seedClipboard()
            }
            settled = now(); stage = 2; return
        }
        if stage == 2, names[index] == "late-clipboard", !clipboardInjected, NSPasteboard.general.string(forType: .string) != marker {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(externalMarker, forType: .string); clipboardInjected = true
        }
        if stage == 2, now() - settled > 0.35 {
            current["after"] = metrics(view.textStorage!); current["syntheticAfter"] = view.string
            current["unchangedFormattingPreserved"] = unchangedFormatting()
            current["caretAfter"] = [view.selectedRange().location, view.selectedRange().length]
            current["clipboardMarkerRestored"] = NSPasteboard.general.string(forType: .string) == marker
            if clipboardProtection {
                current["clipboardFormatsRestored"] = clipboardSnapshot() == seededClipboard
            }
            current["externalClipboardPreserved"] = clipboardInjected && NSPasteboard.general.string(forType: .string) == externalMarker
            current["finalCaretPreserved"] = view.selectedRange() == NSRange(location: expectedFinalCaret, length: 0)
            saveView("after"); stage = 3; request(6, command: true); return
        }
        if stage == 3, completed(), view.string.utf8.elementsEqual(initial.string.utf8) {
            current["oneUndoRestoredText"] = true; current["undo"] = metrics(view.textStorage!)
            current["oneUndoRestoredFormatting"] = originalFormatting()
            saveView("undo"); stage = 4; request(6, command: true, shift: true); return
        }
        if stage == 4, completed(), view.string.utf8.elementsEqual(expected.utf8) {
            current["redoRestoredText"] = true; current["redo"] = metrics(view.textStorage!)
            current["redoUnchangedFormattingPreserved"] = unchangedFormatting()
            if let expectedRedoCaret {
                current["redoCaretMatchesNative"] = view.selectedRange() == expectedRedoCaret
                current["nativeRedoCaret"] = [expectedRedoCaret.location, expectedRedoCaret.length]
            }
            current["redoCaret"] = [view.selectedRange().location, view.selectedRange().length]
            saveView("redo"); rows.append(current); index += 1; begin()
        }
    }
    func windowWillClose(_ note: Notification) { finish(false, "window closed by user") }
    func clipboardSnapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }
    func seedClipboard() {
        let board = NSPasteboard.general
        board.clearContents()
        guard clipboardProtection else { board.setString(marker, forType: .string); return }
        let text = NSPasteboardItem(), binary = NSPasteboardItem()
        text.setString(marker, forType: .string)
        let attributed = NSAttributedString(string: "owned synthetic clipboard", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        text.setData(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!, forType: .rtf)
        // Also preserve an existing transient marker, without inventing one on restoration.
        if index < names.count, names[index] == "nfd" { text.setData(Data([7]), forType: TemporaryPasteboard.transientType) }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.blue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill(); image.unlockFocus()
        binary.setData(image.tiffRepresentation!, forType: .tiff)
        binary.setData(Data([0, 1, 127, 255]), forType: .init("in.hanq.owned-synthetic-binary"))
        guard board.writeObjects([text, binary]) else { finish(false, "synthetic clipboard setup failed"); return }
        seededClipboard = clipboardSnapshot()
    }
    func observeTemporaryClipboard() {
        guard clipboardProtection, !nativeControl, index < names.count, stage == 1,
              let payload = JamoPasteboard.make(plannedEdits.map(\.replacement)) else { return }
        let board = NSPasteboard.general
        let marked = board.data(forType: TemporaryPasteboard.transientType) == Data()
        current["temporaryProtectionObserved"] = marked && board.pasteboardItems?.count == 1
            && board.string(forType: .string) == payload.string
            && board.data(forType: .multipleTextSelection) == payload.multipleSelection
        // A cooperating history reader skips by type presence. This is not an
        // installed third-party history manager or a cross-device test.
        current["cooperatingHistoryReaderSkips"] = board.types?.contains(TemporaryPasteboard.transientType) == true
    }
    func finish(_ passed: Bool, _ reason: String) {
        timer?.invalidate()
        let clipboard = NSPasteboard.general
        let canRestore = clipboard.string(forType: .string) == marker || clipboard.string(forType: .string) == externalMarker
            || (nativeControl && controlGeneration == clipboard.changeCount)
        var restored = false
        if canRestore {
            clipboard.clearContents()
            let objects = savedClipboard.map { entries -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in entries { item.setData(data, forType: type) }; return item }
            if !objects.isEmpty { clipboard.writeObjects(objects) }
            let actual = (clipboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
            restored = actual == savedClipboard.map { Dictionary(uniqueKeysWithValues: $0) }
        }
        write("result.json", ["completed": passed, "reason": reason, "cases": rows, "partialCase": current, "stage": stage, "physicalKeys": false, "actualNativePaste": true, "nativeControl": nativeControl, "originalClipboardRestored": restored,
            "startup": ["retried": startupRetried, "active": NSApp.isActive, "keyWindow": NSApp.keyWindow === window, "firstResponder": window.firstResponder === view]])
        try? Data().write(to: root.appendingPathComponent("quit"))
        prior?.activate()
        exit(passed && restored ? 0 : 1)
    }
}
@main enum Main {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("result.json").path) else { exit(64) }
        let app = NSApplication.shared, delegate = RichFixture(root)
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}
