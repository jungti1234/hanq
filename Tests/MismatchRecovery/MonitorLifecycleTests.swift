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
        p.monitorTapFailed(1)
        RunLoop.current.run(until:Date().addingTimeInterval(0.015))
        probeTestCheck(!p.enabled && p.suspended && p.tap==nil && posts==0)
        probeTestCheck(p.prepareIdleMonitorRestart()==(mode=="idle"),mode)
        if mode=="idle"{probeTestCheck(!p.suspended && p.plan==nil && p.planElement==nil)}
        else{probeTestCheck(p.suspended)}
        probeTestCheck(!p.prepareIdleMonitorRestart())
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
    print("PASS: idle disabled tap rebuild, active edit/queued input/held switch stay parked, bounded restart rate, permission denial and explicit stop; no OS keys or taps")
}
