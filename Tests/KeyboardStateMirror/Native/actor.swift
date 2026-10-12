import AppKit
final class ActorWindow:NSWindow {
    var producers:Set<Int32>=[]
    var edges:[[String:Int64]]=[]
    override func sendEvent(_ event:NSEvent) {
        if [NSEvent.EventType.keyDown,.keyUp,.flagsChanged].contains(event.type),
           let cg=event.cgEvent,producers.contains(Int32(cg.getIntegerValueField(.eventSourceUnixProcessID))),
           [37,56].contains(Int(event.keyCode)) {
            edges.append(["type":Int64(event.type.rawValue),"code":Int64(event.keyCode),"flags":Int64(event.modifierFlags.rawValue),"tag":cg.getIntegerValueField(.eventSourceUserData),"repeat":cg.getIntegerValueField(.keyboardEventAutorepeat)])
            // A raw receiver must not ask the IME to reinterpret an otherwise
            // unhandled key on a label window after focus moves to another app.
            return
        }
        super.sendEvent(event)
    }
}
final class Actor:NSObject,NSApplicationDelegate {
    let root:URL,role:String,producer:Int32
    var window:ActorWindow!
    init(_ root:URL,_ role:String,_ producer:Int32){self.root=root;self.role=role;self.producer=producer}
    func applicationDidFinishLaunching(_ n:Notification){
        window=ActorWindow(contentRect:NSRect(x:0,y:0,width:450,height:130),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="한Q 키 경로 시험 "+role
        window.producers=[producer]
        window.contentView=NSTextField(labelWithString:"시험 창 "+role+" — 사용자 입력을 기록하지 않습니다.")
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        try! JSONSerialization.data(withJSONObject:["pid":getpid()]).write(to:root.appendingPathComponent("ready-"+role+".json"))
        Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){_ in
            if let data=try? Data(contentsOf:self.root.appendingPathComponent("producers.json")),let ids=try? JSONDecoder().decode([Int32].self,from:data){self.window.producers=Set(ids)}
            try? JSONSerialization.data(withJSONObject:self.window.edges).write(to:self.root.appendingPathComponent("edges-"+self.role+".json"),options:.atomic)
            if FileManager.default.fileExists(atPath:self.root.appendingPathComponent("quit").path){exit(0)}
        }
    }
}
@main struct ActorMain {
    static func main(){
        guard CommandLine.arguments.count==4,let producer=Int32(CommandLine.arguments[3]) else{exit(0)}
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let actor=Actor(URL(fileURLWithPath:CommandLine.arguments[1]),CommandLine.arguments[2],producer)
        app.delegate=actor;app.run()
    }
}
