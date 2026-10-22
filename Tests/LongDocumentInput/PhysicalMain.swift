import AppKit
import Carbon

// Human starts each step. This executable has no sender, event tap, CGEvent
// posting or key-state reset. Only the owned NSTextView receives test input.
struct LongPhysicalStep {
    let name:String,instruction:String,inserted:String
    var singleParagraph=false
    var bodyCount=10000,initialSource=longTwoSet,finalSource=longTwoSet
    var replaceAll=false,forced=false,manualConversion=false
}
func physicalLongSteps()->[LongPhysicalStep] {
    [
        .init(name:"1천 자 연속 타자",instruction:"아래 문장을 두 번 연속으로 직접 입력하세요. 각 문장 마침표 뒤에 공백 하나를 넣으세요.\n왼쪽과 오른쪽을 오가며 확인합니다.",inserted:String(repeating:longSentence,count:2),bodyCount:1000),
        .init(name:"1만 자 연속 타자",instruction:"같은 문장을 세 번 연속으로, 평소 빠른 속도로 입력하세요. 각 문장 마침표 뒤 공백 하나를 포함합니다.\n왼쪽과 오른쪽을 오가며 확인합니다.",inserted:String(repeating:longSentence,count:3),singleParagraph:true),
        .init(name:"빠른 한영 왕복",instruction:"간 → 한영키(기본 우측 Command) → abc → 한영키 → 간을 쉬지 않고 이어 입력하세요. 마지막 간 뒤 공백은 넣지 마세요.",inserted:"간abc간"),
        .init(name:"전체 선택 뒤 전환·대체",instruction:"간(R K S) → Command+A를 한 번 → 한영키 → abc. 입력 직후 시험용 긴 본문 전체를 abc로 바꾸는 단계입니다.",inserted:"abc",finalSource:longABC,replaceAll:true),
        .init(name:"첫 영문 불일치 복구",instruction:"영문 키 위치 D K를 빠르게 입력하세요(두벌식 ‘아’). 복구 재입력 전의 D/K를 시험 창이 영문으로 넣어 복구 상황을 만듭니다. 정상 결과는 ‘아’입니다.",inserted:"아",forced:true),
        .init(name:"복구 직후 빠른 전환",instruction:"영문 키 위치 D K → 즉시 한영키 → A B를 빠르게 이어 입력하세요. 정상 결과는 ‘아ab’. 복구 전 D/K 영문 주입은 시험 조건입니다.",inserted:"아ab",finalSource:longABC,forced:true),
        .init(name:"삭제 후 재입력·첫 전환",instruction:"간(R K S) → Backspace 한 번 → ㅁ(A) → 한영키 → abc. 정상 결과는 ‘감abc’입니다.",inserted:"감abc",finalSource:longABC),
        .init(name:"선택 영타 변환 뒤 첫 전환",instruction:"Tkdldnjfem 입력 → Option+Shift+왼쪽으로 단어 선택 → 한자키(기본 우측 Option). ‘싸이월드’ 변환을 눈으로 확인한 즉시 한영키 → 간(R K S). 정상 결과는 ‘싸이월드간’입니다.",inserted:"싸이월드간",initialSource:longABC,manualConversion:true)
    ]
}
final class LongPhysical:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let root:URL,steps=physicalLongSteps(),sourceState=LongSourceState()
    let heading=NSTextField(labelWithString:""),hint=NSTextField(wrappingLabelWithString:""),status=NSTextField(wrappingLabelWithString:"")
    let device=NSPopUpButton(),start=NSButton(title:"단계 시작",target:nil,action:nil),confirm=NSButton(title:"입력 완료 확인",target:nil,action:nil),end=NSButton(title:"종료·원래 소스 복원",target:nil,action:nil)
    var window:NSWindow!,field=longField(.zero),scroll:NSScrollView!,timer:Timer?
    var index=0,attempt=0,armed=false,checking=false,hadStarted=false,finished=false,startedAt=0.0
    var attempts:[[String:Any]]=[],latest:[Int:Bool]=[:]
    let product:[String:Any]
    let processIdentity:LongProductIdentity?
    let originalCaps=CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    init(_ root:URL){self.root=root;product=(try? JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("product.json"))) as? [String:Any]) ?? [:]
        if let pid=product["pid"] as? Int,let path=product["path"] as? String{processIdentity=LongProductIdentity(pid:pid,path:path+"/Contents/MacOS/HanQ")}else{processIdentity=nil}
    }
    var now:Double {ProcessInfo.processInfo.systemUptime}
    func productAlive()->Bool {
        processIdentity?.alive==true
    }
    func write(_ name:String,_ value:[String:Any]){longWrite(root,name,value)}
    func applicationDidFinishLaunching(_ note:Notification){
        longInstallMenus();window=NSWindow(contentRect:NSRect(x:180,y:120,width:900,height:680),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false);window.delegate=self;window.title="한Q \(product["build"] ?? "미확인") · 긴 본문 물리 키 검증"
        heading.font=NSFont.boldSystemFont(ofSize:19);heading.frame=NSRect(x:22,y:625,width:850,height:30)
        hint.frame=NSRect(x:22,y:515,width:850,height:103);hint.font=NSFont.systemFont(ofSize:15)
        status.frame=NSRect(x:22,y:457,width:850,height:54)
        scroll=NSScrollView(frame:NSRect(x:22,y:100,width:850,height:350));scroll.hasVerticalScroller=true
        field=longField(NSRect(x:0,y:0,width:830,height:350));field.isVerticallyResizable=true;scroll.documentView=field;field.isEditable=false
        device.frame=NSRect(x:22,y:50,width:140,height:30);device.addItems(withTitles:["내장 키보드","외부 키보드","기기 미기록"])
        start.frame=NSRect(x:180,y:50,width:170,height:32);start.target=self;start.action=#selector(begin)
        confirm.frame=NSRect(x:365,y:50,width:180,height:32);confirm.target=self;confirm.action=#selector(verify)
        end.frame=NSRect(x:575,y:50,width:270,height:32);end.target=self;end.action=#selector(closeTest)
        for view in [heading,hint,status,scroll,device,start,confirm,end] as [NSView]{window.contentView!.addSubview(view)}
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);showStep()
        write("ready.json",["pid":getpid(),"steps":steps.count,"product":product,"status":"waiting_for_human_start","physicalInput":true,"physicalKeysExecuted":false,"testStarted":false,"productIdentityVerifiedAtLaunch":productAlive(),"postsKeys":false,"actualTextStored":false])
        timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in
            guard let self,self.armed else{return}
            if !self.productAlive(){self.armed=false;self.confirm.isEnabled=false;self.status.stringValue="한Q 프로세스가 바뀌거나 종료됐습니다. 입력을 멈추고 이 창을 유지한 채 알려주세요.";self.saveProgress("product_changed")}
        }
    }
    func showStep(){
        guard index<steps.count else{finish();return};let s=steps[index]
        heading.stringValue="\(index+1)/\(steps.count) · \(s.name)"
        hint.stringValue=s.instruction+"\n붙여넣기 없이 직접 입력한 뒤 ‘입력 완료 확인’을 누르세요."
        status.stringValue="대기 중 · 단계 시작을 누르면 합성 본문과 커서를 준비합니다. 키는 자동 전송하지 않습니다."
        start.title="단계 시작";start.isEnabled=productAlive();confirm.isEnabled=false;field.isEditable=false
    }
    @objc func begin(){
        guard !checking,index<steps.count,productAlive(),NSApp.isActive else{status.stringValue="한Q 실행과 이 창의 활성 상태를 먼저 확인하세요.";return}
        hadStarted=true;attempt+=1;armed=false;let s=steps[index];field.forceRoman=false;field.staleRole=false;field.inputContext?.discardMarkedText()
        guard sourceState.select(s.initialSource) else{status.stringValue="입력 소스를 준비하지 못했습니다. 통과로 기록하지 않습니다.";return}
        let (prefix,suffix)=longContext(s.bodyCount,singleParagraph:s.singleParagraph);field.isEditable=true;field.string=prefix+suffix;field.setSelectedRange(NSRange(location:prefix.utf16.count,length:0));window.makeFirstResponder(field);_=field.inputContext;field.scrollRangeToVisible(field.selectedRange())
        field.deletionEvidence=[:];field.deletionCaret=index==6 ? prefix.utf16.count:nil;field.deletionSuffixCount=suffix.utf16.count
        field.observedOriginalDowns=0;field.observedRepairDowns=0;field.forcedRoman=0;field.pasteCalls=0
        start.isEnabled=false;confirm.isEnabled=false;status.stringValue="준비 중…"
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5){
            guard self.productAlive(),NSApp.isActive,self.window.firstResponder === self.field,longSource()==s.initialSource else{self.status.stringValue="준비 상태가 바뀌었습니다. 단계 시작을 다시 누르세요.";self.start.isEnabled=true;return}
            self.field.forceRoman=s.forced;self.startedAt=self.now;self.armed=true;self.confirm.isEnabled=true
            self.status.stringValue="입력 준비 완료 · 시작 문맥 \(s.bodyCount)자 · \(s.initialSource==longABC ? "영문":"두벌식") · 정해진 문구를 직접 입력하세요."
            self.saveProgress("armed")
        }
    }
    func saveProgress(_ stage:String){write("progress.json",["stage":stage,"step":index+1,"attempt":attempt,"verifiedSteps":latest.values.filter{$0}.count,"attempts":attempts,"physicalInput":true,"postsKeys":false,"actualTextStored":false])}
    @objc func verify(){
        guard armed,!checking,index<steps.count else{return};checking=true;confirm.isEnabled=false
        let s=steps[index],(prefix,suffix)=longContext(steps[index].bodyCount,singleParagraph:steps[index].singleParagraph)
        let expected=s.replaceAll ? s.inserted:prefix+s.inserted+suffix,caret=s.replaceAll ? s.inserted.utf16.count:prefix.utf16.count+s.inserted.utf16.count
        let originals=field.observedOriginalDowns,firstExact=field.string.utf16.elementsEqual(expected.utf16),firstRange=field.selectedRange()
        status.stringValue="본문·커서·소스가 안정적으로 유지되는지 확인 중…"
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4){
            self.checking=false
            let exact=self.field.string.utf16.elementsEqual(expected.utf16),range=self.field.selectedRange()==NSRange(location:caret,length:0),source=longSource()==s.finalSource
            let repair=self.field.forcedRoman>0 && self.field.observedRepairDowns>0
            let stable=firstExact && firstRange==self.field.selectedRange() && self.field.observedOriginalDowns==originals
            let inputMatched=self.productAlive() && exact && range && source && stable && originals>0 && (s.manualConversion || self.field.pasteCalls==0)
            let passed=inputMatched && (!s.forced || repair)
            let nativeDeleteReferencePending=self.index==6 && source && range && self.field.deletionEvidence["afterDeleteState"] as? String=="empty" && self.field.deletionEvidence["afterRetypeState"] as? String=="mieum" && self.field.string.utf16.elementsEqual((prefix+"ㅁabc"+suffix).utf16)
            let classification=passed ? "matched":(nativeDeleteReferencePending ? "native_delete_reference_pending":(inputMatched && s.forced ? (self.field.forcedRoman==0 ? "fault_not_injected":"replay_not_observed"):"input_or_guard_mismatch"))
            let row:[String:Any]=["step":self.index+1,"attempt":self.attempt,"name":s.name,"passed":passed,"classification":classification,"inputMatched":inputMatched,"faultInjected":self.field.forcedRoman>0,"productReplayObserved":self.field.observedRepairDowns>0,"physicalInputDeclared":true,"postsKeys":false,"keyboardClass":self.device.indexOfSelectedItem,"bodyCount":s.bodyCount,"singleParagraph":s.singleParagraph,"startedUptime":self.startedAt,"confirmedUptime":self.now,"wholeUTF16Exact":exact,"selectionMatched":range,"sourceMatched":source,"stableAtConfirmation":stable,"originalKeyDowns":originals,"repairKeyDowns":self.field.observedRepairDowns,"forcedOriginalLetters":self.field.forcedRoman,"repairObserved":repair,"pasteCalls":self.field.pasteCalls,"difference":longDifference(self.field.string,expected),"deletionEvidence":self.field.deletionEvidence,"switchDuringRepairProven":false]
            self.attempts.append(row);self.latest[self.index]=passed;self.armed=false;self.field.forceRoman=false
            self.saveProgress(passed ? "step_passed":"step_failed")
            if passed{self.index+=1;self.showStep()}
            else{
                if nativeDeleteReferencePending {self.status.stringValue="글자 단위 삭제 결과가 관측됐습니다. 조합 중 삭제와 기준이 달라 미확인으로 기록했습니다. 창을 유지하고 알려주세요."}
                else if inputMatched && s.forced {self.status.stringValue="본문은 맞지만 오류 주입·복구 실행 조건을 확인하지 못했습니다. 통과로 세지 않았습니다. 같은 단계를 다시 시작할 수 있습니다."}
                else{self.status.stringValue="불일치: 통과로 기록하지 않았습니다. 창을 유지하고 한Q 메뉴의 ‘방금 입력 누락 기록’을 누른 뒤 알려주세요. 다시 시작은 이 시험 본문만 초기화합니다."}
                self.start.title="같은 단계 다시 시작";self.start.isEnabled=self.productAlive();self.confirm.isEnabled=false
            }
        }
    }
    func finish(){
        armed=false;field.forceRoman=false;field.isEditable=false;finished=true
        let restored = !hadStarted || sourceState.restore()
        let capsRestored=CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)==originalCaps
        let passed=latest.count==steps.count && latest.values.allSatisfy{$0} && restored && capsRestored
        write("results.json",["passed":passed,"completedSteps":latest.values.filter{$0}.count,"attempts":attempts,"previousFailedAttempts":attempts.filter{$0["passed"] as? Bool==false}.count,"unexercisedFaultAttempts":attempts.filter{$0["classification"] as? String=="fault_not_injected"}.count,"sourceRestored":restored,"capsStateUnchanged":capsRestored,"initialManageableEnabled":sourceState.initiallyEnabled,"enabledAfter":LongSourceState.enabled(),"initialSelectableIncludingOSManaged":sourceState.initiallySelectable,"selectableAfterIncludingOSManaged":LongSourceState.enabled(false),"physicalInputDeclared":true,"postsKeys":false,"actualTextStored":false,"product":product])
        heading.stringValue="물리 키 시험 종료 · \(latest.values.filter{$0}.count)/\(steps.count)단계 확인"
        status.stringValue=passed ? "결과 저장 완료 · 원래 입력 소스 복원. 이전 실패 시도도 기록에 남겼습니다.":"부분 결과를 저장했습니다. 미완료 단계와 소스/Caps 상태는 통과로 표시하지 않습니다."
        start.isEnabled=false;confirm.isEnabled=false
    }
    @objc func closeTest(){NSApp.terminate(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{NSApp.terminate(nil);return false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        timer?.invalidate();if !finished{finish()}
        if sourceState.needsCleanup {
            guard sourceState.restore() else{status.stringValue="다른 앱의 입력 소스는 바꾸지 않았습니다. 이 창으로 돌아와 종료 버튼을 눌러 복원하세요.";return .terminateCancel}
            write("cleanup.json",["restoredAfterReturn":true,"originalResultUnchanged":true])
        }
        return .terminateNow
    }
}
@main enum LongPhysicalMain {
    static func main(){
        guard CommandLine.arguments.count==2 else{exit(2)}
        if CommandLine.arguments[1]=="--self-test" {
            let (p,s)=longContext(10000);precondition(p.utf16.count>10000 && s.utf16.count>300)
            let (a,b)=longContext(10000,singleParagraph:true);precondition(!(a+b).contains("\n") && a.utf16.count==p.utf16.count && b.utf16.count==s.utf16.count)
            let own=LongProductIdentity(pid:Int(getpid()),path:URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path)
            precondition(own.alive && !LongProductIdentity(pid:Int(getpid()),path:"/invalid").alive && !LongProductIdentity(pid:0,path:"/invalid").alive)
            precondition(longDifference("🙂abc","🙂ac")["exact"] as? Bool==false)
            precondition(longDifference("e\u{301}","é")["exact"] as? Bool==false)
            let d=longDifference("SECRET🙂","KNOWN🙂");let data=try! JSONSerialization.data(withJSONObject:d);precondition(!String(data:data,encoding:.utf8)!.contains("SECRET"))
            precondition(physicalLongSteps().count==8);print("PASS physical fixture UTF16/privacy/plan self-check; no physical input or key posts");return
        }
        let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=LongPhysical(URL(fileURLWithPath:CommandLine.arguments[1]));app.delegate=delegate;withExtendedLifetime(delegate){app.run()}
    }
}
