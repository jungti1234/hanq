import AppKit

// Role admission is only the first check. Snapshot/replacement still require
// readable text, a valid text selection, and the existing edit safety checks.
enum OnsetEditableRole {
    static func supports(_ role:String)->Bool {
        [kAXTextFieldRole,kAXTextAreaRole,kAXComboBoxRole].contains(role)
    }
}
