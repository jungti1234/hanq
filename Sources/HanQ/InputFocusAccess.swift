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
    var observeFocus:((AXUIElement?,pid_t?,Int)->Void)?
    var read: ((AXUIElement) -> AXUIElement?)?
    var observeResult:((Int,AXError)->Void)?
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    init() { AXUIElementSetMessagingTimeout(system, 0.05) }

    func readElement(_ root:AXUIElement,route:Int=1)->AXUIElement? {
        if let read{return read(root)} // injected reads have no real AX result
        return Self.readFocused(root){[self] in observeResult?(route,$0)}
    }

    static func readFocused(_ root: AXUIElement,observed:((AXError)->Void)?=nil) -> AXUIElement? {
        var value: CFTypeRef?
        let error=AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        observed?(error)
        guard error == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func owner(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    private static let outsideRoles=[kAXGroupRole,kAXButtonRole,kAXWindowRole,"AXWebArea",kAXScrollAreaRole,kAXToolbarRole]

    // Called only after the ordinary four-attribute read found a non-editor.
    // Keep the editable path intact even for applications with limited AX batches.
    static func readOutsideWindow(pid:pid_t,element:AXUIElement,role:String,subrole:String?)->AXUIElement? {
        guard outsideRoles.contains(role),subrole != "AXSecureTextField",
              AXUIElementSetMessagingTimeout(element,0.01) == .success else{return nil}
        defer {AXUIElementSetMessagingTimeout(element,0.05)} // focusedElement sets this timeout
        let names=[kAXRoleAttribute,kAXSubroleAttribute,kAXFocusedAttribute,kAXWindowAttribute] as CFArray
        var values:CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element,names,[],&values) == .success,
              let list=values as? [AnyObject],list.count==4,list[0] as? String==role else{return nil}
        return outsideWindow(pid:pid,element:element,role:role,subrole:list[1] as? String,focused:list[2],window:list[3])
    }

    // Only an explicit switch asks for these attributes. Never derive a window
    // from a text value, an unfocused sibling, or a different process.
    static func outsideWindow(pid:pid_t,element:AXUIElement,role:String,subrole:String?,
                              focused:CFTypeRef,window:CFTypeRef,
                              owner:(AXUIElement)->pid_t? = InputFocusAccess.owner(of:))->AXUIElement? {
        guard pid>0,subrole != "AXSecureTextField",
              outsideRoles.contains(role),
              CFGetTypeID(focused)==CFBooleanGetTypeID(),CFEqual(focused,kCFBooleanTrue),
              owner(element)==pid else{return nil}
        if role==kAXWindowRole{return element}
        guard CFGetTypeID(window)==AXUIElementGetTypeID() else{return nil}
        let ref=window as! AXUIElement
        return owner(ref)==pid ? ref:nil
    }

    func currentPID() -> pid_t? {
        if let element = readElement(system) {
            let owner=Self.owner(of:element);observeFocus?(element,owner,1);return owner
        }
        let owner=frontmostPID();observeFocus?(nil,owner,2);return owner
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

    static func attributes(_ element:AXUIElement,_ names:[String],observed:((String,CFTypeRef?,AXError)->Void)?=nil)->[CFTypeRef?] {
        resolveAttributes(names,batch:{
            var values:CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element,names as CFArray,[],&values) == .success else{return nil}
            let result=values as? [AnyObject]
            if let observed,let result,result.count==names.count {
                for (name,value) in zip(names,result) {
                    var error=AXError.success
                    if CFGetTypeID(value)==AXValueGetTypeID(),AXValueGetType(value as! AXValue) == .axError {
                        _ = AXValueGetValue(value as! AXValue,.axError,&error)
                    }
                    observed(name,error == .success ? value:nil,error)
                }
            }
            return result
        },single:{ name in
            var value:CFTypeRef?
            let error=AXUIElementCopyAttributeValue(element,name as CFString,&value)
            observed?(name,error == .success ? value:nil,error)
            return error == .success ? value:nil
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
        if let element = readElement(system,route:1) {
            lastOwner=Self.owner(of:element)
            observeFocus?(element,lastOwner,1)
            guard lastOwner == pid else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            lastRoute=1
            return element
        }
        // Some editors expose focus only on the application AX root. This
        // fallback is valid only for the actual frontmost application.
        lastOwner=frontmostPID()
        guard lastOwner == pid,let element=readElement(application,route:2) else{
            observeFocus?(nil,lastOwner,2);return nil
        }
        let owner=Self.owner(of:element);observeFocus?(element,owner,2)
        guard owner == pid else{return nil}
        AXUIElementSetMessagingTimeout(element, 0.05)
        lastRoute=2
        return element
    }
}

/// A read-only slice in the editor's UTF-16 coordinate space. Only an edit
/// transaction may expand it into a complete, newly verified editor value.
struct EditorTextWindow: Equatable {
    let leading: Int
    let trailing: Int?
    static let entire = Self(leading: 0, trailing: 0)
    static let beforeCaret = 64
    static let afterCaret = 32
    static let maximumSelection = 128

    struct Observation {
        let window: EditorTextWindow
        let text: String
        let selection: NSRange
        var absoluteSelection: NSRange { window.absolute(selection) }
    }

    func absolute(_ range: NSRange) -> NSRange {
        NSRange(location: leading + range.location, length: range.length)
    }

    /// Use unchanged text outside the slice from the verified editor. A slice
    /// cannot authorize writing until its absolute caret and contents agree.
    func expanding(_ baseline: String, observed: String, selection: NSRange,
                   full: String, fullSelection: NSRange) -> String? {
        let body = full as NSString
        let width = observed.utf16.count
        guard absolute(selection) == fullSelection, leading <= body.length,
              width <= body.length - leading,
              trailing.map({ $0 == body.length - leading - width }) ?? true else { return nil }
        // AX can cut through a surrogate pair at either edge of a fixed
        // UTF-16 window. Preserve the complete scalar from the live document.
        let left = leading>0 && leading<body.length && (0xdc00...0xdfff).contains(body.character(at:leading)) ? 1:0
        let end=leading+width
        let right = end>0 && end<body.length && (0xd800...0xdbff).contains(body.character(at:end-1)) ? 1:0
        let current=observed as NSString, prior=baseline as NSString
        guard left+right<=width,left+right<=prior.length,
              current.substring(to:left).utf16.elementsEqual(prior.substring(to:left).utf16),
              current.substring(from:width-right).utf16.elementsEqual(prior.substring(from:prior.length-right).utf16) else{return nil}
        let inner=NSRange(location:left,length:width-left-right)
        let absolute=NSRange(location:leading+left,length:inner.length)
        guard body.substring(with:absolute).utf16.elementsEqual(current.substring(with:inner).utf16) else{return nil}
        let replace=NSRange(location:left,length:prior.length-left-right)
        return body.replacingCharacters(in:absolute,with:prior.substring(with:replace))
    }

    static func selection(_ raw: CFTypeRef?) -> NSRange? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &r), r.location >= 0,
              r.location < NSNotFound, r.length >= 0, r.length <= Int.max - r.location else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    static func string(_ field: AXUIElement, range: NSRange) -> (AXError, String?) {
        var r = CFRange(location: range.location, length: range.length)
        guard let argument = AXValueCreate(.cfRange, &r) else { return (.illegalArgument, nil) }
        var raw: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, argument, &raw)
        return (error, raw as? String)
    }

    // Pre-focus witnesses may use a complete short accessible range. A
    // clipped or unreadable field can never masquerade as an empty editor.
    static func preFocusAttributes(_ field: AXUIElement, names: [String]) -> [CFTypeRef?] {
        guard let index=names.firstIndex(of:kAXValueAttribute) else{return InputFocusAccess.attributes(field,names)}
        var requested=names
        requested[index]=kAXNumberOfCharactersAttribute
        let selectionIndex=requested.firstIndex(of:kAXSelectedTextRangeAttribute) ?? requested.count
        if selectionIndex==requested.count {requested.append(kAXSelectedTextRangeAttribute)}
        var values=InputFocusAccess.attributes(field,requested)
        let count=values[index] as? NSNumber
        let selected=selection(values[selectionIndex])
        values[index]=nil
        if let count,CFGetTypeID(count) != CFBooleanGetTypeID(),(0...maximumSelection).contains(count.intValue),
           selected.map({ NSMaxRange($0)<=count.intValue }) ?? true {
            let (status,text)=string(field,range:NSRange(location:0,length:count.intValue))
            if status == .success, let text,text.utf16.count==count.intValue {
                if count.intValue>0 {values[index]=text as CFString}
                else {
                    // A zero-width slice is empty even in a nonempty editor.
                    // Require independent evidence for the end of the range.
                    let probe=string(field,range:NSRange(location:0,length:1))
                    if probe.0 == .illegalArgument || probe.0 == .noValue || (probe.0 == .success && probe.1=="") {values[index]="" as CFString}
                }
            }
        }
        return Array(values.prefix(names.count))
    }

    static func read(_ field: AXUIElement, count: CFTypeRef?, selected: CFTypeRef?, preferred: Self? = nil) -> Observation? {
        guard let caret = selection(selected) else { return nil }
        guard let view = resolve(count: count.flatMap { CFGetTypeID($0)==CFBooleanGetTypeID() ? nil:($0 as? NSNumber)?.intValue }, selection: caret, preferred: preferred, read: { string(field, range: $0) }) else { return nil }
        let after = InputFocusAccess.attributes(field, [kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute])
        guard selection(after[0]) == caret, (count as? NSNumber)?.intValue == (after[1] as? NSNumber)?.intValue else { return nil }
        return view
    }

    static func resolve(count: Int?, selection: NSRange, preferred: Self? = nil, read: (NSRange) -> (AXError, String?)) -> Observation? {
        let at = selection.location, length = selection.length
        guard at >= 0, length >= 0, length <= maximumSelection,
              at <= Int.max - length - afterCaret * 2 else { return nil }
        let end = at + length
        if let count, count < end { return nil }
        // Fixed omitted margins keep a run of new keys in the same coordinates.
        var leading = max(0, at / beforeCaret - 1) * beforeCaret
        var trailing = count.map { max(0, ($0 - end) / afterCaret - 1) * afterCaret }
        if let preferred, preferred.leading <= at, at - preferred.leading <= beforeCaret * 3,
           let count, let tail=preferred.trailing, tail <= count-end, count-end-tail <= afterCaret*3 {
            leading=preferred.leading;trailing=tail
        }
        let right = count.flatMap { n in trailing.map { n - $0 - end } } ?? afterCaret
        let local = NSRange(location: at - leading, length: length)
        let minimum = end - leading
        func fetch(_ right: Int) -> (AXError, String?) {
            read(NSRange(location: leading, length: minimum + right))
        }
        let (error, value) = fetch(right)
        func observation(_ value: String, _ omitted: Int?) -> Observation? {
            guard value.utf16.count >= minimum, value.utf16.count <= minimum + right else { return nil }
            return Observation(window: Self(leading: leading, trailing: omitted), text: value, selection: local)
        }
        if error == .success, let value {
            let exact = value.utf16.count == minimum + right
            guard exact || trailing == nil || trailing == 0 else { return nil }
            return observation(value, exact ? trailing : 0)
        }
        // Some providers omit the count, or include a display-only terminal
        // newline in it. Only an out-of-range reply can shorten this probe.
        func boundary(_ result: AXError) -> Bool { result == .illegalArgument || result == .noValue }
        guard right > 0, boundary(error), trailing == nil || trailing == 0 else { return nil }
        var lo = 0, hi = right - 1
        let first = fetch(0)
        guard first.0 == .success, var best = first.1, best.utf16.count == minimum else { return nil }
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            let (status, text) = fetch(mid)
            if status == .success, let text, text.utf16.count == minimum + mid {
                best = text; lo = mid
            } else if boundary(status) { hi = mid - 1 }
            else { return nil }
        }
        return observation(best, 0)
    }
}
