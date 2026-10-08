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
print("PASS \(checks) keyboard-focus routing checks; no OS keys posted")
