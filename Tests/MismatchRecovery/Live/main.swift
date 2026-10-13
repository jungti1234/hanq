import AppKit
import Carbon
import Foundation

// An owned editor for the installed HanQ. Uses real AX and IME paths; the first
// raw letter is deliberately inserted as ASCII to reproduce a mismatch.
final class Field:NSTextView {
    var fault=true
    var faultKey:UInt16=15
    var capsEdges=0
    var capsDetails:[[String:Any]]=[]
    var canBegin:(()->Bool)?
    var blocked:(()->Void)?
    var began:(()->Void)?
    var hold=false
    var holdUntil=0.0
    var held=false
    var edges:[String]=[]
    var eventDetails:[[String:Any]]=[]
    var lastInput=0.0
    override func accessibilitySelectedTextRange()->NSRange {
        if hold,!held,InputSourceAccess.currentID()=="com.apple.keylayout.ABC" {
            held=true;holdUntil=ProcessInfo.processInfo.systemUptime+0.6
            // Simulate an unresponsive editor, not an impossible selected range.
            // Preserve the client's real selection range. Only this owned
            // test editor is delayed.
            Thread.sleep(forTimeInterval:0.6)
        }
        return super.accessibilitySelectedTextRange()
    }
    override func keyDown(with e:NSEvent){
        if fault,e.keyCode==faultKey,canBegin?()==false{blocked?();return}
        lastInput=ProcessInfo.processInfo.systemUptime;edges.append("down:\(e.keyCode)")
        let marker=e.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        eventDetails.append(["code":Int(e.keyCode),"source":InputSourceAccess.currentID(),"contextSource":inputContext?.selectedKeyboardInputSource ?? "", "contextIsCurrent":NSTextInputContext.current === inputContext,"replay":UInt64(bitPattern:marker)>>32 == 0x48414E51,"navigation":marker==0x48414E514E415653,"time":lastInput,"modifiers":e.modifierFlags.rawValue])
        if fault,e.keyCode==faultKey{fault=false;began?();let literal=[15:"r",40:"k",5:"g"][Int(faultKey)]!;insertText(literal,replacementRange:selectedRange());return}
        super.keyDown(with:e)
    }
    override func flagsChanged(with e:NSEvent){
        if e.keyCode==57{
            capsEdges+=1;lastInput=ProcessInfo.processInfo.systemUptime
            capsDetails.append(["time":lastInput,"modifiers":e.modifierFlags.rawValue,"source":InputSourceAccess.currentID(),"contextSource":inputContext?.selectedKeyboardInputSource ?? ""])
        }
        super.flagsChanged(with:e)
    }
    override func keyUp(with e:NSEvent){edges.append("up:\(e.keyCode)");super.keyUp(with:e)}
}
final class Fixture:NSObject,NSApplicationDelegate {
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    var window:NSWindow!,field=Field(),label=NSTextField(labelWithString:""),guide=NSTextField(wrappingLabelWithString:""),button=NSButton(),retryButton=NSButton()
    var original:TISInputSource?,roman:Bool?
    var added:[TISInputSource]=[]
    var timer:Timer?
    var generation=0
    var mode="caps"
    var singleMenu:Bool{CommandLine.arguments.contains("--menu-single-suite")}
    var sourceID=KoreanKeyboardLayout.twoSetID
    var completed=false
    var waitingForActivation=false
    var retryCurrent=false
    var attempts:[[String:Any]]=[]
    var sources=[KoreanKeyboardLayout.twoSetID]
    var caseIndex=0
    var rows:[[String:Any]]=[]
    var trialTrace=TrialTrace()
    var observedSource=""
    var ready=false
    var selfCheckStage=0
    var selfCheckStarted=0.0
    var selfCheckOriginalHanqPID:Int?
    let hanqBuild=CommandLine.arguments.first(where:{$0.hasPrefix("--hanq-build=")}).map{String($0.dropFirst("--hanq-build=".count))} ?? "unknown"
    var instruction=""
    var retryNonce:String?
    var retryAck=false
    var retryStarted=0.0
    var hanqPID=CommandLine.arguments.first(where:{$0.hasPrefix("--hanq-pid=")}).flatMap{Int($0.dropFirst("--hanq-pid=".count))}
    var diagnostics:URL?
    func monitorReady()->Bool {
        guard let diagnostics,let handle=try? FileHandle(forReadingFrom:diagnostics) else{return false}
        defer{try? handle.close()}
        guard let size=try? handle.seekToEnd() else{return false}
        try? handle.seek(toOffset:size>16_384 ? size-16_384:0)
        let tail=(try? handle.readToEnd()) ?? Data()
        return CapsTrial.monitorReady(String(decoding:tail,as:UTF8.self),pid:hanqPID,now:Double(DispatchTime.now().uptimeNanoseconds))
    }
    func applicationDidFinishLaunching(_ n:Notification){
        if CommandLine.arguments.count>=3 {diagnostics=URL(fileURLWithPath:CommandLine.arguments[2])}
        if CommandLine.arguments.contains("--five"){sources=KoreanKeyboardLayout.supportedIDs}
        if CommandLine.arguments.contains("--diagnostic-three"){sources=[KoreanKeyboardLayout.twoSetID]}
        if CommandLine.arguments.contains("--menu-suite") || singleMenu{sources=Array(repeating:KoreanKeyboardLayout.twoSetID,count:3)}
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue();roman=try? RomanSwitchController.isEnabled()
        for id in KoreanKeyboardLayout.supportedIDs {
            guard let list=TISCreateInputSourceList([kTISPropertyInputSourceID as String:id] as CFDictionary,true)?.takeRetainedValue() as? [TISInputSource],let source=list.first else{continue}
            if let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()){
                if TISEnableInputSource(source)==noErr{added.append(source)}
            }
        }
        if CommandLine.arguments.contains("--five"),let data=try? Data(contentsOf:root.appendingPathComponent("prior.json")),let prior=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let cases=prior["cases"] as? [[String:Any]] {
            for row in cases{guard caseIndex<sources.count,row["passed"] as? Bool == true,row["originalSource"] as? String==sources[caseIndex] else{break};rows.append(row);caseIndex+=1}
        }
        window=NSWindow(contentRect:NSRect(x:180,y:200,width:680,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="한Q · 실제 입력 소스 전환 검사"
        label.frame=NSRect(x:20,y:240,width:640,height:35);window.contentView!.addSubview(label)
        guide.frame=NSRect(x:20,y:285,width:640,height:95);window.contentView!.addSubview(guide)
        retryButton.frame=NSRect(x:20,y:195,width:310,height:38);retryButton.title="같은 단계 다시 시도";retryButton.target=self;retryButton.action=#selector(retrySame);retryButton.refusesFirstResponder=true;window.contentView!.addSubview(retryButton)
        button.frame=NSRect(x:350,y:195,width:310,height:38);button.title="다음 입력기 검사";button.target=self;button.action=#selector(reset);button.refusesFirstResponder=true;window.contentView!.addSubview(button)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        label.stringValue="준비 중 · 입력하지 마세요";button.isEnabled=false;retryButton.isEnabled=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4){self.reset()}
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in self?.pulse()}
    }
    @objc func retrySame(){
        guard retryNonce==nil else{return}
        if completed,!retryCurrent,rows.last?["generation"] as? Int==generation {
            var previous=rows.removeLast();previous["reason"]="repeat_of_previously_passed_trial";attempts.append(previous);saveResults()
        }
        if completed{retryCurrent=true}
        reset()
    }
    @objc func reset(){
        guard retryNonce==nil else{return}
        if generation>0,!completed,!waitingForActivation {
            if let data=try? Data(contentsOf:root.appendingPathComponent("progress.json")),var attempt=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                attempt["passed"]=false;attempt["reason"]="user_requested_retry_before_verdict";attempts.append(attempt)
                saveResults()
            }
            completed=true;retryCurrent=true
        }
        if generation>0,!monitorReady(),!waitingForActivation {
            let nonce=UUID().uuidString;retryNonce=nonce;retryAck=false
            retryStarted=ProcessInfo.processInfo.systemUptime
            field.isEditable=false;button.isEnabled=false;retryButton.isEnabled=false;retryButton.title="같은 단계 재준비 중"
            label.stringValue="한Q를 자동으로 재준비합니다 · 시험창은 그대로 유지됩니다"
            let request:[String:Any]=["nonce":nonce,"pid":Int(getpid()),"generation":generation]
            if let data=try? JSONSerialization.data(withJSONObject:request){try? data.write(to:root.appendingPathComponent("retry-request.json"),options:.atomic)}
            return
        }
        guard NSApp.isActive,window.isKeyWindow else{
            waitingForActivation=true;label.stringValue="검사창을 클릭하면 자동으로 준비됩니다";retryButton.isEnabled=true;button.isEnabled=false;return
        }
        waitingForActivation=false
        if completed && !retryCurrent{caseIndex+=1}
        retryCurrent=false
        guard caseIndex<sources.count else{finish();return}
        completed=false;ready=false;generation+=1
        sourceID=sources[caseIndex]
        if CommandLine.arguments.contains("--menu-suite") || singleMenu{mode=["menu-English","menu-Korean","menu-cancel"][caseIndex]}
        trialTrace.begin(diagnostics)
        if let data=try? Data(contentsOf:root.appendingPathComponent("config.json")),let c=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{mode=c["mode"] as? String ?? "caps";if sources.count==1{sourceID=c["source"] as? String ?? KoreanKeyboardLayout.twoSetID}}
        field.inputContext?.discardMarkedText();field.removeFromSuperview();field=Field(frame:NSRect(x:20,y:20,width:640,height:165));field.isRichText=false;field.hold=true
        if CommandLine.arguments.contains("--ime-only"){field.fault=false;field.hold=false}
        if CommandLine.arguments.contains("--no-hold"){field.hold=false}
        field.faultKey=sourceID==KoreanKeyboardLayout.twoSetID ? 15:([KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID].contains(sourceID) ? 40:5)
        field.canBegin={ [weak self] in self?.monitorReady() ?? false }
        field.blocked={ [weak self] in self?.field.isEditable=false;self?.label.stringValue="한Q 복구 감시가 준비되지 않았습니다 · 입력하지 마세요" }
        field.began={ [weak self] in self?.retryButton.isEnabled=true;self?.retryButton.title="입력 실수 · 같은 단계 다시 시도" }
        button.isEnabled=true
        field.string="앞🙂뒤";field.setSelectedRange(NSRange(location:3,length:0));window.contentView!.addSubview(field);window.makeFirstResponder(field)
        guard InputSourceAccess.select("com.apple.keylayout.ABC")==noErr,InputSourceAccess.select(sourceID)==noErr else{label.stringValue="입력 소스 준비 실패 · 다시 준비를 눌러주세요";completed=true;retryCurrent=true;field.isEditable=false;button.title="다시 준비";retryButton.isEnabled=true;button.isEnabled=false;return}
        do{try RomanSwitchController.setEnabled(mode != "caps-off")}catch{label.stringValue="Caps Lock 설정 확인 실패 · 다시 준비를 눌러주세요";completed=true;retryCurrent=true;field.isEditable=false;button.title="다시 준비";retryButton.isEnabled=true;button.isEnabled=false;return}
        let first=[15:"r",40:"k",5:"g"][Int(field.faultKey)]!
        label.stringValue="\(caseIndex+1)/\(sources.count)  영문 \(first) 위치 → Caps Lock 직접 한 번 → 영문 키 2개(예: a, b)"
        if mode.hasPrefix("menu-") {
            label.stringValue=mode=="menu-English" ? "r k s → 즉시 입력 메뉴 → ABC 선택 → a b":(mode=="menu-Korean" ? "r k s → 즉시 입력 메뉴 → 세벌식390 선택 → k f s":"r k s → 즉시 입력 메뉴 → Esc로 취소 → r k s")
            if singleMenu{label.stringValue="\(caseIndex+1)/3  "+(mode=="menu-English" ? "r → 입력 메뉴에서 ABC 선택 → a b":(mode=="menu-Korean" ? "r → 입력 메뉴에서 세벌식390 선택 → k f s":"r → 입력 메뉴 열기 → Esc 취소 → r k s"))}
        }
        if CommandLine.arguments.contains("--diagnostic-three"){label.stringValue="진단 · 영문 R → K → S 위치만 입력 · 메뉴 전환 없음"}
        instruction=label.stringValue
        guide.stringValue="첫 \(first)은 시험창이 일부러 영문으로 넣습니다. 한Q가 복구하는지 확인하는 검사입니다."
        if singleMenu {
            let titles=["영어로 바꾸기","다른 한글 입력기로 바꾸기","메뉴를 열었다가 취소하기"]
            let actions=["목록에서 ABC를 클릭합니다.","목록에서 세벌식 390을 클릭합니다.","아무 항목도 선택하지 말고 Esc를 한 번 누릅니다."]
            let following=["a → b","k → f → s","r → k → s"]
            guide.stringValue="\(caseIndex+1)/3 · \(titles[caseIndex])\n① 입력칸에서 r 한 번 → 화면 오른쪽 위 ‘한/가/A’ 아이콘 클릭\n② \(actions[caseIndex])\n③ 시험창 입력칸으로 돌아와 \(following[caseIndex])를 입력합니다.\n첫 r은 일부러 영문으로 넣습니다. 실패해도 본문은 직접 고치지 마세요."
            instruction="\(caseIndex+1)/3 · 입력 기다리는 중 · 위 순서대로 진행하세요"
            label.stringValue=instruction
        }
        window.title="한Q 전환 검사 · \(caseIndex+1)/\(sources.count) · \(sourceID.components(separatedBy:".").last!)"
        field.isEditable=false;button.isEnabled=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.05){[weak self] in
            guard let self else{return};self.field.isEditable=true;self.window.makeFirstResponder(self.field);self.field.setAccessibilityFocused(true);self.ready=true;self.retryButton.title="같은 단계 다시 시도";self.retryButton.isEnabled=true;self.button.isEnabled=false
            if CommandLine.arguments.contains("--smoke") || CommandLine.arguments.contains("--smoke-five"){self.label.stringValue="한Q 자동 진단 중 · 키 입력을 잠시 멈춰주세요";self.button.isEnabled=false}
        }
    }
    func saveResults(){
        if let data=try? JSONSerialization.data(withJSONObject:["cases":rows,"attempts":attempts,"passed":rows.count==sources.count && rows.allSatisfy{$0["passed"] as? Bool == true}],options:[.prettyPrinted,.sortedKeys]){try? data.write(to:root.appendingPathComponent("results.json"),options:.atomic)}
    }
    func pulse(){
        if let nonce=retryNonce {
            if let data=try? Data(contentsOf:root.appendingPathComponent("retry-ready.json")),let ack=try? JSONSerialization.jsonObject(with:data) as? [String:Any],ack["nonce"] as? String==nonce {
                if ack["passed"] as? Bool == true,let pid=ack["pid"] as? Int {hanqPID=pid;retryAck=true}
                else {retryNonce=nil;retryButton.isEnabled=true;button.isEnabled=false;retryButton.title="같은 단계 다시 시도";label.stringValue="한Q 재준비에 실패했습니다 · 같은 버튼으로 다시 시도할 수 있습니다"}
            }
            if retryAck,monitorReady(){retryNonce=nil;retryAck=false;reset()}
            if retryNonce != nil,ProcessInfo.processInfo.systemUptime-retryStarted>15 {
                retryNonce=nil;retryAck=false;retryButton.isEnabled=true;button.isEnabled=false
                retryButton.title="같은 단계 다시 시도";label.stringValue="재준비 응답이 늦습니다 · 같은 버튼으로 다시 시도할 수 있습니다"
            }
        }

        if retryNonce==nil,ready,!completed,field.fault {
            let healthy=monitorReady()
            field.isEditable=healthy
            label.stringValue=healthy ? instruction:"한Q 복구 감시 확인 실패 · 아래 버튼으로 같은 단계를 다시 준비하세요"
            if !healthy{retryButton.isEnabled=true;button.isEnabled=false;retryButton.title="같은 단계 다시 시도"}
        }

        if (CommandLine.arguments.contains("--self-check-retry") || CommandLine.arguments.contains("--self-check-retry-reset") || CommandLine.arguments.contains("--self-check-retry-pass") || CommandLine.arguments.contains("--self-check-retry-reprepare")),ready {
            if selfCheckStage==0 {
                selfCheckStage=1
                if CommandLine.arguments.contains("--self-check-retry-reprepare") {
                    selfCheckOriginalHanqPID=hanqPID
                    // Run after the preparation shell has exited. Verify that
                    // the detached helper can still service a real retry.
                    DispatchQueue.main.asyncAfter(deadline:.now()+3){[weak self] in self?.hanqPID = -1;self?.retryButton.performClick(nil)}
                }else{
                if CommandLine.arguments.contains("--self-check-retry") {
                    guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"b",charactersIgnoringModifiers:"b",isARepeat:false,keyCode:11) else{failSelfCheck("event allocation failed");return}
                    field.keyDown(with:event)
                }
                if CommandLine.arguments.contains("--self-check-retry-pass"){rows.append(["passed":true,"generation":generation,"originalSource":sourceID,"hanqBuild":hanqBuild]);completed=true;retryCurrent=false}
                retryButton.performClick(nil)
                }
            }else if generation==2,retryNonce==nil,field.eventDetails.isEmpty,monitorReady() {
                let passed=caseIndex==0 && field.fault && rows.isEmpty && attempts.count==1 && window.firstResponder === field && retryButton.isEnabled && !button.isEnabled && (!CommandLine.arguments.contains("--self-check-retry-reprepare") || hanqPID != selfCheckOriginalHanqPID)
                let result:[String:Any]=["passed":passed,"physical_keys":false,"fixturePID":Int(getpid()),"hanqPID":hanqPID ?? 0,"test":"incomplete trial retry preserves same window/source/step and archives attempt; monitor reprepare automatic if needed"]
                if let data=try? JSONSerialization.data(withJSONObject:result){try? data.write(to:root.appendingPathComponent("self-check.json"),options:.atomic)}
                finish();return
            }
        }
        if CommandLine.arguments.contains("--self-check-monitor"),ready,selfCheckStage==0 {
            selfCheckStage=1;field.canBegin={false}
            let before=field.string
            guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"r",charactersIgnoringModifiers:"r",isARepeat:false,keyCode:field.faultKey) else{failSelfCheck("event allocation failed");return}
            field.keyDown(with:event)
            let passed=field.fault && field.string==before && field.eventDetails.isEmpty && !field.isEditable && label.stringValue.contains("준비되지 않았습니다")
            let result:[String:Any]=["passed":passed,"physical_keys":false,"test":"inactive monitor blocks first key without injecting false Roman text"]
            if let data=try? JSONSerialization.data(withJSONObject:result){try? data.write(to:root.appendingPathComponent("self-check.json"),options:.atomic)}
            finish();return
        }
        if CommandLine.arguments.contains("--self-check-first-key"),ready {
            if selfCheckStage==0 {
                selfCheckStage=1;selfCheckStarted=ProcessInfo.processInfo.systemUptime
                guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:selfCheckStarted,windowNumber:window.windowNumber,context:nil,characters:"b",charactersIgnoringModifiers:"b",isARepeat:false,keyCode:11) else{failSelfCheck("event allocation failed");return}
                field.keyDown(with:event)
            }else if selfCheckStage==1,completed {
                guard retryCurrent,retryButton.isEnabled,label.stringValue.contains("첫 키는 영문 G") else{failSelfCheck("wrong first key did not become retryable");return}
                selfCheckStage=2;retryButton.performClick(nil)
                return
            }else if selfCheckStage==2,field.eventDetails.isEmpty {
                let passed=caseIndex==3 && field.fault && window.firstResponder === field
                let result:[String:Any]=["passed":passed,"physical_keys":false,"test":"wrong first key completes, retry button acts, same source and step reset"]
                if let data=try? JSONSerialization.data(withJSONObject:result){try? data.write(to:root.appendingPathComponent("self-check.json"),options:.atomic)}
                finish();return
            }
            if selfCheckStage==1,ProcessInfo.processInfo.systemUptime-selfCheckStarted>4 {
                failSelfCheck("wrong-first-key check hung");return
            }
        }
        if waitingForActivation,NSApp.isActive,window.isKeyWindow{reset();return}
        if NSApp.isActive,window.isKeyWindow{observedSource=InputSourceAccess.currentID()}
        var row:[String:Any]=["observedAt":ProcessInfo.processInfo.systemUptime,"hanqBuild":hanqBuild,"pid":Int(getpid()),"generation":generation,"ready":ready,"firstResponderIsField":window.firstResponder === field,"mode":mode,"text":field.string,"caret":field.selectedRange().location,"selectionLength":field.selectedRange().length,"source":observedSource,"held":field.held,"holdRemaining":max(0,field.holdUntil-ProcessInfo.processInfo.systemUptime),"edges":field.edges,"capsEventsReceivedByField":field.capsEdges,"eventDetails":field.eventDetails,"originalSource":sourceID,"active":NSApp.isActive,"capsEnabled":(try? RomanSwitchController.isEnabled()) ?? false]
        row["monitorReady"]=monitorReady()
        row["capsDetails"]=field.capsDetails
        row["contextIsCurrent"]=NSTextInputContext.current === field.inputContext
        if let d=try? JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]){try? d.write(to:root.appendingPathComponent("progress.json"),options:.atomic)}
        let nudgeOnly=CommandLine.arguments.contains("--ime-only-nudge")
        if CommandLine.arguments.contains("--ime-only"),!completed,field.eventDetails.count >= (nudgeOnly ? 3:1),ProcessInfo.processInfo.systemUptime-field.lastInput>0.3 {
            completed=true
            let expectedEdges=(nudgeOnly ? ["down:123","up:123","down:124","up:124"]:[])+["down:\(field.faultKey)","up:\(field.faultKey)"]
            let pass=field.string=="앞🙂ㄱ뒤" && field.selectedRange()==NSRange(location:4,length:0) && observedSource==sourceID && field.eventDetails.count==(nudgeOnly ? 3:1) && field.edges==expectedEdges
            var result=row;result["passed"]=pass;result["physical_keys"]=false;result["test"]="native IME only; no HanQ recovery"
            rows.append(result)
            if let data=try? JSONSerialization.data(withJSONObject:["passed":rows.count==sources.count && rows.allSatisfy{$0["passed"] as? Bool == true},"cases":rows],options:[.prettyPrinted,.sortedKeys]){try? data.write(to:root.appendingPathComponent("ime-results.json"),options:.atomic)}
            if pass{DispatchQueue.main.asyncAfter(deadline:.now()+0.25){self.reset()}}
            else{label.stringValue="기본 IME 경로 비교 실패 · 추가 입력 없음";field.isEditable=false}
            return
        }
        if !completed {trialTrace.refresh(diagnostics)}
        let trace=trialTrace.text
        if !completed,!trialTrace.valid {
            completed=true;retryCurrent=true;field.isEditable=false;retryButton.isEnabled=true;button.isEnabled=false
            label.stringValue="진단 기록을 읽지 못했습니다 · 같은 단계 다시 시도";return
        }
        if CommandLine.arguments.contains("--smoke-five"),!completed,!field.fault,trialTrace.caughtUp {
            let finished=trace.contains("mismatch.recovery_finished") || trace.contains("mismatch.rollback_finished") || trace.contains("mismatch.pending_retained")
            if finished {
                completed=true
                let pass=field.string=="앞🙂ㄱ뒤" && field.selectedRange()==NSRange(location:4,length:0) && observedSource==sourceID && trace.contains("mismatch.korean_result_verified") && trace.contains("mismatch.recovery_finished") && !trace.contains("mismatch.abort ") && !trace.contains("mismatch.park ")
                var result=row;result["passed"]=pass;result["physical_keys"]=false;result["test"]="one fixed HID key, actual AX, installed HanQ"
                rows.append(result)
                if let data=try? JSONSerialization.data(withJSONObject:["passed":rows.count==sources.count && rows.allSatisfy{$0["passed"] as? Bool == true},"cases":rows,"physical_keys":false],options:[.prettyPrinted,.sortedKeys]){try? data.write(to:root.appendingPathComponent("smoke-results.json"),options:.atomic)}
                if pass {DispatchQueue.main.asyncAfter(deadline:.now()+0.25){self.reset()}}
                else {field.isEditable=false;label.stringValue="자동 진단 실패 · 추가 키를 보내지 않습니다"}
            }
            return
        }
        if completed || !trialTrace.caughtUp {
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("stop").path){finish()}
            return
        }
        let rawEvents=CapsTrial.userEvents(field.eventDetails,trace:trace)
        if CommandLine.arguments.contains("--diagnostic-three"),rawEvents.count>=3,ProcessInfo.processInfo.systemUptime-field.lastInput>1.5 {
            completed=true;field.isEditable=false
            let pass=rawEvents.compactMap{$0["code"] as? Int}==[15,40,1] && field.string=="앞🙂간뒤" && field.selectedRange()==NSRange(location:4,length:0) && observedSource==sourceID && trace.contains("mismatch.recovery_finished") && !trace.contains("mismatch.park ") && !trace.contains("mismatch.abort ")
            var result=row;result["passed"]=pass;result["physical_keys"]=CommandLine.arguments.contains("--physical-three");result["test"]="RKS detection with real AX/IME, no menu interaction; physical input requires user confirmation"
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:root.appendingPathComponent("diagnostic-result.json"),options:.atomic)}
            finish();return
        }
        let wrongFirst=field.fault && field.eventDetails.first.map{$0["code"] as? Int != Int(field.faultKey)} == true
        let requiredKeys=mode=="caps" ? 3:(singleMenu ? (mode=="menu-English" ? 3:4):(mode=="menu-English" ? 5:6))
        if !completed,(wrongFirst || rawEvents.count>=requiredKeys),ProcessInfo.processInfo.systemUptime-field.lastInput>1.5 {
            completed=true;field.isEditable=false
            let desired=mode=="caps" || mode=="menu-English" ? "com.apple.keylayout.ABC":(mode=="menu-Korean" ? KoreanKeyboardLayout.threeSet390ID:sourceID)
            button.title="검사 종료 · 추가 입력 잠김"
            let rawKeys=rawEvents.compactMap{$0["code"] as? Int}
            let script=mode=="caps" ? [Int(field.faultKey),0,11]:(singleMenu ? (mode=="menu-English" ? [15,0,11]:(mode=="menu-Korean" ? [15,40,3,1]:[15,15,40,1])):(mode=="menu-English" ? [15,40,1,0,11]:(mode=="menu-Korean" ? [15,40,1,40,3,1]:[15,40,1,15,40,1])))
            // Caps verifies language/order, not whether the user chose A/B.
            // Derive the expected suffix from exactly two physical letter keys;
            // extra keys, deletion and direct correction remain invalid.
            let unmodified=rawEvents.allSatisfy{event in
                guard let value=event["modifiers"] as? NSNumber else{return false}
                return NSEvent.ModifierFlags(rawValue:value.uintValue).intersection([.command,.control,.option,.shift]).isEmpty
            }
            let suffix=unmodified ? CapsTrial.followingRoman(rawEvents,first:Int(field.faultKey)):nil
            let prescribed=mode=="caps" ? suffix != nil:rawKeys==script
            let menuRoman=unmodified && mode=="menu-English" ? CapsTrial.followingRoman(Array(rawEvents.suffix(3)),first:singleMenu ? 15:1):nil
            let expected=mode=="caps" ? "앞🙂ㄱ\(suffix ?? "ab")뒤":(mode=="menu-English" ? "앞🙂\(singleMenu ? "ㄱ":"간")\(menuRoman ?? "ab")뒤":(singleMenu ? "앞🙂ㄱ간뒤":"앞🙂간간뒤"))
            let caret=expected.utf16.count-1
            let pass=field.string==expected && field.selectedRange()==NSRange(location:caret,length:0) && observedSource==desired
            let interaction=mode=="caps" ? trace.contains("mismatch.caps_source_confirmed"):(trace.contains("mismatch.source_menu_paused") && trace.contains("mismatch.source_work_resumed") && (mode=="menu-cancel" || trace.contains("mismatch.user_source_boundary")))
            let recovered=trace.contains("mismatch.recovery_finished") && interaction && !trace.contains("mismatch.abort ") && !trace.contains("mismatch.park ")
            let verified=pass && prescribed && recovered && trialTrace.valid && unmodified
            let first=[15:"R",40:"K",5:"G"][Int(field.faultKey)]!
            label.stringValue=wrongFirst ? "첫 키는 영문 \(first) 위치입니다 · 아래 버튼으로 같은 단계 재시도":(verified ? "통과 · 본문·커서·전환·복구 완료 확인":(prescribed ? "결과 불일치 또는 복구 미완료 · 아래 버튼 상태 확인":"지정 키 외 입력 포함 · 같은 단계에서 다시 시도"))
            retryCurrent = !verified
            button.isEnabled=verified;retryButton.isEnabled=true
            retryButton.title="같은 단계 다시 시도"
            button.title=verified ? (caseIndex+1<sources.count ? (mode.hasPrefix("menu-") ? "다음 메뉴 검사":"다음 입력기 검사"):"검사 완료 · 종료·설정 복원") : (mode.hasPrefix("menu-") ? "다음 메뉴 검사":"다음 입력기 검사")
            var result=row;result["bodyPassed"]=pass;result["prescribedKeys"]=prescribed;result["recoveryConfirmed"]=recovered;result["passed"]=verified
            if mode=="caps",let suffix{result["followingRoman"]=suffix}
            if verified{rows.append(result)}else{attempts.append(result)}
            if let d=try? JSONSerialization.data(withJSONObject:["cases":rows,"attempts":attempts,"passed":rows.count==sources.count && rows.allSatisfy{$0["passed"] as? Bool == true}],options:[.prettyPrinted,.sortedKeys]){try? d.write(to:root.appendingPathComponent("results.json"),options:.atomic)}
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:root.appendingPathComponent("result.json"),options:.atomic)}
        }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("stop").path){finish()}
    }
    func failSelfCheck(_ reason:String){
        if let data=try? JSONSerialization.data(withJSONObject:["passed":false,"reason":reason]){try? data.write(to:root.appendingPathComponent("self-check.json"),options:.atomic)}
        finish()
    }
    func finish(){
        try? Data().write(to:root.appendingPathComponent("stop"))
        field.inputContext?.discardMarkedText();if let original{TISSelectInputSource(original)};if let roman{try? RomanSwitchController.setEnabled(roman)}
        for source in added{TISDisableInputSource(source)};added=[]
        timer?.invalidate();NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        try? Data().write(to:root.appendingPathComponent("stop"))
        if let original{TISSelectInputSource(original)};if let roman{try? RomanSwitchController.setEnabled(roman)};for source in added{TISDisableInputSource(source)};added=[];return .terminateNow
    }
}
guard CommandLine.arguments.count>=2,CommandLine.arguments[1].hasPrefix("/private/tmp/hanq-source-live.") else{exit(0)}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let fixture=Fixture();app.delegate=fixture;app.run()
