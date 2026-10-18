import AppKit
import Carbon

// Hardware HID records can expose Mach ticks while posted HID and session
// records already contain nanoseconds. Resolve the representation against the
// observation's monotonic clock before preserving provenance. Never rewrite
// the delivered event, and never turn an invalid/future value into a boundary.
enum MismatchEventClock {
    static let timebase:mach_timebase_info_data_t = {
        var value=mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    static func nanoseconds(fromHIDTicks ticks:UInt64,numerator:UInt32,denominator:UInt32)->CGEventTimestamp {
        guard denominator>0,numerator>0 else{return 0}
        let product=ticks.multipliedFullWidth(by:UInt64(numerator))
        guard product.high<UInt64(denominator) else{return 0}
        return UInt64(denominator).dividingFullWidth(product).quotient
    }
    static func normalizeHIDTimestamp(_ raw:UInt64,observedAt now:UInt64,numerator:UInt32,denominator:UInt32)->CGEventTimestamp {
        guard raw>0,numerator>0,denominator>0 else{return 0}
        let converted=nanoseconds(fromHIDTicks:raw,numerator:numerator,denominator:denominator)
        // Both formats can occur in one HID stream. The compatible clock is
        // the closest past representation; multiplying an already-nanosecond
        // event would create a far-future, permanently blocking watermark.
        var result:UInt64=raw<=now ? raw:0
        if converted<=now,converted>result{result=converted}
        return result
    }
    static func hidTimestamp(_ event:CGEvent)->CGEventTimestamp {
        normalizeHIDTimestamp(event.timestamp,observedAt:DispatchTime.now().uptimeNanoseconds,numerator:timebase.numer,denominator:timebase.denom)
    }
}

extension MismatchRecoveryEngine {
    func supportsRecoverySource(_ id:String)->Bool {
        MismatchKeyboardLayout.supports(id) || id==englishID || id=="com.apple.keylayout.ABC" || id=="com.apple.keylayout.US"
    }
    static func sourceEventTime()->CGEventTimestamp {
        if let timestamp=CGEvent(source:nil)?.timestamp,timestamp>0{return timestamp}
        return CGEventTimestamp(ProcessInfo.processInfo.systemUptime*1_000_000_000)
    }
    func setUserSourceIntent(_ source:String,at timestamp:CGEventTimestamp) {
        guard recovering else{return}
        guard supportsRecoverySource(source) else{park("unsupported_external_source");return}
        if MismatchKeyboardLayout.supports(source){lastIntendedKorean=source}else{englishID=source}
        intendedSource=source
        noteUserSourceSwitch(at:timestamp)
        if timestamp>0 {
            recoverySourceBoundaries.append((timestamp,source))
            recoverySourceBoundaries.sort{$0.timestamp<$1.timestamp}
            intendedSource=recoverySourceBoundaries.last!.source
        }
        log("user_source_boundary")
    }
    func toggledUserSource(_ base:String)->String {
        MismatchKeyboardLayout.supports(base) ? englishID:lastIntendedKorean
    }
    func observeRecoverySource(_ source:String,at time:CGEventTimestamp=0) {
        guard recovering,testSource==nil || observeSourcesForTests else{return}
        let external=systemSwitch.observe(source)
        if let caps=capsSourceInteraction {
            if source != caps.actual,external {
                capsSourceInteraction=nil
                log("caps_source_confirmed")
                setUserSourceIntent(toggledUserSource(caps.intended),at:caps.timestamp)
                applyConfirmedCapsBoundary(at:caps.timestamp)
                if !sourceMenuPaused{resumeSourceWork()}
                return
            }
            if interactionNow()>=caps.until {
                log("caps_source_unchanged")
                // Caps OFF/long-press uppercase must not invent a language switch.
                capsSourceInteraction=nil
                if !sourceMenuPaused{resumeSourceWork()}
            }
        }else if external {
            setUserSourceIntent(source,at:time>0 ? time:Self.sourceEventTime())
            guard recovering else{return}
            if sourceMenuPaused{resumeMenuAfterSelection()}
            else{settleExternalSource()}
        }
    }
    func pauseSourceWork() {
        if sourcePauseStarted==nil{sourcePauseStarted=interactionNow()}
        asyncReady=nil
    }
    func deferRecovery(_ action:@escaping ()->Void) {
        guard recovering else{return}
        guard pausedRecoveryActions.count<16 else{park("source_interaction_work_limit");return}
        pausedRecoveryActions.append(action)
    }
    func resumeSourceWork() {
        guard recovering else{return}
        log("source_work_resumed")
        sourceMenuPaused=false;sourceMenuSawPopup=false;capsSourceInteraction=nil;sourceInteractionRevision+=1
        if let start=sourcePauseStarted{recoveryDeadline+=max(0,interactionNow()-start)}
        sourcePauseStarted=nil;asyncReady=nil
        resumeDeferredSourceWork()
    }
    func clearSourceInteraction() {
        sourceMenuPaused=false;sourceMenuSawPopup=false;capsSourceInteraction=nil;sourcePauseStarted=nil;pausedRecoveryActions=[];sourceInteractionRevision+=1
        cancelExternalSourceSettlement()
    }
    func potentialCapsSourceSwitch(at timestamp:CGEventTimestamp) {
        guard recovering,!rollingBack,capsSwitchEnabled(),!sourceMenuPaused,capsSourceInteraction==nil else{return}
        guard !systemSwitch.unsettled else{park("caps_during_unsettled_source");return}
        observeRecoverySource(currentSource(),at:timestamp)
        guard recovering else{return}
        cancelExternalSourceSettlement()
        pauseSourceWork();log("caps_source_wait")
        // A busy target editor can delay the system's actual Caps source
        // acknowledgement beyond 350ms. Wait a bounded second, require a real
        // external change, and keep source work paused until the verdict.
        capsSourceInteraction=(currentSource(),intendedSource,timestamp,interactionNow()+1.0)
    }
    func beginSourceMenu(at timestamp:CGEventTimestamp) {
        guard recovering,!rollingBack,!sourceMenuPaused else{return}
        guard !systemSwitch.unsettled,capsSourceInteraction==nil else{park("menu_during_unsettled_source");return}
        observeRecoverySource(currentSource(),at:timestamp)
        guard recovering else{return}
        cancelExternalSourceSettlement()
        sourceMenuPaused=true;sourceMenuSawPopup=false;pauseSourceWork();log("source_menu_paused")
        // The menu must display user intent, not recovery's temporary English.
        // Restore before the original mouse-down reaches the menu owner.
        if currentSource() != intendedSource {
            guard chooseSource(intendedSource)==noErr,!systemSwitch.unsettled else{park("menu_source_restore_failed");return}
        }
    }
    func resumeMenuAfterSelection() {
        guard sourceMenuPaused else{return}
        sourceInteractionRevision+=1
        let revision=sourceInteractionRevision,epoch=recoveryEpoch
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1){[weak self] in
            guard let self,self.recovering,self.sourceMenuPaused,self.recoveryEpoch==epoch,self.sourceInteractionRevision==revision else{return}
            self.observeRecoverySource(self.currentSource())
            guard !self.sourceMenuPopupVisible() else{return}
            guard self.recovering,self.fastRecoveryContext() else{self.park("source_menu_focus_changed");return}
            self.resumeSourceWork()
        }
    }
}
