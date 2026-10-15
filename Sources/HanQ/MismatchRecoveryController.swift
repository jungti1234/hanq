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
    var permissionReady:()->Bool = {AXIsProcessTrusted() && !IsSecureEventInputEnabled()}
    var busy:Bool { engine.recovering }
    func start(){
        active=true
        guard timer==nil else{return}
        timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.tick()}
        tick()
    }
    func tick(){
        guard active else{return}
        let probe=NSWorkspace.shared.runningApplications.contains{$0.bundleIdentifier=="taek.in.hanq.auto-recovery-probe"}
        guard canRun(),!probe,permissionReady(),
              !ProcessInfo.processInfo.arguments.contains("--disable-mismatch-recovery") else {
            if engine.enabled{engine.suspend("input_unavailable")}
            return
        }
        if engine.enabled,!engine.suspended,!engine.monitorTapsHealthy {
            engine.monitorTapFailed(3)
            return
        }
        let instant=now()
        if !engine.enabled,instant>=retryAt {
            if engine.suspended {
                restartTimes.removeAll{instant-$0>=60}
                guard restartTimes.count<3,engine.prepareIdleMonitorRestart() else{return}
                restartTimes.append(instant)
            }
            retryAt=instant+2
            if let testStartMonitor{testStartMonitor()}else{engine.start()}
        }
    }
    func stop(){active=false;timer?.invalidate();timer=nil;engine.suspend("hanq_input_stopped")}
    func prepareManualEdit()->Bool {
        guard !engine.recovering else{return false}
        engine.cancelDetection();return true
    }
    func copyRetained(){
        guard !engine.recovering else{return}
        engine.copyPending();tick()
    }
}
