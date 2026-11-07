import AppKit
import Carbon

// Bounded read-only editor observation. Discovery neither establishes input
// intent nor moves focus; only a later actual focused field can use its history.
final class OnsetFocusHandoff {
    enum Outcome:Int {case idle=0,eligibility,window,systemFocus,outsideIdentity,outsideRole,field,lateContext,deadline,requested,unconfirmed,confirmed}
    private(set) var lastOutcome=Outcome.idle
    private(set) var lastFieldCheck=0
    struct Candidate {let field:AXUIElement;let window:AXUIElement;let observedAt:Double}
    private(set) var candidate:Candidate?
    private var root:AXUIElement?
    private var outside:AXUIElement?
    private var cachedEditor:AXUIElement?
    var observeSnapshot:((OnsetSnapshot)->Void)?
    var nodeLimit=2048
    var sceneCompleted:Bool{completedScans>0}
    var sceneVisited:Int{visitedCount}
    var sceneClipped:Bool{(uncertainReasons & 48) != 0}
    var sceneScanning:Bool{!queue.isEmpty || pendingSearch != nil}
    var sceneEditorCount:Int{editors}
    private var emptyEntries:[(field:AXUIElement,window:AXUIElement,time:Double)]=[]
    private var representedEntries:[(snapshot:OnsetSnapshot,window:AXUIElement,time:Double)]=[]
    private var representationEpoch:UInt64=0
    var collectWitnessDiagnostics=false {
        didSet {if oldValue != collectWitnessDiagnostics && !collectWitnessDiagnostics {resetWitnessDiagnostics()}}
    }
    private var representationObservations:[(field:AXUIElement,reason:Int,time:Double)]=[]
    private var lastDiscovery=0,lastWitnessLookup=0,lastContextDiagnostic=0
    func resetWitnessDiagnostics(){representationObservations=[];lastDiscovery=0;lastWitnessLookup=0;lastContextDiagnostic=0}
    func noteDiscovery(_ reason:Int){if collectWitnessDiagnostics{lastDiscovery=reason}}
    private func noteRepresentation(_ field:AXUIElement,_ reason:Int,at time:Double){
        guard collectWitnessDiagnostics else{return}
        representationObservations.removeAll{CFEqual($0.field,field)}
        representationObservations.append((field,reason,time))
        if representationObservations.count>8{representationObservations.removeFirst()}
    }
    func witnessDetail(for field:AXUIElement,history:Int=0)->InputIncidentTrace.OnsetDetail? {
        guard collectWitnessDiagnostics else{return nil}
        let observed=representationObservations.last{CFEqual($0.field,field)}
        let age=observed.flatMap{entry -> Int? in
            let elapsed=now()-entry.time
            return elapsed.isFinite && elapsed>=0 ? Int(min(elapsed,60)*1_000_000):nil
        }
        return .init(discovery:lastDiscovery,representation:observed?.reason ?? 0,lookup:lastWitnessLookup,history:history,observationAgeMicros:age)
    }
    private var draftEntries:[(snapshot:OnsetSnapshot,window:AXUIElement,time:Double)]=[]
    // A recently observed editor is only a search hint. Pointer/shortcut input
    // still clears every proof; this reference can authorize no write.
    private var recentEditor:(field:AXUIElement,time:Double)?
    private var nextRecentValidation=0.0
    // A read-only pre-key baseline is useful even when another node makes
    // the whole-window focus candidate ambiguous. It never authorizes focus.
    func emptyEntryBaseline(for field:AXUIElement,before time:Double)->OnsetSnapshot? {
        guard let proof=emptyEntries.last(where:{CFEqual($0.field,field) && $0.time<=time && time-$0.time<=0.75}) else{return nil}
        guard now()>=proof.time,now()-proof.time<=1.1,currentContext(field,window:proof.window),
              !draftEntries.contains(where:{CFEqual($0.snapshot.element,field) && $0.time<time && $0.time>=proof.time}) else{return nil}
        return .init(element:field,text:"",selection:NSRange(location:0,length:0))
    }
    func draftEntryBaseline(for field:AXUIElement,before time:Double)->OnsetSnapshot? {
        guard let proof=draftEntries.last(where:{CFEqual($0.snapshot.element,field) && $0.time<time && time-$0.time<=0.75}),
              now()>=proof.time,now()-proof.time<=1.1,currentContext(field,window:proof.window),
              !emptyEntries.contains(where:{CFEqual($0.field,field) && $0.time<=time && $0.time>=proof.time}) else{return nil}
        return proof.snapshot
    }
    // Pointer/shortcut input invalidates both empty and existing-body evidence.
    func invalidateEmptyEntries(){emptyEntries=[];draftEntries=[];representedEntries=[];representationEpoch &+= 1;representationObservations=[];lastWitnessLookup=0}
    private var nextRefresh=0.0
    var sceneCacheEnabled=false
    private var queue:[(AXUIElement,Int)]=[]
    var editorSearch=OnsetEditorSearch()
    private var pendingSearch:(document:AXUIElement,children:[AXUIElement],depth:Int)?
    private var searchesThisScan=0
    private(set) var searchAttempts=0,searchOutcome=0
    private var visited:[CFHashCode:[AXUIElement]]=[:]
    private var visitedCount=0,editors=0
    private var found:AXUIElement?
    private var sceneEditor:AXUIElement?
    private var uncertain=false,attempted=false
    var diagnosticsEnabled=false
    private var diagnosticEditor:AXUIElement?,diagnosticEditorAt=0.0
    private var focusedSeen=0,focusedMatch=0,focusedShape=0,focusedSize=0,focusedCaret=0,rangeOneClass=0
    private var editableEmptyProof=0
    private var diagnosticCaretKind=0,diagnosticHintRelation=0,diagnosticHintKind=0
    private var diagnosticValueKind=0,diagnosticValueShape=0,diagnosticCountKind=0,diagnosticValueSize=0,diagnosticFormatOnly=0
    private var uncertainReasons=0,resetCount=0,scanCount=0,completedScans=0
    var diagnosticState:String {"candidate=\(candidate != nil ? 1:0) visited=\(visitedCount) limit=\(nodeLimit) queue=\(queue.count) editors=\(editors) uncertain=\(uncertainReasons) resets=\(resetCount) scans=\(scanCount) completed=\(completedScans) field=\(lastFieldCheck) outcome=\(lastOutcome.rawValue) attempted=\(attempted ? 1:0) cache=\(sceneCacheEnabled ? 1:0) valueKind=\(diagnosticValueKind) valueShape=\(diagnosticValueShape) countKind=\(diagnosticCountKind) valueSize=\(diagnosticValueSize) formatOnly=\(diagnosticFormatOnly) caretKind=\(diagnosticCaretKind) hintRelation=\(diagnosticHintRelation) hintKind=\(diagnosticHintKind) editableEmpty=\(editableEmptyProof) rangeOne=\(rangeOneClass) focusedSeen=\(focusedSeen) focusedMatch=\(focusedMatch) focusedShape=\(focusedShape) focusedSize=\(focusedSize) focusedCaret=\(focusedCaret) searchAttempts=\(searchAttempts) searchOutcome=\(searchOutcome)"}
    private var nextScan=0.0
    var now:()->Double={ProcessInfo.processInfo.systemUptime}
    var read:(AXUIElement,String)->CFTypeRef? = { element,name in
        AXUIElementSetMessagingTimeout(element,0.003)
        var value:CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
    }
    var batch:(AXUIElement,[String])->[CFTypeRef?] = { element,names in
        AXUIElementSetMessagingTimeout(element,0.003)
        return InputFocusAccess.attributes(element,names)
    }
    var rangeText:(AXUIElement,CFRange)->(AXError,String?) = {element,range in
        AXUIElementSetMessagingTimeout(element,0.003)
        var range=range
        guard let argument=AXValueCreate(.cfRange,&range) else{return (.failure,nil)}
        var raw:CFTypeRef?
        let error=AXUIElementCopyParameterizedAttributeValue(element,kAXStringForRangeParameterizedAttribute as CFString,argument,&raw)
        return (error,raw as? String)
    }
    var writable:(AXUIElement,String)->Bool = { element,name in
        var value:DarwinBoolean=false
        return AXUIElementIsAttributeSettable(element,name as CFString,&value) == .success && value.boolValue
    }
    var children:(AXUIElement)->[AXUIElement]? = { element in
        var value:CFTypeRef?
        let status=AXUIElementCopyAttributeValue(element,kAXChildrenAttribute as CFString,&value)
        if status == .attributeUnsupported || status == .noValue{return []}
        return status == .success ? value as? [AXUIElement]:nil
    }
    var owner:(AXUIElement)->pid_t?=InputFocusAccess.owner
    var frontPID:()->pid_t?={NSWorkspace.shared.frontmostApplication?.processIdentifier}
    var ready:()->Bool={AXIsProcessTrusted() && !IsSecureEventInputEnabled()}
    func reset(){resetCount=min(9_999_999,resetCount+1);candidate=nil;root=nil;outside=nil;cachedEditor=nil;nextRefresh=0;queue=[];pendingSearch=nil;searchesThisScan=0;visited=[:];visitedCount=0;editors=0;found=nil;uncertain=false;uncertainReasons=0;attempted=false;nextScan=0;nextRecentValidation=0;lastDiscovery=0}
    func beginDiagnosticObservation(){
        diagnosticEditor=nil;diagnosticEditorAt=0
        focusedSeen=0;focusedMatch=0;focusedShape=0;focusedSize=0;focusedCaret=0;rangeOneClass=0
    }
    func enteredEditor(_ element:AXUIElement?=nil,text:String?=nil,selection:NSRange?=nil){
        if let element{recentEditor=(element,now())}
        if diagnosticsEnabled,let element,let text,let selection {
            focusedSeen=1;focusedShape=InputIncidentAXEvidence.classify(text);focusedSize=min(3,text.utf16.count)
            focusedCaret=selection.length>0 ? 3:(selection.location==0 ? 1:2)
            if let diagnosticEditor,now()>=diagnosticEditorAt,now()-diagnosticEditorAt<=5.5 {
                focusedMatch=CFEqual(diagnosticEditor,element) ? 1:2
            }
        }
        reset()
    }
    private static let details=[kAXRoleAttribute,kAXSubroleAttribute,kAXValueAttribute,kAXSelectedTextRangeAttribute,kAXEnabledAttribute,"AXHidden",kAXWindowAttribute,kAXNumberOfCharactersAttribute]
    private func emptyEditor(_ field:AXUIElement,window:AXUIElement,observing:Bool=false,recording:Bool=true,readDraft:((OnsetSnapshot)->Void)?=nil)->Bool {
        let began=now()
        var representationReason=2
        defer{if observing{noteRepresentation(field,representationReason,at:began)}}
        let values=batch(field,Self.details)
        lastFieldCheck=1
        guard values.count==Self.details.count else{return false}
        lastFieldCheck=2
        guard let role=values[0] as? String,OnsetEditableRole.supports(role),values[1] as? String != kAXSecureTextFieldSubrole else{representationReason=3;return false}
        let text:String?,valueKind:Int
        if let raw=values[2],CFGetTypeID(raw) != CFNullGetTypeID() {
            if let string=raw as? String{text=string;valueKind=1}
            else if CFGetTypeID(raw)==CFAttributedStringGetTypeID(){text=CFAttributedStringGetString((raw as! CFAttributedString)) as String;valueKind=2}
            else{text=nil;valueKind=3}
        }else{text=nil;valueKind=0}
        let count:Double?={
            guard let raw=values[7],CFGetTypeID(raw)==CFNumberGetTypeID(),let number=raw as? NSNumber,
                  number.doubleValue.isFinite,number.doubleValue>=0 else{return nil}
            return number.doubleValue
        }()
        if observing,let text,text.utf16.count<=16384,
           values[4] as? Bool==true,values[5] as? Bool==false,
           let windowValue=values[6],CFGetTypeID(windowValue)==AXUIElementGetTypeID(),CFEqual(windowValue,window),
           let rawRange=values[3],CFGetTypeID(rawRange)==AXValueGetTypeID(),
           ready(),let pid=frontPID(),owner(window)==pid,owner(field)==pid {
            var range=CFRange()
            if AXValueGetValue(rawRange as! AXValue,.cfRange,&range),range.length==0,
               range.location>=0,range.location<=text.utf16.count,now()>=began,now()-began<0.012 {
                observeSnapshot?(.init(element:field,text:text,selection:NSRange(location:range.location,length:0)))
            }
        }
        func observeRepresentation(){
            guard let text else{representationReason=4;return}
            guard !text.isEmpty,text.utf16.count<=4096 else{representationReason=5;return}
            guard let count else{representationReason=6;return}
            guard count==Double(text.utf16.count) else{representationReason=7;return}
            guard Self.origin(values[3]) else{representationReason=8;return}
            guard values[4] as? Bool==true,values[5] as? Bool==false else{representationReason=9;return}
            guard let rawWindow=values[6],CFGetTypeID(rawWindow)==AXUIElementGetTypeID() else{representationReason=10;return}
            guard CFEqual(rawWindow,window) else{representationReason=11;return}
            guard ready(),let pid=frontPID(),owner(window)==pid,owner(field)==pid else{representationReason=12;return}
            guard now()>=began,now()-began<0.012 else{representationReason=13;return}
            let time=now()
            // A validated display is also a read-only refresh hint. It grants
            // no focus/write authority and retains the existing sample limits.
            rememberEditorHint(field,time:time)
            representedEntries.removeAll{time-$0.time>1.1}
            let previous=representedEntries.last(where:{CFEqual($0.snapshot.element,field)})
            if previous.map({!InputFocusAccess.literalTextEqual($0.snapshot.text,text) || !CFEqual($0.window,window) || time-$0.time>=0.05}) ?? true {
                representedEntries.append((.init(element:field,text:text,selection:NSRange(location:0,length:0)),window,time))
                if representedEntries.count>8{representedEntries.removeFirst()}
            }
            representationReason=1
        }
        if observing{observeRepresentation()}
        if observing,valueKind==1,let text,
           let draft=verifiedDraft(field,window:window,values:values,text:text,count:count,began:began) {
            readDraft?(draft)
            if recording{rememberDraftEntry(draft,window:window)}
        }
        if diagnosticsEnabled {
            diagnosticValueKind=valueKind;diagnosticValueShape=text.map(InputIncidentAXEvidence.classify) ?? 0
            diagnosticValueSize=text.map{min(3,$0.utf16.count)} ?? 0
            diagnosticFormatOnly=text.map{value in
                !value.isEmpty && value.utf16.count<=8 && value.unicodeScalars.allSatisfy{$0.properties.generalCategory == .format} ? 1:0
            } ?? 0
            diagnosticCountKind=values[7]==nil ? 0:(count==0 ? 1:(count != nil ? 2:3))
        }
        if diagnosticsEnabled && observing {
            diagnosticCaretKind=0
            if let raw=values[3],CFGetTypeID(raw) != CFNullGetTypeID() {
                diagnosticCaretKind=5
                if CFGetTypeID(raw)==AXValueGetTypeID() {
                    var range=CFRange()
                    if AXValueGetValue(raw as! AXValue,.cfRange,&range) {
                        if range.location==kCFNotFound || range.location==NSNotFound{diagnosticCaretKind=4}
                        else if range.location>=0 && range.length>=0 {
                            diagnosticCaretKind=range.length>0 ? 3:(range.location==0 ? 1:2)
                        }
                    }
                }
            }
            // Explicit temporary diagnostics only: compare published hints in
            // memory. No hint, body, label or range is passed to the logger.
            diagnosticHintKind=0;diagnosticHintRelation=0
            let hints=batch(field,["AXPlaceholderValue",kAXDescriptionAttribute,kAXTitleAttribute])
            if let text,!text.isEmpty {
                for (index,raw) in hints.enumerated() {
                    guard let hint=raw as? String,!hint.isEmpty else{continue}
                    if diagnosticHintKind==0{diagnosticHintKind=index+1;diagnosticHintRelation=2}
                    if hint==text{diagnosticHintKind=index+1;diagnosticHintRelation=1;break}
                }
            }
        }
        lastFieldCheck=12
        guard valueKind != 3 else{return false}
        editableEmptyProof=0
        let needsEditableProof=text.map{!$0.isEmpty && $0 != "\n"} ?? false
        lastFieldCheck=3
        // A published nonempty value remains content of unknown provenance.
        // Neither a hint string nor a range-query error proves an empty body.
        if needsEditableProof {return false}
        lastFieldCheck=4
        var unknownRange=values[3] == nil || values[3].map{CFGetTypeID($0)==CFNullGetTypeID()} == true
        if !unknownRange,let raw=values[3] {
            guard CFGetTypeID(raw)==AXValueGetTypeID() else{return false}
            var range=CFRange()
            guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.length==0 else{return false}
            unknownRange=range.location == kCFNotFound || range.location == NSNotFound
            if !unknownRange {
                lastFieldCheck=8
                guard range.location>=0,range.location<=(text?.utf16.count ?? 0) else{return false}
            }
        }
        // Missing value/caret is unknown even when a provider advertises zero
        // characters. Only an explicit value and valid caret can be a baseline.
        lastFieldCheck=10
        guard let text,!unknownRange else{return false}
        if text.isEmpty {
            guard values[7]==nil || count==0 else{return false}
        }else{
            // A format-only terminal LF is normalized only when the provider
            // independently reports an empty character domain.
            guard text=="\n",count==0 else{return false}
        }
        lastFieldCheck=5
        guard values[4] as? Bool==true else{return false}
        lastFieldCheck=6
        guard values[5] as? Bool==false else{return false}
        lastFieldCheck=7
        guard let rawWindow=values[6],CFGetTypeID(rawWindow)==AXUIElementGetTypeID(),CFEqual(rawWindow,window) else{return false}
        lastFieldCheck=9
        guard writable(field,kAXSelectedTextRangeAttribute) else{return false}
        lastFieldCheck=0
        if recording{rememberEmptyEntry(field,window:window)}
        return true
    }
    // Reuse the idle scan's existing batch. A draft can authorize no focus and
    // is usable only after an exact same-field, original-key/body comparison.
    private func verifiedDraft(_ field:AXUIElement,window:AXUIElement,values:[CFTypeRef?],text:String,count:Double?,began:Double)->OnsetSnapshot? {
        guard !text.isEmpty,text != "\n",text.utf16.count<=16384,
              count==Double(text.utf16.count),values[4] as? Bool==true,values[5] as? Bool==false,
              let rawWindow=values[6],CFGetTypeID(rawWindow)==AXUIElementGetTypeID(),CFEqual(rawWindow,window),
              let raw=values[3],CFGetTypeID(raw)==AXValueGetTypeID() else{return nil}
        var range=CFRange()
        guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location==text.utf16.count,range.length==0,
              ready(),let pid=frontPID(),owner(window)==pid,owner(field)==pid,
              now()>=began,now()-began<0.012,ready(),frontPID()==pid else{return nil}
        return .init(element:field,text:text,selection:NSRange(location:range.location,length:0))
    }
    // This is a prior displayed value, not an empty-body or focus proof.
    func representedEntry(for field:AXUIElement,before time:Double)->OnsetSnapshot? {
        representationWitness(for:field,before:time)?.snapshot
    }
    struct RepresentationWitness {
        let snapshot:OnsetSnapshot
        let isCurrent:()->Bool
    }
    // Once an exact first publication has been witnessed, the pre-key display
    // cache's 1.1s expiry must not revoke it mid-word. This frozen witness keeps
    // the original 2s input-history limit, context checks and explicit invalidation.
    func representationWitness(for field:AXUIElement,before time:Double)->RepresentationWitness? {
        guard let entry=representedEntries.last(where:{CFEqual($0.snapshot.element,field) && $0.time<time && time-$0.time<=0.75}) else{
            if collectWitnessDiagnostics {
                let matching=representedEntries.filter{CFEqual($0.snapshot.element,field)}
                lastWitnessLookup=matching.isEmpty ? 2:(matching.contains{$0.time<time} ? 4:3)
            }
            return nil
        }
        guard now()>=entry.time else{if collectWitnessDiagnostics{lastWitnessLookup=5};return nil}
        guard now()-entry.time<=1.1 else{if collectWitnessDiagnostics{lastWitnessLookup=6};return nil}
        guard currentContext(field,window:entry.window) else{if collectWitnessDiagnostics{lastWitnessLookup=lastContextDiagnostic};return nil}
        if collectWitnessDiagnostics{lastWitnessLookup=1}
        let epoch=representationEpoch,window=entry.window
        return RepresentationWitness(snapshot:entry.snapshot,isCurrent:{[weak self] in
            guard let self,self.representationEpoch==epoch,
                  self.now()>=time,self.now()-time<2 else{return false}
            return self.currentContext(field,window:window)
        })
    }
    func currentContext(_ field:AXUIElement,window:AXUIElement)->Bool {
        func failure(_ reason:Int)->Bool{if collectWitnessDiagnostics{lastContextDiagnostic=reason};return false}
        guard ready() else{return failure(7)}
        guard let pid=frontPID(),owner(field)==pid,owner(window)==pid else{return failure(8)}
        guard let actual=read(field,kAXWindowAttribute),CFGetTypeID(actual)==AXUIElementGetTypeID() else{return failure(9)}
        guard CFEqual(actual,window) else{return failure(10)}
        guard ready() else{return failure(11)}
        guard frontPID()==pid else{return failure(12)}
        return true
    }
    private func rememberEditorHint(_ field:AXUIElement,time:Double){
        if recentEditor.map({CFEqual($0.field,field) || time-$0.time>5.5}) ?? true{recentEditor=(field,time)}
    }
    private func rememberDraftEntry(_ snapshot:OnsetSnapshot,window:AXUIElement){
        let time=now();rememberEditorHint(snapshot.element,time:time)
        draftEntries.removeAll{time-$0.time>1.1}
        let previous=draftEntries.last(where:{CFEqual($0.snapshot.element,snapshot.element)})
        if previous.map({old in
            !old.snapshot.text.utf16.elementsEqual(snapshot.text.utf16) || old.snapshot.selection != snapshot.selection || time-old.time>=0.05
                || emptyEntries.contains(where:{CFEqual($0.field,snapshot.element) && $0.time>=old.time})
        }) ?? true {
            draftEntries.append((snapshot,window,time));if draftEntries.count>8{draftEntries.removeFirst()}
        }
    }
    private func rememberEmptyEntry(_ field:AXUIElement,window:AXUIElement){
        let time=now();rememberEditorHint(field,time:time)
        emptyEntries.removeAll{time-$0.time>1.1}
        if emptyEntries.last(where:{CFEqual($0.field,field)}).map({old in
            time-old.time>=0.05 || draftEntries.contains(where:{CFEqual($0.snapshot.element,field) && $0.time>=old.time})
        }) ?? true {
            emptyEntries.append((field,window,time));if emptyEntries.count>8{emptyEntries.removeFirst()}
        }
    }
    private func revalidateRecentEditor(window:AXUIElement,began:Double){
        guard let recent=recentEditor,began>=recent.time,began-recent.time<=5.5 else{recentEditor=nil;return}
        guard began>=nextRecentValidation,
              emptyEntries.last(where:{CFEqual($0.field,recent.field)}).map({began-$0.time>=0.2}) ?? true else{return}
        nextRecentValidation=began+0.2
        // Same ordinary empty-document checks, on the idle observer only.
        // An unfinished/ambiguous scene still has no focus candidate.
        guard ready(),let pid=frontPID(),owner(window)==pid,owner(recent.field)==pid else{return}
        var draft:OnsetSnapshot?
        let empty=emptyEditor(recent.field,window:window,observing:true,recording:false,readDraft:{draft=$0})
        guard empty || draft != nil,
              now()-began<0.012,ready(),frontPID()==pid,owner(window)==pid,owner(recent.field)==pid else{return}
        if empty{rememberEmptyEntry(recent.field,window:window)}
        else if let draft{rememberDraftEntry(draft,window:window)}
    }
    private static func origin(_ raw:CFTypeRef?)->Bool {
        guard let raw,CFGetTypeID(raw)==AXValueGetTypeID() else{return false}
        var range=CFRange()
        return AXValueGetValue(raw as! AXValue,.cfRange,&range) && range.location==0 && range.length==0
    }
    // A partial/truncated tree cannot establish that there is just one editor.
    // AX wrappers put the current composer deeper than the legacy depth-12 walk.
    func advance(window:AXUIElement,outside currentOutside:AXUIElement?=nil){
        let start=now()
        let changedOutside=outside.map{old in currentOutside.map{!CFEqual(old,$0)} ?? true} ?? (currentOutside != nil)
        if (root.map({!CFEqual($0,window)}) ?? true) || changedOutside{reset();root=window;outside=currentOutside}
        if let request=pendingSearch {
            pendingSearch=nil;searchAttempts=min(9_999_999,searchAttempts+1)
            let result:OnsetEditorSearch.Result
            if currentContext(request.document,window:window),now()-start<0.003 {
                result=editorSearch.lookup(request.document)
            }else{result = .unavailable}
            var useFallback=true
            switch result {
            case .unique(let field):
                searchOutcome=5
                if ready(),now()>=start,now()-start<0.012 {
                    // Query output is only a read hint, never scene uniqueness
                    // or focus authority. Validate this editor on the next tick.
                    queue.insert((field,request.depth+1),at:0);useFallback=false
                    uncertain=true;uncertainReasons |= 256
                }
            case .multiple:searchOutcome=4;uncertain=true;uncertainReasons |= 128
            case .none:searchOutcome=3
            case .unavailable:searchOutcome=2;uncertain=true;uncertainReasons |= 64
            case .unsupported:searchOutcome=1
            }
            if useFallback{queue.append(contentsOf:request.children.map{($0,request.depth+1)})}
            if queue.count>nodeLimit{queue=[];uncertain=true;uncertainReasons |= 16}
            if queue.isEmpty{finishScan(window:window)}
            return
        }
        if candidate==nil{revalidateRecentEditor(window:window,began:start)}
        if queue.isEmpty {
            guard start>=nextScan else{
                if sceneCacheEnabled,start>=nextRefresh,let cachedEditor {
                    nextRefresh=start+0.2
                    if diagnosticsEnabled{diagnosticEditor=cachedEditor;diagnosticEditorAt=now()}
                    candidate=emptyEditor(cachedEditor,window:window,observing:true) ? Candidate(field:cachedEditor,window:window,observedAt:now()):nil
                }
                return
            }
            queue=[(window,0)];searchesThisScan=0;visited=[:];visitedCount=0;editors=0;found=nil;sceneEditor=nil;uncertain=false;uncertainReasons=0;scanCount=min(9_999_999,scanCount+1)
            noteDiscovery(4)
            nextScan=start+0.5
        }
        var count=0
        while !queue.isEmpty,count<128,visitedCount<nodeLimit,now()-start<0.012 {
            let (node,depth)=queue.removeFirst();count+=1
            let hash=CFHash(node)
            if visited[hash]?.contains(where:{CFEqual($0,node)}) == true{continue}
            visited[hash,default:[]].append(node);visitedCount+=1
            let values=batch(node,[kAXRoleAttribute,kAXChildrenAttribute,"AXHidden"])
            guard values.count==3,let role=values[0] as? String else{uncertain=true;uncertainReasons |= 1;continue}
            if values[2] as? Bool==true{continue}
            if OnsetEditableRole.supports(role){
                editors+=1;sceneEditor=node
                if emptyEditor(node,window:window,observing:true){found=node}
                continue
            }
            guard let descendants=(values[1] as? [AXUIElement]) ?? children(node) else{uncertain=true;uncertainReasons |= 2;continue}
            if depth>=40 {if !descendants.isEmpty{uncertain=true;uncertainReasons |= 4};continue}
            if descendants.count>512{uncertain=true;uncertainReasons |= 8}
            if role=="AXWebArea",searchesThisScan<4 {
                searchesThisScan+=1
                pendingSearch=(node,Array(descendants.prefix(512)),depth)
                break
            }
            queue.append(contentsOf:descendants.prefix(512).map{($0,depth+1)})
            if queue.count>nodeLimit{queue=[];uncertain=true;uncertainReasons |= 16}
        }
        if visitedCount>=nodeLimit,!queue.isEmpty{queue=[];uncertain=true;uncertainReasons |= 32}
        if queue.isEmpty,pendingSearch==nil {finishScan(window:window)}
        else if let candidate,now()-candidate.observedAt>0.75{self.candidate=nil}
    }
    private func finishScan(window:AXUIElement){
            completedScans=min(9_999_999,completedScans+1)
            let unique = !uncertain && editors==1
            noteDiscovery((uncertainReasons & 60) != 0 ? 9:(uncertain ? 8:(editors>1 ? 7:(unique ? 6:5))))
            cachedEditor=unique ? sceneEditor:nil
            if diagnosticsEnabled,let cachedEditor{diagnosticEditor=cachedEditor;diagnosticEditorAt=now()}
            candidate = unique ? found.map{Candidate(field:$0,window:window,observedAt:now())}:nil
            if sceneCacheEnabled,unique{nextScan=now()+5;nextRefresh=now()+0.2}
    }

}
