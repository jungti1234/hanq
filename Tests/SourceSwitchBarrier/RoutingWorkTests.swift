import AppKit
func runRoutingWorkTests(){
 for mode in ["new","existing","field_move","shortcut","release","held"] {
  let b=SourceSwitchBarrier();var wall=100.0,cpu:UInt64=100_000_000,captures:[InputIncidentTrace.Capture]=[]
  let trace=InputIncidentTrace(secureInput:{false},destination:nil,clock:{wall},callbackCPU:{cpu},writer:{captures.append($0)})
  b.incidentTrace=trace;b.source={wall+=0.001;cpu+=500_000;return ko}
  b.read={wall+=0.015;cpu+=15_000_000;return .init(field:field,text:"",selection:NSRange(location:0,length:0))}
  b.readFocus={wall+=0.025;cpu+=100_000;return mode=="field_move" ? other:field}
  b.send={_ in check(false,"routing profile does not post keys")};b.select={_ in check(false,"routing profile does not select source");return -50}
  if ["existing","field_move"].contains(mode){b.observe(.keyDown,key(15))}
  let e=key(40,mode=="shortcut" ? .maskCommand:[])
  let type:CGEventType=mode=="release" ? .keyUp:.keyDown
  var span=trace.beginCallback(type);trace.checkpoint(.filters,&span)
  b.observeBeforeOnset(type,e,waiting:mode=="held",checkpoint:{trace.routingCheckpoint($0,&span)})
  trace.routingCheckpoint(.delivery,&span);trace.checkpoint(.routing,&span)
  trace.event(.main,type,e,started:span);trace.mark();trace.flush()
  let points=captures.last!.frames.last{$0.workEvidence != nil}!.workEvidence!.routingCheckpoints!
  check(points.map{$0.stage} == (mode=="held" ? [5]:(["shortcut","release"].contains(mode) ? [4,5]:[1,2,3,4,5])),"real routing records only traversed phases: \(mode)")
  if mode=="existing" {check(points[1].cpuMicros!-points[0].cpuMicros! == 100,"focus wait separated from CPU");check(points[2].cpuMicros! == points[1].cpuMicros!,"existing ledger needs no baseline read")}
  if mode=="new" || mode=="field_move" {check(points[2].cpuMicros!-points[1].cpuMicros! == 15000,"baseline read CPU separated from ledger work")}
  trace.stopAndFlush();b.fail("test_cleanup")
 }
}
