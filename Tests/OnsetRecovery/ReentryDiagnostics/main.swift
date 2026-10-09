import AppKit
var checks=0
func check(_ value:Bool,_ name:String){checks+=1;if !value{print("FAIL",name);exit(1)}}
func event(_ down:Bool=true)->CGEvent {let e=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:down)!;e.flags=[];let privateText=Array("PRIVATE_REENTRY_PAYLOAD".utf16);e.keyboardSetUnicodeString(stringLength:privateText.count,unicodeString:privateText);return e}
func run(_ trace:Bool)->[String] {
 let g=OnsetInputGate(marker:99);if trace{g.enableReentryTrace()};g.beat();var results:[String]=[]
 func state(_ label:String,_ accepted:Bool){results.append("\(label):\(accepted):\(g.reservation() != nil):\(g.passedObservation()?.keys.count ?? 0):\(g.held.count):\(g.stopped):\(g.expiredEarly)")}
 state("unprepared",g.receive(.keyDown,event()) != nil)
 g.configureEarly(true);state("reserved",g.receive(.keyDown,event()) != nil);state("up",g.receive(.keyUp,event(false)) != nil)
 state("followup",g.receive(.keyDown,event()) != nil)
 _ = g.takeEarlyExpiration();g.discardPassed(reason:.field_changed);g.configureEarly(true);g.hintUntil=ProcessInfo.processInfo.systemUptime-1
 state("elapsed",g.receive(.keyDown,event()) != nil)
 g.configureEarly(false);g.configureEarly(true);state("claimStart",g.receive(.keyDown,event()) != nil)
 state("claim",g.claimEarly());state("held",g.receive(.keyDown,event()) != nil);_ = g.take();state("finish",g.finishIfEmpty())
 let (frames,dropped)=g.takeReentryTrace();check(dropped==0,"small trace has no drops")
 if trace {
  let reasons=frames.map{$0.reason};for reason:OnsetReentryDiagnostics.Reason in [.hint_missing,.ready,.reserved,.unclaimed_followup,.field_changed,.hint_elapsed,.not_outside,.hold_active,.empty_finished]{check(reasons.contains(reason),"decision recorded: \(reason)")}
  check(zip(frames,frames.dropFirst()).allSatisfy{$0.0.sequence<$0.1.sequence && $0.0.decisionMonoNs<=$0.1.decisionMonoNs},"decision times and sequence ordered")
  let text=frames.map{$0.line}.joined(separator:"\n");check(!text.contains("PRIVATE_REENTRY_PAYLOAD") && !text.contains("code=") && !text.contains("sourceID=") && !text.contains("text="),"no key values, text or source payload")
 }else{check(frames.isEmpty,"disabled trace has no records")}
 return results
}
check(run(false)==run(true),"same routing, claims, history and hold state with diagnostics enabled")
let disabled=OnsetInputGate(marker:123);disabled.lock.lock();check(disabled.takeReentryTrace().0.isEmpty,"disabled trace does not acquire gate lock");disabled.lock.unlock()
let bounded=OnsetInputGate(marker:123);bounded.enableReentryTrace();for _ in 0..<600{_ = bounded.receive(.keyDown,event())};let (frames,dropped)=bounded.takeReentryTrace();check(frames.count==256 && dropped==344,"bounded 256-record memory with visible dropped count");check(bounded.healthy() && bounded.held.isEmpty,"trace saturation never changes input handling");check(bounded.takeReentryTrace().0.isEmpty,"drain clears trace exactly once")
let markers=OnsetInputGate(marker:123);markers.enableReentryTrace();for marker:Int64 in [123,0x48414E5100000001,0x454F5448]{let e=event();e.setIntegerValueField(.eventSourceUserData,value:marker);_ = markers.receive(.keyDown,e)};check(markers.takeReentryTrace().0.isEmpty,"synthetic recovery markers never count as original input")
check(OnsetReentryDiagnostics.engineReason("PRIVATE_REENTRY_PAYLOAD")=="other","engine reasons sanitize unknown payload")
let engine=OnsetRecoveryEngine();engine.gate=disabled
if !InputDiagnostics.shared.isEnabled{disabled.lock.lock();engine.flushReentryTrace();engine.traceReentryObservation("PRIVATE_REENTRY_PAYLOAD",hasSnapshot:false);disabled.lock.unlock();check(true,"disabled engine trace avoids gate reads")}
else{engine.traceReentryObservation("PRIVATE_REENTRY_PAYLOAD",hasSnapshot:false);let args=ProcessInfo.processInfo.arguments;let p=args[args.firstIndex(of:"--diagnose-input")!+1];let text=try! String(contentsOfFile:p,encoding:.utf8);check(text.contains("reason=other") && !text.contains("PRIVATE_REENTRY_PAYLOAD"),"actual engine log excludes payload")}
print("PASS \(checks) reentry diagnostics privacy, bounded memory and behavior-equivalence assertions")
