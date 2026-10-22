import AppKit
import Carbon
// Own editor only. Each letter, Select All, Hanja and right Command goes
// through the installed app's real global tap chain; no pre-seeded body.
final class Fixture:NSObject,NSApplicationDelegate {
 let root=URL(fileURLWithPath:CommandLine.arguments[1]);var view=NSTextView(),window:NSWindow!,prior:NSRunningApplication?,original:TISInputSource?,timer:Timer?
 let delays=[0.0,0.05,0.3,0.8];var retained:[NSTextView]=[],cases:[[String:Any]]=[]
 var index=0,stage=0,started=0.0,deadline=0.0,convertedAt=0.0,requestedAt=0.0
 var preparing=false
 func source()->String {guard let s=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),let p=TISGetInputSourceProperty(s,kTISPropertyInputSourceID) else{return ""};return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String}
 func write(_ name:String,_ value:[String:Any]){do{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent(name),options:.atomic)}catch{fputs("fixture output failure\n",stderr);exit(1)}}
 func request(_ keys:[[String:Any]]){try? FileManager.default.removeItem(at:root.appendingPathComponent("done.json"));write("request.json",["pid":getpid(),"keys":keys])}
 func key(_ code:Int,_ command:Bool=false){request([["code":code,"rightCommand":command,"gap":0.0]])}
 func done()->Bool {guard let data=try? Data(contentsOf:root.appendingPathComponent("done.json")),let v=try? JSONSerialization.jsonObject(with:data) as? [String:Bool] else{return false};return v["passed"]==true}
 func applicationDidFinishLaunching(_ note:Notification){
  prior=NSWorkspace.shared.frontmostApplication;original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
  let menu=NSMenu(),edit=NSMenuItem(title:"Edit",action:nil,keyEquivalent:""),items=NSMenu(title:"Edit")
  items.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v");items.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a");edit.submenu=items;menu.addItem(edit);NSApp.mainMenu=menu
  window=NSWindow(contentRect:NSRect(x:160,y:170,width:620,height:160),styleMask:[.titled],backing:.buffered,defer:false);window.title="HanQ typed conversion and immediate right Command"
  window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);stage = -1;deadline=ProcessInfo.processInfo.systemUptime+5
  timer=Timer.scheduledTimer(withTimeInterval:0.005,repeats:true){[weak self] _ in self?.tick()}
 }
 func beginCase(){
  preparing=true;defer{preparing=false}
  guard index<delays.count else{finish(true,"all actual-typing cases completed");return}
  retained.append(view);view=NSTextView(frame:NSRect(x:0,y:0,width:620,height:160));view.isRichText=false;window.contentView=view;window.makeFirstResponder(view)
  if let sources=TISCreateInputSourceList([kTISPropertyInputSourceID as String:"com.apple.keylayout.ABC"] as CFDictionary,false)?.takeRetainedValue() as? [TISInputSource],let s=sources.first{guard ownedSelectInputSource(s)==noErr else{finish(false,"owned source guard unavailable");return}}
  started=ProcessInfo.processInfo.systemUptime;deadline=started+8;stage=0
 }
 func tick(){
  guard !preparing else{return}
  let now=ProcessInfo.processInfo.systemUptime
  if stage == -1 {guard now<deadline else{finish(false,"owned source guard unavailable");return};if ownedInputSourceChangeAllowed(){beginCase()};return}
  guard NSApp.isActive,window.firstResponder === view else{finish(false,"owned focus changed");return}
  guard now<deadline else{finish(false,"stage timeout");return}
  if stage==0,now-started>=0.35 {
   guard source()=="com.apple.keylayout.ABC" else{finish(false,"English unavailable");return}
   stage=1;request([17,40,2,37,2,45,38,3,14,46].enumerated().map{["code":$0.element,"rightCommand":false,"shift":$0.offset==0,"gap":0.01]});return
  }
  if stage==1,done(),view.string=="Tkdldnjfem" {stage=2;request([["code":0,"rightCommand":false,"commandChord":true,"gap":0.0]]);return}
  if stage==2,done(),view.selectedRange()==NSRange(location:0,length:10) {stage=3;key(61);return}
  if stage==3,view.string=="싸이월드" {convertedAt=now;stage=4;return}
  if stage==4,now-convertedAt>=delays[index] {requestedAt=now;stage=5;key(54,true);return}
  if stage==5,done(),source()=="com.apple.inputmethod.Korean.2SetKorean" {
   let elapsed=(now-requestedAt)*1000
   guard elapsed<400,view.string=="싸이월드" else{finish(false,"first toggle delayed or body changed");return}
   cases.append(["delayAfterConversionSeconds":delays[index],"firstRequestSucceeded":true,"toggleMilliseconds":elapsed,"conversionPreserved":true]);stage=6;started=now;return
  }
  if stage==6,now-started>=0.25 {index+=1;beginCase()}
 }
 func finish(_ passed:Bool,_ reason:String){
  timer?.invalidate();var restored=false
  if ownedInputSourceChangeAllowed(),let original,let p=TISGetInputSourceProperty(original,kTISPropertyInputSourceID){let expected=Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String;let status=ownedSelectInputSource(original);let end=Date().addingTimeInterval(1);while source() != expected,Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.01))};restored=status==noErr && source()==expected}
  write("result.json",["passed":passed && restored,"reason":reason,"cases":cases,"caseIndex":index,"stage":stage,"originalSourceRestored":restored,"typedViaGlobalEvents":true,"textSeededProgrammatically":false,"physicalKeys":false,"extraCleanupKeys":false,"secondToggleAttempts":0])
  if !restored,let original {_ = OwnedInputSourceCleanup(window:window,restore:{ownedSelectInputSource(original)==noErr},completed:{self.write("cleanup.json",["restoredAfterReturn":true,"originalResultUnchanged":true]);exit(1)});return}
  exit(passed && restored ? 0:1)
 }
}
@main enum ManualFixtureMain {static func main(){let app=NSApplication.shared,fixture=Fixture();app.delegate=fixture;app.run()}}
