import AppKit
import Carbon

/// Starts only alongside HanQ's input lifecycle, and follows the frontmost process without an app allowlist.
final class OnsetRecoveryController: NSObject {
    var canRun: () -> Bool = { false }
    var canBeginRepair: () -> Bool = { true }
    var willBeginRepair: () -> Void = {}
    var engine: OnsetRecoveryEngine?
    var timer: Timer?
    var failed = false
    var retryAt=0.0
    var retryDelay=1.0
    var healthySince:Double?
    var now:()->Double = { ProcessInfo.processInfo.systemUptime }
    var launchEngine:(OnsetRecoveryEngine)->Void = { $0.start() }
    func noteFailure(){
        failed=true;healthySince=nil
        retryAt=now()+retryDelay;retryDelay=min(8,retryDelay*2)
    }
    func replaceStoppedEngine(){
        guard now()>=retryAt else{return}
        let old=engine
        old?.closeSession()
        let next=OnsetRecoveryEngine()
        next.retainedInput=(old?.retainedInput ?? [])+(old?.pending ?? [])
        old?.pending=[];old?.retainedInput=[]
        next.canBeginRepair = { [weak self] in self?.canBeginRepair() ?? false }
        next.willBeginRepair = { [weak self] in self?.willBeginRepair() }
        next.didStop = { [weak self,weak next] in
            guard let self,let next,self.engine === next else{return};self.noteFailure()
        }
        engine=next;failed=false;healthySince=now()
        launchEngine(next)
        if !next.enabled{noteFailure()}
    }
    var probeRunning = false
    var active=false
    var boundPID:pid_t?
    var testConditions:(()->(allowed:Bool,ready:Bool,probe:Bool,pid:pid_t?))?
    static func supports(pid: pid_t?, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard let pid else { return false }
        return pid > 0 && pid != ownPID
    }
    static func needsRebind(currentPID: pid_t?, frontPID: pid_t?) -> Bool { currentPID != frontPID }
    var activationObserver: NSObjectProtocol?
    static func recoveryAllowed(arguments:[String])->Bool {
        !arguments.contains("--disable-onset-recovery")
    }
    var allowed: Bool { Self.recoveryAllowed(arguments:ProcessInfo.processInfo.arguments) }

    func start() {
        active=true
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        tick()
    }
    func stop() {
        active=false
        timer?.invalidate(); timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; activationObserver = nil
        // Permission/policy teardown must release the gate immediately, never replay.
        if let engine, engine.enabled || engine.recovering { engine.emergencyStop("hanq_input_stopped") }
    }
    func tick() {
        guard active else{return}
        let conditions=testConditions?()
        probeRunning = conditions?.probe ?? NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "taek.in.hanq.onset-recovery-probe" }
        if probeRunning {
            if let engine, engine.enabled {
                if engine.recovering { engine.emergencyStop("probe_running") }
                else { engine.closeSession() }
            }
            return
        }
        guard conditions?.allowed ?? allowed, conditions?.ready ?? (canRun() && AXIsProcessTrusted() && !IsSecureEventInputEnabled()) else {
            if let engine, engine.enabled { engine.emergencyStop("hanq_input_unavailable") }
            return
        }
        let frontPID = conditions == nil ? NSWorkspace.shared.frontmostApplication?.processIdentifier:conditions?.pid
        let target = Self.supports(pid: frontPID)
        if !target || Self.needsRebind(currentPID: boundPID, frontPID: frontPID) {
            if let engine, engine.enabled {
                if engine.recovering { engine.emergencyStop("target_changed") }
                else { engine.closeSession() }
            }
            if !target { return }
        }
        if engine?.enabled != true { boundPID=frontPID;replaceStoppedEngine() }
        else if let since=healthySince,now()-since>=5 { retryDelay=1 }
    }
    func prepareManualEdit() -> Bool {
        guard engine?.recovering != true else { return false }
        engine?.onset.cancel(); engine?.plan = nil
        return true
    }

}
