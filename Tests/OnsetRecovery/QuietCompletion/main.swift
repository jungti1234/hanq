import AppKit
var checks=0;var failures=0
func check(_ v:Bool,_ name:String){checks+=1;if !v{failures+=1;print("FAIL",name)}}
let field=AXUIElementCreateApplication(1234)
func setup(_ mode:String)->(OnsetRecoveryEngine,OnsetInputGate,()->Int){
 let e=OnsetRecoveryEngine();let g=OnsetInputGate(marker:e.marker);g.beat();_ = g.begin();e.gate=g;e.enabled=true;e.recovering=true;e.replayStarted=true;e.planElement=field;e.postedToGate=2;g.replaySeen=mode=="unacknowledged" ? 1:2;e.currentPlan=OnsetRecoveryPlan(before:"",caret:0,roman:"ㄱ",codes:[(15,false)])
 #if !HANQ_OLD_QUIET
 e.deliveryPrefixConfirmed=mode != "unverified"
 #endif
 var posts=0;e.testPost={_ in posts+=1};e.testSource={mode=="source_changed" ? "com.apple.keylayout.ABC":onsetKoreanID};e.testSnapshot={e.unavailableReason="not_supported_text_field";return nil};e.testOriginalSnapshot={_ in OnsetSnapshot(element:field,text:"간 ",selection:NSRange(location:2,length:0))}
 if mode=="pending"{e.pending=[CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!]}
 return(e,g,{posts})
}
let (finished,g,posts)=setup("complete");finished.drain([])
let end=Date().addingTimeInterval(0.05);while Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.001))}
check(finished.enabled && !finished.recovering && g.healthy(),"acknowledged empty delivery finishes when field loses focus")
check(finished.lastEditable?.text=="간 " && finished.pending.isEmpty && posts()==0,"original field baseline recovered with no extra key posts")
finished.closeSession()
#if !HANQ_OLD_QUIET
let (waiting,wg,wposts)=setup("unacknowledged");waiting.drain([]);check(waiting.enabled && waiting.recovering && wg.healthy(),"no AX focus requirement while awaiting final acknowledgment");wg.replaySeen=2;waiting.drain([]);RunLoop.current.run(until:Date().addingTimeInterval(0.01));check(waiting.enabled && !waiting.recovering && wposts()==0,"acknowledgment completes once without reposting");waiting.closeSession()
for mode in ["pending","unverified"]{let (e,_,p)=setup(mode);e.drain([]);check(!e.enabled && p()==0,"focus checks retained for \(mode)");if mode=="pending"{check(e.pending.count==1,"undelivered originals retained")};e.closeSession()}
let (changed,_,cp)=setup("source_changed");changed.drain([]);RunLoop.current.run(until:Date().addingTimeInterval(0.01));check(changed.enabled && !changed.recovering && cp()==0 && changed.publishedPassedBaselines.isEmpty,"source change after completed delivery triggers no edit or baseline reuse");changed.closeSession()
#endif
print("\(failures==0 ? "PASS":"FAIL") \(checks) quiet acknowledged completion assertions; no OS keys posted")
exit(failures==0 ? 0:1)
