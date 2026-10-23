import AppKit
let pid=pid_t(CommandLine.arguments[1])!
let expected=URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL
// Restrict automation to the same HanQ checked by the preparation tool.
guard AXIsProcessTrusted(),let running=NSRunningApplication(processIdentifier:pid),!running.isTerminated,
      running.bundleIdentifier=="taek.in.hanq",running.bundleURL?.standardizedFileURL==expected else{exit(2)}
let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.1)
func value(_ e:AXUIElement,_ attribute:String)->CFTypeRef? {
    var v:CFTypeRef?
    guard AXUIElementCopyAttributeValue(e,attribute as CFString,&v) == .success else{return nil}
    return v
}
func find(_ e:AXUIElement,_ depth:Int)->AXUIElement? {
    guard depth<8 else{return nil}
    if let title=value(e,"AXTitle") as? String,["방금 발생한 문제 기록","방금 입력 누락 기록"].contains(title){return e}
    for child in (value(e,"AXChildren") as? [AXUIElement] ?? []).prefix(24){if let result=find(child,depth+1){return result}}
    return nil
}
guard let bar=value(app,"AXExtrasMenuBar"),let item=find(unsafeBitCast(bar,to:AXUIElement.self),0) else{print("SKIP: incident menu unavailable; no diagnostic capture claimed");exit(2)}
let result=AXUIElementPerformAction(item,kAXPressAction as CFString)
print("incident mark AX action result=\(result.rawValue)")
exit(result == .success ? 0:1)
