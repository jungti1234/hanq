import AppKit
import Carbon
let trace=InputIncidentTrace.shared
let out=URL(fileURLWithPath:CommandLine.arguments[1])
let two=InputSourceSnapshot(id:"test.ko",name:nil,languages:["ko"]),abc=InputSourceSnapshot(id:"test.en",name:nil,languages:["en"])
var filter=CommandFilter(),latencies:[UInt64]=[],queries=0,edges=0,consumed=0,digest:UInt64=0
let right=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10)
let hid=MismatchSwitchGate(accepts:{false},switched:{_ in});hid.incidentTrace=trace
trace.start()
for index in 0..<1200 {
 for down in [true,false] {
  let e=CGEvent(keyboardEventSource:nil,virtualKey:54,keyDown:down)!;e.type = .flagsChanged;e.flags=down ? right:[];e.timestamp=1_000_000_000+UInt64(index*2+(down ? 0:1))*1_000_000
  let began=DispatchTime.now().uptimeNanoseconds
  _ = hid.receive(.flagsChanged,e)
  var c=InputIncidentControl.begin(trace,.flagsChanged,e)
  let queryBegan=c==nil ? 0:ProcessInfo.processInfo.systemUptime
  queries+=2 // injected current and enabled-list reads, identical ON and OFF
  let source=down ? two:abc
  let q=KoreanEnglishSwitch.resolution(current:source,readable:true,sources:[two,abc],rememberedKorean:two.id,rememberedEnglish:abc.id)
  c?.query(site:1,status:q.status,current:q.currentClass,target:q.targetClass,available:q.availableCount,korean:q.koreanCount,english:q.englishCount,began:queryBegan)
  let before=filter.diagnosticState,flags=e.flags
  let result=filter.process(type:.flagsChanged,key:54,flags:flags,acceptNewPress:q.target != nil)
  c?.filter(before:before,after:filter.diagnosticState,flags:flags,accepted:q.target != nil,edge:result.edge,consumed:result.consume,matching:true)
  c?.route=(result.consume ? InputIncidentControl.Route.filterConsumed:.passed).rawValue
  e.flags=result.flags
  if let c{trace.control(.main,.flagsChanged,e,c,consumed:result.consume)}
  let elapsed=DispatchTime.now().uptimeNanoseconds-began
  if index>=200 {latencies.append(elapsed)}
  edges+=result.edge==nil ? 0:1;consumed+=result.consume ? 1:0
  digest=digest &* 31 &+ result.flags.rawValue &+ UInt64(result.consume ? 1:0)
  usleep(1000)
 }
}
trace.flush()
latencies.sort()
let value:[String:Any]=["diagnostics":trace.enabled,"callbacks":latencies.count,"outcome":["queries":queries,"edges":edges,"consumed":consumed,"digest":String(digest)],"p99_us":Double(latencies[latencies.count*99/100])/1000,"max_us":Double(latencies.last!)/1000,"syntheticQueries":true,"globalPosts":0]
try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:out)
