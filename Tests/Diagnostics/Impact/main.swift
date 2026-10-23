import AppKit
import Carbon

// Product callback replay with synthetic, private CGEvents. No event tap,
// global post, source selection, real AX read or user's editor is used.
func option(_ name:String,_ fallback:String)->String {let a=CommandLine.arguments;guard let i=a.firstIndex(of:name),i+1<a.count else{return fallback};return a[i+1]}
let profile=option("--profile","paced"),count=Int(option("--keys","320"))!,gap=UInt64(option("--gap-us","8000"))!*1000
let output=URL(fileURLWithPath:option("--result","/private/tmp/hanq-impact.json"))
let trace=InputIncidentTrace.shared,enabled=trace.enabled
let field=AXUIElementCreateApplication(12345)
var shapeProbe=InputIncidentShapeProbe()
let gate=OnsetInputGate(marker:0x48414E5100000000)
let replaySource=CGEventSource(stateID:.privateState)!;replaySource.userData=gate.marker
let engine=MismatchRecoveryEngine();engine.enabled=true;engine.incidentTrace=trace;engine.locked=field;engine.lastSource=mismatchKoreanID
let sourceEvidence=MismatchSourceEvidence();engine.sourceEvidence=sourceEvidence
sourceEvidence.request(mismatchKoreanID,at:200);sourceEvidence.didCommit(mismatchKoreanID,at:200);sourceEvidence.observe(mismatchKoreanID)
let sourceMode=ProcessInfo.processInfo.environment["HANQ_IMPACT_SOURCE_MODE"] ?? "korean"
if sourceMode=="roman" {sourceEvidence.request("com.apple.keylayout.ABC",at:300);sourceEvidence.didCommit("com.apple.keylayout.ABC",at:300);sourceEvidence.observe("com.apple.keylayout.ABC")}
var text="",reads=0,sourceReads=0,downPassed=0,upPassed=0,consumed=0,replayed=0,retained=0,failures=0
var observerCopies=0,digest:UInt64=1469598103934665603
engine.testSource={sourceReads+=1;return sourceMode=="roman" ? "com.apple.keylayout.ABC":mismatchKoreanID};engine.testFastContext={true};engine.canObserve={true};engine.canBeginRepair={false}
engine.testSnapshot={reads+=1;return .init(element:field,text:text,selection:NSRange(location:text.utf16.count,length:0))}
engine.testPost={_ in failures+=1};engine.testPostAtTap={_,_ in failures+=1};engine.testSelectSource={_ in failures+=1;return -1}
gate.deliver={_ in observerCopies+=1};gate.failed={_ in failures+=1}
if enabled{gate.diagnosticEvent={type,event,consumed,duration,started in trace.event(.onset,type,event,consumed:consumed,duration:duration,started:started)}}
var filter=CommandFilter(),latencies:[UInt64]=[],lateness:[UInt64]=[],blockedCaller:[UInt64]=[]
var stagePassed=[0,0,0],submitted=0
let codes:[CGKeyCode]=[2,0,14,15,40,3,5,1,6,7,8,9,11,12,13,17]
func mix(_ n:UInt64){digest=(digest^n)&*1099511628211}
func event(_ key:Int,_ down:Bool)->CGEvent {
 guard let e=CGEvent(keyboardEventSource:nil,virtualKey:codes[key%codes.count],keyDown:down) else{fputs("CGEvent unavailable\n",stderr);exit(2)}
 e.flags=key%17==0 ? .maskShift:[];e.timestamp=1_000_000_000_000+UInt64(key*2+(down ? 0:1))*1_000_000
 e.setIntegerValueField(.eventSourceUserData,value:0);return e
}
let events=(0..<(count+128)).map{[event($0,true),event($0,false)]}
func process(_ e:CGEvent,_ measured:Bool,hold:Bool=false){
 let began=DispatchTime.now().uptimeNanoseconds
 let hidStart=trace.beginCallback(e.type)
 if enabled{trace.event(.hid,e.type,e,started:hidStart)}
 let mainStart=trace.beginCallback(e.type)
 let mainBegan=enabled ? ProcessInfo.processInfo.systemUptime:0
 let f=filter.process(type:e.type,key:e.getIntegerValueField(.keyboardEventKeycode),flags:e.flags,acceptNewPress:true);e.flags=f.flags
 if enabled{trace.event(.main,e.type,e,consumed:f.consume,duration:ProcessInfo.processInfo.systemUptime-mainBegan,started:mainStart)}
 let onset=gate.receive(e.type,e) != nil
 var passed=onset
 if onset {
  let mismatchStart=trace.beginCallback(e.type)
  let mismatchBegan=enabled ? ProcessInfo.processInfo.systemUptime:0
  passed=engine.event(e.type,e) != nil
  if enabled{trace.event(.mismatch,e.type,e,consumed:!passed,duration:ProcessInfo.processInfo.systemUptime-mismatchBegan,started:mismatchStart)}
 }
 if passed,enabled{trace.event(.boundary,e.type,e)}
 if enabled,e.type == .keyDown {
  let (identity,owner,window,epoch)=trace.fieldRegistry.identify(field,owner:12345,window:nil,generation:trace.collectionGeneration)
  var ax=InputIncidentAXEvidence();ax.owner=owner;ax.window=window;ax.identityEpoch=epoch
  let change=shapeProbe.observe(identity:identity,text:text,selection:NSRange(location:text.utf16.count,length:0),generation:trace.collectionGeneration,ax:ax)
  trace.shape(.onsetAX,identity:identity,count:text.utf16.count,selected:false,editing:false,change:change)
 }
 let elapsed=DispatchTime.now().uptimeNanoseconds-began
 if measured {
  latencies.append(elapsed);if hold{blockedCaller.append(elapsed)}
  stagePassed[0]+=f.consume ? 0:1;stagePassed[1]+=onset ? 1:0;stagePassed[2]+=passed ? 1:0
  submitted+=1;mix(UInt64(e.type.rawValue));mix(UInt64(e.getIntegerValueField(.keyboardEventKeycode)));mix(e.flags.rawValue);mix(passed ? 1:0)
  if passed{if e.type == .keyDown{downPassed+=1}else{upPassed+=1}}else{consumed+=1}
 }
 if passed,e.type == .keyDown,!OnsetInputGate.isRecoveryMarker(e.getIntegerValueField(.eventSourceUserData)) {
  text.append(e.flags.contains(.maskShift) ? "D":"d")
 }
}
func drainMain(){_ = RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.00001))}
trace.start()
// Warm both input paths and layout caches before collecting latency samples.
for i in 0..<128{process(events[i][0],false);process(events[i][1],false);drainMain()}
trace.flush();text="";engine.plan=nil;engine.heldKeys=[];reads=0;sourceReads=0;observerCopies=0
var busyStarted=DispatchSemaphore(value:0),busyDone=DispatchSemaphore(value:0),releaseHeld=DispatchSemaphore(value:0)
var contentionBegin:UInt64=0,contentionEnd:UInt64=0
if profile=="blocked" {
 Thread{
  trace.withLockedMetadataForTest {
   contentionBegin=DispatchTime.now().uptimeNanoseconds;busyStarted.signal();releaseHeld.wait();contentionEnd=DispatchTime.now().uptimeNanoseconds
  }
  busyDone.signal()
 }.start()
 guard busyStarted.wait(timeout:.now()+2) == .success else{exit(3)}
 // Release independently, so no input callback can be hidden behind the hold.
 DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.06){releaseHeld.signal()}
}
// Real independent store rotation runs only with diagnostics ON. It uses the
// same product store and private test files, never the user's incident folder.
let storageDone=DispatchSemaphore(value:0)
var pressureStatus:DiagnosticLogStore.Status?
if profile=="storage",enabled {
 let pressure=output.deletingLastPathComponent().appendingPathComponent("pressure")
 DispatchQueue.global(qos:.utility).async {
  let store=DiagnosticLogStore(directory:pressure,policy:.init(maximumAutomaticFiles:6,maximumAutomaticBytes:2*1024*1024))
  let data=Data(repeating:32,count:256*1024)
  for id in 1...24{
   _=store.save(data,incident:id,phase:0,automatic:true);_=store.save(data,incident:id,phase:1,automatic:true)
   Thread.sleep(forTimeInterval:0.015)
  }
  pressureStatus=store.status;storageDone.signal()
 }
}
let began=DispatchTime.now().uptimeNanoseconds
var next=began
for i in 0..<count {
 if gap>0{
  let now=DispatchTime.now().uptimeNanoseconds
  if now<next{Thread.sleep(forTimeInterval:Double(next-now)/1e9)}
  let arrived=DispatchTime.now().uptimeNanoseconds;lateness.append(arrived>next ? arrived-next:0);next+=gap
 }
 if i%32==0{if enabled{trace.context()};text="";engine.plan=nil;engine.heldKeys=[]}
 if profile=="storage",i%128==0{trace.mark()}
 if profile=="capture",i%16==0{trace.sourceBoundary(.manualEditUnverified,queued:1,awaitingOnset:0)}
 if profile=="capture",i%64==0{trace.recoveryStarted(.mismatch,reason:.interruptedComposition)}
 let buffered=profile=="buffered" && i%32<8
 if buffered,i%32==0{gate.beat();if !gate.begin(){failures+=1};if enabled{trace.state(.onset,.repairStarted)}}
 for e in events[i+128] {
  let duringHold=profile=="blocked" && DispatchTime.now().uptimeNanoseconds<contentionBegin+60_000_000
  process(e,true,hold:duringHold)
 }
 if buffered,i%32==7{
  let held=gate.take();if held.count != 16{failures+=1}
  _=gate.finishIfEmpty()
  if enabled{trace.state(.onset,.replay,pending:held.count)}
  for e in held{
   mix(UInt64(e.type.rawValue));mix(UInt64(e.getIntegerValueField(.keyboardEventKeycode)));mix(e.flags.rawValue)
   guard let replay=CGEvent(keyboardEventSource:replaySource,virtualKey:CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode)),keyDown:e.type == .keyDown) else{exit(7)}
   replay.flags=e.flags;replay.timestamp=e.timestamp
   guard replay.getIntegerValueField(.eventSourceUserData)==gate.marker else{exit(8)}
   process(replay,true);replayed+=1
  }
  if enabled{trace.state(.onset,.finished)}
 }
 drainMain()
}
if profile=="buffered"{
 gate.beat();_=gate.begin()
 for e in [event(count+200,true),event(count+200,false)]{process(e,true)}
 let held=gate.cancelHold();retained=held.count;held.forEach{mix(UInt64($0.type.rawValue))}
 if enabled{trace.state(.onset,.retained,pending:retained)}
}
let elapsed=DispatchTime.now().uptimeNanoseconds-began
if profile=="blocked"{guard busyDone.wait(timeout:.now()+2) == .success else{exit(4)}}
if profile=="storage",enabled{guard storageDone.wait(timeout:.now()+4) == .success else{exit(5)}}
// Capture after all callback samples; waiting/JSON analysis is outside samples.
trace.mark();trace.flush();Thread.sleep(forTimeInterval:1.2);trace.flush();drainMain()
if profile=="capture"{trace.stopAndFlush()}
func stats(_ values:[UInt64])->[String:Double]{
 let s=values.sorted();guard !s.isEmpty else{return [:]}
 func p(_ f:Double)->Double{Double(s[min(s.count-1,Int(Double(s.count-1)*f))])/1000}
 return ["count":Double(s.count),"mean_us":Double(s.reduce(UInt64(0),+))/Double(s.count)/1000,"p50_us":p(0.5),"p95_us":p(0.95),"p99_us":p(0.99),"max_us":Double(s.last!)/1000]
}
var result:[String:Any]=["profile":profile,"diagnostics":enabled,"keys":count,"gap_us":gap/1000,"callback":stats(latencies),"cadence_lateness":stats(lateness),"held_diagnostic_callback":stats(blockedCaller),"elapsed_ms":Double(elapsed)/1e6,"outcome":["digest":String(digest),"submitted":submitted,"down_passed":downPassed,"up_passed":upPassed,"consumed":consumed,"replayed":replayed,"retained":retained,"failures":failures,"stage_passed":stagePassed,"snapshot_reads":reads,"source_reads":sourceReads,"observer_copies":observerCopies,"gate_replay_seen":gate.seenCount(),"engine_pending":engine.pending.count,"engine_retained":engine.retained.count,"gate_pending":gate.take().count,"gate_healthy":gate.healthy()],"global_posts":0,"real_ax_queries":0,"input_source_changes":0,"product_build_reference":"252","source_mode":sourceMode,"latencies_ns":latencies,"cadence_lateness_ns":lateness,"diagnostic_hold_callback_ns":blockedCaller]
if profile=="capture",enabled,let directory=trace.destinationDirectory {
 let paths=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
 let documents=paths.filter{$0.pathExtension=="json"}.compactMap{try? JSONSerialization.jsonObject(with:Data(contentsOf:$0)) as? [String:Any]}
 let protected=documents.compactMap{$0["capturePreservation"] as? [String:Any]}
 result["capture_pressure"]=["files":documents.count,"deferred_phases":protected.filter{($0["deferred"] as? Bool)==true}.count,"requests":protected.compactMap{$0["requests"] as? [[String:Any]]}.map{$0.count}.reduce(0,+)]
}
if let pressureStatus{result["pressure_storage"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(pressureStatus))}
if profile=="blocked"{result["diagnostic_hold_us"]=Double(contentionEnd-contentionBegin)/1000}
try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:output)
if failures != 0{exit(6)}
print("PASS \(profile) diagnostics=\(enabled) callbacks=\(submitted) digest=\(digest)")
