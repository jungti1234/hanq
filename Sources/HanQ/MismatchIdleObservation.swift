import AppKit

extension MismatchRecoveryEngine {
    // Timer observation must not monopolize the event-tap run loop while an
    // editor is slow. Key callbacks still take their own pre-insertion snapshot.
    func requestIdleSnapshot() {
        guard idleSnapshotRequest==nil,enabled,!suspended,!recovering else{return}
        let pid=target?.processIdentifier ?? 0,epoch=recoveryEpoch
        let revision=detectionRevision,source=currentSource()
        idleSnapshotSequence+=1;let request=idleSnapshotSequence
        idleSnapshotRequest=request
        let completion:(MismatchSnapshotResult)->Void = {[weak self] result in
            guard let self,self.idleSnapshotRequest==request else{return}
            self.idleSnapshotRequest=nil
            guard self.enabled,!self.suspended,!self.recovering,
                  self.recoveryEpoch==epoch,self.detectionRevision==revision,
                  (self.target?.processIdentifier ?? 0)==pid,self.currentSource()==source,
                  self.fastRecoveryContext(),self.canObserve(),
                  ProcessInfo.processInfo.systemUptime-result.completedAt<0.05 else{return}
            self.unavailableReason=result.reason
            self.consumeIdleSnapshot(result.snapshot)
        }
        if let testIdleRead{testIdleRead(completion)}
        else{snapshotWorker.request(pid:pid,semantics:true,completion:completion)}
    }
}
