import AppKit
import Carbon

extension OnsetRecoveryEngine {
    // Keep cursor commands distinct from this gate's replay receipt counter,
    // including when an OS delivery route exposes a targeted post to its tap.
    var compositionCommitMarker:Int64 { marker ^ 1 }
    // An AX selection over a live marked consonant can look correct while the
    // IME still commits that consonant before processing its replacement. A
    // native cursor command commits it first, without deleting or rewriting it.
    func commitConsonantComposition(_ candidate:OnsetRecoveryPlan,_ before:OnsetSnapshot){
        if let testCommitComposition {
            guard testCommitComposition(before.element),
                  currentSource()==repairSourceID,let current=snapshot(),
                  CFEqual(current.element,before.element),
                  candidate.matches(text:current.text,selection:current.selection) else {
                park("composition_commit_context_changed");return
            }
            requestRepairSelection(candidate,current)
            return
        }
        guard postCompositionCommit(before.element) else{park("composition_commit_rejected");return}
        log("composition_commit_posted")
        awaitCompositionCommit(candidate,before,deadline:ProcessInfo.processInfo.systemUptime+0.12)
    }

    func postCompositionCommit(_ field:AXUIElement)->Bool {
        guard let source=CGEventSource(stateID:.hidSystemState) else{return false}
        source.userData=compositionCommitMarker
        guard let down=CGEvent(keyboardEventSource:source,virtualKey:123,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:123,keyDown:false) else{return false}
        // Preserve Quartz's native key-code representation. A private source
        // or an AppKit function-character override can be ignored by a live IME.
        // The PID-pinned delivery and caret acknowledgment below remain required.
        for event in [down,up] {event.flags=[]}
        if let testPostCompositionCommit {
            return testPostCompositionCommit(field,down) && testPostCompositionCommit(field,up)
        }
        // Never let a test with mocked replay accidentally post real cursor keys.
        guard testPost==nil,AXIsProcessTrusted(),!IsSecureEventInputEnabled(),
              let target,!target.isTerminated,let ax,
              let focused=focusAccess.focusedElement(application:ax,pid:target.processIdentifier),
              CFEqual(focused,field),currentSource()==repairSourceID else{return false}
        var pid:pid_t=0
        guard AXUIElementGetPid(field,&pid) == .success,pid==target.processIdentifier else{return false}
        // Both edges belong to the proved original process even if focus changes.
        // Its separate marker cannot acknowledge replay; the actual caret below
        // proves completion of this command.
        down.postToPid(pid);up.postToPid(pid)
        return true
    }

    func awaitCompositionCommit(_ candidate:OnsetRecoveryPlan,_ before:OnsetSnapshot,deadline:Double){
        guard recovering,!rollingBack,gate?.healthy() ?? true else{return}
        collectHeld()
        guard currentSource()==repairSourceID else{park("composition_commit_source_changed");return}
        if let current=snapshot() {
            guard CFEqual(current.element,before.element),current.text==before.text else {
                park("composition_commit_context_changed");return
            }
            let expectedCaret=NSRange(location:candidate.isObservedReplay ? before.selection.location-1:candidate.caret,length:0)
            if current.selection==expectedCaret {
                if candidate.isObservedReplay{replayCommitCaret=expectedCaret}
                log("composition_commit_confirmed")
                requestRepairSelection(candidate,current)
                return
            }
            guard current.selection==before.selection else{park("composition_commit_context_changed");return}
        }else if !transientReadFailure {
            park("composition_commit_context_changed");return
        }
        guard ProcessInfo.processInfo.systemUptime<deadline else{park("composition_commit_deadline");return}
        scheduleRecovery(0.002){[weak self] in self?.awaitCompositionCommit(candidate,before,deadline:deadline)}
    }
}
