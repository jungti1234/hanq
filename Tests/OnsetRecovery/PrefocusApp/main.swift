import AppKit
import Carbon
guard CommandLine.arguments.count==3 else{exit(2)}
let directory=URL(fileURLWithPath:CommandLine.arguments[1]),expectNormal=CommandLine.arguments[2]=="--expect-normal"
let displayModel:String={
 guard let data=try? Data(contentsOf:directory.appendingPathComponent("model.json")),
       let info=try? JSONSerialization.jsonObject(with:data) as? [String:String],
       let value=info["model"],["unpublished","display-empty","display-draft","placeholder-as-content","literal-hint-draft","first-consonant","first-consonant-empty","first-consonant-stale-lf","first-consonant-stale-hint","first-word","native-marked-stale-focus","fast-pointer-reentry","draft-reentry","late-pair-empty","late-pair-draft","late-normal-empty","late-normal-draft"].contains(value) else{return "unpublished"}
 return value
}()
let draftTrial=displayModel=="draft-reentry"
let lateTrial=displayModel.hasPrefix("late-")
let normalLate=displayModel.hasPrefix("late-normal-")
let initialPrefix=(draftTrial || (lateTrial && displayModel.hasSuffix("-draft"))) ? "기존":""
let trialCases:[LateLayoutCase]={
 if displayModel.hasPrefix("first-consonant") {
  var seen=Set<String>()
  return lateLayoutCases.compactMap{item in
   guard seen.insert(item.sourceID).inserted,let first=item.keys.first else{return nil}
   let onset=String(item.split.prefix(1))
   return LateLayoutCase(sourceID:item.sourceID,name:"first consonant/"+item.name,keys:[first],split:onset,joined:onset)
  }
 }
 var cases=lateLayoutCases
 if displayModel=="fast-pointer-reentry" {
  let keys:[(UInt16,Bool)]=[(5,false),(4,false),(2,false),(6,false),(37,false),(2,false),(49,false)]
  cases=[0.15,0.075,0.025].map{delay in LateLayoutCase(sourceID:"com.apple.inputmethod.Korean.2SetKorean",name:"hongking/\(Int(delay*1000))ms",keys:keys,split:"ㅎㅗㅇ킹 ",joined:"홍킹 ")}+cases
 }
 if lateTrial {
  let source="com.apple.inputmethod.Korean.2SetKorean"
  cases=[
   LateLayoutCase(sourceID:source,name:"ha/no-space",keys:[(5,false),(40,false)],split:"ㅎㅏ",joined:"하"),
   LateLayoutCase(sourceID:source,name:"han/no-space",keys:[(5,false),(40,false),(1,false)],split:"ㅎㅏㄴ",joined:"한"),
   LateLayoutCase(sourceID:source,name:"hana/no-space",keys:[(5,false),(40,false),(1,false),(40,false)],split:"ㅎㅏ나",joined:"하나"),
   LateLayoutCase(sourceID:source,name:"ha/space",keys:[(5,false),(40,false),(49,false)],split:"ㅎㅏ ",joined:"하 "),
   LateLayoutCase(sourceID:source,name:"hongking/no-space",keys:[(5,false),(4,false),(2,false),(6,false),(37,false),(2,false)],split:"ㅎㅗㅇ킹",joined:"홍킹"),
   LateLayoutCase(sourceID:source,name:"hongking/space",keys:[(5,false),(4,false),(2,false),(6,false),(37,false),(2,false),(49,false)],split:"ㅎㅗㅇ킹 ",joined:"홍킹 "),
   LateLayoutCase(sourceID:source,name:"ha/following-word",keys:[(5,false),(40,false),(49,false),(1,false),(40,false),(49,false)],split:"ㅎㅏ 나 ",joined:"하 나 ")
  ]
 }
 let file=directory.appendingPathComponent("case-limit.json")
 if let data=try? Data(contentsOf:file),let info=try? JSONSerialization.jsonObject(with:data) as? [String:Int],let count=info["limit"],(1...cases.count).contains(count){return Array(cases.prefix(count))}
 return cases
}()

