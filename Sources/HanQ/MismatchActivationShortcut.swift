import AppKit
import Carbon

// Optional last-retry activation through the configured OS input-source path.
// A Korean TIS ID can coexist with ABC translation and a missing IME override.
final class MismatchActivationShortcut {
    private(set) var busy=false
    private var generation=0
    private var release:(()->Void)?
    private lazy var eventSource=CGEventSource(stateID:.privateState)
    var configuration:()->(CGKeyCode,CGEventFlags)? = {
        guard let keys=UserDefaults(suiteName:"com.apple.symbolichotkeys")?.dictionary(forKey:"AppleSymbolicHotKeys"),
              let item=keys["60"] as? [String:Any],(item["enabled"] as? NSNumber)?.boolValue==true,
              let value=item["value"] as? [String:Any],value["type"] as? String=="standard",
              let p=value["parameters"] as? [NSNumber],p.count==3,p[1].intValue==49,
              p[2].uint64Value==CGEventFlags.maskControl.rawValue else{return nil}
        return (49,.maskControl)
    }
    var canPost:()->Bool = {CGPreflightPostEventAccess() && !IsSecureEventInputEnabled()}
    var modifiersClear:()->Bool = {CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift]).isEmpty}
    var schedule:(Double,@escaping ()->Void)->Void = {delay,action in DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:action)}
    var post:(CGEvent)->Void = {$0.post(tap:.cghidEventTap)}
    var releasePosted:(CGEvent,pid_t?)->Void = {event,pid in
        if KeyboardStateMirror.shared.ready{KeyboardStateMirror.shared.releasePosted(event,to:pid)}
        else{event.post(tap:.cghidEventTap)} // Mirror failure must still attempt the owned releases.
    }
    var configured:Bool {guard let (code,flags)=configuration() else{return false};return code==49 && flags == .maskControl}
    deinit{cancel()}
    func cancel(){generation+=1;release?();release=nil;busy=false}
    func request(marker:Int64,recipient:NSRunningApplication?,valid:@escaping ()->Bool)->OSStatus {
        guard !busy,configured,canPost(),modifiersClear(),valid(),let source=eventSource else{return -50}
        func event(_ code:CGKeyCode,_ down:Bool,_ type:CGEventType,_ flags:CGEventFlags)->CGEvent? {
            guard let e=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down) else{return nil}
            e.type=type;e.flags=flags;e.setIntegerValueField(.eventSourceUserData,value:marker);return e
        }
        guard let controlDown=event(59,true,.flagsChanged,.maskControl),let controlUp=event(59,false,.flagsChanged,[]),
              let down=event(49,true,.keyDown,.maskControl),let up=event(49,false,.keyUp,.maskControl) else{return -50}
        let cleanup=releasePosted
        var spaceHeld=false,controlHeld=true
        busy=true;generation+=1;let token=generation
        release={
            let pid=recipient?.isTerminated==false ? recipient?.processIdentifier:nil
            if spaceHeld{cleanup(up,pid);spaceHeld=false}
            if controlHeld{cleanup(controlUp,pid);controlHeld=false}
        }
        post(controlDown)
        schedule(0.05){[weak self] in
            guard let self,self.generation==token else{return}
            guard valid(),self.canPost() else{self.cancel();return}
            spaceHeld=true;self.post(down)
            self.schedule(0.03){[weak self] in
                guard let self,self.generation==token else{return}
                guard valid(),self.canPost() else{self.cancel();return}
                self.post(up);spaceHeld=false
                self.schedule(0.03){[weak self] in
                    guard let self,self.generation==token else{return}
                    guard valid(),self.canPost() else{self.cancel();return}
                    self.post(controlUp);controlHeld=false;self.release=nil
                }
                self.schedule(0.08){[weak self] in
                    guard let self,self.generation==token else{return};self.busy=false
                }
            }
        }
        return noErr
    }
}

