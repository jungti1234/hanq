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
    private let readOperation:(pid_t)->MismatchSnapshotResult
    init(read:@escaping (pid_t)->MismatchSnapshotResult=MismatchSnapshotWorker.read){readOperation=read}
    func request(pid:pid_t,completion:@escaping (MismatchSnapshotResult)->Void){
        queue.async {
            let result=self.readOperation(pid)
            DispatchQueue.main.async{completion(result)}
        }
    }
    static func read(pid:pid_t)->MismatchSnapshotResult {
        let began=ProcessInfo.processInfo.systemUptime
        let focusAccess=InputFocusAccess()
        let application=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application,0.05)
        var focusMs=0.0,attributesMs=0.0
        func result(_ snapshot:MismatchSnapshot?=nil,_ reason:String="")->MismatchSnapshotResult {
            MismatchSnapshotResult(snapshot:snapshot,reason:reason,durationMs:(ProcessInfo.processInfo.systemUptime-began)*1000,focusMs:focusMs,attributesMs:attributesMs)
        }
        func focused()->AXUIElement? {
            let start=ProcessInfo.processInfo.systemUptime
            defer{focusMs+=(ProcessInfo.processInfo.systemUptime-start)*1000}
            return focusAccess.focusedElement(application:application,pid:pid)
        }
        guard let element=focused() else{return result(nil,"focused_element_unreadable")}
        let start=ProcessInfo.processInfo.systemUptime
        var values:CFArray?
        let names=[kAXRoleAttribute,kAXSubroleAttribute,kAXValueAttribute,kAXSelectedTextRangeAttribute] as CFArray
        let error=AXUIElementCopyMultipleAttributeValues(element,names,[],&values)
        attributesMs=(ProcessInfo.processInfo.systemUptime-start)*1000
        guard error == .success,let list=values as? [AnyObject],list.count==4 else{return result(nil,"attribute_batch_unreadable")}
        guard let role=list[0] as? String,["AXTextArea","AXTextField"].contains(role) else{return result(nil,"not_supported_text_field")}
        guard list[1] as? String != "AXSecureTextField" else{return result(nil,"secure_text_field")}
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
        return result(MismatchSnapshot(element:element,text:content.text,selection:selection,selectedText:content.selectedText))
    }
}
