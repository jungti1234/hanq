import AppKit
import Carbon

/// Owns the product lifecycle; the recovery algorithm has no app allowlist.
final class MismatchRecoveryController: NSObject {
    let engine=MismatchRecoveryEngine()
    var canRun:()->Bool = { false }
    var active=false
    var timer:Timer?
    var retryAt=0.0
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    var restartTimes:[Double]=[]
    var testStartMonitor:(()->Void)?
    var prepareFreshObservation:()->Bool = { true }
    private var readinessReason=0
    private var startAttempts=0
    private var tapState=0
    lazy var permissionReady:()->Bool = { [weak self] in
        guard AXIsProcessTrusted() else{self?.readinessReason=4;return false}
        guard !IsSecureEventInputEnabled() else{self?.readinessReason=5;return false}
        self?.readinessReason=0;return true
    }
    var busy:Bool { engine.recovering }
    func start(){
        active=true
        guard timer==nil else{return}
        timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.tick()}
        tick()
    }
    func tick(){
        var stage=1,reason=0
        defer{recordMonitor(stage:stage,reason:reason)}
        guard active else{reason=1;return}
        let probe = !NSRunningApplication.runningApplications(withBundleIdentifier:"taek.in.hanq.auto-recovery-probe").isEmpty
        let runnable=canRun()
        let ready=runnable && !probe && permissionReady()
        let disabled=ProcessInfo.processInfo.arguments.contains("--disable-mismatch-recovery")
        guard runnable,!probe,ready,!disabled else {
            reason = !runnable ? 2:(probe ? 3:(!ready ? (readinessReason==0 ? 4:readinessReason):6))
            if engine.enabled{engine.suspend("input_unavailable")}
            return
        }
        if engine.enabled,!engine.suspended {
            tapState=engine.monitorTapsHealthy ? 1:2
            if tapState==2{reason=7;engine.monitorTapFailed(3);return}
        }
        let instant=now()
        if engine.suspended,engine.freshObservationRequested {
            // End all callbacks from the failed epoch before registering again.
            // The controller’s readiness checks above apply even when tabs survive.
            guard instant>=retryAt else{reason=11;return}
            restartTimes.removeAll{instant-$0>=60}
            guard restartTimes.count<3 else{reason=8;return}
            guard !engine.recovering,!engine.rollingBack,engine.pending.isEmpty,
                  engine.switchGate?.filter.consuming != true,engine.canObserve(),
                  prepareFreshObservation() else{reason=9;return}
            engine.closeSession()
            engine.ledger=nil;engine.ledgerAfterRepair=nil
            engine.freshObservationRequested=false;engine.monitorRestartAllowed=true
        }
        if !engine.enabled,instant>=retryAt {
            if engine.suspended {
                restartTimes.removeAll{instant-$0>=60}
                guard restartTimes.count<3 else{reason=8;return}
                guard engine.prepareIdleMonitorRestart() else{reason=9;return}
                restartTimes.append(instant)
            }
            retryAt=instant+2
            startAttempts+=1;stage=2;tapState=0
            if let testStartMonitor{testStartMonitor()}else{engine.start()}
            if !engine.enabled{reason=10}else{stage=3}
        }else if !engine.enabled{reason=11}
    }
    private func recordMonitor(stage:Int,reason:Int){
        guard engine.incidentTrace.enabled else{return}
        var sample=InputIncidentTrace.MonitorSample()
        sample.stage=stage;sample.reason=reason;sample.tapState=engine.enabled ? tapState:0
        sample.active=active;sample.enabled=engine.enabled;sample.suspended=engine.suspended
        sample.recovering=engine.recovering;sample.rollingBack=engine.rollingBack;sample.restartAllowed=engine.monitorRestartAllowed
        sample.pending=engine.pending.count;sample.retained=engine.retained.count
        sample.attempts=startAttempts;sample.failures=engine.monitorFailureCount;sample.failureKind=engine.monitorFailureKind
        sample.stopReason=engine.monitorStopReason;sample.receivedEvents=engine.monitorReceivedEvents
        if let last=engine.monitorLastEventAt {
            sample.lastEventAgeMicros=Int(max(0,min((now()-last)*1_000_000,60_000_000)))
        }
        engine.incidentTrace.monitor(sample)
    }
    func stop(afterIdleTimeout:Bool=false){
        // Both the main and mismatch taps can time out before the next tick.
        // Carry only the idle restart decision over teardown of both ports.
        let resumeClosedRepair = afterIdleTimeout && engine.suspended && engine.freshObservationRequested
        let restartIdle = afterIdleTimeout && engine.suspended && engine.monitorRestartAllowed &&
            !engine.recovering && !engine.rollingBack && engine.pending.isEmpty && engine.switchGate?.filter.consuming != true
        engine.freshObservationRequested=false;active=false;timer?.invalidate();timer=nil
        engine.suspend("hanq_input_stopped")
        if resumeClosedRepair {engine.freshObservationRequested=true}
        if restartIdle {
            engine.monitorRestartAllowed=true
            _ = engine.prepareIdleMonitorRestart()
        }
        recordMonitor(stage:4,reason:1)
    }
    func prepareManualEdit()->Bool {
        guard !engine.recovering else{return false}
        engine.cancelDetection();return true
    }
    func copyRetained(){
        guard !engine.recovering else{return}
        engine.copyPending();tick()
    }
}
