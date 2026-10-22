import AppKit
import Carbon

private enum OwnedInputFocusRoot {
    static let element:AXUIElement={
        // These helpers are command-line processes. Initialize AppKit without
        // activation before the system-wide AX request; otherwise macOS can
        // return cannotComplete even though per-application AX access works.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let value=AXUIElementCreateSystemWide();AXUIElementSetMessagingTimeout(value,0.05);return value
    }()
}
// Reuse the AX root object only. Resolve keyboard focus freshly before each
// source mutation/key edge, including non-activating panels such as Spotlight.
func ownedInputFocusMatches(_ pid:pid_t,onFailure:((Int,Int32)->Void)?=nil)->Bool {
    func failed(_ reason:Int,_ status:Int32=0)->Bool {onFailure?(reason,status);return false}
    guard pid>1 else{return failed(1)}
    guard AXIsProcessTrusted() else{return failed(2)}
    guard !IsSecureEventInputEnabled() else{return failed(3)}
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else{return failed(4)}
    var value:CFTypeRef?,owner:pid_t=0
    let copied=AXUIElementCopyAttributeValue(OwnedInputFocusRoot.element,kAXFocusedUIElementAttribute as CFString,&value)
    guard copied == .success else{return failed(5,copied.rawValue)}
    guard let value,CFGetTypeID(value)==AXUIElementGetTypeID() else{return failed(6)}
    let resolved=AXUIElementGetPid(value as! AXUIElement,&owner)
    guard resolved == .success else{return failed(7,resolved.rawValue)}
    guard owner==pid else{return failed(8)}
    return true
}
