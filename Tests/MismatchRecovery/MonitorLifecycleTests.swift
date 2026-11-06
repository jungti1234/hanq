import AppKit

func runMonitorLifecycleTests(){
    for mode in ["idle","recovery","pending","retained","previous-park","switch-held"] {
        let p=MismatchRecoveryEngine();p.enabled=true
        let key=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!
        switch mode {
        case "recovery":p.recovering=true
        case "pending":p.pending=[key]
        case "retained":p.retained=[key]
        case "previous-park":p.suspended=true
        case "switch-held":
            let gate=MismatchSwitchGate(accepts:{true},switched:{_ in})
            _ = gate.filter.process(type:.flagsChanged,key:54,flags:CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10),acceptNewPress:true)
            p.switchGate=gate
        default:break
        }
        var posts=0;p.testPost={_ in posts+=1}
        p.monitorTapFailed(1);p.monitorTapFailed(2)
        RunLoop.current.run(until:Date().addingTimeInterval(0.015))
        probeTestCheck(!p.enabled && p.suspended && p.tap==nil && posts==0)
        probeTestCheck(p.prepareIdleMonitorRestart()==(mode=="idle"),mode)
        if mode=="idle"{probeTestCheck(!p.suspended && p.plan==nil && p.planElement==nil)}
        else{probeTestCheck(p.suspended)}
        probeTestCheck(!p.prepareIdleMonitorRestart())
        probeTestCheck(p.monitorFailureCount==2 && p.monitorFailureKind==2,"both failure notifications remain countable")
    }
    for order in [[1,2],[2,1],[3,1,2]] {
        let p=MismatchRecoveryEngine();p.enabled=true
        for kind in order { p.monitorTapFailed(kind) }
        RunLoop.current.run(until:Date().addingTimeInterval(0.015))
        probeTestCheck(!p.enabled && p.suspended && p.monitorRestartAllowed,
                       "duplicate tap failures preserve the first idle restart decision")
        probeTestCheck(p.prepareIdleMonitorRestart(),"duplicate failure permits one idle restart")
        probeTestCheck(!p.prepareIdleMonitorRestart(),"restart authorization is consumed once")
    }
    let c=MismatchRecoveryController();var instant=0.0,starts=0,permission=true
    c.active=true;c.canRun={true};c.now={instant};c.permissionReady={permission}
    c.testStartMonitor={starts+=1;c.engine.enabled=true}
    for time in [0.0,2.0,4.0,6.0,62.0] {
        instant=time;c.engine.enabled=false;c.engine.suspended=true;c.engine.monitorRestartAllowed=true
        c.tick()
        probeTestCheck(starts==(time==6 ? 3:(time==62 ? 4:Int(time/2)+1)))
    }
    c.engine.enabled=false;c.engine.suspended=true;c.engine.monitorRestartAllowed=true
    instant=64;permission=false;c.tick();probeTestCheck(starts==4 && c.engine.suspended)
    permission=true;c.engine.retained=[CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!]
    c.tick();probeTestCheck(starts==4 && c.engine.retained.count==1 && c.engine.suspended)
    c.stop();probeTestCheck(!c.engine.monitorRestartAllowed)
    var records:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,writer:{records.append($0)})
    c.engine.incidentTrace=trace;c.active=true;c.engine.enabled=false
    c.engine.retained.removeAll();c.engine.suspended=true;c.engine.monitorRestartAllowed=false
    c.tick();trace.flush();trace.mark();trace.flush()
    probeTestCheck(records.last?.monitorStatus?.current.reason==9,"unsafe restart is diagnosed without a start attempt")
    permission=false;c.tick();trace.flush();trace.mark();trace.flush()
    probeTestCheck(records.last?.monitorStatus?.current.reason==4,"permission refusal is distinguishable from idle input")
    probeTestCheck(starts==4,"diagnostics cannot authorize registration")
    print("PASS: idle disabled tap rebuild, active edit/queued input/held switch stay parked, bounded restart rate, permission denial and explicit stop; no OS keys or taps")
}
