import AppKit
import Carbon

// Use the user's enabled previous-input-source shortcut. Never change preferences.
final class MismatchSourceSwitch {
    var busy=false
    private var generation=0
    private var release:(()->Void)?
    // All down/up events in the shortcut must share one retained private
    // state table. Creating a source for each event splits press and release
    // across unrelated Quartz keyboard states.
    private lazy var eventSource=CGEventSource(stateID:.privateState)
    func shortcutEvents(marker:Int64)->[CGEvent]? {
        guard let eventSource else{return nil}
        func event(_ key:CGKeyCode,_ down:Bool,_ type:CGEventType,_ flags:CGEventFlags)->CGEvent? {
            guard let e=CGEvent(keyboardEventSource:eventSource,virtualKey:key,keyDown:down) else{return nil}
            e.type=type;e.flags=flags;e.setIntegerValueField(.eventSourceUserData,value:marker);return e
        }
        guard let controlDown=event(59,true,.flagsChanged,.maskControl),let controlUp=event(59,false,.flagsChanged,[]),
              let down=event(49,true,.keyDown,.maskControl),let up=event(49,false,.keyUp,.maskControl) else{return nil}
        return [controlDown,down,up,controlUp]
    }
    deinit{cancel()}
    func cancel(){generation+=1;release?();release=nil;busy=false}
    func request(marker:Int64,valid:@escaping ()->Bool,posted:@escaping (CGEvent)->Void={_ in})->OSStatus {
        guard !busy,valid(),CGPreflightPostEventAccess() else{return -50}
        let prefs=UserDefaults(suiteName:"com.apple.symbolichotkeys")
        guard let keys=prefs?.dictionary(forKey:"AppleSymbolicHotKeys"),
              let item=keys["60"] as? [String:Any],(item["enabled"] as? NSNumber)?.boolValue==true,
              let value=item["value"] as? [String:Any],let params=value["parameters"] as? [NSNumber],params.count==3 else{return -50}
        let code=CGKeyCode(params[1].uint16Value),flags=CGEventFlags(rawValue:params[2].uint64Value)
        // Tested configuration. Unsupported shortcuts fail visibly rather than use a different path.
        guard code==49,flags == .maskControl else{return -50}
        guard let events=shortcutEvents(marker:marker) else{return -50}
        let controlDown=events[0],down=events[1],up=events[2],controlUp=events[3]
        func send(_ event:CGEvent){posted(event);event.post(tap:.cghidEventTap)}
        busy=true;generation+=1;let token=generation
        var spaceDown=false
        release={if spaceDown{send(up)};send(controlUp)}
        // Allow each modifier phase to reach the input manager before the next
        // source cycle. A TIS ID change can precede actual IME activation.
        send(controlDown)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.05){[weak self] in
            guard let self,self.generation==token else{return}
            guard valid() else{self.cancel();return}
            spaceDown=true;send(down)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.03){[weak self] in
                guard let self,self.generation==token else{return}
                send(up);spaceDown=false
                DispatchQueue.main.asyncAfter(deadline:.now()+0.03){[weak self] in
                    guard let self,self.generation==token else{return}
                    send(controlUp);self.release=nil
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.08){[weak self] in
                    guard let self,self.generation==token else{return};self.busy=false
                }
            }
        }
        return noErr
    }
}

// A replay ledger models composition across batches, but commits a segment at
// every source boundary. Key-up events never create a boundary or a character.
struct MismatchReplayLedger {
    let before:String
    let caret:Int
    var segments:[(source:String,keys:[(UInt16,Bool)])]=[]
    mutating func append(source:String,keys:[(UInt16,Bool)]) {
        guard !keys.isEmpty else{return}
        if segments.last?.source==source{segments[segments.count-1].keys+=keys}
        else{segments.append((source,keys))}
    }
    static func render(_ segment:(source:String,keys:[(UInt16,Bool)]))->String {
        let roman=segment.keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
        guard MismatchKeyboardLayout.supports(segment.source) else{return roman}
        return MismatchKeyboardLayout.render(keys:segment.keys,sourceID:segment.source) ?? roman
    }
    var insertion:String{segments.map{Self.render($0)}.joined()}
    var text:String{(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:insertion)}
    var selection:NSRange{NSRange(location:caret+insertion.utf16.count,length:0)}
}
