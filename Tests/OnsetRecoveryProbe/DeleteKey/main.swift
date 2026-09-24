import AppKit
var checks=0
for down in [true,false] {
    let event=DeletionKey.make(down:down,marker:123456)!
    var buffer=[UniChar](repeating:0,count:8);var length=0
    event.keyboardGetUnicodeString(maxStringLength:8,actualStringLength:&length,unicodeString:&buffer)
    precondition(length==1 && buffer[0]==127);checks+=1
    precondition(event.getIntegerValueField(.keyboardEventKeycode)==51);checks+=1
    precondition(event.type == (down ? .keyDown:.keyUp));checks+=1
    precondition(event.getIntegerValueField(.eventSourceUserData)==123456);checks+=1
    precondition(NSEvent(cgEvent:event)?.characters=="\u{7f}");checks+=1
}
print("PASS \(checks) delete-event payload checks; target app handling not tested")

let raw=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:true)!
precondition(!DeletionKey.hasDeletePayload(raw),"raw U0008 rejected")
precondition(DeletionKey.hasDeletePayload(DeletionKey.make(down:true,marker:1)!))
print("PASS: raw delete rejected, explicit delete accepted")
