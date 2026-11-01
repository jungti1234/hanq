import AppKit
import Carbon

extension OnsetRecoveryEngine {
    // Allocation and all preconditions precede the only native request. There
    // is no AX text write, alternate strategy or retry after uncertain delivery.
    func postCommittedUnicode(_ replacement:String,_ field:AXUIElement)->Bool {
        guard gate?.healthy() ?? true,currentSource()==repairSourceID,
              let candidate=currentPlan,candidate.isCommittedLate,
              let live=snapshot(),CFEqual(live.element,field),live.text==candidate.expected,
              live.selection==NSRange(location:candidate.caret,length:candidate.roman.utf16.count),
              (1...32).contains(replacement.utf16.count),
              let source=CGEventSource(stateID:.hidSystemState) else{return false}
        source.userData=compositionCommitMarker
        guard let down=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:false) else{return false}
        let units=Array(replacement.utf16)
        for event in [down,up] {
            event.flags=[]
            units.withUnsafeBufferPointer{event.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress!)}
        }
        if let testPostCommittedUnicode{committedNativeIssued=true;return testPostCommittedUnicode(field,[down,up])}
        // Injected harnesses can never fall through to actual OS delivery.
        guard testPost==nil,testSnapshot==nil,AXIsProcessTrusted(),!IsSecureEventInputEnabled(),
              CGPreflightPostEventAccess(),let target,!target.isTerminated,let ax,
              let focused=focusAccess.focusedElement(application:ax,pid:target.processIdentifier),
              CFEqual(focused,field),currentSource()==repairSourceID,
              attr(field,kAXSelectedTextAttribute) as? String==candidate.roman else{return false}
        var pid:pid_t=0
        guard AXUIElementGetPid(field,&pid) == .success,pid==target.processIdentifier else{return false}
        committedNativeIssued=true
        down.postToPid(pid);up.postToPid(pid)
        return true
    }
}
