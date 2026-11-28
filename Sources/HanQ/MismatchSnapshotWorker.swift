import AppKit

struct MismatchSnapshotResult {
    let snapshot:MismatchSnapshot?
    let reason:String
    var completedAt:Double=ProcessInfo.processInfo.systemUptime
    var durationMs:Double=0
    var focusMs:Double=0
    var attributesMs:Double=0
}

// This worker owns its AX roots. It never reads or mutates MismatchRecoveryEngine state,
// sends keys, edits text, or touches UI. Results are consumed on the main queue.
final class MismatchSnapshotWorker {
    private let queue=DispatchQueue(label:"hanq.mismatch.snapshot",qos:.userInitiated)
    private let incidentFocusProbe=InputIncidentFocusProbe()
    private let readOperation:((pid_t)->MismatchSnapshotResult)?
    init(read:((pid_t)->MismatchSnapshotResult)?=nil){readOperation=read}
    func request(pid:pid_t,semantics:Bool=false,local:Bool=false,preferred:EditorTextWindow?=nil,purpose:InputIncidentTrace.ReadPurpose = .unknown,completion:@escaping (MismatchSnapshotResult)->Void){
        let activity=InputIncidentTrace.shared.activityEpoch
        queue.async {
            let result=self.readOperation?(pid) ?? Self.read(pid:pid,semantics:semantics,local:local,preferred:preferred,focusProbe:self.incidentFocusProbe,purpose:purpose,activityAtRequest:activity)
            DispatchQueue.main.async{completion(result)}
        }
    }
    static func read(pid:pid_t,semantics:Bool=false,local:Bool=false,preferred:EditorTextWindow?=nil,focusProbe:InputIncidentFocusProbe=InputIncidentFocusProbe(),purpose:InputIncidentTrace.ReadPurpose = .unknown,activityAtRequest:Int64?=nil)->MismatchSnapshotResult {
        let began=ProcessInfo.processInfo.systemUptime
        let incidentRead=InputIncidentTrace.shared.beginRead(.mismatchAX,purpose:purpose,activityAtRequest:activityAtRequest)
        var axResult=InputIncidentAXResult()
        var incidentReason=""
        let incidentGeneration=InputIncidentTrace.shared.collectionGeneration
        var focusRead:InputIncidentFocusProbe.Read?=incidentRead == nil ? nil:InputIncidentFocusProbe.Read(target:pid)
        let focusAccess=InputFocusAccess()
        if incidentRead != nil{focusAccess.observeResult={route,code in axResult.focus(route,code)}}
        if incidentRead != nil {focusAccess.observeFocus={element,owner,route in focusRead?.observe(element,owner:owner,route:route)}}
        defer{
            focusAccess.observeFocus=nil
            let allowed=incidentRead != nil && !["secure_input","secure_text_field"].contains(incidentReason)
            let focus=focusProbe.finish(allowed ? focusRead:nil,generation:incidentGeneration,path:3)
            InputIncidentTrace.shared.endRead(.mismatchAX,incidentRead,outcome:incidentRead == nil ? nil:.snapshot(incidentReason),focus:focus,axResult:allowed ? axResult:nil,applications:allowed ? focusRead?.applications:nil)
        }
        let application=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application,0.05)
        var focusMs=0.0,attributesMs=0.0
        let diagnosticGeneration=InputIncidentTrace.shared.collectionGeneration
        let collectSemantics=semantics && InputIncidentTrace.shared.enabled
        var route=0
        func result(_ snapshot:MismatchSnapshot?=nil,_ reason:String="")->MismatchSnapshotResult {
            if incidentRead != nil{incidentReason=reason}
            return MismatchSnapshotResult(snapshot:snapshot,reason:reason,durationMs:(ProcessInfo.processInfo.systemUptime-began)*1000,focusMs:focusMs,attributesMs:attributesMs)
        }
        func focused()->AXUIElement? {
            let start=ProcessInfo.processInfo.systemUptime
            defer{focusMs+=(ProcessInfo.processInfo.systemUptime-start)*1000}
            let element=focusAccess.focusedElement(application:application,pid:pid)
            let current=focusAccess.lastRoute
            if current != 0{route=route==0 || route==current ? current:3}
            return element
        }
        guard let element=focused() else{return result(nil,"focused_element_unreadable")}
        let start=ProcessInfo.processInfo.systemUptime
        var values:CFArray?
        let baseNames=[kAXRoleAttribute,kAXSubroleAttribute,local ? kAXNumberOfCharactersAttribute:kAXValueAttribute,kAXSelectedTextRangeAttribute]
        // One optional attribute batch on the existing bounded idle worker;
        // input callbacks never perform these supplemental IPCs or await it.
        let names=(baseNames + (collectSemantics ? ["AXPlaceholderValue",kAXTitleAttribute,kAXDescriptionAttribute,kAXNumberOfCharactersAttribute,kAXWindowAttribute]:[])) as CFArray
        var error=AXUIElementCopyMultipleAttributeValues(element,names,[],&values)
        if error != .success,collectSemantics {
            values=nil
            error=AXUIElementCopyMultipleAttributeValues(element,baseNames as CFArray,[],&values)
        }
        if incidentRead != nil{axResult.attribute(error)}
        attributesMs=(ProcessInfo.processInfo.systemUptime-start)*1000
        guard error == .success,let list=values as? [AnyObject],list.count>=4 else{return result(nil,"attribute_batch_unreadable")}
        if incidentRead != nil {focusRead?.observedRole(list[0] as? String)}
        guard let role=list[0] as? String else {
            // Preserve the engine's original stop/retry reason. Diagnostics must
            // not mistake an unreadable role for a confirmed non-editor.
            let unavailable=result(nil,"not_supported_text_field")
            if incidentRead != nil{incidentReason="role_unreadable"}
            return unavailable
        }
        guard ["AXTextArea","AXTextField"].contains(role) else{return result(nil,"not_supported_text_field")}
        guard list[1] as? String != "AXSecureTextField" else{return result(nil,"secure_text_field")}
        if local {
            guard let view=EditorTextWindow.read(element,count:list[2],selected:list[3],preferred:preferred) else{return result(nil,"editor_coordinates_unverified")}
            guard let final=focused(),CFEqual(element,final) else{return result(nil,"focus_changed_during_snapshot")}
            var evidence:InputIncidentAXEvidence?,window:AXUIElement?
            if collectSemantics,list.count>=9 {
                if view.window == .entire {
                    var measured=InputIncidentAXEvidence.attributes(list,value:view.text,verified:view.text,route:route)
                    measured.0.representation=0 // AXValue was not requested.
                    (evidence,window)=measured
                } else if CFGetTypeID(list[8])==AXUIElementGetTypeID() {window=(list[8] as! AXUIElement)}
            }
            return result(MismatchSnapshot(element:element,text:view.text,selection:view.selection,observation:view.window,incidentAX:evidence,incidentWindow:window,incidentGeneration:diagnosticGeneration))
        }
        guard let text=MismatchTextReader.value(element,batchValue:list[2]) else{return result(nil,"text_unreadable")}
        let raw=list[3]
        guard CFGetTypeID(raw)==AXValueGetTypeID() else{return result(nil,"selection_unreadable")}
        var range=CFRange()
        guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location>=0,range.length>=0,
              range.location+range.length<=text.utf16.count else{return result(nil,"selection_invalid")}
        // Reject a focus change during the potentially slow attribute query.
        guard let after=focused() else{return result(nil,"focused_element_unreadable")}
        guard CFEqual(element,after) else{return result(nil,"focus_changed_during_snapshot")}
        let selection=NSRange(location:range.location,length:range.length)
        guard let content=MismatchTextReader.read(element,value:text,selection:selection) else{return result(nil,"editor_coordinates_unverified")}
        guard let finalFocus=focused(),CFEqual(element,finalFocus) else{return result(nil,"focus_changed_during_snapshot")}
        var evidence:InputIncidentAXEvidence?,window:AXUIElement?
        if collectSemantics,InputIncidentTrace.shared.collectionGeneration==diagnosticGeneration,InputIncidentTrace.shared.enabled {
            (evidence,window)=InputIncidentAXEvidence.attributes(list,value:text,verified:content.text,route:route)
        }
        return result(MismatchSnapshot(element:element,text:content.text,selection:selection,selectedText:content.selectedText,incidentAX:evidence,incidentWindow:window,incidentGeneration:diagnosticGeneration))
    }
}
