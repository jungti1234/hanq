import AppKit
import Carbon

struct LongTrial {
    let name:String,source:String,inserted:String,keys:[LongKey]
    var gap=0.008,bodyCount=10000,stale=false,forced=false,replaceAll=false
    var expectedSource:String?=nil
}
func longTrials()->[LongTrial] {
    var rows:[LongTrial]=[]
    for gap in [0.040,0.020,0.008] {
        rows.append(.init(name:"continuous sentence \(Int(gap*1000))ms",source:longTwoSet,inserted:String(repeating:longSentence,count:8),keys:Array(repeating:longSentenceKeys,count:8).flatMap{$0},gap:gap))
    }
    for item in lateLayoutCases where item.name=="final" {
        let word=item.keys.map{LongKey(code:Int($0.0),shift:$0.1)}
        rows.append(.init(name:"layout continuous \(item.sourceID)",source:item.sourceID,inserted:String(repeating:item.joined,count:32),keys:Array(repeating:word,count:32).flatMap{$0}))
    }
    var staleKeys=Array(repeating:longSentenceKeys,count:4).flatMap{$0};staleKeys[0].gap=0.08
    rows.append(.init(name:"temporarily unreadable AX role then normal continuous",source:longTwoSet,inserted:String(repeating:longSentence,count:4),keys:staleKeys,stale:true))
    let ganSpace=longGan+[LongKey(code:49)]
    rows.append(.init(name:"forced Roman then continuous",source:longTwoSet,inserted:"아 "+String(repeating:"간 ",count:24),keys:[LongKey(code:2),LongKey(code:40),LongKey(code:49)]+Array(repeating:ganSpace,count:24).flatMap{$0},forced:true))
    let toggle=LongKey(code:54,rightCommand:true)
    rows.append(.init(name:"fast Korean English Korean",source:longTwoSet,inserted:"간abc간",keys:longGan+[toggle]+longABCKeys+[toggle]+longGan))
    rows.append(.init(name:"Select All switch replacement",source:longTwoSet,inserted:"abc",keys:longGan+[LongKey(code:0,command:true),toggle]+longABCKeys,replaceAll:true,expectedSource:longABC))
    rows.append(.init(name:"forced Roman and immediate switch",source:longTwoSet,inserted:"아ab",keys:[LongKey(code:2),LongKey(code:40),toggle]+Array(longABCKeys.prefix(2)),forced:true,expectedSource:longABC))
    rows.append(.init(name:"committed syllable delete retype first switch",source:longTwoSet,inserted:"ㅁabc",keys:longGan+[LongKey(code:51),LongKey(code:0),toggle]+longABCKeys,gap:0.04,expectedSource:longABC))
    let roman=[17,40,2,37,2,45,38,3,14,46].enumerated().map{LongKey(code:$0.element,shift:$0.offset==0)}
    var conversion=LongKey(code:61,rightOption:true)
    if let raw=ProcessInfo.processInfo.environment["HANQ_LONG_MANUAL_SWITCH_GAP_MS"] {
        guard let ms=Double(raw),(0...200).contains(ms) else{return []};conversion.gap=ms/1000
    }
    rows.append(.init(name:"manual conversion immediate switch",source:longABC,inserted:"싸이월드간",keys:roman+Array(repeating:LongKey(code:123,shift:true),count:9)+[LongKey(code:123,shift:true,gap:0.08)]+[conversion,toggle]+longGan,expectedSource:longTwoSet))
    return rows
}
final class LongAuto:NSObject,NSApplicationDelegate {
    let root:URL,sourceState=LongSourceState(),trials:[LongTrial]
    let singleParagraph=ProcessInfo.processInfo.environment["HANQ_LONG_SINGLE_PARAGRAPH"]=="1"
    var window:NSWindow!,field=longField(.zero),retired:[LongField]=[]
    var rows:[[String:Any]]=[],index=0,done=false,productTimer:Timer?
    var productPID:Int?,monitoringBefore:[String:Any]=[:]
    let status=NSTextField(wrappingLabelWithString:"")
    init(_ root:URL){
        self.root=root;let all=longTrials(),env=ProcessInfo.processInfo.environment
        if env["HANQ_LONG_CASE"]=="native delete prefix"{trials=[LongTrial(name:"native committed delete prefix",source:longTwoSet,inserted:"ㅁ",keys:longGan+[LongKey(code:51),LongKey(code:0)],gap:0.04)]}
        else if let name=env["HANQ_LONG_CASE"] {trials=all.filter{$0.name==name}}
        else if let raw=env["HANQ_LONG_CASES"] {
            if let data=raw.data(using:.utf8),let names=(try? JSONSerialization.jsonObject(with:data)) as? [String],
               !names.isEmpty,Set(names).count==names.count,Set(names).isSubset(of:Set(all.map(\.name))) {
                trials=all.filter{names.contains($0.name)}
            }else{trials=[]}
        }
        else if env["HANQ_LONG_NORMAL_ONLY"]=="1"{trials=Array(all.prefix(3))}
        else if env["HANQ_LONG_RECOVERY_ONLY"]=="1"{trials=Array(all.dropFirst(3))}
        else{trials=all}
    }
    var now:Double {ProcessInfo.processInfo.systemUptime}
    func later(_ seconds:Double,_ action:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:action)}
    func applicationDidFinishLaunching(_ note:Notification) {
        longInstallMenus();window=NSWindow(contentRect:NSRect(x:170,y:150,width:820,height:550),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="한Q 긴 본문 자동 입력 검증"
        status.frame=NSRect(x:20,y:492,width:780,height:40);window.contentView!.addSubview(status)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        longWrite(root,"ready.json",["pid":getpid(),"cases":trials.count,"syntheticHID":true,"physicalKeys":false,"bodyCount":10000,"actualTextStored":false,"initialSource":sourceState.original.map(longSourceID) ?? "","initialManageableEnabled":sourceState.initiallyEnabled,"initialSelectableIncludingOSManaged":sourceState.initiallySelectable])
        guard !trials.isEmpty else{finish("empty_trial_plan");return}
        if let data=try? Data(contentsOf:root.appendingPathComponent("product.json")),let record=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let pid=record["main_pid"] as? Int,let identity=record["app"] as? [String:Any],let path=identity["path"] as? String {
            let product=LongProductIdentity(pid:pid,path:path+"/Contents/MacOS/HanQ")
            productPID=pid
            productTimer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){[weak self] _ in
                guard let self,!self.done else{return}
                if !product.alive {
                    longWrite(self.root,"product-exit.json",["pid":pid,"uptime":self.now,"caseIndex":self.index,"originalKeyDowns":self.field.observedOriginalDowns,"repairKeyDowns":self.field.observedRepairDowns])
                    self.finish("product_exited")
                }
            }
        }else if FileManager.default.fileExists(atPath:root.appendingPathComponent("product.json").path){
            finish("invalid_product_record");return
        }
        later(0.4){self.next()}
    }
    func finish(_ reason:String) {
        guard !done else{return};done=true;productTimer?.invalidate();field.forceRoman=false;field.staleRole=false
        let restored=sourceState.restore(),passed=reason=="completed" && rows.count==trials.count && rows.allSatisfy{$0["passed"] as? Bool==true} && restored
        try? Data().write(to:root.appendingPathComponent("quit"))
        longWrite(root,"results.json",["passed":passed,"reason":reason,"cases":rows,"plannedCases":trials.map(\.name),"singleParagraph":singleParagraph,"restored":restored,"restoredSource":longSource(),"enabledAfter":LongSourceState.enabled(),"selectableAfterIncludingOSManaged":LongSourceState.enabled(false),"physicalKeys":false,"actualTextStored":false])
        status.stringValue=passed ? "전체 통과 · 원래 입력 소스 복원":"중단: \(reason) · 원래 소스 복원 \(restored)"
        if !restored,sourceState.needsCleanup {
            status.stringValue="중단: \(reason) · 다른 앱의 소스는 바꾸지 않았습니다. 이 창으로 돌아와 복원 버튼을 누르세요."
            _=OwnedInputSourceCleanup(window:window,restore:{self.sourceState.restore()},completed:{
                longWrite(self.root,"cleanup.json",["restoredAfterReturn":true,"originalTestPassed":false]);NSApp.terminate(nil)
            })
        }
        if passed {NSApp.terminate(nil)}
    }
    func monitoringState()->[String:Any] {
        productPID.map{LongProductIdentity.monitoringState(pid:$0)} ?? ["allExpectedTapsActive":true,"controlWithoutProduct":true]
    }
    func awaitMonitoring(deadline:Double,completion:@escaping()->Void) {
        guard !done else{return}
        guard NSApp.isActive,window.firstResponder === field else{finish("focus_lost_during_monitoring_warmup");return}
        let state=monitoringState()
        if state["allExpectedTapsActive"] as? Bool==true {monitoringBefore=state;completion();return}
        if now>=deadline {longWrite(root,"monitoring-unavailable.json",state);finish("product_monitoring_unavailable");return}
        status.stringValue="입력 감시 준비 확인 중 · 아직 키를 보내지 않습니다."
        later(0.1){self.awaitMonitoring(deadline:deadline,completion:completion)}
    }
    func send(_ keys:[LongKey],gap:Double,_ completion:@escaping([String:Any])->Void) {
        guard !done else{return}
        guard NSApp.isActive,window.firstResponder === field else{finish("focus_lost_before_send");return}
        try? FileManager.default.removeItem(at:root.appendingPathComponent("done.json"))
        longWrite(root,"request.json",["pid":getpid(),"gap":gap,"keys":keys.map(\.json)])
        let deadline=now+max(8,Double(keys.count)*gap+6)
        func poll(){
            guard !done else{return}
            guard NSApp.isActive,window.firstResponder === field else{finish("focus_lost_during_send");return}
            if let data=try? Data(contentsOf:root.appendingPathComponent("done.json")),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                guard value["passed"] as? Bool==true else{finish("sender_guard_aborted");return};completion(value);return
            }
            guard now<deadline else{finish("sender_timeout");return};later(0.01,poll)
        };poll()
    }
    func sendTrial(_ t:LongTrial,prefix:String,suffix:String,sentAt:Double){
        func verifyResult(_ sender:[String:Any]){self.verify(t,prefix:prefix,suffix:suffix,sender:sender,sentAt:sentAt,deadline:self.now+5,stable:nil)}
        guard t.name=="manual conversion immediate switch" else{send(t.keys,gap:t.gap,verifyResult);return}
        // Establish the selected-word precondition before testing conversion
        // followed immediately by the source switch. Posting arrows is no proof
        // that the editor has applied their selection yet.
        send(Array(t.keys.prefix(20)),gap:t.gap){first in
            let deadline=self.now+3
            func awaitSelection(_ stable:Double?){
                guard !self.done else{return}
                let good=self.field.string.utf16.elementsEqual((prefix+"Tkdldnjfem"+suffix).utf16) && self.field.selectedRange()==NSRange(location:prefix.utf16.count,length:10) && longSource()==longABC
                let began=good ? (stable ?? self.now):nil
                if let began,self.now-began>=0.12 {
                    longWrite(self.root,"manual-precondition.json",["wholeUTF16Exact":true,"selectionMatched":true,"sourceMatched":true,"uptime":self.now,"stableMilliseconds":120,"wallTime":Date().timeIntervalSince1970])
                    self.send(Array(t.keys.dropFirst(20)),gap:t.gap){second in
                        let combined:[String:Any]=["passed":true,"plannedKeys":t.keys.count,"postedDowns":(first["postedDowns"] as? Int ?? 0)+(second["postedDowns"] as? Int ?? 0),"postedUps":(first["postedUps"] as? Int ?? 0)+(second["postedUps"] as? Int ?? 0),"finishedUptime":second["finishedUptime"] as? Double ?? self.now,"nominalGapMs":t.gap*1000,"groups":[first,second],"selectionPreparedSeparately":true]
                        verifyResult(combined)
                    };return
                }
                guard self.now<deadline else{self.finish("manual_selection_precondition_unmet");return}
                self.later(0.02){awaitSelection(began)}
            };awaitSelection(nil)
        }
    }
    func next(){
        guard !done else{return}
        guard ownedInputSourceLocalFocus() else{finish("focus_lost_before_preparation");return}
        guard index<trials.count else{finish("completed");return}
        let t=trials[index];status.stringValue="\(index+1)/\(trials.count) · \(t.name) · 합성 입력 중"
        field.forceRoman=false;field.staleRole=false;field.inputContext?.discardMarkedText();field.removeFromSuperview();retired.append(field)
        field=longField(NSRect(x:0,y:0,width:770,height:440));let scroll=NSScrollView(frame:NSRect(x:20,y:30,width:780,height:450));scroll.hasVerticalScroller=true;scroll.documentView=field;field.isVerticallyResizable=true;field.autoresizingMask=[.width]
        for child in window.contentView!.subviews where child is NSScrollView{child.removeFromSuperview()}
        window.contentView!.addSubview(scroll);window.makeFirstResponder(field);_=field.inputContext
        guard sourceState.select(longTwoSet) else{finish("source_unavailable");return}
        later(0.25){
            guard !self.done else{return}
            guard self.sourceState.select(t.source) else{self.finish("trial_source_unavailable");return}
            self.later(0.25){self.send([LongKey(code:49),LongKey(code:51)],gap:0.04){_ in
                self.later(0.1){
                    self.field.inputContext?.discardMarkedText();let (prefix,suffix)=longContext(t.bodyCount,singleParagraph:self.singleParagraph)
                    self.field.string=prefix+suffix;self.field.setSelectedRange(NSRange(location:prefix.utf16.count,length:0));self.field.scrollRangeToVisible(self.field.selectedRange())
                    self.field.observedOriginalDowns=0;self.field.observedRepairDowns=0;self.field.forcedRoman=0;self.field.pasteCalls=0;self.field.resetReceiptTiming()
                    if t.name.contains("delete"){self.field.deletionCaret=prefix.utf16.count;self.field.deletionSuffixCount=suffix.utf16.count}
                    self.field.staleRole=t.stale
                    self.later(0.4){
                        guard self.field.string.utf16.elementsEqual((prefix+suffix).utf16),self.field.selectedRange()==NSRange(location:prefix.utf16.count,length:0),longSource()==t.source else{self.finish("invalid_trial_baseline");return}
                        func beginSend(){
                            guard self.field.string.utf16.elementsEqual((prefix+suffix).utf16),self.field.selectedRange()==NSRange(location:prefix.utf16.count,length:0),longSource()==t.source else{self.finish("changed_baseline_during_hold");return}
                            longWrite(self.root,"idle-end.json",["case":t.name,"uptime":self.now,"baselineVerified":true])
                            self.awaitMonitoring(deadline:self.now+10){
                                guard self.field.string.utf16.elementsEqual((prefix+suffix).utf16),self.field.selectedRange()==NSRange(location:prefix.utf16.count,length:0),longSource()==t.source else{self.finish("changed_baseline_during_monitoring_warmup");return}
                                self.field.forceRoman=t.forced;self.field.staleRole=t.stale
                                let sentAt=self.now
                                longWrite(self.root,"trial-start.json",["case":t.name,"index":self.index,"uptime":sentAt,"bodyCount":t.bodyCount,"nominalGapMs":t.gap*1000,"productMonitoring":self.monitoringBefore,"wallTime":Date().timeIntervalSince1970])
                                self.sendTrial(t,prefix:prefix,suffix:suffix,sentAt:sentAt)
                            }
                        }
                        let hold=Double(ProcessInfo.processInfo.environment["HANQ_LONG_IDLE_SECONDS"] ?? "0") ?? 0
                        if hold>0,hold<=30 {
                            longWrite(self.root,"idle-start.json",["case":t.name,"uptime":self.now,"bodyCount":t.bodyCount,"seconds":hold,"baselineVerified":true])
                            self.later(hold,beginSend)
                        }else{beginSend()}
                    }
                }
            }}
        }
    }
    func verify(_ t:LongTrial,prefix:String,suffix:String,sender:[String:Any],sentAt:Double,deadline:Double,stable:Double?){
        guard !done else{return}
        guard NSApp.isActive,window.firstResponder === field else{finish("focus_lost_during_verify");return}
        let expected=t.replaceAll ? t.inserted:prefix+t.inserted+suffix
        let caret=t.replaceAll ? t.inserted.utf16.count:prefix.utf16.count+t.inserted.utf16.count
        let exact=field.string.utf16.elementsEqual(expected.utf16),selection=field.selectedRange()==NSRange(location:caret,length:0),source=longSource()==(t.expectedSource ?? t.source)
        let repairObserved=field.observedRepairDowns>0
        let repair = !t.forced || (field.forcedRoman>0 && repairObserved)
        let normalKeyDelivery = (!t.name.hasPrefix("continuous sentence") && !(t.stale && !repairObserved)) || (field.observedOriginalDowns==(sender["postedDowns"] as? Int ?? -1) && field.observedRepairDowns==0)
        let deletionScenario = !t.name.contains("committed") || (field.deletionEvidence["markedBeforeDelete"] as? Bool==false && field.deletionEvidence["beforeDeleteState"] as? String=="gan" && field.deletionEvidence["afterDeleteState"] as? String=="empty" && field.deletionEvidence["afterRetypeState"] as? String=="mieum")
        let first=(exact && selection && source && repair && normalKeyDelivery && deletionScenario) ? (stable ?? now):nil
        if now<deadline && (first==nil || now-first!<0.12){later(0.02){self.verify(t,prefix:prefix,suffix:suffix,sender:sender,sentAt:sentAt,deadline:deadline,stable:first)};return}
        let sentEnd=sender["finishedUptime"] as? Double ?? sentAt
        var row:[String:Any]=["case":t.name,"passed":exact && selection && source && repair && normalKeyDelivery && deletionScenario,"deletionScenarioMatched":deletionScenario,"normalKeyDeliveryMatched":normalKeyDelivery,"source":t.source,"sourceMatched":source,"bodyCount":t.bodyCount,"expectedInserted":t.inserted,"wholeUTF16Exact":exact,"selectionMatched":selection,"difference":longDifference(field.string,expected),"deletionEvidence":field.deletionEvidence,"selectionLocation":field.selectedRange().location,"selectionLength":field.selectedRange().length,"forcedOriginalLetters":field.forcedRoman,"repairKeyDowns":field.observedRepairDowns,"originalKeyDowns":field.observedOriginalDowns,"repairObserved":repairObserved,"repairRequirementMatched":repair,"repairExerciseRequired":t.forced,"staleAXRoleOnlyNoCompositionFault":t.stale,"staleAXRoleInjected":t.stale,"confirmAfterLastPostMs":((first ?? now)-sentEnd)*1000,"sendToStableMs":((first ?? now)-sentAt)*1000,"sender":sender]
        row["pasteCalls"]=field.pasteCalls
        row["lastPasteReceivedUptime"]=field.lastPasteReceived
        row["lastPasteHandledUptime"]=field.lastPasteHandled
        if t.name=="manual conversion immediate switch",let groups=sender["groups"] as? [[String:Any]],groups.count==2,
           let times=groups[1]["downSequenceUptime"] as? [Double],times.count>=2 {
            row["manualSwitchDownUptime"]=times[1]
            row["switchPostedBeforePasteHandled"]=field.pasteCalls>0 && times[1]<field.lastPasteHandled
            row["switchDownToVerifiedMs"]=((first ?? now)-times[1])*1000
            row["conversionDownToSwitchDownMs"]=(times[1]-times[0])*1000
        }
        row["receiverFirstOriginalUptime"]=field.firstOriginalReceived
        row["receiverLastOriginalUptime"]=field.lastOriginalReceived
        row["receiverLastHandledUptime"]=field.lastOriginalHandled
        row["receiverHandlingSeconds"]=field.originalHandlingSeconds
        row["receiverCheckpoints"]=field.receiptCheckpoints
        // Times/counts only, bounded to the sender's existing1500-key maximum.
        // Pair by index only for normal continuous cases whose complete original
        // key count matches the sender; modifier/manual groups differ in shape.
        row["receiverOriginalReceiptTimes"]=field.originalReceiptTimes
        row["receiverOriginalHandledTimes"]=field.originalHandledTimes
        row["receiverTimingClipped"]=field.observedOriginalDowns>1500
        row["lastReceiptAfterLastPostMs"]=(field.lastOriginalReceived-sentEnd)*1000
        row["lastHandledAfterLastPostMs"]=(field.lastOriginalHandled-sentEnd)*1000
        let monitoringAfter=monitoringState()
        row["inputResultMatched"]=row["passed"]
        row["productMonitoringBefore"]=monitoringBefore;row["productMonitoringAfter"]=monitoringAfter
        row["passed"]=(row["passed"] as? Bool==true) && (monitoringAfter["allExpectedTapsActive"] as? Bool==true)
        longWrite(root,"trial-end.json",["index":index,"case":t.name,"uptime":now,"wallTime":Date().timeIntervalSince1970,"passed":row["passed"] as? Bool==true,"scope":"input verification complete; source restoration follows outside this interval"])
        rows.append(row);longWrite(root,"progress.json",["completed":rows.count,"cases":rows]);index+=1
        if row["passed"] as? Bool != true{finish("case_failure");return}
        let hold=Double(ProcessInfo.processInfo.environment["HANQ_LONG_RESULT_HOLD_SECONDS"] ?? "0") ?? 0
        later(hold>=0 && hold<=2 ? max(0.1,hold):0.1){self.next()}
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if !done{finish("user_cancelled")}
        return sourceState.needsCleanup ? .terminateCancel:.terminateNow
    }
}
@main enum LongAutoMain {
    static func main(){
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--guard-probe" {
            longWrite(URL(fileURLWithPath:CommandLine.arguments[2]),"source-guard-permission.json",["ax":AXIsProcessTrusted(),"post":CGPreflightPostEventAccess(),"pid":getpid(),"changesSource":false,"postsKeys":false]);return
        }
        guard CommandLine.arguments.count==2 else{exit(2)}
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=LongAuto(URL(fileURLWithPath:CommandLine.arguments[1]));app.delegate=delegate
        withExtendedLifetime(delegate){app.run()}
    }
}
