import AppKit

extension MismatchRecoveryEngine {
    /// Discard a disabled registration after the callback returns. Only an idle
    /// monitor may be rebuilt; an interrupted edit or retained input stays parked.
    func monitorTapFailed(_ kind:Int) {
        guard enabled else{return}
        monitorRestartAllowed = !suspended && !recovering && !rollingBack &&
            pending.isEmpty && retained.isEmpty && switchGate?.filter.consuming != true
        suspended=true
        NSLog("입력 불일치 감시 중단: kind=%d recovering=%d retained=%d restart=%d",
              kind,recovering ? 1:0,retained.count+pending.count,monitorRestartAllowed ? 1:0)
        InputDiagnostics.shared.record("mismatch.monitor_tap_failed kind=\(kind) restart=\(monitorRestartAllowed)")
        DispatchQueue.main.async{[weak self] in self?.suspend("tap_disabled")}
    }

    func prepareIdleMonitorRestart()->Bool {
        guard monitorRestartAllowed,!enabled,tap==nil,!recovering,!rollingBack,
              pending.isEmpty,retained.isEmpty else{return false}
        monitorRestartAllowed=false;suspended=false
        cancelDetection()
        InputDiagnostics.shared.record("mismatch.idle_monitor_restart")
        return true
    }

    var monitorTapsHealthy:Bool {
        guard let tap,let switchTap=switchGate?.tap else{return false}
        return CGEvent.tapIsEnabled(tap:tap) && CGEvent.tapIsEnabled(tap:switchTap)
    }
}
