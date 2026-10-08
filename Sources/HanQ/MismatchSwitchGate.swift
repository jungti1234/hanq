import AppKit
import Carbon

// Own only right-Command transitions that begin during an active recovery.
// Normal switching continues through HanQ. This tap never selects a source.
final class MismatchSwitchGate {
    var filter=CommandFilter()
    var tap:CFMachPort?
    var runSource:CFRunLoopSource?
    var accepts:()->Bool
    var failed:()->Void = {}
    var switched:(CGEventTimestamp)->Void
    var forwarded:(CGEventType,CGEvent)->Void = {_,_ in}
    init(accepts:@escaping ()->Bool,switched:@escaping (CGEventTimestamp)->Void){self.accepts=accepts;self.switched=switched}
    func receive(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async{[weak self] in self?.stop();self?.failed()}
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData)==0 else{return Unmanaged.passUnretained(event)}
        let result=filter.process(type:type,key:event.getIntegerValueField(.keyboardEventKeycode),flags:event.flags,acceptNewPress:accepts())
        event.flags=result.flags
        if result.edge=="right-down"{switched(event.timestamp)}
        if !result.consume {forwarded(type,event)}
        return result.consume ? nil:Unmanaged.passUnretained(event)
    }
    func start()->Bool {
        let mask:CGEventMask=[CGEventType.flagsChanged,.keyDown,.keyUp].reduce(0){$0 | (1 << $1.rawValue)}
        tap=CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,event,ref in
            Unmanaged<MismatchSwitchGate>.fromOpaque(ref!).takeUnretainedValue().receive(type,event)
        },userInfo:Unmanaged.passUnretained(self).toOpaque())
        guard let tap else{return false}
        runSource=CFMachPortCreateRunLoopSource(nil,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),runSource,.commonModes)
        return true
    }
    func stop(){if let tap{CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)};if let runSource{CFRunLoopRemoveSource(CFRunLoopGetMain(),runSource,.commonModes);CFRunLoopSourceInvalidate(runSource)};tap=nil;runSource=nil}
    deinit{stop()}
}
