import AppKit
var checks=0
func check(_ value:Bool,_ message:String){checks+=1;if !value{print("FAIL",message);exit(1)}}
let arguments=ProcessInfo.processInfo.arguments
let traceExpected=arguments.contains("--trace-onset-focus")
guard let index=arguments.firstIndex(of:"--diagnose-input"),index+1<arguments.count else{exit(2)}
let file=URL(fileURLWithPath:arguments[index+1])
check(InputDiagnostics.shared.isEnabled,"explicit private test sink opened")
let engine=OnsetRecoveryEngine()
engine.unavailableReason="PRIVATE_FOCUS_TEXT"
engine.lastText="PRIVATE_FOCUS_TEXT"
var reads=0
engine.focusHandoff.read={_,_ in reads+=1;return nil}
engine.focusHandoff.batch={_,_ in reads+=1;return []}
engine.focusHandoff.frontPID={reads+=1;return nil}
engine.focusHandoff.ready={reads+=1;return false}
let event=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!
let eventData=event.data,before=(try? Data(contentsOf:file)) ?? Data()
engine.prepareFocusForFirstInput(.keyDown,event)
check(event.data==eventData,"original event unchanged")
check(((try? Data(contentsOf:file)) ?? Data())==before,"key callback has no diagnostic file write")
check(reads==0,"diagnostic key path issues no added reads")
engine.flushFocusHandoffDiagnostics()
let content=(try? String(contentsOf:file,encoding:.utf8)) ?? ""
check(reads==0,"idle diagnostics issue no AX or source reads")
check(!content.contains("PRIVATE_FOCUS_TEXT") && !content.contains("com.openai") && !content.contains("keycode") && !content.contains("sourceID"),"no body, application identity or key/source values")
check(content.contains("onset.focus_idle")==traceExpected,"focus trace requires explicit opt-in")
check(content.contains("onset.focus_key")==traceExpected,"decision trace requires explicit opt-in and idle flush")
engine.flushFocusHandoffDiagnostics()
check(((try? String(contentsOf:file,encoding:.utf8)) ?? "")==content,"unchanged trace is coalesced")
print("PASS \(checks) focus diagnostic opt-in, no callback writes/added reads, unchanged event and content-free idle flush checks; no OS keys")
