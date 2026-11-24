import AppKit
import Carbon

extension Fixture {
    // Text keys target only this process. The optional activation shortcut uses macOS.
    // The initial wrong ASCII is seeded
    // explicitly so that observing a rare macOS activation delay is unnecessary.
    func checkMixedReturn(_ item: Case) {
        let id = item.id
        let keys: [CGKeyCode]
        switch id {
        case KoreanKeyboardLayout.twoSetID: keys = [15, 40, 1]
        case KoreanKeyboardLayout.threeSetID, KoreanKeyboardLayout.threeSet390ID: keys = [40, 3, 1]
        default: keys = [5, 0, 45]
        }
        let abc = "com.apple.keylayout.ABC"
        let forced = item.mixed
        let testShortcut = forced && CommandLine.arguments.contains("--confirmed-replay-shortcut")
        var shortcutDowns = 0
        var retryAtShortcut: Int?
        var injectedKeyDowns = 0
        func owned() -> Bool { NSApp.isActive && window.firstResponder === view }
        func wait(_ condition: @escaping () -> Bool, _ label: String, _ next: @escaping () -> Void) {
            guard owned() else { finish(false,"lost test window at \(label)"); return }
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            func poll() {
                guard owned() else { self.finish(false,"lost test window at \(label)"); return }
                if condition() { next(); return }
                if ProcessInfo.processInfo.systemUptime >= deadline { self.finish(false,"\(id) \(label) timed out"); return }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.015,execute:poll)
            }
            poll()
        }
        func send(_ codes: [CGKeyCode], shift: Bool = false) {
            guard owned() else { finish(false,"lost test window before key"); return }
            for code in codes { for down in [true,false] {
                guard let e = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else { finish(false,"event unavailable"); return }
                e.flags = shift ? .maskShift : []; e.postToPid(getpid())
            }}
        }
        func composed(_ value: String) -> Bool {
            view.string == value && view.selectedRange() == NSRange(location:value.utf16.count,length:0)
        }
        func select(_ target: String, _ next: @escaping () -> Void) {
            guard owned(),InputSourceAccess.select(target)==noErr else { finish(false,"could not select \(target)"); return }
            wait({ InputSourceAccess.currentID()==target },"source \(target)") {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:next)
            }
        }
        func complete() {
            if testShortcut {
                guard injectedKeyDowns == 2, shortcutDowns == 1, retryAtShortcut == 0 else {
                    finish(false,"unexpected early activation count for \(id)"); return
                }
                print("PASS native-shortcut",id,"injected ASCII replay count",injectedKeyDowns,"shortcut",shortcutDowns,"direct retries",retryAtShortcut ?? -1)
            }
            print("PASS native-roundtrip",id,forced ? "seeded ASCII, product repair":"normal",
                  "prefix Q unchanged; 가 → 간 → 간가; caret=4; active layout",InputSourceAccess.currentLayoutID())
            fflush(stdout)
            owner?.closeSession(); owner=nil
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1){ self.next() }
        }
        func continueComposition() {
            let text = "간Q"
            wait({ composed(text+"가") },"first syllable") {
                send([keys[2]])
                wait({ composed(text+"간") },"final consonant") {
                    send(Array(keys.prefix(2)))
                    wait({ composed(text+"간가") && InputSourceAccess.currentID()==id },"next syllable",complete)
                }
            }
        }
        func returnToKorean() {
            guard owned(), composed("간Q"), InputSourceAccess.currentID()==id else { finish(false,"return prefix/source changed"); return }
            if !forced {
                send(Array(keys.prefix(2))); continueComposition(); return
            }
            var plan = MismatchRecoveryPlan(before:"간Q",caret:2,sourceID:id)
            for code in keys.prefix(2){ _ = plan.append(code:code,shift:false) }
            view.insertText(plan.replayRoman,replacementRange:view.selectedRange())
            guard composed("간Q"+plan.replayRoman) else { finish(false,"could not establish wrong suffix"); return }
            let p = MismatchRecoveryEngine(), field = AXUIElementCreateApplication(getpid())
            owner=p; p.enabled=true; p.target=NSRunningApplication.current; p.planElement=field
            p.testSnapshot={ owned() ? MismatchSnapshot(element:field,text:self.view.string,selection:self.view.selectedRange()) : nil }
            p.testSelectionWritable={_ in true}
            p.testSetRange={ _,range in
                guard owned(),range.location==2,range.length==plan.replayRoman.utf16.count else { return .failure }
                self.view.setSelectedRange(range);return .success
            }
            p.testPost={ e in if owned(){e.postToPid(getpid())} }
            if testShortcut {
                guard p.activationShortcut.configured, p.activationShortcut.canPost(), p.activationShortcut.modifiersClear() else {
                    finish(false,"configured Control–Space unavailable for native shortcut trial"); return
                }
                let originalCanPost = p.activationShortcut.canPost
                p.activationShortcut.canPost = { owned() && originalCanPost() }
                // Inject the stale-ABC report and editor output only on the first replay.
                // The subsequent shortcut uses the configured macOS input-source path.
                p.testActivationNeeded = { injectedKeyDowns > 0 && shortcutDowns == 0 }
                let postShortcut = p.activationShortcut.post
                p.activationShortcut.post = { [weak p] event in
                    guard owned() else { return }
                    if event.type == .keyDown { shortcutDowns += 1; retryAtShortcut = p?.koreanRetries }
                    postShortcut(event)
                }
                p.testPostAtTap = { event,_ in
                    guard owned() else { return }
                    if shortcutDowns == 0 {
                        if event.type == .keyDown, let key = UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)),
                           let ascii = MismatchRecoveryPlan.character(key,event.flags.contains(.maskShift)) {
                            injectedKeyDowns += 1
                            self.view.insertText(ascii,replacementRange:self.view.selectedRange())
                        }
                    } else { event.postToPid(getpid()) }
                }
            }
            guard let start = p.testSnapshot?() else { finish(false,"lost test field before repair"); return }
            p.beginRecovery(plan,start)
            wait({ !p.recovering && !p.suspended && p.retained.isEmpty && composed("간Q가") },"actual IME repair",continueComposition)
        }
        guard InputSourceAccess.currentID()==id else { finish(false,"wrong starting source"); return }
        send(keys)
        wait({ composed("간") },"initial syllable") {
            select(abc) {
                send([12],shift:true)
                wait({ composed("간Q") },"intentional Q") { select(id,returnToKorean) }
            }
        }
    }
}
