import AppKit

// Read-only, bounded discovery of editors before an outside key chooses one.
// Never focuses a field, posts input, or treats a post-key read as prior text.
final class OnsetOutsideObservation {
    struct Entry { let snapshot:OnsetSnapshot; let completed:Double }
    var entries:[Entry]=[]
    private var root:AXUIElement?
    private var queue:[(AXUIElement,Int)]=[]
    private var visited:[AXUIElement]=[]
    private var nextCycle=0.0
    var clock:()->Double = { ProcessInfo.processInfo.systemUptime }
    var read:(AXUIElement,String)->CFTypeRef? = { element,name in
        var value:CFTypeRef?
        AXUIElementSetMessagingTimeout(element,0.003)
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else{return nil}
        return value
    }
    func reset(){entries=[];root=nil;queue=[];visited=[];nextCycle=0}
    func baseline(for field:AXUIElement,before time:Double)->OnsetSnapshot? {
        entries.last{CFEqual($0.snapshot.element,field) && $0.completed<time && time-$0.completed<=0.75}?.snapshot
    }
    func advance(root newRoot:AXUIElement,focused:AXUIElement?=nil){
        let start=clock()
        if root.map({!CFEqual($0,newRoot)}) ?? true {reset();root=newRoot}
        entries.removeAll{start-$0.completed>0.75}
        if queue.isEmpty {
            guard start>=nextCycle else{return}
            queue=[(newRoot,0)];visited=[];nextCycle=start+0.15
            // Browser chrome can put the active document beyond the window's
            // depth limit. Begin at the actual outside focus as well, while
            // retaining the window walk for sibling controls. An anchor from
            // a different/unknown window must never seed this observation.
            if let focused,!CFEqual(focused,newRoot),
               let window=read(focused,kAXWindowAttribute),
               CFGetTypeID(window)==AXUIElementGetTypeID(),CFEqual(window,newRoot) {
                queue.insert((focused,0),at:0)
            }
        }
        var count=0
        while !queue.isEmpty,count<24,visited.count<256,clock()-start<0.015 {
            let (node,depth)=queue.removeFirst();count+=1
            if visited.contains(where:{CFEqual($0,node)}){continue}
            visited.append(node)
            guard let role=read(node,kAXRoleAttribute) as? String else{continue}
            if OnsetEditableRole.supports(role) {
                guard read(node,kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else{continue}
                guard let text=read(node,kAXValueAttribute) as? String,text.utf16.count<=16384 else{continue}
                // Unfocused fields may omit their cursor. Unknown is not zero:
                // only a full surrounding-text match can use this observation.
                // The focused, post-key snapshot still requires a valid caret.
                var selection=NSRange(location:NSNotFound,length:0)
                let rawSelection=read(node,kAXSelectedTextRangeAttribute)
                // A menu-only combo is not a text editor. Require its text
                // selection interface even for a pre-focus observation.
                if role == kAXComboBoxRole,rawSelection == nil{continue}
                if let raw=rawSelection {
                    guard CFGetTypeID(raw)==AXValueGetTypeID() else{continue}
                    var range=CFRange()
                    guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.length==0 else{continue}
                    if range.location>=0 {
                        guard range.location<=text.utf16.count else{continue}
                        selection=NSRange(location:range.location,length:0)
                    }
                }
                // Timestamp after all reads. A key arriving during the read
                // makes this entry ineligible for that reservation.
                let entry=Entry(snapshot:.init(element:node,text:text,selection:selection),completed:clock())
                entries.removeAll{CFEqual($0.snapshot.element,node)}
                entries.append(entry)
                if entries.count>16{entries.removeFirst()}
                continue
            }
            // Finish the node already removed from the queue. Stopping between
            // role and children silently loses its entire subtree forever in
            // this cycle. The next node remains subject to the time budget.
            guard depth<12 else{continue}
            guard let children=read(node,kAXChildrenAttribute) as? [AXUIElement] else{continue}
            queue.append(contentsOf:children.prefix(64).map{($0,depth+1)})
            if queue.count>256{queue=Array(queue.prefix(256))}
        }
        if visited.count>=256{queue=[]}
    }
}
