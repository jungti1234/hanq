import AppKit

extension MismatchRecoveryEngine {
    // An external API round trip can overlap our own restoration. Do not
    // select a source between its two observations: the return would then
    // look like our acknowledgement and leave the intermediate user intent.
    static let externalSourceQuietInterval=0.1
    static let externalSourceSettlementLimit=0.3

    func settleExternalSource(){
        let now=interactionNow()
        if let previous=externalSourceSettlement {
            externalSourceSettlement=(previous.started,now,previous.changes+1)
            return
        }
        externalSourceSettlement=(now,now,1);sourceSettlementRevision+=1
        asyncReady=nil
        NSLog("입력 불일치 외부 소스 대기: stage=1 changes=1")
        pollExternalSource(epoch:recoveryEpoch,revision:sourceSettlementRevision)
    }
    func pollExternalSource(epoch:Int,revision:Int){
        guard recovering,recoveryEpoch==epoch,sourceSettlementRevision==revision,
              externalSourceSettlement != nil else{return}
        guard fastRecoveryContext(),canObserve() else{park("external_source_context_changed");return}
        guard ProcessInfo.processInfo.systemUptime<recoveryDeadline else{park("external_source_deadline");return}
        observeRecoverySource(currentSource())
        guard recovering,let state=externalSourceSettlement,sourceSettlementRevision==revision else{return}
        let now=interactionNow()
        guard now-state.started<Self.externalSourceSettlementLimit else{park("external_source_unsettled");return}
        if now-state.changed>=Self.externalSourceQuietInterval {
            NSLog("입력 불일치 외부 소스 대기: stage=2 changes=%d korean=%d",state.changes,MismatchKeyboardLayout.supports(intendedSource) ? 1:0)
            cancelExternalSourceSettlement();resumeDeferredSourceWork();return
        }
        // This poll must run while the normal recovery callbacks are paused.
        // It never selects a source, edits text, posts keys or extends a deadline.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.01){[weak self] in
            self?.pollExternalSource(epoch:epoch,revision:revision)
        }
    }
    func cancelExternalSourceSettlement(){
        externalSourceSettlement=nil;sourceSettlementRevision+=1
    }
    func resumeDeferredSourceWork(){
        guard !sourceWorkPaused else{return}
        let actions=pausedRecoveryActions;pausedRecoveryActions=[]
        for action in actions{later(0,action)}
    }
}
