import AppKit

// Optional provider capability, not an application or URL permission. A
// result is only a discovery hint; ordinary editor/context validation follows.
struct OnsetEditorSearch {
    enum Result {case unsupported,unavailable,none,multiple,unique(AXUIElement)}
    var now:()->Double={ProcessInfo.processInfo.systemUptime}
    var attributes:(AXUIElement)->(AXError,[String]?) = {element in
        AXUIElementSetMessagingTimeout(element,0.003)
        var names:CFArray?
        let status=AXUIElementCopyParameterizedAttributeNames(element,&names)
        return (status,names as? [String])
    }
    var query:(AXUIElement,String,CFDictionary)->(AXError,CFTypeRef?) = {element,name,argument in
        AXUIElementSetMessagingTimeout(element,0.003)
        var value:CFTypeRef?
        let status=AXUIElementCopyParameterizedAttributeValue(element,name as CFString,argument,&value)
        return (status,value)
    }
    func lookup(_ document:AXUIElement)->Result {
        let began=now()
        func timely()->Bool{now()>=began && now()-began<0.009}
        let countName="AXUIElementCountForSearchPredicate",elementsName="AXUIElementsForSearchPredicate"
        let advertised=attributes(document)
        if advertised.0 == .attributeUnsupported || advertised.0 == .notImplemented{return .unsupported}
        guard advertised.0 == .success,let names=advertised.1,names.count<=256,timely() else{return .unavailable}
        guard names.contains(countName),names.contains(elementsName) else{return .unsupported}
        let argument:[String:Any]=["AXSearchKey":"AXTextFieldSearchKey","AXResultsLimit":2,
            "AXDirection":"AXDirectionNext","AXImmediateDescendantsOnly":false,"AXVisibleOnly":false]
        let count=query(document,countName,argument as CFDictionary)
        if count.0 == .parameterizedAttributeUnsupported || count.0 == .attributeUnsupported{return .unsupported}
        guard count.0 == .success,let raw=count.1,CFGetTypeID(raw)==CFNumberGetTypeID(),
              let number=raw as? NSNumber,number.doubleValue.isFinite,
              number.doubleValue==Double(number.intValue),(0...2).contains(number.intValue),timely() else{return .unavailable}
        if number.intValue==0{return .none}
        if number.intValue==2{return .multiple}
        let elements=query(document,elementsName,argument as CFDictionary)
        guard elements.0 == .success,let raw=elements.1,CFGetTypeID(raw)==CFArrayGetTypeID(),
              let fields=raw as? [CFTypeRef],fields.count==1,CFGetTypeID(fields[0])==AXUIElementGetTypeID(),
              timely() else{return .unavailable}
        return .unique(fields[0] as! AXUIElement)
    }
}
