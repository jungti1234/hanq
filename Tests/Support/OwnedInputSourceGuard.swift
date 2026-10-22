import AppKit
import Carbon

// Source selection is global too. A lost-focus test must not restore a source
// into the app the person has started using. A non-activating panel can own
// keyboard focus while NSWorkspace still reports the underlying application.
func ownedInputSourceLocalFocus()->Bool {
    NSApp?.isActive==true && NSApp.keyWindow?.isKeyWindow==true &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() && !IsSecureEventInputEnabled()
}
private enum OwnedInputSourceTransport {static var busy=false}
func ownedInputSourceCommand(_ operation:String,_ sourceID:String="")->OSStatus {
    guard !OwnedInputSourceTransport.busy,ownedInputSourceLocalFocus(),CommandLine.arguments.count==2 else{return OSStatus(-1)}
    OwnedInputSourceTransport.busy=true;defer{OwnedInputSourceTransport.busy=false}
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),nonce=UUID().uuidString
    let request:[String:Any]=["operation":operation,"sourceID":sourceID,"pid":getpid(),"nonce":nonce,"uptime":ProcessInfo.processInfo.systemUptime]
    let response=root.appendingPathComponent("source-control-response.json")
    do {
        try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys]).write(to:root.appendingPathComponent("source-control-request.json"),options:.atomic)
        let deadline=ProcessInfo.processInfo.systemUptime+1
        while ProcessInfo.processInfo.systemUptime<deadline,ownedInputSourceLocalFocus() {
            if let data=try? Data(contentsOf:response),let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any],result["nonce"] as? String==nonce,let status=result["status"] as? Int {
                return OSStatus(status)
            }
            // Serve AX focus queries without allowing a nested source request.
            RunLoop.current.run(until:Date().addingTimeInterval(0.002))
        }
    }catch{}
    return OSStatus(-1)
}
func ownedInputSourceChangeAllowed()->Bool {ownedInputSourceCommand("check")==noErr}
func ownedInputSourceID(_ source:TISInputSource)->String {
    guard let pointer=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return ""}
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}
func ownedSelectInputSource(_ source:TISInputSource)->OSStatus {ownedInputSourceCommand("select",ownedInputSourceID(source))}
func ownedEnableInputSource(_ source:TISInputSource)->OSStatus {ownedInputSourceCommand("enable",ownedInputSourceID(source))}
func ownedDisableInputSource(_ source:TISInputSource)->OSStatus {ownedInputSourceCommand("disable",ownedInputSourceID(source))}

// This adds a button without activating the window. Cleanup requires the
// person to return to the owned window; an aborted result stays a failure.
final class OwnedInputSourceCleanup:NSObject {
    private static var pending:[OwnedInputSourceCleanup]=[]
    private let restore:()->Bool,completed:()->Void
    init(window:NSWindow,restore:@escaping()->Bool,completed:@escaping()->Void) {
        self.restore=restore;self.completed=completed;super.init()
        let button=NSButton(title:"이 창에서 원래 입력 소스 복원 후 종료",target:self,action:#selector(run))
        button.frame=NSRect(x:10,y:5,width:min(430,window.frame.width-20),height:26)
        window.contentView?.addSubview(button);Self.pending.append(self)
    }
    @objc private func run(){guard ownedInputSourceChangeAllowed(),restore() else{return};completed()}
}
