import AppKit

// CGEvent's default keyCode 51 payload is U+0008; this target previously
// inserted that payload instead of deleting. Supply macOS backward-delete
// text U+007F explicitly while retaining physical keyCode 51.
enum OnsetDeletionKey {
    static func hasDeletePayload(_ event:CGEvent)->Bool {
        var length=0
        var value:UniChar=0
        event.keyboardGetUnicodeString(maxStringLength:1,actualStringLength:&length,unicodeString:&value)
        return length==1 && value==0x7f
    }
    static func make(down:Bool,marker:Int64)->CGEvent? {
        guard let event=CGEvent(keyboardEventSource:CGEventSource(stateID:.hidSystemState),virtualKey:51,keyDown:down) else{return nil}
        var character:UniChar=0x7f
        event.keyboardSetUnicodeString(stringLength:1,unicodeString:&character)
        event.flags=[]
        event.setIntegerValueField(.eventSourceUserData,value:marker)
        return event
    }
}
