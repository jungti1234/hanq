import AppKit
import Carbon

// Synthetic text only. Delayed AX role publication leaves the actual IME and
// native editor unchanged, exercising a stale outside-editor observation.
guard CommandLine.arguments.count==2,!CommandLine.arguments[1].hasPrefix("--") else{exit(0)}
let directory=URL(fileURLWithPath:CommandLine.arguments[1])
func save(_ name:String,_ value:[String:Any]){try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(name),options:.atomic)}
func sourceID(_ source:TISInputSource)->String{guard let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return ""};return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String}
func enabledSources()->[String]{
 (TISCreateInputSourceList(nil,false)?.takeRetainedValue() as? [TISInputSource] ?? []).filter{source in
  guard let category=TISGetInputSourceProperty(source,kTISPropertyInputSourceCategory),
        Unmanaged<CFString>.fromOpaque(category).takeUnretainedValue() as String == kTISCategoryKeyboardInputSource as String else{return false}
  guard let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsSelectCapable) else{return false}
  return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
 }.map(sourceID).sorted()
}
final class Field:NSTextView {
 var staleRole=false
 var downs:[[String:Any]]=[]
 override func accessibilityRole()->NSAccessibility.Role?{staleRole ? .button:super.accessibilityRole()}
 override func keyDown(with event:NSEvent){
  staleRole=false
  let before=string,range=selectedRange(),wasMarked=hasMarkedText()
  super.keyDown(with:event)
  downs.append(["code":Int(event.keyCode),"tag":event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,"before":before,"after":string,"selected_before":[range.location,range.length],"marked_before":wasMarked,"marked_after":hasMarkedText()])
 }
}
final class AuditWindow:NSWindow {
 var downs:[[String:Any]]=[]
 override func sendEvent(_ event:NSEvent){
  if event.type == .keyDown{downs.append(["code":Int(event.keyCode),"tag":event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0])}
  super.sendEvent(event)
 }
}
final class Fixture:NSObject,NSApplicationDelegate {
 struct Trial {let source:String,name:String,stale:Bool,keys:[(UInt16,Bool)],expected:String,requireCommit:Bool}
 var trials:[Trial]=[],rows:[[String:Any]]=[],index=0
 var window:AuditWindow!,field=Field(),original:TISInputSource?,added:[TISInputSource]=[],initialEnabled:[String]=[]
 let prefix="앞🙂 ",suffix="뒤"
 func later(_ seconds:Double,_ body:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:body)}
 func applicationDidFinishLaunching(_ notification:Notification){
  original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue();initialEnabled=enabledSources()
  for stale in [false,true]{for item in lateLayoutCases{trials.append(.init(source:item.sourceID,name:item.name,stale:stale,keys:item.keys,expected:item.joined,requireCommit:false))}}
  let full:[(UInt16,Bool)]=[(2,false),(4,false),(37,false),(1,false),(13,true),(4,false),(15,false),(15,false),(4,false),(40,false),(49,false),(2,false),(4,false),(3,false),(46,false),(1,false),(13,true),(4,false),(15,false),(2,false),(46,false),(3,false),(49,false),(2,false),(4,false),(15,false),(40,false),(0,false),(32,false),(49,false),(5,false),(4,false),(40,false),(15,false),(2,false),(37,false),(1,false),(5,false),(40,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false)]
  for round in 0..<4{trials.insert(.init(source:KoreanKeyboardLayout.twoSetID,name:"normal composition with stale AX role \(round)",stale:true,keys:full,expected:"왼쪽과 오른쪽을 오가며 확인합니다.",requireCommit:true),at:round)}
  window=AuditWindow(contentRect:NSRect(x:130,y:220,width:740,height:300),styleMask:[.titled],backing:.buffered,defer:false)
  window.title="HanQ owned active composition regression"
  window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  save("ready.json",["pid":getpid(),"cases":trials.count,"initial_source":original.map(sourceID) ?? "","enabled":initialEnabled])
  later(0.4){self.next()}
 }
 func finish(_ reason:String){
  field.inputContext?.discardMarkedText()
  let selected=original.map{TISSelectInputSource($0)==noErr} ?? false
  let disabled=added.map{TISDisableInputSource($0)==noErr}.allSatisfy{$0}
  let restored=selected && disabled && InputSourceAccess.currentID()==original.map(sourceID) && enabledSources()==initialEnabled
  let passed=reason=="completed" && rows.count==trials.count && rows.allSatisfy{$0["pass"] as? Bool==true} && restored
  save("results.json",["passed":passed,"reason":reason,"cases":rows,"physical_keys":false,"stale_ax_role_injected":true,"restored":restored,"restored_source":InputSourceAccess.currentID(),"enabled_after":enabledSources()])
  NSApp.terminate(nil)
 }
 func send(_ keys:[(UInt16,Bool)],_ done:@escaping()->Void){
  guard NSApp.isActive,window.isKeyWindow else{finish("focus_lost");return}
  try? FileManager.default.removeItem(at:directory.appendingPathComponent("keys-done.json"))
  save("keys-request.json",["pid":getpid(),"keys":keys.map{["code":Int($0.0),"shift":$0.1,"gap":0.004] as [String:Any]}])
  let deadline=ProcessInfo.processInfo.systemUptime+8
  func poll(){
   guard NSApp.isActive,window.isKeyWindow else{finish("focus_lost");return}
   if let data=try? Data(contentsOf:directory.appendingPathComponent("keys-done.json")),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
    guard value["passed"] as? Bool==true else{finish("sender_aborted");return};done();return
   }
   guard ProcessInfo.processInfo.systemUptime<deadline else{finish("sender_timeout");return};later(0.01,poll)
  };poll()
 }
 func next(){
  guard index<trials.count else{finish("completed");return}
  guard NSApp.isActive,window.isKeyWindow else{finish("focus_lost");return}
  let item=trials[index];index+=1
  let query=[kTISPropertyInputSourceID as String:item.source] as CFDictionary
  guard let source=(TISCreateInputSourceList(query,true)?.takeRetainedValue() as? [TISInputSource])?.first else{finish("source_missing");return}
  if !enabledSources().contains(item.source){guard TISEnableInputSource(source)==noErr else{finish("source_enable_failed");return};added.append(source)}
  field.inputContext?.discardMarkedText();field.removeFromSuperview();field=Field(frame:NSRect(x:20,y:20,width:700,height:260));field.isRichText=false;field.isAutomaticTextReplacementEnabled=false;field.isAutomaticSpellingCorrectionEnabled=false
  window.contentView!.addSubview(field);window.makeFirstResponder(field);_=field.inputContext
  field.string=prefix+suffix;field.setSelectedRange(NSRange(location:prefix.utf16.count,length:0))
  guard TISSelectInputSource(source)==noErr else{finish("source_selection_failed");return}
  later(0.2){self.send([(49,false),(51,false)]){self.later(0.1){
   self.field.inputContext?.discardMarkedText();self.field.string=self.prefix+self.suffix;self.field.setSelectedRange(NSRange(location:self.prefix.utf16.count,length:0))
   self.field.downs=[];self.window.downs=[];self.field.staleRole=item.stale
   self.later(0.4){
    guard self.field.string==self.prefix+self.suffix,self.field.selectedRange()==NSRange(location:self.prefix.utf16.count,length:0),InputSourceAccess.currentID()==item.source else{self.finish("invalid_precondition");return}
    self.send(item.keys){self.verify(item,deadline:ProcessInfo.processInfo.systemUptime+5,stable:nil)}
   }
  }}}
 }
 func verify(_ item:Trial,deadline:Double,stable:Double?){
  guard NSApp.isActive,window.isKeyWindow else{finish("focus_lost");return}
  let expected=prefix+item.expected+suffix,caret=prefix.utf16.count+item.expected.utf16.count
  let now=ProcessInfo.processInfo.systemUptime
  let exact=field.string==expected && field.selectedRange()==NSRange(location:caret,length:0) && InputSourceAccess.currentID()==item.source
  let began=exact ? (stable ?? now):nil
  if now<deadline && (!exact || now-(began ?? now)<0.12){later(0.02){self.verify(item,deadline:deadline,stable:began)};return}
  let repairs=window.downs.filter{(UInt64(bitPattern:$0["tag"] as? Int64 ?? 0)>>32)==0x48414e51}
  let commits=repairs.filter{$0["code"] as? Int==123}
  var removedPrefix=false
  let logical=window.downs.compactMap{event->Int? in
   guard let code=event["code"] as? Int else{return nil}
   let repair=(UInt64(bitPattern:event["tag"] as? Int64 ?? 0)>>32)==0x48414e51
   if repair,code==123{return nil}
   if repair,!commits.isEmpty,!removedPrefix,code==Int(item.keys[0].0){removedPrefix=true;return nil}
   return code
  }
  let commitCheck = !item.requireCommit || (commits.count==1 && field.downs.contains{event in
   let repair=(UInt64(bitPattern:event["tag"] as? Int64 ?? 0)>>32)==0x48414e51
   return repair && event["code"] as? Int==Int(item.keys[0].0) && event["marked_before"] as? Bool==false
  })
  let pass=exact && logical==item.keys.map{Int($0.0)} && commitCheck
  rows.append(["name":item.name,"source":item.source,"stale_role":item.stale,"expected":expected,"actual":field.string,"selection":[field.selectedRange().location,field.selectedRange().length],"expected_codes":item.keys.map{Int($0.0)},"logical_codes":logical,"commit_count":commits.count,"commit_exercised":commitCheck,"received":field.downs,"pass":pass])
  save("progress.json",["completed":index,"cases":rows])
  if !pass{finish("first_failure");return};later(0.05){self.next()}
 }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular);let fixture=Fixture();app.delegate=fixture;app.run()
