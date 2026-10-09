import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
final class Case {
 let e=OnsetRecoveryEngine();let g:OnsetInputGate;var now=100.0;var stops=0
 init(){g=OnsetInputGate(marker:e.marker);g.beat();e.gate=g;e.enabled=true;e.acknowledgmentClock={self.now};e.didStop={self.stops+=1}}
 func post(_ time:Double){now=time;e.recordPostedEvent()}
 func ack(_ seen:Int,_ time:Double)->Bool{now=time;g.replaySeen=seen;return e.gateAcknowledged(now:time)}
}
let flow=Case()
for index in 0..<60 {
 let time=100+Double(index)*0.02;flow.post(time)
 check(!flow.ack(index,time),"latest post remains outstanding")
 check(flow.e.enabled && flow.stops==0,"20ms acknowledgment progress must not time out")
 check(flow.e.unacknowledgedPosts.count==1,"completed post timestamps are removed")
}
check(flow.ack(60,101.19) && flow.e.unacknowledgedPosts.isEmpty,"final acknowledgment clears ledger")
flow.e.closeSession()
let stalled=Case();stalled.post(100)
check(!stalled.ack(0,100.249) && stalled.e.enabled,"no premature timeout")
check(!stalled.ack(0,100.251) && !stalled.e.enabled && stalled.stops==1,"genuinely missing acknowledgment stops within original 250ms limit")
let partial=Case();partial.post(100);partial.post(100.02)
check(!partial.ack(1,100.249) && partial.e.enabled,"remaining post uses its original issue time")
check(!partial.ack(1,100.271) && !partial.e.enabled,"partial acknowledgment never refreshes remaining post deadline")
let newest=Case();newest.post(100)
for i in 1...4{newest.post(100+Double(i)*0.05);_ = newest.ack(0,newest.now)}
newest.post(100.24)
check(!newest.ack(0,100.251) && !newest.e.enabled,"new posts cannot extend an older missing post")
let batch=Case();batch.post(100);batch.post(100.01);batch.post(100.02)
check(batch.ack(3,100.1) && batch.e.unacknowledgedPosts.isEmpty,"batch acknowledgment consumes exactly completed prefix")
batch.e.closeSession()
print("PASS \(checks) per-transmission acknowledgment deadline assertions; no OS key posting")
