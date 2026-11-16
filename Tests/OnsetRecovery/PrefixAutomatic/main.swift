import AppKit
import Carbon
let args=CommandLine.arguments
let bundle=args.contains("--edge") ? "com.microsoft.edgemac":(args.contains("--safari") ? "com.apple.Safari":"com.apple.TextEdit")
let fixture=URL(fileURLWithPath:args[1]),output=URL(fileURLWithPath:args[2])
func onMain<T>(_ body:() throws->T) rethrows->T{try Thread.isMainThread ? body():DispatchQueue.main.sync(execute:body)}
enum Failure:Error{case check(String)}
final class Runner:NSObject,NSApplicationDelegate {
 let e=OnsetRecoveryEngine();var field:AXUIElement!,pid:pid_t=0;var trialWindow:AXUIElement?,menuBaseline:OnsetSnapshot?
 var selectionWrites=0,historyWrites=0,historyHeld=0;var historyStarted=false; var injected=false,delayed=false; var rows=[[String:Any]](),began=0.0,hideUntil=0.0,finished=false
 func note(_ name:String,_ extra:[String:Any]=[:]){var row=extra;row["phase"]=name;row["ms"]=(ProcessInfo.processInfo.systemUptime-began)*1000;rows.append(row)
  if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.deletingLastPathComponent().appendingPathComponent("progress.json"),options:.atomic)}
 }
 func save(_ status:String){guard !finished else{return};finished=true
  e.collectHeld();note("final",["pending":e.pending.count,"retained":e.retainedInput.count,"enabled":e.enabled,"selectionWrites":selectionWrites,"historyHeld":historyHeld,"gate":e.gate?.diagnosticState() ?? "none"])
  let retained=e.pending.count+e.retainedInput.count
  if retained>0 {
   let dir=output.deletingLastPathComponent().appendingPathComponent("held-events")
   try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
   for (i,event) in (e.pending+e.retainedInput).enumerated(){if let data=event.data {try? (data as Data).write(to:dir.appendingPathComponent("\(i).cgevent"),options:.atomic)}}
  }
  e.closeSession()
  let result:[String:Any]=["status":status,"rows":rows,"ax":AXIsProcessTrusted(),"post":CGPreflightPostEventAccess(),"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") ?? "", "physical":false,"clipboardRead":false,"clipboardWritten":false,"sourceChanged":false]
  try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output);if retained==0{NSApp.terminate(nil)}
 }
 func applicationDidFinishLaunching(_ n:Notification){
  began=ProcessInfo.processInfo.systemUptime
  note("preflight",["source":InputSourceAccess.currentID() ?? "none","ax":AXIsProcessTrusted(),"post":CGPreflightPostEventAccess(),"secure":IsSecureEventInputEnabled()])
  guard AXIsProcessTrusted(),CGPreflightPostEventAccess(),!IsSecureEventInputEnabled(),InputSourceAccess.currentID()==onsetKoreanID,
        let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else{save("preflight");return}
  pid=app.processIdentifier;app.activate(options:.activateIgnoringOtherApps)
  DispatchQueue.main.asyncAfter(deadline:.now()+0.4){self.start()}
 }
 func checkContext() throws {
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,InputSourceAccess.currentID()==onsetKoreanID,!IsSecureEventInputEnabled(),AXIsProcessTrusted(),CGPreflightPostEventAccess() else{note("context_guard",["frontMatches":NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,"sourceMatches":InputSourceAccess.currentID()==onsetKoreanID,"secure":IsSecureEventInputEnabled(),"ax":AXIsProcessTrusted(),"post":CGPreflightPostEventAccess()]);throw Failure.check("context")}
  guard let root=e.ax else{throw Failure.check("root")}
  var window=e.attr(root,kAXFocusedWindowAttribute)
  if window==nil,let prior=menuBaseline,let main=e.attr(root,kAXMainWindowAttribute),CFGetTypeID(main)==AXUIElementGetTypeID(),let original=trialWindow,CFEqual(main,original),let live=e.originalSnapshot(field),OnsetPrefixCoordinator.exact(live.text,prior.text),live.selection==prior.selection {
   window=main;note("menu_main_window_verified")
  }
  guard let window,CFGetTypeID(window)==AXUIElementGetTypeID() else{note("window_unavailable",["duringMenu":menuBaseline != nil]);throw Failure.check("window")}
  if let trialWindow,!CFEqual(window,trialWindow){throw Failure.check("changed_window")}
  if bundle=="com.apple.TextEdit" {
   guard e.attr(window as! AXUIElement,kAXDocumentAttribute) as? String==fixture.absoluteString else{throw Failure.check("fixture")}
  }else{
   guard let snap=menuBaseline != nil ? e.originalSnapshot(field):actual() else{throw Failure.check("browser_field")}
   var node:AXUIElement?=snap.element,matched=false
   for _ in 0..<16 {guard let n=node else{break};if let url=e.attr(n,kAXURLAttribute) as? URL,url.absoluteString==fixture.absoluteString{matched=true;break};if let url=e.attr(n,kAXURLAttribute) as? String,url==fixture.absoluteString{matched=true;break};node=e.attr(n,kAXParentAttribute) as! AXUIElement?}
   guard matched else{throw Failure.check("browser_fixture")}
  }
 }
 func actual()->OnsetSnapshot?{let hook=e.testSnapshot;e.testSnapshot=nil;defer{e.testSnapshot=hook};return e.snapshot()}
 func start(){
  if args.contains("--control") || args.contains("--native-control"){e.settledPrefixEnabled=false};e.prefixCoordinator.trace={[weak self] in self?.note($0)};e.start()
  e.testSetRange = { [weak self] element,range in
   guard let self else{return .failure}
   self.selectionWrites+=1
   var value=CFRange(location:range.location,length:range.length)
   let code=AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&value)!)
   self.note("product_selection_write",["range":[range.location,range.length],"code":code.rawValue,"historyStarted":self.historyStarted])
   return code
  }
  e.gate?.testAcceptedMarker=0x48414E5148495354
  e.gate?.diagnosticEvent={[weak self] type,event,consumed,_,_ in
   guard consumed else{return}
   DispatchQueue.main.async{guard let self else{return};if self.historyStarted{self.historyHeld+=1};self.note("input_held",["type":type.rawValue,"historyStarted":self.historyStarted])}
  }
  do{try checkContext();guard e.enabled,let snap=actual(),snap.text.isEmpty,snap.selection==NSRange(location:0,length:0) else{throw Failure.check("nonempty_or_unreadable")};field=snap.element;trialWindow=e.attr(e.ax!,kAXFocusedWindowAttribute) as! AXUIElement?
   e.testSnapshot={[weak self] in guard let self else{return nil};if ProcessInfo.processInfo.systemUptime<self.hideUntil{self.e.unavailableReason="text_unreadable";return nil};return self.actual()}
   var names:CFArray?;let status=AXUIElementCopyParameterizedAttributeNames(field,&names)
   note("capabilities",["parameterizedStatus":status.rawValue,"names":names as? [String] ?? [],"bundle":bundle])
   if args.contains("--capabilities"){save("capabilities");return}
   e.automaticTick();note("ready")
   DispatchQueue.global(qos:.userInitiated).async{self.run()}
  }catch{save("\(error)")}
 }
 func capture(_ phase:String) throws->OnsetSnapshot{
  try onMain{try checkContext();guard let s=actual(),CFEqual(s.element,field) else{throw Failure.check("field")};note(phase,["text":s.text,"selection":[s.selection.location,s.selection.length],"ticket":e.prefixCoordinator.transaction != nil,"keys":e.gate?.passedObservation()?.keys.count ?? 0,"proof":e.settledPrefixPublication != nil]);return s}
 }
 func wait(_ text:String,timeout:Double=1,ticket:Bool=false,selection:NSRange?=nil) throws {
  let deadline=ProcessInfo.processInfo.systemUptime+timeout
  repeat {
   let ok:Bool=try onMain{try checkContext();guard e.enabled else{throw Failure.check("engine_stopped")};guard let s=actual(),CFEqual(s.element,field) else{return false};return s.text==text && s.selection==(selection ?? NSRange(location:text.utf16.count,length:0)) && !e.recovering && (!ticket || (!e.prefixCoordinator.busy && e.prefixCoordinator.transaction == nil))}
   if ok{return};Thread.sleep(forTimeInterval:0.01)
  }while ProcessInfo.processInfo.systemUptime<deadline
  _=try capture("wait_failed");throw Failure.check("expected_body_or_caret")
 }
 func send(_ code:UInt16,_ down:Bool,text:String?=nil,flags:CGEventFlags=[]) throws {
  try onMain{try checkContext();guard e.enabled else{throw Failure.check("engine_stopped")}}
  let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=flags
  if let text{let units=Array(text.utf16);event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)}
  event.setIntegerValueField(.eventSourceUserData,value:0x48414E5148495354);event.post(tap:.cghidEventTap)
 }
 func key(_ code:UInt16,flags:CGEventFlags=[]) throws{
  try send(code,true,flags:flags);Thread.sleep(forTimeInterval:0.006);try send(code,false,flags:flags)
  if flags.contains(.maskCommand){
   try onMain{try checkContext();guard e.enabled else{throw Failure.check("engine_stopped")}}
   let release=CGEvent(keyboardEventSource:nil,virtualKey:55,keyDown:false)!;release.type = .flagsChanged;release.flags=[]
   release.setIntegerValueField(.eventSourceUserData,value:0x48414E5148495354);release.post(tap:.cghidEventTap)
  }
 }
 func click(_ rect:CGRect) throws{
  try onMain{try checkContext()}
  for type in [CGEventType.leftMouseDown,.leftMouseUp]{let ev=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:rect.midX,y:rect.midY),mouseButton:.left)!;ev.flags=[];ev.setIntegerValueField(.eventSourceUserData,value:0x48414E5148495354);ev.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.008)}
 }
 func menu(_ redo:Bool) throws{
  try onMain{try checkContext();guard let live=actual(),CFEqual(live.element,field) else{throw Failure.check("menu_origin")};menuBaseline=live}
  defer{onMain{menuBaseline=nil}}
  let edit:CGRect=try onMain{try checkContext();guard let root=e.ax,let mb=e.attr(root,kAXMenuBarAttribute),let items=e.attr(mb as! AXUIElement,kAXChildrenAttribute) as? [AXUIElement],let edit=items.first(where:{["편집","Edit"].contains(e.attr($0,kAXTitleAttribute) as? String ?? "")}),let rect=rect(edit) else{throw Failure.check("edit_menu")};return rect}
  let source=CGEventSource(stateID:.hidSystemState)
  for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp]{
   try onMain{try checkContext()}
   onMain{note("menu_header_event",["type":type.rawValue])}
   let ev=CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:CGPoint(x:edit.midX,y:edit.midY),mouseButton:.left)!
   ev.flags=[];ev.setIntegerValueField(.mouseEventClickState,value:1);ev.setIntegerValueField(.eventSourceUserData,value:0x48414E5148495354);if type == .mouseMoved{ev.post(tap:.cghidEventTap)}else{ev.postToPid(pid)}
   Thread.sleep(forTimeInterval:type == .mouseMoved ? 0.35:0.06)
  }
  Thread.sleep(forTimeInterval:0.15)
  let item:CGRect=try onMain{guard let root=e.ax,let mb=e.attr(root,kAXMenuBarAttribute),let items=e.attr(mb as! AXUIElement,kAXChildrenAttribute) as? [AXUIElement],let edit=items.first(where:{["편집","Edit"].contains(e.attr($0,kAXTitleAttribute) as? String ?? "")}),let menu=(e.attr(edit,kAXChildrenAttribute) as? [AXUIElement])?.first,let children=e.attr(menu,kAXChildrenAttribute) as? [AXUIElement],let item=children.first(where:{(e.attr($0,kAXMenuItemCmdCharAttribute) as? String)?.lowercased()=="z" && (e.attr($0,kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue==(redo ? 1:0) && e.attr($0,kAXEnabledAttribute) as? Bool==true}),let rect=rect(item) else{throw Failure.check("undo_menu")};return rect}
  try onMain{try checkContext()}
  let move=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:CGPoint(x:item.midX,y:item.midY),mouseButton:.left)!
  move.flags=[];move.setIntegerValueField(.eventSourceUserData,value:0x48414E5148495354);move.post(tap:.cghidEventTap)
  Thread.sleep(forTimeInterval:0.06)
  try click(item)

 }
 func rect(_ element:AXUIElement)->CGRect? {
  guard let p=e.attr(element,kAXPositionAttribute),let s=e.attr(element,kAXSizeAttribute),CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else{return nil}
  var point=CGPoint.zero,size=CGSize.zero
  guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size),size.width>0,size.height>0 else{return nil}
  return CGRect(origin:point,size:size)
 }
 func select(_ range:NSRange) throws {
  try onMain{try checkContext();guard e.enabled else{throw Failure.check("engine_stopped")};var r=CFRange(location:range.location,length:range.length)
   guard AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,AXValueCreate(.cfRange,&r)!) == .success else{throw Failure.check("fixture_selection_set")}}
  Thread.sleep(forTimeInterval:0.09)
  let snap=try capture("fixture_selection");guard snap.selection==range else{throw Failure.check("fixture_selection_confirm")}
 }
 func historyGuard() throws {
  guard e.enabled,!e.recovering,!e.prefixCoordinator.busy,e.prefixCoordinator.transaction==nil,
        e.pending.isEmpty,e.retainedInput.isEmpty,e.gate?.ownsInput==false,
        selectionWrites==historyWrites,historyHeld==0 else{throw Failure.check("history_interference")}
 }
 @discardableResult func stable(_ text:String,_ phase:String,_ selection:NSRange?=nil)throws->OnsetSnapshot {
  let end=ProcessInfo.processInfo.systemUptime+1.5
  var first:Double?,last:NSRange?
  repeat {
   let snap=try onMain{try checkContext();if historyStarted{try historyGuard()};guard let s=actual(),CFEqual(s.element,field) else{return nil as OnsetSnapshot?};return s}
   if let snap,OnsetPrefixCoordinator.exact(snap.text,text),snap.selection.location>=0,snap.selection.length>=0,NSMaxRange(snap.selection)<=text.utf16.count,selection==nil || snap.selection==selection {
    if last != snap.selection{last=snap.selection;first=ProcessInfo.processInfo.systemUptime}
    if let first,ProcessInfo.processInfo.systemUptime-first>=0.065{return try capture(phase)}
   }else{first=nil;last=nil}
   Thread.sleep(forTimeInterval:0.01)
  }while ProcessInfo.processInfo.systemUptime<end
  _=try capture("stable_failed");throw Failure.check("native_body_or_selection")
 }
 func command(_ redo:Bool)throws {
  try onMain{try historyGuard();note("driver_native_command",["redo":redo,"menu":args.contains("--menu")])}
  if args.contains("--menu"){try menu(redo)}else{try key(6,flags:redo ? [.maskCommand,.maskShift]:.maskCommand)}
 }
 func put(_ text:String)throws {try send(7,true,text:text);try send(7,false,text:text)}
 func history() throws {
  let before="ㄱㅏ나다라마바사 ",after="가나다라마바사 "
  let savedBefore=args.contains("--selected") ? NSRange(location:4,length:2):(args.contains("--middle") ? NSRange(location:5,length:0):NSRange(location:9,length:0))
  let savedAfter=OnsetPrefixCoordinator.mappedSelection(savedBefore,textLength:before.utf16.count)!
  if args.contains("--history-fixture") {
   try send(0,true,text:before);try send(0,false,text:before);try wait(before)
   try select(savedBefore)
   try onMain {
    try checkContext();guard let snap=actual(),snap.text==before,snap.selection==savedBefore,
       e.prefixCoordinator.supportsRangeEdit(field),e.gate?.begin()==true,
       let plan=OnsetRecoveryEngine.settledPrefixPlan(keys:[15,40,1,40,14,40,3,40,0,40,12,40,17,40,49].map{(UInt16($0),false)},text:before,selection:NSRange(location:9,length:0),sourceID:onsetKoreanID) else{throw Failure.check("fixture_claim")}
    _=e.prefixCoordinator.performClaimedEdit(plan,snap,source:onsetKoreanID)
   }
   try wait(after,ticket:true,selection:savedAfter);_=try capture("fixture_prefix")
  } else {
   let start=ProcessInfo.processInfo.systemUptime
   onMain{hideUntil=start+0.195;note("visibility_delay_195ms")}
   let codes:[UInt16]=[15,40,1,40,14,40,3,40,0,40,12,40,17,40,49]
   let downs=[0,109,228,286,414,471,583,653,774,823,942,986,1119,1169,1370]
   let ups=[108,194,287,382,449,564,640,725,821,904,1021,1084,1206,1300,1400]
   var events=[(Int,Int,Bool)]();for i in codes.indices{events.append((downs[i],i,true));events.append((ups[i],i,false))};events.sort{$0.0<$1.0}
   for (ms,i,down) in events{let delay=start+Double(ms)/1000-ProcessInfo.processInfo.systemUptime;if delay>0{Thread.sleep(forTimeInterval:delay)};try send(codes[i],down,text:i==0 ? "ㄱ":(i==1 ? "ㅏ":nil))}
   try wait(after,ticket:true);_=try capture("automatic_prefix")
  }
  try onMain{guard !e.recovering,!e.prefixCoordinator.busy,e.prefixCoordinator.transaction==nil else{throw Failure.check("initial_edit_unfinished")};historyWrites=selectionWrites;historyStarted=true;note("native_history_begins")}
  if args.contains("--idle-after-repair") {Thread.sleep(forTimeInterval:0.8);_=try stable(after,"initial_caret_after_idle",savedAfter)}
  // Native navigation ends the preceding editor typing group, as in the 407 comparison.
  try key(123);Thread.sleep(forTimeInterval:0.08)
  let selected=args.contains("--intervening-selected")
  try select(NSRange(location:4,length:selected ? 2:0))
  try put("X")
  let withX=selected ? "가나다라X사 ":"가나다라X마바사 "
  _=try stable(withX,"middle_X",NSRange(location:5,length:0))
  let count=args.contains("--ten-cycles") ? 10:3
  for cycle in 1...count {
   try command(false);_=try stable(after,"undo_X_\(cycle)",NSRange(location:4,length:selected ? 2:0))
   try command(false);_=try stable(before,"undo_prefix_\(cycle)",NSRange(location:0,length:2))
   if cycle==count && args.contains("--older-history") {
    try command(false);_=try stable("","undo_original_typing",NSRange(location:0,length:0))
    try command(true);_=try stable(before,"redo_original_typing",NSRange(location:9,length:0))
   }
   if cycle==count && args.contains("--type-after-undo") {
    try put("Y");_=try stable("Y나다라마바사 ","next_Y_after_prefix_undo",NSRange(location:1,length:0))
    try command(false);_=try stable(before,"undo_branch_Y")
    try command(true);_=try stable("Y나다라마바사 ","redo_branch_Y",NSRange(location:1,length:0))
    return
   }
   if cycle==count && args.contains("--immediate-redo") {
    try command(true)
    for code:UInt16 in [2,40,49]{try key(code)}
    _=try stable("가아 나다라마바사 ","immediate_redo_native_keys",NSRange(location:3,length:0))
    try command(false);_=try stable(after,"undo_immediate_input")
    try command(false);_=try stable(before,"undo_correction_after_immediate_input",NSRange(location:0,length:2))
    return
   }
   try command(true);_=try stable(after,"redo_prefix_\(cycle)",NSRange(location:1,length:0))
   if cycle==count && args.contains("--type-after-redo") {
    try put("Y");_=try stable("가Y나다라마바사 ","next_Y_after_prefix_redo",NSRange(location:2,length:0))
    try command(false);_=try stable(after,"undo_branch_Y")
    try command(true);_=try stable("가Y나다라마바사 ","redo_branch_Y",NSRange(location:2,length:0))
    return
   }
   try command(true);_=try stable(withX,"redo_X_\(cycle)",NSRange(location:5,length:0))
  }
  try put("Y")
  _=try stable(selected ? "가나다라XY사 ":"가나다라XY마바사 ","next_Y",NSRange(location:6,length:0))
 }
 func run(){do{try history();try onMain{try historyGuard();save("passed")}}catch{onMain{if let s=actual(),field != nil,CFEqual(s.element,field){note("failure_snapshot",["text":s.text,"selection":[s.selection.location,s.selection.length]])};save("\(error)")}}}
}
let app=NSApplication.shared;app.setActivationPolicy(.accessory);let r=Runner();app.delegate=r;app.run()
