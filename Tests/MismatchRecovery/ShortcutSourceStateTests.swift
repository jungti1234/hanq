import AppKit

func runShortcutSourceStateTests() {
    let owner=MismatchSourceSwitch(),marker:Int64=0x48414E514155544F
    let first=owner.shortcutEvents(marker:marker)!,second=owner.shortcutEvents(marker:marker)!
    let events=first+second
    let states=Set(events.map{$0.getIntegerValueField(.eventSourceStateID)})
    probeTestCheck(states.count==1,"all shortcut presses and releases share one Quartz state")
    probeTestCheck(!states.contains(Int64(CGEventSourceStateID.combinedSessionState.rawValue)) && !states.contains(Int64(CGEventSourceStateID.hidSystemState.rawValue)),"shortcut state remains independent of physical keyboard")
    probeTestCheck(first.map{$0.type} == [.flagsChanged,.keyDown,.keyUp,.flagsChanged],"complete control-space press/release order")
    probeTestCheck(first.map{$0.getIntegerValueField(.keyboardEventKeycode)} == [59,49,49,59],"each synthetic down has matching release")
    probeTestCheck(events.allSatisfy{$0.getIntegerValueField(.eventSourceUserData)==marker},"all four phases bypass ordinary detection")
    probeTestCheck(first.last?.flags.isEmpty==true,"last phase releases Control")
    print("PASS: 6 real Quartz shortcut source-state checks; shared private press/release identity")
}
