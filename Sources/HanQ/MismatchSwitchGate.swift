import AppKit
import Carbon

// Own only right-Command transitions that begin during an active recovery.
// Normal switching continues through HanQ. This tap never selects a source.
final class MismatchSwitchGate {
    var filter=CommandFilter()
    var incidentTrace=InputIncidentTrace.shared
    var acceptanceReason=0
    var tap:CFMachPort?
    var runSource:CFRunLoopSource?
    var accepts:()->Bool
    var failed:()->Void = {}
    var switched:(CGEventTimestamp)->Void
    var forwarded:(CGEventType,CGEvent,CGEventTimestamp)->Void = {_,_,_ in}
    var acceptsExternalSource:()->Bool = {false}
    var capsChanged:(CGEventTimestamp)->Void = {_ in}
    var menuBegan:(CGEventTimestamp)->Void = {_ in}
    static func menuPopupVisible()->Bool {
        // Numeric window metadata only; do not read titles or capture images.
        guard let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else{return false}
        let level=CGWindowLevelForKey(.popUpMenuWindow)
        return windows.contains{($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(level)}
    }
    static func isMenuBarClick(_ type:CGEventType,_ event:CGEvent)->Bool {
        guard type == .leftMouseDown || type == .rightMouseDown else{return false}
        return NSScreen.screens.contains { screen in
            guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{return false}
            let bounds=CGDisplayBounds(number.uint32Value),point=event.location
            return point.x>=bounds.minX && point.x<bounds.maxX && point.y>=bounds.minY && point.y<bounds.minY+NSStatusBar.system.thickness
        }
    }
    init(accepts:@escaping ()->Bool,switched:@escaping (CGEventTimestamp)->Void){self.accepts=accepts;self.switched=switched}
    // Pure/injected callers already supply a single timestamp domain. Only the
    // actual HID callback crosses Quartz's tick/nanosecond boundary.
    func receiveHID(_ type:CGEventType,_ event:CGEvent)->Unmanaged<CGEvent>? {
        receive(type,event,at:MismatchEventClock.hidTimestamp(event))
    }
    func receive(_ type:CGEventType,_ event:CGEvent,at capturedTimestamp:CGEventTimestamp?=nil)->Unmanaged<CGEvent>? {
        var control=InputIncidentControl.begin(incidentTrace,type,event)
        var consumed=false
        defer{if let control{incidentTrace.control(.hid,type,event,control,consumed:consumed)}}
        let timestamp=capturedTimestamp ?? event.timestamp
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            control?.route=InputIncidentControl.Route.tapDisabled.rawValue
            InputDiagnostics.shared.record("mismatch.tap_disabled kind=2 type=\(type.rawValue)")
            DispatchQueue.main.async{[weak self] in self?.stop();self?.failed()}
            return Unmanaged.passUnretained(event)
        }
        let tag=event.getIntegerValueField(.eventSourceUserData)
        guard tag==0 || InputDeliveryOrigin.isMarker(tag) else{control?.route=InputIncidentControl.Route.hidTagIgnored.rawValue;return Unmanaged.passUnretained(event)}
        if acceptsExternalSource() {
            if event.getIntegerValueField(.keyboardEventKeycode)==57,(type == .flagsChanged || type == .keyDown) {capsChanged(timestamp)}
            if Self.isMenuBarClick(type,event){menuBegan(timestamp)}
        }
        acceptanceReason=0
        let before=filter.diagnosticState,flags=event.flags,accepted=accepts()
        let result=filter.process(type:type,key:event.getIntegerValueField(.keyboardEventKeycode),flags:flags,acceptNewPress:accepted)
        if control?.role==1 {
            control?.hidAcceptance=acceptanceReason
            control?.filter(before:before,after:filter.diagnosticState,flags:flags,accepted:accepted,edge:result.edge,consumed:result.consume,matching:type == .flagsChanged)
        }
        consumed=result.consume
        control?.route=(consumed ? InputIncidentControl.Route.hidConsumed:.hidPassed).rawValue
        event.flags=result.flags
        if result.edge=="right-down"{switched(timestamp)}
        if !result.consume {forwarded(type,event,timestamp)}
        return result.consume ? nil:Unmanaged.passUnretained(event)
    }
    func start()->Bool {
        guard KeyboardStateMirror.shared.start() else{return false}
        let mask:CGEventMask=[CGEventType.flagsChanged,.keyDown,.keyUp,.leftMouseDown,.rightMouseDown].reduce(0){$0 | (1 << $1.rawValue)}
        tap=CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,event,ref in
            let gate=Unmanaged<MismatchSwitchGate>.fromOpaque(ref!).takeUnretainedValue()
            var processed=false
            let result=KeyboardStateMirror.shared.preserve(type,event) {processed=true;return gate.receiveHID(type,event)}
            if !processed,var value=InputIncidentControl.begin(gate.incidentTrace,type,event) {
                value.route=(KeyboardStateMirror.isMarker(event.getIntegerValueField(.eventSourceUserData)) ? InputIncidentControl.Route.mirrorMarker:.mirrorInactive).rawValue
                gate.incidentTrace.control(.hid,type,event,value)
            }
            return result
        },userInfo:Unmanaged.passUnretained(self).toOpaque())
        guard let tap else{return false}
        runSource=CFMachPortCreateRunLoopSource(nil,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),runSource,.commonModes)
        return true
    }
    func stop(){if let tap{CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)};if let runSource{CFRunLoopRemoveSource(CFRunLoopGetMain(),runSource,.commonModes);CFRunLoopSourceInvalidate(runSource)};tap=nil;runSource=nil}
    deinit{stop()}
}
