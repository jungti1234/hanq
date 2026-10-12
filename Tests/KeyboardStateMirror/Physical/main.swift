import AppKit
import Carbon

// Human input in this owned window only. No event tap, AX requests, key posts,
// or key-state reset. Store fixed-key counts and booleans, never arbitrary text.
final class PhysicalWindow: NSWindow {
    weak var audit: PhysicalAudit?
    override func sendEvent(_ event: NSEvent) {
        if audit?.letter(event) == true { return }
        super.sendEvent(event)
    }
}
final class PhysicalField: NSTextView {
    var pasteCalls = 0
    override func paste(_ sender: Any?) { pasteCalls += 1; super.paste(sender) }
}

final class PhysicalAudit: NSObject, NSApplicationDelegate {
    struct Step {
        let name: String, instruction: String, key: CGKeyCode
        let initialSource: String?
    }
    let abc = "com.apple.keylayout.ABC", korean = "com.apple.inputmethod.Korean.2SetKorean"
    lazy var steps: [Step] = [
        .init(name: "L tap", instruction: "L 키를 짧게 한 번 누르고 완전히 놓아주세요.", key: 37, initialSource: abc),
        .init(name: "L repeat", instruction: "L 키를 약 2초 누르고 있다가 완전히 놓아주세요.", key: 37, initialSource: abc),
        .init(name: "right Command to Korean", instruction: "우측 Command만 1초 누르고 완전히 놓아주세요.", key: 54, initialSource: abc),
        .init(name: "right Command to English", instruction: "우측 Command만 다시 1초 누르고 완전히 놓아주세요.", key: 54, initialSource: nil),
        .init(name: "right Option conversion", instruction: "선택된 rks는 그대로 두고 우측 Option만 1초 누른 뒤 놓아주세요.", key: 61, initialSource: korean),
        .init(name: "right Command with L", instruction: "우측 Command를 누른 채 L을 짧게 한 번 누르세요. L부터 놓고 Command를 놓아주세요.", key: 54, initialSource: korean),
        .init(name: "right Option with L", instruction: "우측 Option을 누른 채 L을 짧게 한 번 누르세요. L부터 놓고 Option을 놓아주세요.", key: 61, initialSource: abc)
    ]
    let root: URL
    var original: TISInputSource?
    var window: PhysicalWindow!, field: PhysicalField!
    let heading = NSTextField(labelWithString: ""), hint = NSTextField(wrappingLabelWithString: ""), status = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?, index = 0, armed = false, finishing = false
    var downHID = false, downSession = false, letterDownHID = false, letterDownSession = false
    var downs = 0, ups = 0, repeats = 0, dirtyLetterFlags = false
    var seenPress = false, releasedAt: Double?, armedAt = 0.0, deadline = 0.0
    var sourceBefore = "", rows: [[String: Any]] = [], retries = 0, lastProgress = 0.0
    init(_ root: URL) {
        self.root = root
        if let data = try? Data(contentsOf:root.appendingPathComponent("prior.json")),
           let prior = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           prior["physical_input"] as? Bool == true, prior["posts_keys"] as? Bool == false,
           let oldRows = prior["cases"] as? [[String:Any]] {
            // Preserve only checks whose input and verification are unchanged.
            let names = ["L tap","L repeat","right Command to Korean","right Command to English"]
            for row in oldRows.prefix(4) {
                guard row["pass"] as? Bool == true,
                      row["case"] as? String == names[index] else { break }
                rows.append(row); index += 1
            }
        }
    }
    var now: Double { ProcessInfo.processInfo.systemUptime }
    func state() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for (name, key): (String, CGKeyCode) in [("L",37),("rightCommand",54),("rightOption",61)] {
            result["HID_" + name] = CGEventSource.keyState(.hidSystemState, key: key)
            result["session_" + name] = CGEventSource.keyState(.combinedSessionState, key: key)
        }
        for (name, mask): (String, UInt64) in [("rightCommand",0x10),("rightOption",0x40)] {
            result["HID_flags_" + name] = CGEventSource.flagsState(.hidSystemState).rawValue & mask != 0
            result["session_flags_" + name] = CGEventSource.flagsState(.combinedSessionState).rawValue & mask != 0
        }
        return result
    }
    func held(_ source: CGEventSourceStateID, _ key: CGKeyCode) -> Bool {
        if key == 54 || key == 61 {
            // Modifier presses are flagsChanged. Observe their SDK-defined
            // right-side flags rather than requiring a keyboard keyDown record.
            let mask: UInt64 = key == 54 ? 0x10:0x40
            return CGEventSource.flagsState(source).rawValue & mask != 0
        }
        return CGEventSource.keyState(source,key:key)
    }
    func write(_ value: [String: Any], _ name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }
    func progress(_ stage: String) {
        write(["stage":stage,"step":index + 1,"verified":rows.count,"active":NSApp.isActive,
               "downs":downs,"ups":ups,"repeats":repeats,"state":state(),"source":InputSourceAccess.currentID(),
               "selectionLocation":field?.selectedRange().location ?? 0,"selectionLength":field?.selectedRange().length ?? 0,
               "pasteCalls":field?.pasteCalls ?? 0,"expectedTextMatches":index >= 4 ? field?.string == (index == 4 ? "간":"l"):true], "progress.json")
    }
    func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(title:"Edit",action:nil,keyEquivalent:""); menu.addItem(editItem)
        let edit = NSMenu(title:"Edit"); editItem.submenu = edit
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu = menu
    }
    func checkEditorMenu() {
        // Local AppKit equivalent only, no CGEvent posting or user keystroke.
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map { (type,$0) } } }
        board.clearContents(); board.setString("간",forType:.string); let generation = board.changeCount
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:now,
            windowNumber:window.windowNumber,context:nil,characters:"v",charactersIgnoringModifiers:"v",isARepeat:false,keyCode:9)!
        let missingMenuHandled = NSApp.mainMenu?.performKeyEquivalent(with:event) ?? false
        installMenus()
        let handled = NSApp.mainMenu!.performKeyEquivalent(with:event)
        let pasted = field.string == "간" && field.pasteCalls == 1
        if board.changeCount == generation {
            board.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type,data) in entries { item.setData(data,forType:type) }; return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        let restored = original.map { TISSelectInputSource($0) == noErr } ?? false
        write(["passed":!missingMenuHandled && handled && pasted && restored,"physical_input":false,
               "posts_keys":false,"missingMenuHandled":missingMenuHandled,"installedMenuHandled":handled,
               "pasteCalls":field.pasteCalls,"expectedTextMatches":pasted,"originalSourceRestored":restored,
               "reason":"local editor paste shortcut validation"],"results.json")
        exit(!missingMenuHandled && handled && pasted && restored ? 0:1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        window = PhysicalWindow(contentRect:NSRect(x:180,y:200,width:760,height:340),styleMask:[.titled],backing:.buffered,defer:false)
        window.audit = self; window.isReleasedWhenClosed = false; window.title = "한Q · 물리 키 놓음·전환 검사"
        heading.frame = NSRect(x:20,y:290,width:720,height:30); heading.font = .boldSystemFont(ofSize:20)
        hint.frame = NSRect(x:20,y:220,width:720,height:60); hint.font = .systemFont(ofSize:17)
        status.frame = NSRect(x:20,y:20,width:720,height:80)
        for label in [heading,hint,status] { window.contentView!.addSubview(label) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        deadline = now + 1200
        let editorCheck = CommandLine.arguments.contains("--verify-editor")
        if editorCheck { index = 4 } else { installMenus() }
        if !editorCheck { timer = Timer.scheduledTimer(withTimeInterval:0.01,repeats:true) { [weak self] _ in self?.poll() } }
        write(["pid":getpid(),"physical_input":!editorCheck,"posts_keys":false,"installs_taps":false], "ready.json")
        prepare()
        if editorCheck { DispatchQueue.main.asyncAfter(deadline:.now()+0.8) { self.checkEditorMenu() } }
    }
    func prepare(_ retry: String? = nil) {
        armed = false; seenPress = false; releasedAt = nil
        downHID = false; downSession = false; letterDownHID = false; letterDownSession = false
        downs = 0; ups = 0; repeats = 0; dirtyLetterFlags = false
        field?.inputContext?.discardMarkedText(); field?.removeFromSuperview()
        field = PhysicalField(frame:NSRect(x:20,y:115,width:720,height:85)); field.isRichText = false
        field.isEditable = index >= 4; field.isSelectable = index >= 4
        field.string = index == 4 ? "rks" : ""
        window.contentView!.addSubview(field); window.makeFirstResponder(field)
        field.setSelectedRange(index == 4 ? NSRange(location:0,length:3) : NSRange(location:0,length:0))
        if let id = steps[index].initialSource, InputSourceAccess.select(id) != noErr { finish(false,"input source unavailable"); return }
        // Source activation can change the editor's selection. Publish a stable
        // selected ASCII range only after the source is ready, before the key.
        sourceBefore = InputSourceAccess.currentID()
        armedAt = now + 0.8
        heading.stringValue = "\(index + 1)/\(steps.count) · 준비 중"
        hint.stringValue = "잠시 기다려주세요. " + (retry ?? "")
        status.stringValue = "검사: Mac 내장 키보드 · 시험 창에서만 입력해주세요.\n입력기 전환은 시험이 준비합니다."
        progress("preparing")
    }
    func letter(_ event: NSEvent) -> Bool {
        guard armed, NSApp.isActive, window.isKeyWindow, event.keyCode == 37,
              event.type == .keyDown || event.type == .keyUp else { return false }
        if event.type == .keyDown {
            downs += 1; if event.isARepeat { repeats += 1 }
            letterDownHID = letterDownHID || CGEventSource.keyState(.hidSystemState,key:37)
            letterDownSession = letterDownSession || CGEventSource.keyState(.combinedSessionState,key:37)
            dirtyLetterFlags = dirtyLetterFlags || !event.modifierFlags.intersection([.command,.option,.control]).isEmpty
        } else { ups += 1 }
        // A raw receiver avoids accent/IME press-and-hold behavior in the repeat
        // test. The preceding 10 physical words exercise actual IME text input.
        return index < 2
    }
    func poll() {
        guard !finishing else { return }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("quit").path) { finish(false,"cancelled"); return }
        if now > deadline { finish(false,"physical input timeout"); return }
        guard NSApp.isActive, window.isKeyWindow else { return }
        if !armed {
            guard now >= armedAt, state().values.allSatisfy({!$0}) else { return }
            if index == 4 { field.setSelectedRange(NSRange(location:0,length:3)) }
            armed = true; heading.stringValue = "\(index + 1)/\(steps.count) · 입력해주세요"
            hint.stringValue = steps[index].instruction; progress("waiting_for_physical_keys")
        }
        let key = steps[index].key
        let hid = held(.hidSystemState,key), session = held(.combinedSessionState,key)
        downHID = downHID || hid; downSession = downSession || session
        if hid || session { seenPress = true; releasedAt = nil }
        let flags = state(), clean = flags.values.allSatisfy({!$0})
        status.stringValue = "L 누름 \(downs) · 놓음 \(ups) · 반복 \(repeats)\n\(clean ? "관측한 키가 모두 놓여 있습니다." : "누름 상태를 관측 중입니다.")"
        if now - lastProgress >= 0.2 { progress("waiting_for_physical_keys"); lastProgress = now }
        guard seenPress else { return }
        if !hid && !session {
            if releasedAt == nil { releasedAt = now }
            guard clean, now - releasedAt! >= 0.35 else { return }
            if index == 4 && field.string != "간" && now - releasedAt! < 3 { return }
            verify()
        }
    }
    func verify() {
        let source = InputSourceAccess.currentID(), s = state()
        let letterOK = downs == 1 && ups == 1 && repeats == 0 && !dirtyLetterFlags
        let sawLetter = letterDownHID && letterDownSession
        let pressOK = downHID && downSession
        var result = false
        switch index {
        case 0: result = pressOK && sawLetter && letterOK && source == abc
        case 1: result = pressOK && sawLetter && downs > 1 && repeats > 0 && ups == 1 && !dirtyLetterFlags && source == abc
        case 2: result = pressOK && source.hasPrefix("com.apple.inputmethod.Korean.") && source != sourceBefore
        case 3: result = pressOK && source == abc && source != sourceBefore
        case 4: result = pressOK && source == korean && field.string == "간" && field.selectedRange() == NSRange(location:1,length:0)
        case 5: result = pressOK && sawLetter && letterOK && source == abc && field.string == "l"
        case 6: result = pressOK && sawLetter && letterOK && source == abc && field.string == "l"
        default: break
        }
        // Missing a quick press or a human repeating the tap is not proof of a
        // product defect. Preserve earlier successes and ask for this step again.
        if index < 2 && !result {
            retries += 1
            prepare(index == 0 ? "이번에는 L을 짧게 한 번만 눌러주세요." : "이번에는 L을 2초 이상 누른 뒤 놓아주세요.")
            return
        }
        rows.append(["case":steps[index].name,"pass":result,"pressedHID":downHID,"pressedSession":downSession,
                     "letterPressedHID":letterDownHID,"letterPressedSession":letterDownSession,"downs":downs,"ups":ups,
                     "repeats":repeats,"letterShortcutFlags":dirtyLetterFlags,"finalState":s,"sourceBefore":sourceBefore,
                     "sourceAfter":source,"expectedTextMatches":index >= 4 ? field.string == (index == 4 ? "간":"l") : true,
                     "selectionLocation":field.selectedRange().location,"selectionLength":field.selectedRange().length,
                     "pasteCalls":field.pasteCalls])
        progress(result ? "passed" : "failed")
        guard result else { finish(false,"physical key or action verification failed at step \(index + 1)"); return }
        index += 1
        if index == steps.count { finish(true,"7 physical press/release, repeat, source switch and Option conversion cases passed") }
        else { prepare() }
    }
    func finish(_ passed: Bool, _ reason: String) {
        finishing = true; armed = false; timer?.invalidate(); field?.inputContext?.discardMarkedText()
        let finalState = state()
        let restored = original.map { TISSelectInputSource($0) == noErr } ?? false
        write(["passed":passed && restored,"reason":reason,"cases":rows,"physical_input":true,"keyboard":"Mac built-in",
               "posts_keys":false,"installs_taps":false,"finalState":finalState,"originalSourceRestored":restored,"retries":retries], "results.json")
        print(passed && restored ? "PASS: \(reason)" : "FAIL: \(reason)"); fflush(stdout); exit(passed && restored ? 0:1)
    }
}
guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--verify-editor") else { exit(0) }
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let owner = PhysicalAudit(URL(fileURLWithPath:CommandLine.arguments[1])); app.delegate = owner; app.run()
