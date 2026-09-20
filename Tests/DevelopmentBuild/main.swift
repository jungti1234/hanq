import AppKit
import ObjectiveC

// Check the runtime entry points without opening test windows, installing an
// event tap, or starting the app delegate's permission/login initialization.
let selectors = ["testJamoRepair", "testHanjaSource", "testHanjaRepair"]
for name in selectors {
    let present = class_getInstanceMethod(AppDelegate.self, NSSelectorFromString(name)) != nil
    #if HANQ_DEVELOPMENT
    precondition(present, "Development build must preserve manual test action: \(name)")
    #else
    precondition(!present, "Normal build must exclude manual test action: \(name)")
    #endif
}
print("PASS: manual test actions have the expected runtime availability")