extension MismatchRecoveryEngine {
    func activationShortcutSupported()->Bool {
        // Snapshot/source doubles must opt into the fully stubbed activation
        // tests; existing retry tests must never reach a real OS shortcut.
        if testSnapshot != nil || testSource != nil || testSelectSource != nil {
            guard testActivationNeeded != nil else{return false}
        }
        return recoverySourceID==mismatchKoreanID && currentSource()==recoverySourceID && activationShortcut.configured
    }
    func needsActivationShortcut()->Bool {
        if let testActivationNeeded{return testActivationNeeded()}
        guard activationShortcutSupported() else{return false}
        let layout=InputSourceAccess.currentLayoutID()
        return InputSourceAccess.currentOverrideID()==nil && [englishID,"com.apple.keylayout.ABC","com.apple.keylayout.US"].contains(layout)
    }
    func chooseKoreanWithActivationShortcut()->OSStatus {
        // The direct English selection immediately preceded this operation;
        // an intervening user source boundary invalidates that previous-source proof.
        guard recovering,!rollingBack,koreanRetries==2,currentSource()==englishID else{return -50}
        let boundaries=recoverySourceBoundaries.count,interaction=sourceInteractionRevision
        return systemSwitch.request(recoverySourceID,valid:{[weak self] in self?.fastRecoveryContext()==true},current:currentSource,select:{[weak self] _ in
            guard let self else{return -50}
            return self.activationShortcut.request(marker:self.marker,recipient:self.target,valid:{[weak self] in
                guard let self else{return false}
                return self.recovering && !self.rollingBack && !self.sourceWorkPaused && self.recoverySourceBoundaries.count==boundaries && self.sourceInteractionRevision==interaction && self.fastRecoveryContext() && self.canObserve() && ProcessInfo.processInfo.systemUptime<self.recoveryDeadline
            })
        })
    }

    func prepareFinalActivation(_ candidate:MismatchRecoveryPlan,_ before:MismatchSnapshot,confirmedReplayFailure:Bool=false){
        guard recovering,!rollingBack else{return}
        // The direct Korean selection itself can lose the override. Inspect
        // after that phase settles, immediately before the final HID edit.
        guard koreanRetries==2,!activationFallbackTried,
              confirmedReplayFailure ? activationShortcutSupported():needsActivationShortcut() else{replaceAndReplay(candidate,before);return}
        guard let snap=recoverySnapshot("activation",retry:{[weak self] in self?.prepareFinalActivation(candidate,before,confirmedReplayFailure:confirmedReplayFailure)}) else{return}
        guard CFEqual(snap.element,before.element),currentSource()==recoverySourceID else{park("activation_context_changed");return}
        var candidate=candidate
        if !candidate.matches(text:snap.text,selection:snap.selection){
            guard let restored=candidate.restoredKoreanPlan(text:snap.text,selection:snap.selection) else{park("activation_context_changed");return}
            candidate=restored;currentPlan=restored
        }
        guard ProcessInfo.processInfo.systemUptime+0.55+Double(candidate.codes.count)*Self.pacedReplayInterval+0.28<recoveryDeadline else{abort("activation_deadline");return}
        activationFallbackTried=true
        let boundaries=recoverySourceBoundaries.count,interaction=sourceInteractionRevision
        guard chooseSource(englishID)==noErr else{abort("english_selection_failed");return}
        waitSource(englishID){[weak self] in
            self?.later(0.1){[weak self] in
                guard let self,self.recovering,!self.rollingBack else{return}
                guard self.recoverySourceBoundaries.count==boundaries,self.sourceInteractionRevision==interaction else{self.park("activation_boundary_changed");return}
                guard self.chooseKoreanWithActivationShortcut()==noErr else{self.abort("korean_selection_failed");return}
                NSLog("입력 불일치 재활성화: stage=%d",confirmedReplayFailure ? 2:1)
                InputDiagnostics.shared.record("mismatch.activation_shortcut_requested")
                self.waitSource(self.recoverySourceID){[weak self] in
                    self?.later(0.1){[weak self] in
                        guard let self,self.recovering,!self.rollingBack else{return}
                        guard self.recoverySourceBoundaries.count==boundaries,self.sourceInteractionRevision==interaction else{self.park("activation_boundary_changed");return}
                        self.replaceAndReplay(candidate,before)
                    }
                }
            }
        }
    }
}
