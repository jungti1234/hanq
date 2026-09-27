import AppKit

// AXValue and editable offsets can describe different strings. Never remove
// newlines to manufacture a mapping. Ask the editor for text in its own ranges.
enum MismatchTextReader {
    static func isBoundaryResponse(_ error:AXError)->Bool { error == .illegalArgument || error == .noValue }
    struct Content { let text:String;let selectedText:String? }
    static func resolve(value:String,selection:NSRange,read:(NSRange)->String?)->String? {
        let upper=value.utf16.count
        guard selection.location>=0,selection.length>=0,selection.location<=upper,
              selection.length<=upper-selection.location else{return nil}
        var invalidLength=false
        func exact(_ range:NSRange)->String? {
            guard let s=read(range) else{return nil}
            guard s.utf16.count==range.length else{invalidLength=true;return nil}
            return s
        }
        let full:String
        if let s=exact(NSRange(location:0,length:upper)){full=s}
        else {
            // AXValue length is only a bounded search ceiling, never a caret offset.
            // Confirm the entire prefix first. A timeout cannot be treated as empty.
            let start=NSMaxRange(selection)
            guard exact(NSRange(location:0,length:start)) != nil else{return nil}
            var low=start,high=upper
            while low<high {
                let mid=low+(high-low+1)/2
                if exact(NSRange(location:0,length:mid)) != nil{low=mid}else{high=mid-1}
            }
            guard let s=exact(NSRange(location:0,length:low)) else{return nil};full=s
        }
        // Verify the coordinate basis locally, including a selection and its context.
        let begin=max(0,selection.location-16),end=min(full.utf16.count,NSMaxRange(selection)+16)
        let r=NSRange(location:begin,length:end-begin)
        guard exact(r)==(full as NSString).substring(with:r),!invalidLength else{return nil}
        return full
    }
    static func read(_ element:AXUIElement,value:String,selection:NSRange)->Content? {
        var unsupported=false,failed=false
        let text=resolve(value:value,selection:selection){ r in
            var cf=CFRange(location:r.location,length:r.length)
            guard let arg=AXValueCreate(.cfRange,&cf) else{return nil}
            var raw:CFTypeRef?
            let error=AXUIElementCopyParameterizedAttributeValue(element,kAXStringForRangeParameterizedAttribute as CFString,arg,&raw)
            if error == .parameterizedAttributeUnsupported{unsupported=true}
            // Only an out-of-range response is evidence for a shorter coordinate domain.
            if error != .success && !isBoundaryResponse(error){failed=true}
            return error == .success ? raw as? String:nil
        }
        guard !unsupported,!failed,let text else{return nil}
        var selectedRaw:CFTypeRef?
        let status=AXUIElementCopyAttributeValue(element,kAXSelectedTextAttribute as CFString,&selectedRaw)
        let selected=selectedRaw as? String
        if selection.length>0 {
            guard status == .success,selected==(text as NSString).substring(with:selection) else{return nil}
        }
        // Reads are asynchronous IPC. Reject a changing value or caret, not a
        // mixed snapshot assembled from two edits.
        var valueAfter:CFTypeRef?,rangeAfter:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXValueAttribute as CFString,&valueAfter) == .success,
              valueAfter as? String == value,
              AXUIElementCopyAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,&rangeAfter) == .success,
              let rangeAfter,CFGetTypeID(rangeAfter)==AXValueGetTypeID() else{return nil}
        var r=CFRange();guard AXValueGetValue(rangeAfter as! AXValue,.cfRange,&r),r.location==selection.location,r.length==selection.length else{return nil}
        return Content(text:text,selectedText:selected)
    }
}
