import Foundation
import ApplicationServices
import Darwin
// Passive scalar callbacks and existing snapshot paths only. No taps, posts, AX calls or source changes.
let enabled=CommandLine.arguments.contains("--on")
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,initiallyEnabled:enabled,writer:{captures.append($0)})
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
var probe=InputIncidentShapeProbe(),latencies:[UInt64]=[],workCount=0,cpuCount=0,selectedCount=0
let count=2048
func processCPU()->UInt64{var usage=rusage();getrusage(RUSAGE_SELF,&usage);return UInt64(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)*1_000_000+UInt64(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)}
func callback(_ lane:InputIncidentTrace.Lane,_ type:CGEventType){
 let before=DispatchTime.now().uptimeNanoseconds
 #if HANQ_INDIRECT_TIMING
 let start=trace.beginCallback(type)
 trace.event(lane,type,event,started:start)
 #else
 trace.event(lane,type,event)
 #endif
 latencies.append(DispatchTime.now().uptimeNanoseconds-before)
}
func iteration(_ i:Int){
 event.timestamp=UInt64(i+1)*1_000_000
 for type in [CGEventType.keyDown,.keyUp]{for lane in [InputIncidentTrace.Lane.hid,.main,.mismatch,.onset]{callback(lane,type)}}
 for lane in [InputIncidentTrace.Lane.onsetAX,.mismatchAX] {
  let read=trace.beginRead(lane);trace.endRead(lane,read)
  if enabled {
   let selection=NSRange(location:i%64,length:0)
   let c=probe.observe(identity:1,text:String(repeating:"a",count:64),selection:selection,generation:trace.collectionGeneration)
   trace.shape(lane,identity:1,count:64,selected:false,editing:false,change:c)
  }
 }
}
for i in 0..<128{iteration(i)};trace.flush();latencies=[]
let beforeCPU=processCPU(),before=DispatchTime.now().uptimeNanoseconds
for i in 0..<count{iteration(i);if i%32==0{trace.flush()}}
trace.flush()
let cpu=processCPU()-beforeCPU,wall=DispatchTime.now().uptimeNanoseconds-before
trace.mark();trace.flush()
#if HANQ_INDIRECT_TIMING
if let c=captures.last{workCount=c.frames.filter{$0.workEvidence != nil}.count;cpuCount=c.frames.filter{$0.workEvidence?.cpuState==1}.count;selectedCount=c.frames.filter{$0.shapeEvidence?.selectionMotion != nil}.count}
#endif
latencies.sort()
func percentile(_ q:Double)->Double{Double(latencies[min(latencies.count-1,Int(Double(latencies.count-1)*q))])/1000}
let row:[String:Any]=["enabled":enabled,"callbacks":latencies.count,"cpu_us":cpu,"wall_us":wall/1000,"p50_us":percentile(0.5),"p99_us":percentile(0.99),"max_us":Double(latencies.last!)/1000,"work_frames":workCount,"cpu_frames":cpuCount,"motion_frames":selectedCount,"capture_bytes":captures.last.flatMap{try? JSONEncoder().encode($0).count} ?? 0]
print(String(data:try! JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
