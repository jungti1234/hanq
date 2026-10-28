import AppKit
import Carbon

// Compatibility for the desktop composer's type-to-focus path. Discovery is
// read-only and idle-only. The first original key is never held or replayed.
final class OnsetFocusHandoff {
    static func supports(_ bundle:String?,arguments:[String]=ProcessInfo.processInfo.arguments)->Bool {
        bundle == "com.openai.codex" || (bundle == "taek.in.hanq.prefocus-fixture" && arguments.contains("--test-onset-focus-handoff"))
    }
    enum Outcome:Int {case idle=0,eligibility,window,systemFocus,outsideIdentity,outsideRole,field,lateContext,deadline,requested,unconfirmed,confirmed}
    private(set) var lastOutcome=Outcome.idle
    private(set) var lastFieldCheck=0
    struct Candidate {let field:AXUIElement;let window:AXUIElement;let observedAt:Double}
    private(set) var candidate:Candidate?
    private var root:AXUIElement?
    private var outside:AXUIElement?
    private var cachedEditor:AXUIElement?
    var nodeLimit=2048
    var sceneCompleted:Bool{completedScans>0}
    var sceneVisited:Int{visitedCount}
    var sceneClipped:Bool{(uncertainReasons & 48) != 0}
    var sceneScanning:Bool{!queue.isEmpty}
    var sceneEditorCount:Int{editors}
    private var emptyEntries:[(field:AXUIElement,time:Double)]=[]
    private var draftEntries:[(snapshot:OnsetSnapshot,time:Double)]=[]
    // A recently observed editor is only a search hint. Pointer/shortcut input
    // still clears every proof; this reference can authorize no write.
    private var recentEditor:(field:AXUIElement,time:Double)?
    private var nextRecentValidation=0.0
    // A read-only pre-key baseline is useful even when another node makes
    // the whole-window focus candidate ambiguous. It never authorizes focus.
    func emptyEntryBaseline(for field:AXUIElement,before time:Double)->OnsetSnapshot? {
        guard let proof=emptyEntries.last(where:{CFEqual($0.field,field) && $0.time<=time && time-$0.time<=0.75}) else{return nil}
        guard now()>=proof.time,now()-proof.time<=1.1,
              !draftEntries.contains(where:{CFEqual($0.snapshot.element,field) && $0.time<time && $0.time>=proof.time}) else{return nil}
        return .init(element:field,text:"",selection:NSRange(location:0,length:0))
    }
    func draftEntryBaseline(for field:AXUIElement,before time:Double)->OnsetSnapshot? {
        guard let proof=draftEntries.last(where:{CFEqual($0.snapshot.element,field) && $0.time<time && time-$0.time<=0.75}),
              now()>=proof.time,now()-proof.time<=1.1,
              !emptyEntries.contains(where:{CFEqual($0.field,field) && $0.time<=time && $0.time>=proof.time}) else{return nil}
        return proof.snapshot
    }
    // Pointer/shortcut input invalidates both empty and existing-body evidence.
    func invalidateEmptyEntries(){emptyEntries=[];draftEntries=[]}
    private var nextRefresh=0.0
    var sceneCacheEnabled=false
    private var queue:[(AXUIElement,Int)]=[]
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
    var diagnosticState:String {"candidate=\(candidate != nil ? 1:0) visited=\(visitedCount) limit=\(nodeLimit) queue=\(queue.count) editors=\(editors) uncertain=\(uncertainReasons) resets=\(resetCount) scans=\(scanCount) completed=\(completedScans) field=\(lastFieldCheck) outcome=\(lastOutcome.rawValue) attempted=\(attempted ? 1:0) cache=\(sceneCacheEnabled ? 1:0) valueKind=\(diagnosticValueKind) valueShape=\(diagnosticValueShape) countKind=\(diagnosticCountKind) valueSize=\(diagnosticValueSize) formatOnly=\(diagnosticFormatOnly) caretKind=\(diagnosticCaretKind) hintRelation=\(diagnosticHintRelation) hintKind=\(diagnosticHintKind) editableEmpty=\(editableEmptyProof) rangeOne=\(rangeOneClass) focusedSeen=\(focusedSeen) focusedMatch=\(focusedMatch) focusedShape=\(focusedShape) focusedSize=\(focusedSize) focusedCaret=\(focusedCaret)"}
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
    var restoreTimeout:(AXUIElement)->Void={AXUIElementSetMessagingTimeout($0,0.05)}
    var focus:(AXUIElement)->AXError = { element in
        AXUIElementSetMessagingTimeout(element,0.003)
        return AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
    }
    func reset(){resetCount=min(9_999_999,resetCount+1);candidate=nil;root=nil;outside=nil;cachedEditor=nil;nextRefresh=0;queue=[];visited=[:];visitedCount=0;editors=0;found=nil;uncertain=false;uncertainReasons=0;attempted=false;nextScan=0;nextRecentValidation=0}
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
        let values=batch(field,Self.details)
        lastFieldCheck=1
        guard values.count==Self.details.count else{return false}
        lastFieldCheck=2
        guard values[0] as? String==kAXTextAreaRole,values[1] as? String != kAXSecureTextFieldSubrole else{return false}
        let text:String?,valueKind:Int
        if let raw=values[2],CFGetTypeID(raw) != CFNullGetTypeID() {
            if let string=raw as? String{text=string;valueKind=1}
            else if CFGetTypeID(raw)==CFAttributedStringGetTypeID(){text=CFAttributedStringGetString(raw as! CFAttributedString) as String;valueKind=2}
            else{text=nil;valueKind=3}
        }else{text=nil;valueKind=0}
        let count:Double?={
            guard let raw=values[7],CFGetTypeID(raw)==CFNumberGetTypeID(),let number=raw as? NSNumber,
                  number.doubleValue.isFinite,number.doubleValue>=0 else{return nil}
            return number.doubleValue
        }()
        if observing,valueKind==1,let text,
           let draft=verifiedDraft(field,window:window,values:values,text:text,count:count,began:began) {
            readDraft?(draft)
            if recording{rememberDraftEntry(draft)}
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
        if needsEditableProof {
            // A published display value is never treated as an empty draft.
            // Ask the provider about its editable coordinate domain instead.
            guard valueKind==1,let text,text.utf16.count<=4096,
                  let count,count>0,Self.origin(values[3]) else{return false}
            editableEmptyProof=2
            let zero=rangeText(field,CFRange(location:0,length:0))
            guard zero.0 == .success,zero.1 == "" else{return false}
            editableEmptyProof=3
            let one=rangeText(field,CFRange(location:0,length:1))
            if diagnosticsEnabled {
                if one.0 == .success{rangeOneClass=one.1.map{$0.isEmpty ? 2:3} ?? 4}
                else if one.0 == .illegalArgument{rangeOneClass=5}
                else if one.0 == .noValue{rangeOneClass=6}
                else if one.0 == .parameterizedAttributeUnsupported{rangeOneClass=7}
                else if one.0 == .cannotComplete{rangeOneClass=8}
                else{rangeOneClass=9}
            }
            // Only an explicit out-of-range response proves a zero domain.
            // Success with clamping, unsupported, timeout and other failures
            // are not proof. This is the existing range-reader boundary rule.
            let zeroDomain=one.0 == .illegalArgument || one.0 == .noValue
            // The user-identified Korean placeholder is also present in the
            // installed Codex locale and the original Oct-11 regression case.
            // This is an exact application hint, never arbitrary draft text.
            let hint=Self.knownCodexPlaceholder(text) && count==Double(text.utf16.count)
                && one.0 == .success && one.1?.utf16.count==1 && one.1?.utf16.first==text.utf16.first
            guard zeroDomain || hint else{return false}
            editableEmptyProof=4
            let after=batch(field,Self.details)
            guard after.count==Self.details.count,
                  after[0] as? String==kAXTextAreaRole,
                  after[1] as? String != kAXSecureTextFieldSubrole,
                  after[2] as? String==text,Self.origin(after[3]),
                  after[4] as? Bool==true,after[5] as? Bool==false,
                  let afterWindow=after[6],CFGetTypeID(afterWindow)==AXUIElementGetTypeID(),CFEqual(afterWindow,window),
                  let afterCount=after[7],CFGetTypeID(afterCount)==CFNumberGetTypeID(),
                  (afterCount as? NSNumber)?.doubleValue==count else{return false}
            editableEmptyProof=zeroDomain ? 1:5 // 5: recognized published hint, not an empty-domain claim
        }
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
        let needsZeroProof=text==nil || unknownRange
        if needsZeroProof {
            // An unfocused client may publish neither its value nor its caret.
            // Only an independently measured exact numeric zero establishes
            // an empty document with no selected text/insertion ambiguity.
            lastFieldCheck=text==nil ? 11:10
            guard count==0,text==nil || text!.isEmpty else{return false}
        }
        lastFieldCheck=5
        guard values[4] as? Bool==true else{return false}
        lastFieldCheck=6
        guard values[5] as? Bool==false else{return false}
        lastFieldCheck=7
        guard let rawWindow=values[6],CFGetTypeID(rawWindow)==AXUIElementGetTypeID(),CFEqual(rawWindow,window) else{return false}
        lastFieldCheck=9
        guard writable(field,kAXFocusedAttribute),needsZeroProof || writable(field,kAXSelectedTextRangeAttribute) else{return false}
        lastFieldCheck=0
        if recording{rememberEmptyEntry(field)}
        return true
    }
    // Reuse the idle scan's existing batch. A draft can authorize no focus and
    // is usable only after an exact same-field, original-key/body comparison.
    private func verifiedDraft(_ field:AXUIElement,window:AXUIElement,values:[CFTypeRef?],text:String,count:Double?,began:Double)->OnsetSnapshot? {
        guard !text.isEmpty,text != "\n",text.utf16.count<=16384,!Self.knownCodexPlaceholder(text),
              count==Double(text.utf16.count),values[4] as? Bool==true,values[5] as? Bool==false,
              let rawWindow=values[6],CFGetTypeID(rawWindow)==AXUIElementGetTypeID(),CFEqual(rawWindow,window),
              let raw=values[3],CFGetTypeID(raw)==AXValueGetTypeID() else{return nil}
        var range=CFRange()
        guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location==text.utf16.count,range.length==0,
              ready(),let pid=frontPID(),owner(window)==pid,owner(field)==pid,
              now()>=began,now()-began<0.012,ready(),frontPID()==pid else{return nil}
        return .init(element:field,text:text,selection:NSRange(location:range.location,length:0))
    }
    private func rememberEditorHint(_ field:AXUIElement,time:Double){
        if recentEditor.map({CFEqual($0.field,field) || time-$0.time>5.5}) ?? true{recentEditor=(field,time)}
    }
    private func rememberDraftEntry(_ snapshot:OnsetSnapshot){
        let time=now();rememberEditorHint(snapshot.element,time:time)
        draftEntries.removeAll{time-$0.time>1.1}
        let previous=draftEntries.last(where:{CFEqual($0.snapshot.element,snapshot.element)})
        if previous.map({old in
            !old.snapshot.text.utf16.elementsEqual(snapshot.text.utf16) || old.snapshot.selection != snapshot.selection || time-old.time>=0.05
                || emptyEntries.contains(where:{CFEqual($0.field,snapshot.element) && $0.time>=old.time})
        }) ?? true {
            draftEntries.append((snapshot,time));if draftEntries.count>8{draftEntries.removeFirst()}
        }
    }
    private func rememberEmptyEntry(_ field:AXUIElement){
        let time=now();rememberEditorHint(field,time:time)
        emptyEntries.removeAll{time-$0.time>1.1}
        if emptyEntries.last(where:{CFEqual($0.field,field)}).map({old in
            time-old.time>=0.05 || draftEntries.contains(where:{CFEqual($0.snapshot.element,field) && $0.time>=old.time})
        }) ?? true {
            emptyEntries.append((field,time));if emptyEntries.count>8{emptyEntries.removeFirst()}
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
        if empty{rememberEmptyEntry(recent.field)}
        else if let draft{rememberDraftEntry(draft)}
    }
    static func knownCodexPlaceholder(_ text:String)->Bool {
        let hint="Codex와 함께 작업하세요"
        return InputIncidentAXEvidence.same(text,hint) || InputIncidentAXEvidence.same(text,hint+"\n")
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
            queue=[(window,0)];visited=[:];visitedCount=0;editors=0;found=nil;sceneEditor=nil;uncertain=false;uncertainReasons=0;scanCount=min(9_999_999,scanCount+1)
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
            queue.append(contentsOf:descendants.prefix(512).map{($0,depth+1)})
            if queue.count>nodeLimit{queue=[];uncertain=true;uncertainReasons |= 16}
        }
        if visitedCount>=nodeLimit,!queue.isEmpty{queue=[];uncertain=true;uncertainReasons |= 32}
        if queue.isEmpty {
            completedScans=min(9_999_999,completedScans+1)
            let unique = !uncertain && editors==1
            cachedEditor=unique ? sceneEditor:nil
            if diagnosticsEnabled,let cachedEditor{diagnosticEditor=cachedEditor;diagnosticEditorAt=now()}
            candidate = unique ? found.map{Candidate(field:$0,window:window,observedAt:now())}:nil
            if sceneCacheEnabled,unique{nextScan=now()+5;nextRefresh=now()+0.2}
        }else if let candidate,now()-candidate.observedAt>0.75{self.candidate=nil}
    }
    // Runs before the untouched first key leaves the existing main tap. There
    // is one bounded focus request, no polling, no text/range write, no key send.
    @discardableResult func prepare(_ type:CGEventType,_ event:CGEvent,application:AXUIElement,pid:pid_t,
                                 sourceID:String,currentSource:()->String,normal:Set<UInt16>,shifted:Set<UInt16>,systemFocus:(()->AXUIElement?)?=nil)->Bool {
        let began=now(),field=candidate?.field
        defer{restoreTimeout(application);if let field{restoreTimeout(field)}}
        func focused()->AXUIElement? {
            if let systemFocus{return systemFocus()}
            guard let raw=read(application,kAXFocusedUIElementAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else{return nil}
            return raw as! AXUIElement
        }
        let recipient=event.getIntegerValueField(.eventTargetUnixProcessID)
        lastOutcome = .eligibility
        guard type == .keyDown,!attempted,let candidate,ready(),frontPID()==pid,
              now()>=candidate.observedAt,now()-candidate.observedAt<=0.75,
              event.getIntegerValueField(.keyboardEventAutorepeat)==0,
              (recipient==Int64(pid) || (recipient==0 && systemFocus != nil)),
              !OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)),
              event.getIntegerValueField(.eventSourceUserData) != SyntheticInputMarker.manualEdit,
              event.flags.intersection([.maskCommand,.maskControl,.maskAlternate,.maskAlphaShift,.maskSecondaryFn]).isEmpty,
              (event.flags.contains(.maskShift) ? shifted:normal).contains(UInt16(event.getIntegerValueField(.keyboardEventKeycode))),
              currentSource()==sourceID,owner(candidate.field)==pid else{return false}
        lastOutcome = .window
        guard let window=read(application,kAXFocusedWindowAttribute),CFEqual(window,candidate.window) else{return false}
        lastOutcome = .systemFocus
        guard let outside=focused(),owner(outside)==pid else{return false}
        lastOutcome = .outsideIdentity
        guard let observedOutside=self.outside,CFEqual(outside,observedOutside) else{return false}
        lastOutcome = .outsideRole
        guard let role=read(outside,kAXRoleAttribute) as? String,
              ["AXWebArea",kAXGroupRole,kAXStaticTextRole,kAXScrollAreaRole,kAXSplitGroupRole].contains(role) else{return false}
        lastOutcome = .field
        guard emptyEditor(candidate.field,window:candidate.window) else{return false}
        let confirmHintOrigin=editableEmptyProof==5
        lastOutcome = .lateContext
        guard ready(),frontPID()==pid,currentSource()==sourceID else{return false}
        lastOutcome = .deadline
        guard now()-began<0.03 else{return false}
        attempted=true;lastOutcome = .requested
        _ = focus(candidate.field)
        // A successful setter is not an acknowledgment. An ambiguous reply is
        // not retried; the caller always returns the original event unchanged.
        lastOutcome = .unconfirmed
        guard ready(),frontPID()==pid,currentSource()==sourceID,
              let actual=focused(),CFEqual(actual,candidate.field) else{return false}
        if confirmHintOrigin{guard Self.origin(read(candidate.field,kAXSelectedTextRangeAttribute)) else{return false}}
        lastOutcome = .confirmed;return true
    }
}
