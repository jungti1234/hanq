import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
let access=InputFocusAccess()
let background=AXUIElementCreateApplication(12345)
let panel=AXUIElementCreateApplication(54321)
var front:pid_t?=12345
var systemField:AXUIElement?=panel
var applicationReads=0
access.frontmostPID={front}
access.read={ root in
    if CFEqual(root,access.system){return systemField}
    applicationReads+=1
    return background
}
check(access.currentPID()==54321,"non-activating panel owns keyboard focus")
check(access.focusedElement(application:background,pid:12345)==nil,"background remembered field must not override panel")
check(applicationReads==0,"foreign system focus cannot fall back to the background app")
check(access.focusedElement(application:panel,pid:54321).map{CFEqual($0,panel)}==true,"panel can be read despite different frontmost PID")
systemField=background
check(access.currentPID()==12345,"closing panel restores application target")
check(access.focusedElement(application:background,pid:12345).map{CFEqual($0,background)}==true,"system field of same process is preferred")
systemField=nil
check(access.currentPID()==12345,"unavailable system focus retains normal app fallback")
check(access.focusedElement(application:background,pid:12345).map{CFEqual($0,background)}==true,"application-only AX focus still supported")
front=54321
check(access.focusedElement(application:background,pid:12345)==nil,"unavailable global focus must not authorize background app")
check(access.focusedElement(application:panel,pid:54321)==nil,"fallback rejects wrong owner")
front=nil
check(access.currentPID()==nil,"no focus owner and no frontmost app means no target")
check(access.focusedElement(application:background,pid:12345)==nil,"missing context does not reuse old app")
systemField=panel;front=12345
check(access.currentPID()==54321,"panel return follows actual focus again")
systemField=background
check(access.focusedElement(application:panel,pid:54321)==nil,"focus change between target selection and read is rejected")
systemField=access.system
check(access.currentPID()==nil,"invalid focus owner cannot authorize frontmost fallback")
check(access.focusedElement(application:background,pid:12345)==nil,"invalid system owner blocks background read")
check(access.lastOwner==nil,"invalid owner never retains a previous PID")
systemField=panel
check(access.focusedElement(application:background,pid:12345)==nil && access.lastOwner==54321,"foreign owner remains distinguishable from unreadable field")
systemField=nil;front=12345
_ = access.focusedElement(application:background,pid:12345)
check(access.lastOwner==12345,"fallback records only the freshly queried frontmost owner")
let current=NSRunningApplication.current
check(InputFocusAccess.application(pid:current.processIdentifier,reusing:current) === current,"same PID reuses process object")
systemField=panel
check(access.currentApplication(reusing:current)?.processIdentifier != current.processIdentifier,"process object reuse cannot hide a focus owner change")
let names=["role","marked","value"]
var singles:[String]=[]
var error=AXError.attributeUnsupported
let unsupported=AXValueCreate(.axError,&error)!
let batch=InputFocusAccess.resolveAttributes(names,batch:{["AXTextArea" as NSString,unsupported,"synthetic" as NSString]},single:{singles.append($0);return nil})
check(batch[0] as? String == "AXTextArea" && batch[1]==nil && batch[2] as? String == "synthetic" && singles.isEmpty,"one batch preserves unsupported attributes without individual retries")
let fallback=InputFocusAccess.resolveAttributes(names,batch:{nil},single:{singles.append($0);return $0 as CFString})
check(singles==names && fallback[2] as? String == "value","unsupported batch retains ordered individual reads")
singles=[]
_ = InputFocusAccess.resolveAttributes(names,batch:{[]},single:{singles.append($0);return nil})
check(singles==names,"malformed batch falls back without treating a missing value as empty text")
// Keep the original Swift canonical equality as an independent oracle. AX can
// expose a different UTF-16 representation without changing Swift equality.
var texts=["","a","A","a\0","a\0b","한글","가","가","é","e\u{301}","a\u{301}\u{323}","a\u{323}\u{301}","Å","Å","😀","👩‍👩‍👧‍👦","\r\n","\n","\u{200b}","\u{feff}","❤","❤️"]
for units:[UInt16] in [[0xd800],[0xdc00],[0xd800,0x61],[0xfffd],[0xd800,0xdc00],[0x61,0,0x62]] {
    texts.append(units.withUnsafeBufferPointer{NSString(characters:$0.baseAddress!,length:$0.count) as String})
}
for a in texts {for b in texts {
    let expected=a==b
    let foreignA=(NSMutableString(string:a).copy() as! NSString) as String
    let foreignB=(NSMutableString(string:b).copy() as! NSString) as String
    for pair in [(a,b),(foreignA,b),(a,foreignB),(foreignA,foreignB)] {
        check(InputFocusAccess.sameText(pair.0,pair.1)==expected,"fresh AX/native text comparison preserves Swift equality")
    }
}}
for pair in [(String(repeating:"한",count:10_000),String(repeating:"한",count:10_000)),
             (String(repeating:"가",count:10_000),String(repeating:"가",count:10_000)),
             (String(repeating:"한",count:10_000)+"a",String(repeating:"한",count:10_000)+"b")] {
    let a=(NSMutableString(string:pair.0).copy() as! NSString) as String
    let b=(NSMutableString(string:pair.1).copy() as! NSString) as String
    check(InputFocusAccess.sameText(a,b)==(a==b),"full long text keeps equal, canonical and changed-suffix results")
}
check(!InputFocusAccess.sameText(nil,""),"missing logging baseline is distinct from empty observed text")
check(InputFocusAccess.sameText(Optional(""),""),"present empty logging baseline remains equal")
// Exercise the long-text branch, including combining marks directly after
// stable separators, different canonical prefixes, and absent boundaries.
let stableSeparators=[" ","\t","\r","\n","\r\n"]
for separator in stableSeparators {for a in texts {for b in texts {
    let prefix=String(repeating:"한",count:300)+separator
    let left=prefix+a,right=prefix+b
    let foreignLeft=(NSMutableString(string:left).copy() as! NSString) as String
    let foreignRight=(NSMutableString(string:right).copy() as! NSString) as String
    for pair in [(left,right),(foreignLeft,foreignRight)] {
        check(InputFocusAccess.sameText(pair.0,pair.1)==(pair.0==pair.1),"stable shared prefix keeps full canonical result")
    }
}}}
for separator in stableSeparators {for a in texts {for b in texts {
    let padding=String(repeating:"한",count:300)
    let left=padding+a+separator+"e\u{301}",right=padding+b+separator+"é"
    check(InputFocusAccess.sameText(left,right)==(left==right),"a differing prefix is never skipped")
}}}
for prefix in [String(repeating:"한",count:600),String(repeating:"한",count:300)+" "+String(repeating:"가",count:600)] {
    for a in texts {for b in texts {
        check(InputFocusAccess.sameText(prefix+a,prefix+b)==(prefix+a==prefix+b),"missing recent separator keeps original fallback")
    }}
}
print("PASS \(checks) keyboard-focus routing and canonical text equality checks; no OS keys posted")

let focusObserverAccess=InputFocusAccess()
let focusObserverApp=AXUIElementCreateApplication(getpid())
var observerReads=0,observerCalls=0
focusObserverAccess.read={_ in observerReads+=1;return focusObserverApp}
let without=focusObserverAccess.focusedElement(application:focusObserverApp,pid:getpid())
let readsWithout=observerReads;observerReads=0
focusObserverAccess.observeFocus={element,owner,route in
    observerCalls+=1
    check(element != nil && owner==getpid() && route==1,"observer uses the original focus result")
}
let with=focusObserverAccess.focusedElement(application:focusObserverApp,pid:getpid())
check(with != nil && without != nil && CFEqual(with!,without!) && observerReads==readsWithout && observerCalls==1,"observer adds no focus query or behavior change")
print("PASS focus observation reuses existing query and owner")