let nativeHint="Codex와 함께 작업하세요\n"
let suffix=displayModel=="display-draft" ? " KEEP":displayModel=="literal-hint-draft" ? nativeHint:""
var fixtureWriteFailed=false,fixtureSourceRestored=false
@discardableResult func save(_ name:String,_ value:[String:Any])->Bool {
 do {
  // Foundation may raise an Objective-C exception for invalid values such as
  // NaN; validate before calling the throwing Swift wrapper.
  guard JSONSerialization.isValidJSONObject(value) else{throw NSError(domain:NSCocoaErrorDomain,code:3840)}
  let bytes=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
  try bytes.write(to:directory.appendingPathComponent(name),options:.atomic)
  return true
 }catch {
  fixtureWriteFailed=true
  let error=error as NSError,underlying=error.userInfo[NSUnderlyingErrorKey] as? NSError
  let failure:[String:Any]=["operation":"fixture_save","file":name,"domain":error.domain,"code":error.code,"underlyingDomain":underlying?.domain ?? "","underlyingCode":underlying?.code ?? 0,"sourceRestored":fixtureSourceRestored,"passed":false]
  if let bytes=try? JSONSerialization.data(withJSONObject:failure,options:[.sortedKeys]) {
   try? bytes.write(to:directory.appendingPathComponent("fixture-write-failure.json"))
  }
  return false
 }
}
func id(_ source:TISInputSource)->String{guard let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return ""};return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String}
func enabled()->[String]{(TISCreateInputSourceList(nil,false)?.takeRetainedValue() as? [TISInputSource] ?? []).filter{source in
 guard let category=TISGetInputSourceProperty(source,kTISPropertyInputSourceCategory),Unmanaged<CFString>.fromOpaque(category).takeUnretainedValue() as String == kTISCategoryKeyboardInputSource as String,let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsSelectCapable),CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()),let active=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled) else{return false};return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(active).takeUnretainedValue())
}.map(id).sorted()}
final class Group:NSView {
 override func isAccessibilityElement()->Bool{true}
 override func accessibilityRole()->NSAccessibility.Role?{.group}
 override func accessibilityChildren()->[Any]?{subviews}
}
@objc(HanQPrefocusApplication) final class OwnedApplication:NSApplication {
 var receivedDownCodes:[Int]=[],receivedUpCodes:[Int]=[],windowlessUpCodes:[Int]=[]
 var receivedScrolls=0
 override func sendEvent(_ event:NSEvent){
  if event.type == .keyDown{receivedDownCodes.append(Int(event.keyCode))}
  if event.type == .keyUp{receivedUpCodes.append(Int(event.keyCode));if event.window==nil{windowlessUpCodes.append(Int(event.keyCode))}}
  if event.type == .scrollWheel{receivedScrolls+=1}
  super.sendEvent(event)
 }
 override func accessibilityApplicationFocusedUIElement()->Any? {
  if (displayModel=="native-marked-stale-focus" || normalLate),let f=delegate as? Fixture,f.window != nil,!f.field.nativeFirstSeen{return f.outside}
  return super.accessibilityApplicationFocusedUIElement()
 }
}
final class Field:NSTextView {
 weak var fixture:Fixture?
 var nativeFirstSeen=false,nativeMarkedBeforeCommit=false
 func observeNativeMark(){if (displayModel=="native-marked-stale-focus" || normalLate),(window as? Window)?.commitObserved==false,hasMarkedText(){nativeMarkedBeforeCommit=true}}
 override func keyDown(with event:NSEvent){
  if normalLate,!nativeFirstSeen{emptyPublicationUntil=ProcessInfo.processInfo.systemUptime+0.20}
  nativeFirstSeen=true
  if lateTrial,!normalLate,let fixture,fixture.detachedSecond {
   guard Int(event.keyCode)==Int(fixture.current!.keys[1].0) else{fixture.finish("unexpected_controlled_key");return}
   fixture.detachedSecond=false
   insertText(String(fixture.current!.split.dropFirst().prefix(1)),replacementRange:selectedRange())
   inputContext?.discardMarkedText();unmarkText();return
  }
  super.keyDown(with:event);observeNativeMark()
 }

