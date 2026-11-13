import AppKit
import Carbon

func runSafariActivationTests() {
    let first: [String:Any] = ["InputSourceKind":"Keyboard Layout","KeyboardLayout Name":"ABC"]
    let second: [String:Any] = ["InputSourceKind":"Input Mode","Input Mode":ko]
    check(SafariInputActivation.hasPreviousTwoSet([first,second]), "current ABC and previous two-set")
    for history in [[], [second,first], [first,first], [first, ["Input Mode":ko]]] {
        check(!SafariInputActivation.hasPreviousTwoSet(history), "ambiguous OS history cannot request a shortcut")
    }
    // Same AX role reported by the Safari recording. A native combo, a list
    // control, or a secure field must not authorize a system input switch.
    func eligible(role: String, writable: Bool = true, hasRange: Bool = true,
                  web: Bool = true, secure: Bool = false, enabled: Bool = true) -> Bool {
        var selected = CFRange(location: 0, length: 0)
        let range = AXValueCreate(.cfRange, &selected)!
        let parent = AXUIElementCreateApplication(8181)
        return SafariInputActivation.isWebEditor(field, read: { element, attribute in
            if CFEqual(element, parent) { return attribute == kAXRoleAttribute ? (web ? "AXWebArea" : "AXToolbar") as CFString : nil }
            switch attribute {
            case kAXRoleAttribute: return role as CFString
            case kAXSubroleAttribute: return secure ? kAXSecureTextFieldSubrole as CFString : nil
            case kAXEnabledAttribute: return enabled ? kCFBooleanTrue : kCFBooleanFalse
            case kAXSelectedTextRangeAttribute: return hasRange ? range : nil
            case kAXParentAttribute: return parent
            default: return nil
            }
        }, canWriteValue: { _ in writable })
    }
    check(eligible(role:kAXComboBoxRole), "editable web combo qualifies")
    check(!eligible(role:kAXComboBoxRole, writable:false) && !eligible(role:kAXComboBoxRole, hasRange:false),
          "read-only and nontext combos stay direct")
    check(!eligible(role:kAXComboBoxRole, web:false) && !eligible(role:kAXComboBoxRole, secure:true) && !eligible(role:kAXComboBoxRole, enabled:false),
          "browser toolbar, secure and disabled combos stay direct")
    check(eligible(role:kAXTextAreaRole) && eligible(role:kAXTextFieldRole) && !eligible(role:kAXButtonRole), "existing web roles")
    for scenario in ["success","movingHistory","held","unconfigured","otherField","noPrior","external","historyChanged","focusChanged","noTarget","override","retrySuccess","lateBeforeRetry","staleHistory","heldReleases","retryFocus","retryBody","retrySelection","retryLateBeforeSpace","retryPress","retryHeld"] {
        let activation = SafariInputActivation()
        let barrier = SourceSwitchBarrier()
        var id=ko, clock=1.0, past=true, currentField=field, posts=0, direct=0
        var held = ["held","heldReleases"].contains(scenario), chord=0
        var body="", range=NSRange(location:0,length:0)
        var directReasons=[String]()
        var reasons:[String]=[], work:[()->Void]=[], parked=0, replayed=0
        activation.safari = {NSRunningApplication.current}
        activation.focus = {currentField}
        activation.source = {id}
        activation.layout = {en}
        activation.override = {scenario=="override" ? "com.apple.keylayout.2SetHangul" : nil}
        activation.previousIsKorean = {past}
        activation.webEditor = {_ in eligible(role:kAXComboBoxRole)}
        activation.usedDirectSwitch = {directReasons.append($0)}
        activation.now = {clock}
        activation.failed = { stage,condition in reasons.append(stage+"."+condition) }
        activation.shortcut.configuration = {scenario=="unconfigured" ? nil : (49,.maskControl)}
        activation.shortcut.modifiersClear = {!held}
        activation.modifiersReleased = {true}
        activation.shortcut.canPost = {true}
        activation.shortcut.schedule = {_,f in work.append(f)}
        activation.shortcut.releasePosted = {_,_ in}
        activation.shortcut.post = {event in
            posts+=1
            if event.type == .keyDown { chord += 1 }
            if event.type == .keyDown && (scenario == "heldReleases" || ["success","movingHistory"].contains(scenario) || (scenario=="retrySuccess" && chord==2) || (scenario=="retryPress" && chord==3)) {
                if scenario=="movingHistory" {past=false} else {id=ko}
            }
            check(OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)), "shortcut bypasses input capture")
        }
        barrier.read = {.init(field:currentField,text:body,selection:range)}
        barrier.source = {id}
        barrier.select = {id=$0;direct+=1;return noErr}
        barrier.webActivation = {activation.select($0,field:$1)}
        barrier.selectionPending = {activation.pending}
        barrier.webActivationLimit = { activation.pendingLimit }
        barrier.cancelSelection = {activation.cancel($0)}
        barrier.didConfirmSource = {v,_ in activation.committed(v)}
        barrier.now = {clock}
        barrier.retained = {parked += $0.count}
        barrier.send = {event in replayed+=1;_=barrier.receive(event.type,event)}
        check(barrier.request(en,rightCommand:scenario != "noPrior"), "outbound boundary")
        barrier.step();barrier.step()
        check(id==en && direct==1 && !barrier.busy,"outbound stays direct")
        if scenario=="otherField" {currentField=other}
        if scenario=="external" {activation.observed("third");activation.observed(en)}
        check(barrier.request(ko,rightCommand:true), "return boundary")
        barrier.step()
        if ["unconfigured","otherField","noPrior","external","override"].contains(scenario) {
            check(id==ko && direct==2 && posts==0,"ineligible return stays direct")
            if scenario=="unconfigured" { check(directReasons==["shortcut_unavailable"], "direct shortcut condition recorded") }
            if scenario=="override" { check(directReasons==["layout_override_present"], "direct override condition recorded") }
            continue
        }
        check(activation.pending && barrier.busy && id==en,"return pending before the first space")
        check(barrier.receive(.keyDown,key(5)), "new key remains queued")
        if held {
            check(posts==0,"no chord before modifier release")
            clock+=0.52;barrier.step()
            check(activation.pending && id==en && direct==1 && parked==0,"a 520ms press stays in its original transaction")
            if scenario=="held" {
                clock+=0.24;barrier.step()
                check(!activation.pending && direct==1 && posts==0 && parked==1 && reasons==["safariModifierRelease.modifier_release_timeout"],"persistent modifier preserves pending input")
                continue
            }
            held=false;barrier.step()
        }
        clock+=0.03;barrier.step()
        if scenario=="historyChanged" {past=false}
        if scenario=="focusChanged" {currentField=other}
        while !work.isEmpty {work.removeFirst()()}
        if scenario=="movingHistory" {id=ko}
        if ["retrySuccess","noTarget","lateBeforeRetry","staleHistory","retryFocus","retryBody","retrySelection","retryLateBeforeSpace","retryPress","retryHeld"].contains(scenario) {
            if scenario=="staleHistory" {past=false}
            clock+=0.43;barrier.step()
            if scenario=="staleHistory" {
                check(reasons==["safariInputActivation.previous_source_changed"] && parked==1 && chord==1,"changed previous source rejects retry")
                continue
            }
            check(reasons==["safariInputActivation.source_switch_timeout"] && activation.pending && chord==1 && parked==0,"single missed chord leaves original queue in place")
            if scenario=="lateBeforeRetry" {id=ko}
            if scenario=="retryFocus" {currentField=other}
            if scenario=="retryBody" {body="new"}
            if scenario=="retrySelection" {range=NSRange(location:0,length:1)}
            if scenario=="retryHeld" {held=true;clock+=0.11}
            barrier.step()
            if ["retryFocus","retryBody","retrySelection","retryHeld"].contains(scenario) {
                check(!activation.pending && parked==1 && chord==1 && replayed==0,"changed context cannot send a second shortcut")
                continue
            }
            clock+=0.03;barrier.step()
            if scenario=="retryLateBeforeSpace" {id=ko}
            while !work.isEmpty {work.removeFirst()()}
            if ["noTarget","retryPress"].contains(scenario) {clock+=0.43}
            barrier.step()
            if ["noTarget","retryPress"].contains(scenario) {
                check(!activation.pending && parked==1 && replayed==0 && chord==2 && direct==1 && reasons.last=="safariActivationRetry.source_switch_timeout","second miss parks original events once")
                if scenario=="retryPress" {
                    check(barrier.request(ko,rightCommand:true),"fresh explicit request after two misses")
                    barrier.step();clock+=0.03;barrier.step();while !work.isEmpty {work.removeFirst()()};barrier.step()
                    check(id==ko && direct==1 && chord==3 && parked==1,"same-field explicit retry keeps parked input and avoids the broken direct fallback")
                }
                continue
            }
            check(id==ko && direct==1 && parked==0 && chord==(scenario=="retrySuccess" ? 2:1),"retry reaches target once, including a delayed first response")
            barrier.step();check(replayed==1,"queued original key follows target acknowledgment once")
            continue
        }
        barrier.step()
        if ["success","movingHistory","heldReleases"].contains(scenario){
            check(!activation.pending && posts==4 && direct==1 && id==ko && reasons.isEmpty && parked==0,"system switch posted once and reached target")
            barrier.step();check(replayed==1,"new key follows confirmed target")
        } else {
            let condition=scenario=="historyChanged" ? "previous_source_changed" : (scenario=="focusChanged" ? "field_changed" : "source_switch_timeout")
            check(parked==1 && replayed==0 && direct==1 && reasons==["safariInputActivation."+condition],"failed activation preserves the new key and first failing condition")
        }
    }
}
