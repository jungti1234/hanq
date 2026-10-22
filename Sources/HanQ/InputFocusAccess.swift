import AppKit
import Darwin

/// Keyboard focus can belong to a non-activating panel (for example Spotlight),
/// while NSWorkspace still reports the application underneath it as frontmost.
/// Never fall back to that application's remembered field when system focus
/// positively identifies another process.
final class InputFocusAccess {
    // Fresh AX strings often use foreign NSString storage. Prove literal
    // equality before asking Swift to normalize both complete strings. A
    // different UTF-16 representation still uses the original Swift equality.
    static func sameText(_ lhs:String,_ rhs:String)->Bool {
        let left=lhs as CFString,right=rhs as CFString
        guard min(CFStringGetLength(left),CFStringGetLength(right))>=256,
              literalHeadMatches(left,right) else {
            if CFStringCompare(left,right,[]) == .compareEqualTo{return true}
            return lhs==rhs
        }
        let proof=withUTF16(left){a in withUTF16(right){b -> Int in
            let limit=min(a.count,b.count);var common=0
            while common+128<=limit {
                if memcmp(a.baseAddress!+common,b.baseAddress!+common,256) != 0{break}
                common+=128
            }
            while common<limit && a[common]==b[common]{common+=1}
            if common==a.count && common==b.count{return -2}
            // Only identical UTF-16 through an NFC-stable ASCII separator is
            // factored. The complete suffix retains Swift canonical equality.
            if common>0 {for i in stride(from:common-1,through:max(0,common-512),by:-1) {
                let unit=a[i]
                if unit==9 || unit==10 || unit==13 || unit==32{return i+1}
            }}
            return -1
        }}
        if proof == -2{return true}
        if proof>0{return (lhs as NSString).substring(from:proof)==(rhs as NSString).substring(from:proof)}
        return lhs==rhs
    }
    // A sufficient literal proof only; callers retain their original fallback.
    static func literalTextEqual(_ lhs:String,_ rhs:String)->Bool {
        let a=lhs as CFString,b=rhs as CFString,length=CFStringGetLength(a)
        guard length==CFStringGetLength(b) else{return false}
        if length==0{return true}
        if length<256{return CFStringCompare(a,b,[]) == .compareEqualTo}
        guard literalHeadMatches(a,b) else{return false}
        return withUTF16(a){x in withUTF16(b){y in memcmp(x.baseAddress!,y.baseAddress!,length*2)==0}}
    }
    // Match Swift's error-corrected UTF16 view, allowing only the editor's
    // existing SPACE/NBSP equivalence. Equal blocks skip loop overhead only;
    // every unit remains covered and no document text is rewritten.
    static func sameEditorUTF16(_ lhs:String,_ rhs:String)->Bool {
        let a=lhs as CFString,b=rhs as CFString,length=CFStringGetLength(a)
        guard length==CFStringGetLength(b) else{return false}
        func corrected(_ units:UnsafeBufferPointer<UInt16>,_ i:Int)->UInt16 {
            let unit=units[i]
            if (0xd800...0xdbff).contains(unit) {
                return i+1<units.count && (0xdc00...0xdfff).contains(units[i+1]) ? unit:0xfffd
            }
            if (0xdc00...0xdfff).contains(unit) {
                return i>0 && (0xd800...0xdbff).contains(units[i-1]) ? unit:0xfffd
            }
            return unit
        }
        return withUTF16(a){x in withUTF16(b){y in
            var i=0
            while i<length {
                if i+128<=length,memcmp(x.baseAddress!+i,y.baseAddress!+i,256)==0 {
                    let end=i+128
                    // Do not separate a high surrogate from its context at
                    // the end of an equal block: the next units may differ.
                    i=end<length && (0xd800...0xdbff).contains(x[end-1]) ? end-1:end
                    continue
                }
                let left=corrected(x,i),right=corrected(y,i)
                if left != right && !(left==32 && right==160) && !(left==160 && right==32){return false}
                i+=1
            }
            return true
        }}
    }
    private static func literalHeadMatches(_ a:CFString,_ b:CFString)->Bool {
        withUTF16(a,limit:32){x in withUTF16(b,limit:32){y in
            x.count==y.count && (x.isEmpty || memcmp(x.baseAddress!,y.baseAddress!,x.count*2)==0)
        }}
    }
    private static func withUTF16<Result>(_ text:CFString,limit:Int?=nil,_ use:(UnsafeBufferPointer<UInt16>)->Result)->Result {
        let length=min(CFStringGetLength(text),limit ?? Int.max)
        return withExtendedLifetime(text){
            if let pointer=CFStringGetCharactersPtr(text){return use(UnsafeBufferPointer(start:pointer,count:length))}
            var units=[UInt16](repeating:0,count:length)
            units.withUnsafeMutableBufferPointer{buffer in
                if length>0{CFStringGetCharacters(text,CFRange(location:0,length:length),buffer.baseAddress!)}
            }
            return units.withUnsafeBufferPointer(use)
        }
    }
    static func sameText(_ lhs:String?,_ rhs:String)->Bool {
        guard let lhs else{return false}
        return sameText(lhs,rhs)
    }
    let system = AXUIElementCreateSystemWide()
    private(set) var lastRoute=0
    private(set) var lastOwner:pid_t?
    var read: (AXUIElement) -> AXUIElement? = InputFocusAccess.readFocused
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    init() { AXUIElementSetMessagingTimeout(system, 0.05) }

    static func readFocused(_ root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func owner(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    func currentPID() -> pid_t? {
        if let element = read(system) { return Self.owner(of: element) }
        return frontmostPID()
    }

    func currentApplication(reusing previous:NSRunningApplication?=nil) -> NSRunningApplication? {
        guard let pid=currentPID() else{return nil}
        return Self.application(pid:pid,reusing:previous)
    }

    // Reuse only the process object, never a focus result. Callers still check
    // termination and every snapshot obtains fresh focus before and after AX.
    static func application(pid:pid_t,reusing previous:NSRunningApplication?) -> NSRunningApplication? {
        if previous?.processIdentifier==pid{return previous}
        return NSRunningApplication(processIdentifier:pid)
    }

    static func attributes(_ element:AXUIElement,_ names:[String])->[CFTypeRef?] {
        resolveAttributes(names,batch:{
            var values:CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element,names as CFArray,[],&values) == .success else{return nil}
            return values as? [AnyObject]
        },single:{ name in
            var value:CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else{return nil}
            return value
        })
    }

    static func resolveAttributes(_ names:[String],batch:()->[AnyObject]?,single:(String)->CFTypeRef?)->[CFTypeRef?] {
        if let values=batch(),values.count==names.count {
            // Per-attribute AX errors are unavailable, just like a failed
            // single read. Do not retry a timeout as if it were an empty value.
            return values.map{ value in
                if CFGetTypeID(value)==AXValueGetTypeID(),AXValueGetType(value as! AXValue) == .axError{return nil}
                return value
            }
        }
        // Editors without batch support retain the original individual path.
        return names.map(single)
    }

    func focusedElement(application: AXUIElement, pid: pid_t) -> AXUIElement? {
        lastRoute=0;lastOwner=nil
        if let element = read(system) {
            lastOwner=Self.owner(of:element)
            guard lastOwner == pid else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            lastRoute=1
            return element
        }
        // Some editors expose focus only on the application AX root. This
        // fallback is valid only for the actual frontmost application.
        lastOwner=frontmostPID()
        guard lastOwner == pid, let element = read(application),
              Self.owner(of: element) == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        lastRoute=2
        return element
    }
}
