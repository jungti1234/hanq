import AppKit
import Carbon

extension MismatchRecoveryEngine {
    static let pacedReplayInterval=0.012

    // A failed session-tap burst must not be repeated identically forever.
    // Use the last existing retry for HID delivery, yielding between complete
    // press/release pairs. Preserve IME composition; never insert committed text.
    func replayPacedCandidate(_ candidate:MismatchRecoveryPlan,index:Int=0,eventSource:CGEventSource?=nil){
        guard recovering,!rollingBack else{return}
        guard fastRecoveryContext(),canObserve(),!sourceWorkPaused else{
            park("paced_replay_unsafe_context");return
        }
        // The final pair is already delivered. A source change now belongs to
        // result verification, not the pre-post guard for another key. Observe
        // the external transition before restoration can race its return.
        if index>=candidate.codes.count,currentSource() != recoverySourceID {
            observeRecoverySource(currentSource())
            guard recovering else{return}
            if sourceWorkPaused {
                deferRecovery{[weak self] in self?.replayPacedCandidate(candidate,index:index,eventSource:eventSource)}
                return
            }
        }
        guard index>=candidate.codes.count || currentSource()==recoverySourceID else{park("paced_replay_source_changed");return}
        guard ProcessInfo.processInfo.systemUptime<recoveryDeadline else{
            park("paced_replay_deadline");return
        }
        guard index<candidate.codes.count else{
            InputDiagnostics.shared.record("mismatch.paced_replay_finished")
            awaitKorean(candidate,remaining:25);return
        }
        let (code,shift)=candidate.codes[index]
        guard let source=eventSource ?? CGEventSource(stateID:.privateState),
              let down=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else{
            park("paced_replay_allocation_failed");return
        }
        if index==0 {
            replayStarted=true;replayIssuedAt=ProcessInfo.processInfo.systemUptime
            log("replay_started")
            InputDiagnostics.shared.record("mismatch.paced_replay_started")
        }
        // Allocate both edges before posting. No scheduled callback owns a held
        // synthetic key, including cancellation, menu pause, or focus departure.
        for event in [down,up] {
            event.flags=shift ? .maskShift:[]
            event.setIntegerValueField(.eventSourceUserData,value:marker)
            post(event,at:.cghidEventTap)
        }
        later(Self.pacedReplayInterval){[weak self] in
            self?.replayPacedCandidate(candidate,index:index+1,eventSource:source)
        }
    }
}
