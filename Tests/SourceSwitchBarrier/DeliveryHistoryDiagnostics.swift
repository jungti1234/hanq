import AppKit
import Carbon

// Exercise the production history proof and diagnostic writer together.
// The matrix controls only fixture security/enablement; production defaults stay unchanged.
func runDeliveryHistoryDiagnosticTests() {
 for mode in ["enabled","secure","disabled"] {
for reason in ["current","pre_key","pending_key","adopted","ascii","mixed","jamo","partial","wrong-key","text","caret","selection","field","source","expiry","boundary","busy","repair","permission","limit","reset"] {
 let b=SourceSwitchBarrier();var source=ko,time=1.0
 var captures:[InputIncidentTrace.Capture]=[]
 let incident=InputIncidentTrace(secureInput:{mode == "secure"},destination:nil,initiallyEnabled:mode != "disabled",writer:{captures.append($0)});b.incidentTrace=incident
 b.now={time};b.source={source};b.read={.init(field:field,text:"앞🙂뒤",selection:NSRange(location:3,length:0))}
 b.frontPID={123};b.frontWindow={_ in field};b.fieldWindow={_ in field}
 b.select={_ in check(false,"history fixture must not select a real source");return -50}
 b.send={_ in check(false,"history fixture must not post a real key")}
 b.applySelection={_,_ in check(false,"history fixture must not write AX selection");return false}
 for code:UInt16 in [15,40,1]{let event=key(code);event.timestamp=100;b.observe(.keyDown,event)}
 let verified=MismatchSnapshot(element:field,text:"앞🙂간뒤",selection:NSRange(location:4,length:0))
 if reason=="adopted"{
  var replay=MismatchReplayLedger(before:"앞🙂뒤",caret:3);replay.append(source:ko,keys:[(15,false),(40,false),(1,false)])
  b.noteExternalEdit();b.adoptVerifiedReplay(replay,snapshot:verified)
 }
 if ["pre_key","pending_key"].contains(reason){b.observe(.keyDown,key(40))}
 if reason=="source"{source=en}
 if reason=="expiry"{time=6.01}
 if reason=="busy"{_ = b.request(en)}
 if reason=="repair"{b.noteExternalEdit()}
 if reason=="permission"{b.ready={false}}
 if reason=="reset"{b.resetObservation()}
 var snap=verified
 let failures=["ascii":"rks","mixed":"rㅏㄴ","jamo":"ㄱㅏㄴ","partial":"가s","wrong-key":"rㅓㄴ"]
 if let value=failures[reason]{snap = .init(element:field,text:"앞🙂"+value+"뒤",selection:NSRange(location:3+value.utf16.count,length:0))}
 if reason=="text"{snap = .init(element:field,text:"다🙂간뒤",selection:verified.selection)}
 if reason=="caret"{snap = .init(element:field,text:verified.text,selection:NSRange(location:3,length:0))}
 if reason=="selection"{snap = .init(element:field,text:verified.text,selection:NSRange(location:4,length:1))}
 if reason=="field"{snap = .init(element:other,text:verified.text,selection:verified.selection)}
 if reason=="limit"{
  var long=MismatchReplayLedger(before:"앞🙂뒤",caret:3);long.append(source:ko,keys:Array(repeating:(15,false),count:65))
  snap = .init(element:field,text:long.text,selection:long.selection);b.adoptVerifiedReplay(long,snapshot:snap)
 }
 let result=b.verifiedTwoSetHistory(snap,after:reason=="boundary" ? UInt64.max:0,allowPrior:reason=="pre_key")
 check((result?.plan.replayRoman=="rks") == ["current","pre_key","adopted","ascii","mixed","jamo","partial"].contains(reason),"verified delivery-history \(reason) proof")
 incident.mark();incident.flush()
 let rejected:[String:InputIncidentTrace.DecisionReason]=["pending_key":.handoffTextMismatch,"wrong-key":.handoffTextMismatch,"text":.handoffTextMismatch,"caret":.handoffTextMismatch,"selection":.handoffTextMismatch,"field":.handoffField,"source":.handoffSource,"expiry":.handoffExpired,"boundary":.handoffBoundary,"busy":.handoffBusy,"repair":.handoffExternalEdit,"permission":.handoffNotReady,"limit":.handoffNoHistory,"reset":.handoffField]
 let decisions=captures.first?.frames.filter{$0.kind == .detectionDecision && $0.edge == InputIncidentTrace.DecisionSite.handoff.rawValue} ?? []
 let expected=(rejected[reason] ?? .handoffAccepted).rawValue
 let wanted=mode == "enabled" ? [expected]:[]
 let actual=decisions.map{$0.category}
 if actual != wanted {
  fputs("delivery-history diagnostic failure mode=\(mode) reason=\(reason) enabled=\(incident.enabled) injectedSecure=\(mode == "secure") captures=\(captures.count) expected=\(wanted) actual=\(actual)\n",stderr)
 }
 check(actual==wanted,"actual delivery-history \(mode) \(reason) diagnostic sequence")
 check(mode == "disabled" ? captures.isEmpty:captures.first?.trigger == .manual,"delivery-history \(mode) \(reason) explicit marker contract")
 incident.stopAndFlush()
 b.fail("test_cleanup")
}

 }
 // Gate admission and queue order must survive a blocked interval on the same object.
 var secure=false,captures:[InputIncidentTrace.Capture]=[]
 let trace=InputIncidentTrace(secureInput:{secure},destination:nil,writer:{captures.append($0)})
 trace.decision(.handoff,.handoffAccepted)
 secure=true;trace.decision(.handoff,.handoffTextMismatch)
 secure=false;trace.decision(.handoff,.handoffSource)
 trace.mark();trace.flush()
 let actual=captures.first?.frames.filter{$0.kind == .detectionDecision}.map{$0.category} ?? []
 check(actual==[InputIncidentTrace.DecisionReason.handoffAccepted.rawValue,InputIncidentTrace.DecisionReason.handoffSource.rawValue],"delivery-history gate resumes without leaking blocked decision or reordering")
 trace.stopAndFlush()
}