 var emptyPublicationUntil=0.0
 var emptyDisplay:String? {
  if lateTrial,ProcessInfo.processInfo.systemUptime<emptyPublicationUntil{return initialPrefix.isEmpty ? "\n":initialPrefix}
  let stale=displayModel=="first-consonant-stale-lf" || displayModel=="first-consonant-stale-hint"
  if stale && (string.isEmpty || ProcessInfo.processInfo.systemUptime<emptyPublicationUntil) {
   return displayModel=="first-consonant-stale-lf" ? "\n":nativeHint
  }
  return ["placeholder-as-content","first-consonant","first-word"].contains(displayModel) && string.isEmpty ? nativeHint:nil
 }

 // AppKit omits these attributes for a plain NSTextView. Expose the owned
 // view's actual state, matching the provider metadata required by the helper.
 override func isAccessibilityEnabled()->Bool{isEditable}
 override func isAccessibilityHidden()->Bool{isHiddenOrHasHiddenAncestor}
 override func accessibilityAttributeNames()->[NSAccessibility.Attribute]{
  Array(Set(super.accessibilityAttributeNames()+[NSAccessibility.Attribute(rawValue:"AXHidden"),.enabled]))
 }
 override func accessibilityAttributeValue(_ attribute:NSAccessibility.Attribute)->Any?{
  if let display=emptyDisplay {
   if attribute == .value{return display}
   if attribute == .numberOfCharacters{return display.utf16.count}
   if attribute == .selectedTextRange{return NSValue(range:NSRange(location:lateTrial ? initialPrefix.utf16.count:0,length:0))}
  }
  if attribute == .value,window?.firstResponder !== self{return displayModel=="unpublished" ? nil:displayModel=="display-empty" ? "FIXTURE_HINT":super.accessibilityAttributeValue(attribute)}
  if attribute == .numberOfCharacters,window?.firstResponder !== self,displayModel=="display-empty"{return 12}
  if attribute.rawValue=="AXHidden"{return isHiddenOrHasHiddenAncestor}
  if attribute == .enabled{return isEditable}
  if attribute == .selectedTextRange,window?.firstResponder !== self{return NSValue(range:(draftTrial || lateTrial) ? selectedRange():NSRange(location:displayModel=="unpublished" ? NSNotFound:0,length:0))}
  return super.accessibilityAttributeValue(attribute)
 }
 // A no-caret client may omit its selection until it becomes first responder.
 // Exercise that state explicitly instead of assuming the focused cursor was
 // already available before the first original key.
 override func accessibilitySelectedTextRange()->NSRange {
  if ProcessInfo.processInfo.systemUptime<emptyPublicationUntil{return NSRange(location:lateTrial ? initialPrefix.utf16.count:0,length:0)}
  if window?.firstResponder !== self{return (draftTrial || lateTrial) ? selectedRange():NSRange(location:displayModel=="unpublished" ? NSNotFound:0,length:0)}
  return super.accessibilitySelectedTextRange()
 }
 override func accessibilityValue()->String? {
  observeNativeMark()
  if let display=emptyDisplay{return display}
  if window?.firstResponder !== self {
   if displayModel=="unpublished"{return nil}
   if displayModel=="display-empty"{return "FIXTURE_HINT"}
  }
  return super.accessibilityValue()
 }
 override func accessibilityNumberOfCharacters()->Int {
  if let display=emptyDisplay{return display.utf16.count}
  if window?.firstResponder !== self,displayModel=="display-empty"{return 12}
  return super.accessibilityNumberOfCharacters()
 }
 override func accessibilityString(for range:NSRange)->String? {
  if let display=emptyDisplay {
   guard range.location>=0,range.length>=0,NSMaxRange(range)<=display.utf16.count else{return nil}
   return (display as NSString).substring(with:range)
  }
  return super.accessibilityString(for:range)
 }
 var focusWrites=0
 override func setAccessibilityFocused(_ focused:Bool){
  if focused{focusWrites+=1}
  // Force the original type-to-focus path. The test must prove the existing
  // same-consonant replay, not succeed through the separate focus-only helper.
  if displayModel.hasPrefix("first-consonant") || displayModel=="first-word" || displayModel=="fast-pointer-reentry" || draftTrial || lateTrial{return}
  super.setAccessibilityFocused(focused)
 }
}
final class Outside:NSView {
 weak var fixture:Fixture?
 override func mouseDown(with event:NSEvent){
  window?.makeFirstResponder(self);fixture?.pointerAt=ProcessInfo.processInfo.systemUptime
 }
 override var acceptsFirstResponder:Bool{true}
 override func isAccessibilityElement()->Bool{true}
 override func accessibilityRole()->NSAccessibility.Role?{.group}
 override func isAccessibilityFocused()->Bool{window?.firstResponder === self}
 override func keyDown(with event:NSEvent){
  guard let fixture else{return};fixture.outsideDowns+=1
  // Model only the observed first-character boundary: a committed initial is
  // inserted before focus reaches the native IME client. No user text is used.
  if displayModel=="first-consonant-stale-lf" || displayModel=="first-consonant-stale-hint" {
   fixture.field.emptyPublicationUntil=ProcessInfo.processInfo.systemUptime+0.085
  }
  if lateTrial{fixture.field.emptyPublicationUntil=ProcessInfo.processInfo.systemUptime+0.20;fixture.detachedSecond=true}
  fixture.field.insertText(String(fixture.current!.split.prefix(1)),replacementRange:NSRange(location:initialPrefix.utf16.count,length:0))
  window?.makeFirstResponder(fixture.field)
  if displayModel=="fast-pointer-reentry" {
   // The reported boundary is a committed first jamo with no live IME mark.
   fixture.controlledFirstWasMarked=fixture.field.hasMarkedText()
   fixture.field.inputContext?.discardMarkedText();fixture.field.unmarkText()
   fixture.controlledFirstIsMarked=fixture.field.hasMarkedText()
  }
 }
}
final class Window:NSWindow {
 var letterDowns=0,ups=0
 var downCodes:[Int]=[],upCodes:[Int]=[]
 var commitSawMarked=false,commitObserved=false,firstKeyAt=0.0
 override func sendEvent(_ event:NSEvent){
  if event.type == .keyDown{if letterDowns==0{firstKeyAt=ProcessInfo.processInfo.systemUptime};letterDowns+=1;downCodes.append(Int(event.keyCode))};if event.type == .keyUp{ups+=1;upCodes.append(Int(event.keyCode))}
  if event.type == .keyDown,event.keyCode==123,!commitObserved{commitObserved=true;commitSawMarked=(firstResponder as? NSTextView)?.hasMarkedText() ?? false}
  super.sendEvent(event)
 }
}
final class Fixture:NSObject,NSApplicationDelegate {
 var window:Window!,field=Field(),outside=Outside(),current:LateLayoutCase?
 var original:TISInputSource?,added:[TISInputSource]=[],originalEnabled:[String]=[]
 var index=0,rows:[[String:Any]]=[],outsideDowns=0,completed=false
 var padding:Group?,pointerAt=0.0,detachedSecond=false
 var controlledFirstWasMarked=false,controlledFirstIsMarked=false
 func later(_ delay:Double,_ body:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:body)}
 func applicationDidFinishLaunching(_ n:Notification){
  original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue();originalEnabled=enabled()
  window=Window(contentRect:NSRect(x:180,y:220,width:680,height:300),styleMask:[.titled],backing:.buffered,defer:false)
  window.title="HanQ owned first-focus IME validation"
  let root=Group(frame:NSRect(x:0,y:0,width:680,height:300));window.contentView=root
  outside.frame=NSRect(x:0,y:0,width:680,height:30);outside.fixture=self;root.addSubview(outside)
  var parent=root
  for level in 0..<30{let group=Group(frame:NSRect(x:0,y:level==0 ? 35:0,width:680,height:250));parent.addSubview(group);parent=group}
  field.frame=NSRect(x:0,y:0,width:640,height:200);field.isRichText=false;field.fixture=self;parent.addSubview(field)
  if draftTrial || !initialPrefix.isEmpty {
   let secondary=NSTextField(frame:NSRect(x:440,y:260,width:180,height:24));secondary.stringValue="OTHER OWNED EDITOR";root.addSubview(secondary)
  }
  window.makeKeyAndOrderFront(nil);window.makeFirstResponder(outside);NSApp.activate(ignoringOtherApps:true)
  guard save("ready.json",["pid":getpid(),"cases":trialCases.count,"expectNormal":expectNormal,"originalSource":original.map(id) ?? "","originalEnabled":originalEnabled]) else{finish("fixture_write_failed");return}
  // App activation is asynchronous. Wait only before the first case; any
  // focus loss after the first case begins still aborts without another key.
  let activationDeadline=ProcessInfo.processInfo.systemUptime+30
  func beginWhenActive(){
   if NSApp.isActive,self.window.isKeyWindow{self.next();return}
   if ProcessInfo.processInfo.systemUptime>=activationDeadline{self.finish("initial_activation_unavailable");return}
   NSRunningApplication.current.activate(options:[.activateAllWindows,.activateIgnoringOtherApps])
   self.window.makeKeyAndOrderFront(nil);self.later(0.1,beginWhenActive)
  }
  later(0.4,beginWhenActive)
 }
 func finish(_ reason:String){
  guard !completed else{return};completed=true
  let ownsFocus=NSApp.isActive && window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid()
  if ownsFocus{field.inputContext?.discardMarkedText()}
  let restored=ownsFocus ? (original.map{TISSelectInputSource($0)==noErr} ?? false):InputSourceAccess.currentID()==original.map(id)
  let disabled=ownsFocus ? added.map{TISDisableInputSource($0)==noErr}.allSatisfy{$0}:added.isEmpty
  let sourceOK=restored && disabled && InputSourceAccess.currentID()==original.map(id) && enabled()==originalEnabled
  fixtureSourceRestored=sourceOK
  save("results.json",["passed":!fixtureWriteFailed && reason=="completed" && rows.count==trialCases.count && rows.allSatisfy{$0["pass"] as? Bool==true} && sourceOK,"reason":reason,"activeAtFinish":NSApp.isActive,"keyWindowAtFinish":window.isKeyWindow,"frontMatchesAtFinish":NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid(),"cases":rows,"restored":sourceOK,"physicalKeys":false,"firstInsertionIsControlledFixture":!normalLate,"model":displayModel,"unfocusedSelectionUnavailable":displayModel=="unpublished","unfocusedValueUnavailable":displayModel=="unpublished","restoreParts":["sourceSelected":restored,"addedDisabled":disabled,"originalSource":original.map(id) ?? "","currentSource":InputSourceAccess.currentID(),"enabledBefore":originalEnabled,"enabledAfter":enabled()]])
  NSApp.terminate(nil)
 }
 func next(){
  guard NSApp.isActive,window.isKeyWindow else{finish("focus_lost");return}
  guard index<trialCases.count else{finish("completed");return}
  let item=trialCases[index];current=item
  field.inputContext?.discardMarkedText();field.string=initialPrefix+suffix;field.setSelectedRange(NSRange(location:initialPrefix.utf16.count,length:0));field.focusWrites=0;field.emptyPublicationUntil=0;detachedSecond=false
  if let app=NSApp as? OwnedApplication{app.receivedDownCodes=[];app.receivedUpCodes=[];app.windowlessUpCodes=[];app.receivedScrolls=0}
  outsideDowns=0;window.letterDowns=0;window.ups=0;window.downCodes=[];window.upCodes=[];window.commitSawMarked=false;window.commitObserved=false;window.firstKeyAt=0;pointerAt=0;controlledFirstWasMarked=false;controlledFirstIsMarked=false;field.nativeFirstSeen=false;field.nativeMarkedBeforeCommit=false
  window.makeFirstResponder((["native-marked-stale-focus","fast-pointer-reentry"].contains(displayModel) || normalLate) ? field:outside)
  if displayModel=="native-marked-stale-focus"{_=field.inputContext}
  let query=[kTISPropertyInputSourceID as String:item.sourceID] as CFDictionary
  guard let source=(TISCreateInputSourceList(query,true)?.takeRetainedValue() as? [TISInputSource])?.first else{finish("source_unavailable");return}
  if let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()) {
   guard TISEnableInputSource(source)==noErr else{finish("enable_failed");return};added.append(source)
  }
  guard TISSelectInputSource(source)==noErr else{finish("select_failed");return}
  if displayModel=="fast-pointer-reentry" {
   field.string="WARM";field.setSelectedRange(NSRange(location:4,length:0))
   later(0.8){
    guard NSApp.isActive,self.window.isKeyWindow else{self.finish("focus_lost");return}
    self.field.string="";self.field.setSelectedRange(NSRange(location:0,length:0))
    if self.padding==nil,let root=self.window.contentView {
     let container=Group(frame:NSRect(x:650,y:40,width:8,height:8))
     for _ in 0..<50 {
      let branch=Group(frame:NSRect(x:0,y:0,width:1,height:1));container.addSubview(branch)
      for _ in 0..<25{branch.addSubview(Group(frame:NSRect(x:0,y:0,width:1,height:1)))}
     }
     root.addSubview(container);self.padding=container
    }
    self.later(0.1){self.send(item)}
   }
  }else{
   // Existing conditions intentionally give discovery a completed tree.
   later(0.8){self.send(item)}
  }
 }
 func send(_ item:LateLayoutCase){
  guard NSApp.isActive,window.isKeyWindow,window.firstResponder === ((["native-marked-stale-focus","fast-pointer-reentry"].contains(displayModel) || normalLate) ? field:outside) else{finish("pre_key_focus_changed");return}
  try? FileManager.default.removeItem(at:directory.appendingPathComponent("keys-done.json"))
  var request:[String:Any]=["pid":getpid(),"keys":item.keys.map{["code":Int($0.0),"shift":$0.1,"gap":lateTrial ? 0.018:(displayModel=="native-marked-stale-focus" || draftTrial ? 0.12:0.025)] as [String:Any]}]
  if displayModel=="fast-pointer-reentry" {
   let point=window.convertPoint(toScreen:outside.convert(NSPoint(x:outside.bounds.midX,y:outside.bounds.midY),to:nil))
   let delay=item.name.hasPrefix("hongking/") ? (Double(item.name.split(separator:"/").last!.dropLast(2)) ?? 150)/1000:0.15
   request["click"]=["x":Double(point.x),"y":Double((NSScreen.screens.first?.frame.maxY ?? 0)-point.y),"delay":delay]
  }
  guard save("keys-request.json",request) else{finish("fixture_write_failed");return}
  let deadline=ProcessInfo.processInfo.systemUptime+6
  func poll(){
   guard NSApp.isActive,self.window.isKeyWindow else{self.finish("focus_lost");return}
   if FileManager.default.fileExists(atPath:directory.appendingPathComponent("abort.json").path){self.finish("requested_abort");return}
   if let data=try? Data(contentsOf:directory.appendingPathComponent("keys-done.json")),let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
    guard result["passed"] as? Bool==true else{self.finish("sender_aborted");return}
    self.later(0.25){self.verify(item)};return
   }
   if ProcessInfo.processInfo.systemUptime>=deadline{self.finish("sender_timeout");return};self.later(0.02,poll)
  }
  poll()
 }
 func verify(_ item:LateLayoutCase){
  guard NSApp.isActive,window.isKeyWindow else{finish("focus_lost");return}
  let expectedInput=initialPrefix+(expectNormal ? item.joined:item.split)
  let expected=expectedInput+suffix
  let caret=field.selectedRange()
  let pairs=displayModel.hasPrefix("first-consonant") ? (expectNormal ? 3:1):(displayModel=="first-word" ? item.keys.count+2:item.keys.count)
  var originalEdges=window.letterDowns==pairs && window.ups==pairs
  let codes=item.keys.map{Int($0.0)},first=codes[0]
  var replayUps=window.upCodes.filter{$0 != 123}
  if replayUps.first==first{replayUps.removeFirst()}
  let verifiedSingleReplay=window.downCodes==[first,123,first]+Array(codes.dropFirst())
   && window.upCodes.filter{$0==123}.count==1 && replayUps==codes
   && window.letterDowns==codes.count+2 && window.ups==codes.count+2
  let nativeFocus=outsideDowns==0 && field.focusWrites==1 && window.downCodes==codes && window.upCodes==codes
  var mechanism=displayModel.hasPrefix("first-consonant") ? outsideDowns==1 && field.hasMarkedText()==expectNormal
   :(displayModel=="first-word" ? outsideDowns==1 && !field.hasMarkedText()
   :(expectNormal ? outsideDowns==0 && field.focusWrites==1:outsideDowns==1 && field.focusWrites==0))
  if expectNormal,displayModel=="unpublished" {
   originalEdges=nativeFocus || verifiedSingleReplay
   mechanism=nativeFocus || (verifiedSingleReplay && outsideDowns<=1 && field.focusWrites<=1)
  }
  if expectNormal,displayModel=="native-marked-stale-focus" {
   originalEdges=verifiedSingleReplay
   mechanism=outsideDowns==0 && field.nativeMarkedBeforeCommit && field.focusWrites<=1
  }
  if displayModel=="fast-pointer-reentry" {
   originalEdges=expectNormal ? verifiedSingleReplay:(window.downCodes==codes && window.upCodes==codes)
   mechanism=outsideDowns==1 && field.focusWrites==0 && pointerAt>0 && window.firstKeyAt>=pointerAt && !field.hasMarkedText() && (NSApp as? OwnedApplication)?.receivedScrolls==0
  }
  var observedReplayKeys=0
  var verifiedObservedReplay=false
  if codes.count>=2,let index=window.downCodes.firstIndex(of:123),(2...codes.count).contains(index) {
   let expectedCodes=Array(codes.prefix(index))+[123]+Array(codes.prefix(index))+Array(codes.dropFirst(index))
   observedReplayKeys=index
   verifiedObservedReplay=window.downCodes==expectedCodes && window.upCodes==expectedCodes
    && window.letterDowns==codes.count+index+1 && window.ups==codes.count+index+1
  }
  if draftTrial {
   originalEdges=verifiedSingleReplay
   mechanism=outsideDowns==1 && field.focusWrites==0 && (NSApp as? OwnedApplication)?.receivedScrolls==0
  }
  if lateTrial {
   originalEdges=(normalLate || !expectNormal) ? window.downCodes==codes && window.upCodes==codes:verifiedObservedReplay
   // The verified empty-field helper may make one refused focus request.
   // Outside delivery/normal-native routing below proves it did not replace the trial.
   mechanism=outsideDowns==(normalLate ? 0:1) && field.focusWrites<=(initialPrefix.isEmpty ? 1:0)
    && field.hasMarkedText()==(expectNormal && codes.last != 49) && (NSApp as? OwnedApplication)?.receivedScrolls==0
  }
  let pass=field.string==expected && caret==NSRange(location:expectedInput.utf16.count,length:0) && originalEdges && mechanism && InputSourceAccess.currentID()==item.sourceID
  rows.append(["source":item.sourceID,"name":item.name,"initialPrefix":initialPrefix,"observedReplayKeys":observedReplayKeys,"verifiedObservedReplay":verifiedObservedReplay,"pass":pass,"text":field.string,"expected":expected,"caret":[caret.location,caret.length],"outsideDowns":outsideDowns,"markedText":field.hasMarkedText(),"focusRequests":field.focusWrites,"originalDowns":window.letterDowns,"originalUps":window.ups,"expectedOriginalPairs":item.keys.count,"verifiedSingleReplay":verifiedSingleReplay,"commitSawMarked":window.commitSawMarked,"nativeMarkedBeforeCommit":field.nativeMarkedBeforeCommit,"nativeFocus":nativeFocus,"downCodes":window.downCodes,"upCodes":window.upCodes,"applicationDownCodes":(NSApp as? OwnedApplication)?.receivedDownCodes ?? [],"applicationUpCodes":(NSApp as? OwnedApplication)?.receivedUpCodes ?? [],"windowlessUpCodes":(NSApp as? OwnedApplication)?.windowlessUpCodes ?? [],"receivedScrolls":(NSApp as? OwnedApplication)?.receivedScrolls ?? -1,"controlledFirstWasMarked":controlledFirstWasMarked,"controlledFirstIsMarked":controlledFirstIsMarked,"pointerObserved":pointerAt>0,"firstKeyAfterPointerMS":pointerAt>0 ? (window.firstKeyAt-pointerAt)*1000:0])
  guard save("progress.json",["cases":rows]) else{finish("fixture_write_failed");return}
  guard pass else{finish("first_failure");return}
  index+=1;later(0.1){self.next()}
 }
}
let app=OwnedApplication.shared,delegate=Fixture();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
