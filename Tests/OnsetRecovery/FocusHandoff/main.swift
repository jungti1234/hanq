import AppKit
var checks=0,failures=0
func check(_ value:Bool,_ message:String){checks+=1;if !value{failures+=1;print("FAIL",message)}}
final class Case {
 let h:OnsetFocusHandoff
 let app=AXUIElementCreateApplication(9001),root=AXUIElementCreateApplication(9002)
 let field=AXUIElementCreateApplication(9100),outside=AXUIElementCreateApplication(9200),other=AXUIElementCreateApplication(9300)
 var rangeCalls=0,proofChanged=false,proofHasDraft=false
 var nodes:[AXUIElement]=[],focused:AXUIElement!,clock=10.0,source="ko",writes=0,slow=false,draftChanged=false
 let mode:String
 init(_ mode:String,h:OnsetFocusHandoff=OnsetFocusHandoff()){self.h=h;self.mode=mode;focused=outside
  let depth=mode=="too_deep" ? 42:31
  nodes=[root]+(0..<depth).map{AXUIElementCreateApplication(pid_t(10000+$0))}+[field]
  h.nodeLimit=mode=="dense_probe" || mode=="dense_ambiguous" ? 16384:2048
  h.sceneCacheEnabled=mode=="cache"
  h.restoreTimeout={_ in};h.diagnosticsEnabled=true
  h.now={self.clock};h.ready={!["secure_input","permission"].contains(self.mode)}
  h.frontPID={self.mode=="target_changed" ? 43:42};h.owner={_ in self.mode=="owner" ? 43:42}
  h.read={e,n in if self.slow{self.clock+=0.003};return self.read(e,n)}
  h.batch={e,names in if self.slow{self.clock+=0.031};return names.map{self.read(e,$0)}}
  h.rangeText={_,range in
   self.rangeCalls+=1
   if self.mode.hasPrefix("known_hint") {
    if range.length==0{return (.success,"")}
    if self.mode=="known_hint_timeout"{return (.cannotComplete,nil)}
    if self.mode=="known_hint_clamped"{return (.success,"")}
    if self.mode=="known_hint_changed"{self.proofChanged=true}
    return (.success,"C")
   }
   guard self.mode.hasPrefix("display_") else{return (.parameterizedAttributeUnsupported,nil)}
   if range.length==0{return self.mode=="display_bad_zero" ? (.noValue,nil):(.success,"")}
   if self.mode=="display_change"{self.proofChanged=true}
   if self.mode=="display_actual" || self.proofHasDraft{return (.success,"X")}
   if self.mode=="display_timeout"{return (.cannotComplete,nil)}
   if self.mode=="display_unsupported"{return (.parameterizedAttributeUnsupported,nil)}
   if self.mode=="display_clamped"{return (.success,"")}
   if self.mode=="display_wrong_type"{return (.success,nil)}
   return (self.mode=="display_no_value" ? .noValue:.illegalArgument,nil)
  }
  h.children={_ in self.mode=="unreadable_tree" ? nil:[]}
  h.writable={_,attribute in self.mode != "unwritable" && !(["unknown_readonly_range","absent_value_readonly"].contains(self.mode) && attribute==kAXSelectedTextRangeAttribute)}
  h.focus={e in self.writes+=1;check(CFEqual(e,self.field),"only discovered field gets focus")
   if self.mode != "unconfirmed"{self.focused=self.field}
   return self.mode=="ambiguous_ack" ? .cannotComplete:.success
  }
  for _ in 0..<(mode.hasPrefix("dense_") ? 64:10){h.advance(window:root,outside:outside)}
 }
 func range(_ location:Int,_ length:Int)->CFTypeRef {var value=CFRange(location:location,length:length);return AXValueCreate(.cfRange,&value)!}
 func read(_ e:AXUIElement,_ name:String)->CFTypeRef? {
  if CFEqual(e,app){
   if name==kAXFocusedWindowAttribute{return mode=="window_changed" ? other:root}
   if name==kAXFocusedUIElementAttribute{return mode=="system_focus" ? other:focused}
   return nil
  }
  if name==kAXWindowAttribute{return root}
  if name=="AXHidden"{return NSNumber(value:mode=="hidden" && CFEqual(e,field))}
  if name==kAXEnabledAttribute{return NSNumber(value:mode != "disabled")}
  if name==kAXSubroleAttribute{return (mode=="secure_field" ? kAXSecureTextFieldSubrole:"") as CFString}
  if mode.hasPrefix("known_hint") {
   let hint="Codex와 함께 작업하세요"+(mode=="known_hint_lf" ? "\n":mode=="known_hint_suffix" ? " USER_TEXT":"")
   if name==kAXValueAttribute{return (proofChanged ? "CHANGED":hint) as CFString}
   if name==kAXNumberOfCharactersAttribute{return NSNumber(value:hint.utf16.count+(mode=="known_hint_count" ? 1:0))}
   if name==kAXSelectedTextRangeAttribute {
    return range(mode=="known_hint_unknown" ? NSNotFound:0,mode=="known_hint_selection" ? 1:0)
   }
  }
  if name==kAXValueAttribute,mode.hasPrefix("display_"){return (proofChanged ? "CHANGED_VALUE":"PRIVATE_HINT") as CFString}
  if name==kAXSelectedTextRangeAttribute,mode=="display_unknown"{return range(NSNotFound,0)}
  if name==kAXSelectedTextRangeAttribute,mode=="display_selection"{return range(0,1)}
  if name==kAXNumberOfCharactersAttribute,mode.hasPrefix("display_"){return mode=="display_bool_count" ? kCFBooleanTrue:NSNumber(value:12)}
  if name==kAXValueAttribute,mode.hasPrefix("absent_value"){return nil}
  if name==kAXValueAttribute,mode=="null_value_no_range"{return kCFNull}
  if name==kAXValueAttribute,mode=="wrong_value_type_no_range"{return NSNumber(value:0)}
  if name==kAXValueAttribute,mode=="attributed_empty_no_range"{return NSAttributedString(string:"")}
  if name==kAXValueAttribute,mode=="attributed_draft_no_range"{return NSAttributedString(string:"PRIVATE_DRAFT")}
  if name==kAXValueAttribute{return (mode=="draft" || mode=="unknown_draft" || mode.hasPrefix("hint_") || draftChanged ? "PRIVATE_DRAFT":mode=="terminal_lf" || mode=="unknown_lf" ? "\n":"") as CFString}
  if name=="AXPlaceholderValue",mode=="hint_placeholder"{return "PRIVATE_DRAFT" as CFString}
  if name==kAXDescriptionAttribute,mode=="hint_description"{return "PRIVATE_DRAFT" as CFString}
  if name==kAXTitleAttribute,mode=="hint_mismatch"{return "OTHER_HINT" as CFString}
  if name==kAXNumberOfCharactersAttribute {
   if ["unknown_count_missing","absent_value_count_missing"].contains(mode){return nil}
   if ["unknown_count_bool","absent_value_count_bool"].contains(mode){return kCFBooleanFalse}
   if ["unknown_count_fraction","absent_value_count_fraction"].contains(mode){return NSNumber(value:0.5)}
   return NSNumber(value:["unknown_count_mismatch","absent_value_nonzero"].contains(mode) ? 1:0)
  }
  if name==kAXSelectedTextRangeAttribute,mode.hasSuffix("_no_range"){return nil}
  if name==kAXSelectedTextRangeAttribute,mode=="absent_value_notfound"{return range(NSNotFound,0)}
  if name==kAXSelectedTextRangeAttribute,mode=="absent_value_bad_range"{return range(1,0)}
  if name==kAXSelectedTextRangeAttribute,mode.hasPrefix("unknown_") {
   if mode=="unknown_missing_range"{return nil}
   if mode=="unknown_wrong_range_type"{return "invalid" as CFString}
   return range(NSNotFound,0)
  }
  if name==kAXSelectedTextRangeAttribute{return range(mode=="terminal_lf" ? 1:0,mode=="selection" ? 1:0)}
  if name==kAXRoleAttribute {
   if CFEqual(e,field) || CFEqual(e,other){return kAXTextAreaRole as CFString}
   if CFEqual(e,outside){return (mode=="button_outside" ? kAXButtonRole:mode=="editor_outside" ? kAXTextFieldRole:kAXGroupRole) as CFString}
   return (CFEqual(e,root) ? kAXWindowRole:kAXGroupRole) as CFString
  }
  if name==kAXChildrenAttribute,mode.hasPrefix("dense_") {
   let groups=(0..<9).map{AXUIElementCreateApplication(pid_t(40000+$0))}
   if CFEqual(e,root){return ([nodes[1]]+groups+(mode=="dense_ambiguous" ? [other]:[])) as CFArray}
   if let g=groups.firstIndex(where:{CFEqual($0,e)}){return (0..<256).map{AXUIElementCreateApplication(pid_t(50000+g*256+$0))} as CFArray}
  }
  if name==kAXChildrenAttribute {
   if mode=="unreadable_tree",CFEqual(e,nodes[2]){return nil}
   if mode=="ambiguous",CFEqual(e,root){return [nodes[1],other] as CFArray}
   if mode=="truncated",CFEqual(e,root){return (0..<513).map{AXUIElementCreateApplication(pid_t(12000+$0))} as CFArray}
   if let i=nodes.firstIndex(where:{CFEqual($0,e)}),i+1<nodes.count{return [nodes[i+1]] as CFArray}
   return [] as CFArray
  }
  return nil
 }
 func attempt(_ type:CGEventType = .keyDown,_ code:UInt16=15,_ flags:CGEventFlags=[])->Bool {
  let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:type == .keyDown)!
  event.type=type;event.flags=flags;event.timestamp=123456
  event.setIntegerValueField(.eventTargetUnixProcessID,value:mode=="event_pid" ? 43:mode=="unreported_pid" || mode=="unreported_without_system" ? 0:42)
  if mode=="repeat"{event.setIntegerValueField(.keyboardEventAutorepeat,value:1)}
  if mode=="replay"{event.setIntegerValueField(.eventSourceUserData,value:Int64(bitPattern:0x48414E5100000001))}
  if mode=="manual"{event.setIntegerValueField(.eventSourceUserData,value:SyntheticInputMarker.manualEdit)}
  if mode=="stale"{clock+=1}
  if mode=="source"{source="other"}
  if mode=="deadline"{slow=true}
  if mode=="editor_outside"{focused=outside}
  if mode=="changed_outside"{focused=nodes[2]}
  let data=event.data
  let accepted=h.prepare(type,event,application:app,pid:42,sourceID:"ko",currentSource:{self.source},normal:[15],shifted:[15],systemFocus:["system_focus","unreported_pid"].contains(mode) ? {self.focused}:nil)
  check(event.data==data,"original event data never changed: \(mode)")
  return accepted
 }
}
for mode in ["normal","terminal_lf","ambiguous_ack","system_focus","unreported_pid"] {
 let c=Case(mode);check(c.h.candidate != nil,"deep complete tree discovers unique empty editor: \(mode)")
 check(c.writes==0,"discovery never changes focus")
 check(c.attempt(),"actual focus acknowledgment accepted: \(mode)");check(c.writes==1,"one focus request")
 check(!c.attempt() && c.writes==1,"same outside episode never retries")
}
for mode in ["draft","selection","ambiguous","hidden","secure_field","unwritable","disabled","unreadable_tree","too_deep","truncated","window_changed","target_changed","owner","source","permission","secure_input","button_outside","editor_outside","changed_outside","stale","deadline","event_pid","unreported_without_system","repeat","replay","manual"] {
 let c=Case(mode);check(!c.attempt(),"unsafe/unsupported context declined: \(mode)");check(c.writes==0,"unsafe context has no focus write: \(mode)")
}
for mode in ["unknown_missing_range","unknown_notfound_range","unknown_readonly_range"] {
 let c=Case(mode);check(c.h.candidate != nil,"zero-character unfocused editor prepared: \(mode)")
 check(c.attempt() && c.writes==1,"empty editor needs no pre-focus caret or selection write: \(mode)")
 check(!c.h.diagnosticState.contains("PRIVATE_DRAFT"),"fixed diagnostic state has no content")
}
for mode in ["unknown_draft","unknown_lf","unknown_count_missing","unknown_count_mismatch","unknown_count_bool","unknown_wrong_range_type"] {
 let c=Case(mode);check(!c.attempt() && c.writes==0,"unknown caret requires independently proved zero characters: \(mode)")
}
for mode in ["absent_value","absent_value_no_range","absent_value_notfound","absent_value_readonly","null_value_no_range","attributed_empty_no_range"] {
 let c=Case(mode);check(c.h.candidate != nil,"independent zero count proves unpublished empty value: \(mode)")
 check(c.attempt() && c.writes==1,"unpublished empty client receives focus only: \(mode)")
 check(!c.h.diagnosticState.contains("PRIVATE_DRAFT"),"value type/shape diagnosis never includes content")
}
for mode in ["absent_value_nonzero","absent_value_count_missing","absent_value_count_bool","absent_value_count_fraction","absent_value_bad_range","wrong_value_type_no_range","attributed_draft_no_range","unknown_count_fraction"] {
 let c=Case(mode);check(!c.attempt() && c.writes==0,"unpublished/contradictory value never guesses an empty body: \(mode)")
 check(!c.h.diagnosticState.contains("PRIVATE_DRAFT"),"refusal metadata remains content-free")
}
for (mode,kind,relation) in [("hint_placeholder",1,1),("hint_description",2,1),("hint_mismatch",3,2)] {
 let c=Case(mode)
 check(c.h.candidate==nil && !c.attempt() && c.writes==0,"hint equality alone never authorizes focus: \(mode)")
 let state=c.h.diagnosticState
 check(state.contains("caretKind=1") && state.contains("hintRelation=\(relation)") && state.contains("hintKind=\(kind)"),"idle fixed metadata compares without publishing hints")
 check(!state.contains("PRIVATE_DRAFT") && !state.contains("OTHER_HINT"),"body and hint are never diagnostic payload")
}
for mode in ["display_zero","display_no_value"] {
 let c=Case(mode);check(c.h.candidate != nil,"independent zero editable domain prepares display-valued field")
 check(c.attempt() && c.writes==1,"only independently empty display-valued document receives focus")
 check(c.h.diagnosticState.contains("editableEmpty=1") && !c.h.diagnosticState.contains("PRIVATE_HINT"),"empty proof diagnostic contains no display text")
}
for mode in ["display_actual","display_bad_zero","display_timeout","display_unsupported","display_clamped","display_wrong_type","display_change","display_unknown","display_selection","display_bool_count"] {
 let c=Case(mode);check(!c.attempt() && c.writes==0,"display value never bypasses independent empty proof: \(mode)")
}
let changedProof=Case("display_zero")
check(changedProof.h.candidate != nil,"initial empty domain prepared")
changedProof.proofHasDraft=true
check(!changedProof.attempt() && changedProof.writes==0,"new draft with identical display metadata is rechecked before first original key")
let identity=Case("normal")
identity.h.reset() // Pointer invalidation must not erase the bounded trace reference.
identity.h.enteredEditor(identity.field,text:"",selection:NSRange(location:0,length:0))
check(identity.h.diagnosticState.contains("focusedMatch=1") && identity.h.diagnosticState.contains("focusedShape=1"),"actual focused snapshot compares last complete discovery without new AX reads")
let differentIdentity=Case("normal")
differentIdentity.h.enteredEditor(differentIdentity.other,text:"PRIVATE_DRAFT",selection:NSRange(location:0,length:0))
check(differentIdentity.h.diagnosticState.contains("focusedMatch=2") && !differentIdentity.h.diagnosticState.contains("PRIVATE_DRAFT"),"different clicked field and value category remain content-free")
for mode in ["known_hint","known_hint_lf"] {
 let c=Case(mode);check(c.h.candidate != nil,"exact historical Codex placeholder prepared")
 check(c.attempt() && c.writes==1 && c.h.diagnosticState.contains("editableEmpty=5"),"known published placeholder gets focus only and is not falsely called an empty range")
}
for mode in ["known_hint_suffix","known_hint_count","known_hint_selection","known_hint_unknown","known_hint_timeout","known_hint_clamped","known_hint_changed"] {
 let c=Case(mode);check(!c.attempt() && c.writes==0,"placeholder recognition never relaxes content/range/count/context safety")
}
for text in ["Codex와 함께 작업하세요 ","\nCodex와 함께 작업하세요","Codex와 함께 작업하세요\nUSER_TEXT","Codex와 함께 작업하세요\n\n","OTHER_HINT","PRIVATE_DRAFT"] {
 check(!OnsetFocusHandoff.knownCodexPlaceholder(text),"only the two exact known placeholder representations match")
}
let dense=Case("dense_default")
check(dense.h.sceneCompleted && dense.h.sceneClipped && dense.h.candidate==nil,"long conversation structure reproduces production traversal clipping")
let fullScene=Case("dense_probe")
check(fullScene.h.sceneCompleted && fullScene.h.sceneVisited>2048 && !fullScene.h.sceneClipped && fullScene.h.candidate != nil,"bounded read-only larger probe measures a complete unique long scene")
check(fullScene.writes==0,"scene measurement never focuses an editor")
let ambiguousScene=Case("dense_ambiguous")
check(ambiguousScene.h.sceneCompleted && ambiguousScene.h.candidate==nil && ambiguousScene.writes==0,"larger measurement does not turn multiple editors into a candidate")
let unconfirmed=Case("unconfirmed");check(!unconfirmed.attempt(),"setter success alone is not focus acknowledgment")
check(!unconfirmed.attempt() && unconfirmed.writes==1,"uncertain result never retried")
for (type,code,flags) in [(CGEventType.keyUp,UInt16(15),CGEventFlags()),(.keyDown,UInt16(18),CGEventFlags()),(.keyDown,UInt16(15),.maskCommand),(.keyDown,UInt16(15),.maskControl),(.keyDown,UInt16(15),.maskAlternate),(.keyDown,UInt16(15),.maskAlphaShift)] {
 let c=Case("normal");check(!c.attempt(type,code,flags) && c.writes==0,"non-first-text input unchanged")
}
let shifted=Case("normal");check(shifted.attempt(.keyDown,15,.maskShift),"initial Shift consonant supported")
check(OnsetFocusHandoff.supports("com.openai.codex",arguments:[]),"current desktop target enabled")
check(!OnsetFocusHandoff.supports("other",arguments:[]),"unrelated apps unchanged")
check(!OnsetFocusHandoff.supports("taek.in.hanq.prefocus-fixture",arguments:[]),"owned fixture requires explicit test mode")
check(OnsetFocusHandoff.supports("taek.in.hanq.prefocus-fixture",arguments:["--test-onset-focus-handoff"]),"bounded native fixture opt-in")
let cached=Case("cache");check(cached.h.candidate != nil,"cached scene starts with complete unique proof")
cached.clock+=0.3;cached.draftChanged=true;cached.h.advance(window:cached.root,outside:cached.outside)
check(cached.h.candidate==nil && !cached.attempt() && cached.writes==0,"new draft invalidates cached empty editor")
cached.h.reset();check(cached.h.candidate==nil,"layout notification invalidates scene proof")
let skipped=OnsetRecoveryEngine(),skipGate=OnsetInputGate(marker:1234567),skipField=AXUIElementCreateApplication(4040)
skipped.enabled=true;skipped.gate=skipGate;skipGate.beat();skipGate.configureEarly(true)
skipped.testSource={onsetKoreanID};skipped.testTargetBundleID={"com.openai.codex"};skipped.testCanReplaceText={true};skipped.testCanSelect={true}
skipped.testSnapshot={OnsetSnapshot(element:skipField,text:"\u{3131}\u{314f}\u{3134} ",selection:NSRange(location:4,length:0))}
var unexpectedWrites=0
skipped.testSetRange={_,_ in unexpectedWrites+=1;return .success};skipped.testReplaceText={_,_ in unexpectedWrites+=1;return .success}
for code:UInt16 in [15,40,1,49]{for down in [true,false]{let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=[];check(skipGate.receive(down ? .keyDown:.keyUp,event) != nil,"unprepared fallback passes originals")}}
skipped.sample()
check(unexpectedWrites==0 && !skipped.recovering && skipped.pending.isEmpty && skipGate.take().isEmpty,"Codex late fallback never selects, writes, or retains input")
skipped.closeSession()
// A failed/ambiguous focus request must not throw away a proved empty
// pre-key baseline. It authorizes only the matching actual focused field.
for mode in ["normal","known_hint","known_hint_lf","ambiguous"] {
 let c=Case(mode),time=10.1
 let baseline=c.h.emptyEntryBaseline(for:c.field,before:time)
 check(baseline?.text=="" && baseline?.selection==NSRange(location:0,length:0),"empty and display-only baseline normalized without restoring hint")
 check(c.h.emptyEntryBaseline(for:c.outside,before:time)==nil,"unobserved field cannot inherit empty proof")
 let snap=OnsetSnapshot(element:c.field,text:"ㄱ",selection:NSRange(location:1,length:0))
 check(OnsetRecoveryEngine.firstConsonantBaseline(baseline,current:snap,observedEmptyEntry:true)=="","observed empty first consonant restores released recovery path")
 check(OnsetRecoveryEngine.firstConsonantBaseline(nil,current:snap,observedEmptyEntry:true)==nil,"boolean without matching actual baseline is insufficient")
 c.h.reset();check(c.h.emptyEntryBaseline(for:c.field,before:time) != nil,"layout reset keeps bounded pre-key history for first-character publication")
 c.clock=10.3;for _ in 0..<10{c.h.advance(window:c.root,outside:c.outside)}
 check(c.h.emptyEntryBaseline(for:c.field,before:time) != nil,"post-key placeholder refresh cannot erase the pre-key proof")
 c.h.invalidateEmptyEntries();check(c.h.emptyEntryBaseline(for:c.field,before:time)==nil,"pointer or shortcut invalidation clears empty history")
}
let expiredEntry=Case("known_hint");expiredEntry.clock=11.2
check(expiredEntry.h.emptyEntryBaseline(for:expiredEntry.field,before:10.1)==nil,"old empty proof expires")
let futureEntry=Case("normal")
check(futureEntry.h.emptyEntryBaseline(for:futureEntry.field,before:9.9)==nil,"post-key discovery cannot authorize earlier input")
for mode in ["draft","known_hint_suffix","unknown_draft"] {
 let c=Case(mode);check(c.h.emptyEntryBaseline(for:c.field,before:10.1)==nil,"actual user text never creates empty baseline")
}
// Exercise the real engine's first-character branch. The commit hook stops
// before any OS key is allocated or posted, so this is not an IME pass.
let restoredEntry=OnsetRecoveryEngine(),restoredGate=OnsetInputGate(marker:123456789)
restoredEntry.enabled=true;restoredEntry.gate=restoredGate
restoredEntry.testSource={onsetKoreanID};restoredEntry.testTargetBundleID={"com.openai.codex"};restoredEntry.testCanSelect={true}
_ = restoredEntry.currentLayout()
let observed=Case("known_hint",h:restoredEntry.focusHandoff)
observed.clock=ProcessInfo.processInfo.systemUptime;observed.h.invalidateEmptyEntries();observed.h.reset()
for _ in 0..<10{observed.h.advance(window:observed.root,outside:observed.outside)}
var commitAttempts=0
restoredEntry.testCommitComposition={_ in commitAttempts+=1;return false}
restoredEntry.testSnapshot={.init(element:observed.field,text:"ㄱ",selection:NSRange(location:1,length:0))}
restoredGate.beat();restoredGate.configureEarly(true)
let first=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;first.flags=[]
check(restoredGate.receive(.keyDown,first) != nil,"first original consonant still passes")
observed.clock=ProcessInfo.processInfo.systemUptime;restoredEntry.sample()
check(commitAttempts==1,"proved-empty Codex entry reaches existing composition commit once")
restoredEntry.closeSession()
// A stale empty display must not discard the reservation before the first
// consonant arrives. These hooks never allocate or post OS input.
for model in ["normal","terminal_lf","known_hint","known_hint_lf"] {
 for deferred in [false,true] {
  let engine=OnsetRecoveryEngine(),gate=OnsetInputGate(marker:123456789)
  engine.enabled=true;engine.gate=gate
  engine.testSource={onsetKoreanID};engine.testTargetBundleID={"com.openai.codex"};engine.testCanSelect={true}
  _ = engine.currentLayout()
  let observed=Case(model,h:engine.focusHandoff)
  observed.clock=ProcessInfo.processInfo.systemUptime;observed.h.invalidateEmptyEntries();observed.h.reset()
  for _ in 0..<10{observed.h.advance(window:observed.root,outside:observed.outside)}
  var commands=0,text=model=="normal" ? "":model=="terminal_lf" ? "\n":"Codex와 함께 작업하세요"+(model=="known_hint_lf" ? "\n":""),caret=0
  engine.earlyBaseline = .init(element:observed.other,text:"OLD_BASELINE",selection:NSRange(location:12,length:0))
  engine.testCommitComposition={_ in commands+=1;return false}
  engine.testSnapshot={.init(element:observed.field,text:text,selection:NSRange(location:caret,length:0))}
  gate.beat();gate.configureEarly(true)
  let first=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;first.flags=[]
  check(gate.receive(.keyDown,first) != nil,"original onset passes before delayed publication")
  if deferred{gate.holdUntil=1;gate.poll();engine.unavailableReason="text_unreadable";engine.sampleEarly(nil)}
  engine.sample();engine.sample()
  check(commands==0 && observed.writes==0 && engine.pending.isEmpty && engine.retainedInput.isEmpty,"stale empty representation causes only reads")
  check(gate.reservation() != nil || gate.deferredReservation() != nil,"empty representation keeps bounded observation: \(model)/\(deferred)")
  text="ㄱ";caret=0;observed.clock=ProcessInfo.processInfo.systemUptime;engine.sample()
  check(commands==0 && (gate.reservation() != nil || gate.deferredReservation() != nil),"stale caret uses normalized empty baseline, not old field caret")
  caret=1;engine.sample()
  check(commands==1,"first published consonant reaches existing commit once: \(model)/\(deferred)")
  engine.closeSession()
 }
}
let proof=OnsetSnapshot(element:skipField,text:"",selection:NSRange(location:0,length:0))
for (text,range) in [("PRIVATE_DRAFT",NSRange(location:0,length:0)),("Codex와 함께 작업하세요 USER_TEXT",NSRange(location:0,length:0)),("\n\n",NSRange(location:0,length:0)),("Codex와 함께 작업하세요",NSRange(location:1,length:0)),("\n",NSRange(location:0,length:1))] {
 let snap=OnsetSnapshot(element:skipField,text:text,selection:range)
 check(!OnsetRecoveryEngine.awaitingEmptyEntryPublication(proof,current:snap),"unrelated text/caret/selection cannot extend empty publication wait")
}
let pendingEmpty=OnsetSnapshot(element:skipField,text:"\n",selection:NSRange(location:0,length:0))
check(!OnsetRecoveryEngine.awaitingEmptyEntryPublication(nil,current:pendingEmpty),"no proof never becomes an empty publication wait")
check(!OnsetRecoveryEngine.awaitingEmptyEntryPublication(proof,current:.init(element:AXUIElementCreateApplication(5678),text:"\n",selection:NSRange(location:0,length:0))),"different field never inherits wait")
let passEngine=OnsetRecoveryEngine(),passGate=OnsetInputGate(marker:123456789)
passEngine.enabled=true;passEngine.gate=passGate;passEngine.testSource={onsetKoreanID};passEngine.testTargetBundleID={"com.openai.codex"}
_ = passEngine.currentLayout()
let passObserved=Case("known_hint_lf",h:passEngine.focusHandoff)
passObserved.clock=ProcessInfo.processInfo.systemUptime;passObserved.h.invalidateEmptyEntries();passObserved.h.reset()
for _ in 0..<10{passObserved.h.advance(window:passObserved.root,outside:passObserved.outside)}
var passText="Codex와 함께 작업하세요\n",passCaret=0,unexpectedCommits=0
passEngine.testCommitComposition={_ in unexpectedCommits+=1;return false}
passEngine.testSnapshot={.init(element:passObserved.field,text:passText,selection:NSRange(location:passCaret,length:0))}
passGate.beat();passGate.configureEarly(true)
for (code,down) in [(UInt16(15),true),(UInt16(40),true)] {
 let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=[]
 check(passGate.receive(.keyDown,event) != nil,"following original key passes before first glyph publication")
 passEngine.sample()
}
passText="ㄱㅏ";passCaret=2;passEngine.sample()
check(unexpectedCommits==0 && passGate.take().isEmpty && passGate.holdUntil==0 && passEngine.pending.isEmpty && passEngine.retainedInput.isEmpty,"passed follow-up never becomes a guessed single-onset repair or held input")
passEngine.closeSession()
let payloadEngine=OnsetRecoveryEngine();var payloads=0
payloadEngine.testPostCompositionCommit={_,event in
 var count=0,character:UniChar=0
 event.keyboardGetUnicodeString(maxStringLength:1,actualStringLength:&count,unicodeString:&character)
 let native=CGEvent(keyboardEventSource:CGEventSource(stateID:.hidSystemState),virtualKey:123,keyDown:event.type == .keyDown)!
 var nativeCount=0,nativeCharacter:UniChar=0
 native.keyboardGetUnicodeString(maxStringLength:1,actualStringLength:&nativeCount,unicodeString:&nativeCharacter)
 check(count==nativeCount && character==nativeCharacter,"composition commit preserves Quartz's native arrow representation")
 check(event.getIntegerValueField(.eventSourceStateID)==Int64(CGEventSourceStateID.hidSystemState.rawValue),"composition commit uses the live HID source state")
 check(event.getIntegerValueField(.keyboardEventKeycode)==123 && event.flags.isEmpty,"composition commit retains actual left key and no modifiers")
 payloads+=1;return true
}
check(payloadEngine.postCompositionCommit(observed.field) && payloads==2,"both composition commit edges checked without OS posts")
// Incident 2834: a recent editor was cleared; a pointer invalidates all old
// evidence, then the deep scene scan has not reached it before the first key.
let fastReentry=Case("normal")
fastReentry.clock += 0.1
fastReentry.h.invalidateEmptyEntries();fastReentry.h.reset()
check(fastReentry.h.emptyEntryBaseline(for:fastReentry.field,before:fastReentry.clock)==nil,"pointer first invalidates the old empty proof")
let slowScene=(0..<400).map{AXUIElementCreateApplication(pid_t(40000+$0))}
fastReentry.h.batch={element,names in
 fastReentry.clock += 0.001
 return names.map{name in
  if name==kAXChildrenAttribute && CFEqual(element,fastReentry.root){return slowScene as CFArray}
  if name==kAXChildrenAttribute && CFEqual(element,slowScene.last!){return [fastReentry.field] as CFArray}
  return fastReentry.read(element,name)
 }
}
fastReentry.h.advance(window:fastReentry.root,outside:fastReentry.outside)
let fastProof=fastReentry.h.emptyEntryBaseline(for:fastReentry.field,before:fastReentry.clock+0.1)
check(fastReentry.h.sceneScanning && fastReentry.h.candidate==nil,"unfinished scene never authorizes a focus request")
check(fastProof != nil,"recent same editor is freshly revalidated before the scene walk reaches it")
check(fastReentry.writes==0,"read-only revalidation never moves focus")
print("FAST_REENTRY_PROBE proof=\(fastProof != nil) sceneScanning=\(fastReentry.h.sceneScanning) focusWrites=\(fastReentry.writes)")

func pendingReentry(_ mode:String)->Case {
 let c=Case(mode)
 c.h.enteredEditor(c.field,text:"",selection:NSRange(location:0,length:0))
 c.clock += 0.1;c.h.invalidateEmptyEntries();c.h.reset()
 let children=(0..<400).map{AXUIElementCreateApplication(pid_t(45000+$0))}
 c.h.batch={element,names in
  c.clock += c.slow ? 0.031:0.001
  return names.map{name in
   if name==kAXChildrenAttribute && CFEqual(element,c.root){return children as CFArray}
   if name==kAXChildrenAttribute && CFEqual(element,children.last!){return [c.field] as CFArray}
   return c.read(element,name)
  }
 }
 return c
}
for mode in ["draft","selection","hidden","secure_field","disabled","unwritable","owner","permission","secure_input"] {
 let c=pendingReentry(mode);c.h.advance(window:c.root,outside:c.outside)
 check(c.h.emptyEntryBaseline(for:c.field,before:c.clock+0.1)==nil,"fresh reentry rejects \(mode)")
 check(c.writes==0,"reentry guard never writes \(mode)")
}
let reentryExpired=pendingReentry("normal");reentryExpired.clock += 5.6;reentryExpired.h.advance(window:reentryExpired.root,outside:reentryExpired.outside)
check(reentryExpired.h.emptyEntryBaseline(for:reentryExpired.field,before:reentryExpired.clock+0.1)==nil,"expired editor hint is not refreshed")
let reentrySlow=pendingReentry("normal");reentrySlow.slow=true;reentrySlow.h.advance(window:reentrySlow.root,outside:reentrySlow.outside)
check(reentrySlow.h.emptyEntryBaseline(for:reentrySlow.field,before:reentrySlow.clock+0.1)==nil,"late fresh read cannot publish empty proof")
let reentryWindow=pendingReentry("normal");reentryWindow.h.advance(window:reentryWindow.other,outside:reentryWindow.outside)
check(reentryWindow.h.emptyEntryBaseline(for:reentryWindow.field,before:reentryWindow.clock+0.1)==nil,"different current window rejects recent editor")
let reentryTyped=pendingReentry("normal"),readBeforeTyping=reentryTyped.h.batch
reentryTyped.h.batch={element,names in
 let values=readBeforeTyping(element,names)
 return zip(names,values).map{name,value in
  if CFEqual(element,reentryTyped.field) && name==kAXValueAttribute{return "ㅎ" as CFString}
  return value
 }
}
reentryTyped.h.advance(window:reentryTyped.root,outside:reentryTyped.outside)
check(reentryTyped.h.emptyEntryBaseline(for:reentryTyped.field,before:reentryTyped.clock+0.1)==nil,"post-key character never becomes empty proof")
check(fastReentry.h.emptyEntryBaseline(for:fastReentry.other,before:fastReentry.clock+0.1)==nil,"recent editor proof never transfers to another field")
check(!fastReentry.attempt() && fastReentry.writes==0,"incomplete scene keeps focus writes disabled after proof refresh")
// Existing-body proofs are independent of a whole-window focus candidate.
func draftScene(_ mode:String="ok")->Case {
 let c=Case("draft");c.h.invalidateEmptyEntries();c.h.reset();c.clock+=0.1
 c.h.batch={element,names in
  if mode=="late"{c.clock+=0.02}
  return names.map{name in
   if name==kAXChildrenAttribute && CFEqual(element,c.root){return [c.field,c.other] as CFArray}
   if name==kAXRoleAttribute && CFEqual(element,c.other){return kAXTextFieldRole as CFString}
   if CFEqual(element,c.field) {
    let text=mode=="hint" ? "Codex와 함께 작업하세요":mode=="large" ? String(repeating:"가",count:16385):"기존"
    if name==kAXValueAttribute{return text as CFString}
    if name==kAXNumberOfCharactersAttribute{return mode=="count_missing" ? nil:NSNumber(value:mode=="count" ? 1:text.utf16.count)}
    if name==kAXSelectedTextRangeAttribute{return c.range(mode=="middle" ? 1:text.utf16.count,mode=="selected" ? 1:0)}
    if name==kAXEnabledAttribute && mode=="disabled"{return kCFBooleanFalse}
    if name=="AXHidden" && mode=="hidden"{return kCFBooleanTrue}
    if name==kAXSubroleAttribute && mode=="secure"{return kAXSecureTextFieldSubrole as CFString}
    if name==kAXWindowAttribute && mode=="window"{return c.other}
   }
   return c.read(element,name)
  }
 }
 if mode=="permission" || mode=="secure_input"{c.h.ready={false}}
 if mode=="owner"{c.h.owner={_ in 43}}
 if mode=="front"{c.h.frontPID={43}}
 for _ in 0..<10{c.h.advance(window:c.root,outside:c.outside)}
 return c
}
let draftOK=draftScene(),draftKeyTime=draftOK.clock+0.05
let draftProof=draftOK.h.draftEntryBaseline(for:draftOK.field,before:draftKeyTime)
check(draftProof?.text=="기존" && draftProof?.selection==NSRange(location:2,length:0),"fresh actual draft body and end caret are preserved")
check(draftOK.h.sceneEditorCount==2 && draftOK.h.candidate==nil && draftOK.writes==0,"draft observation never relaxes multiple-editor focus safety")
check(draftOK.h.draftEntryBaseline(for:draftOK.other,before:draftKeyTime)==nil,"draft evidence is never transferred to another editor")
check(draftOK.h.draftEntryBaseline(for:draftOK.field,before:draftOK.clock)==nil,"a read completing at the key time is not a pre-key draft")
for mode in ["hint","large","count_missing","count","middle","selected","disabled","hidden","secure","window","permission","secure_input","owner","front","late"] {
 let c=draftScene(mode)
 check(c.h.draftEntryBaseline(for:c.field,before:c.clock+0.05)==nil,"draft baseline rejects \(mode)")
 check(c.writes==0,"draft rejection never writes \(mode)")
}
let oldDraft=draftScene();oldDraft.clock+=0.76
check(oldDraft.h.draftEntryBaseline(for:oldDraft.field,before:oldDraft.clock)==nil,"stale existing draft is rejected")
draftOK.h.invalidateEmptyEntries()
check(draftOK.h.draftEntryBaseline(for:draftOK.field,before:draftKeyTime)==nil,"pointer invalidation clears existing-body proofs too")
let lateKeys:[(UInt16,Bool)]=[(5,false),(40,false)]
func inspectLate(_ text:String,_ selection:NSRange,_ before:String="",_ caret:Int=0,_ keys:[(UInt16,Bool)]=lateKeys,_ enabled:Bool=true)->OnsetLateSequenceDetector.Result {
 OnsetLateSequenceDetector.inspect(keys:keys,before:before,caret:caret,text:text,selection:selection,allowObservedReplay:enabled)
}
if case .candidate(let plan)=inspectLate("ㅎㅏ",NSRange(location:2,length:0)) {
 check(plan.isObservedReplay && plan.supportsReplay && !plan.isCommittedLate && plan.observedReplayText=="하","observed split ha replays original keys without a committed-text setter")
}else{check(false,"detached ha has a late replay candidate without Space")}
if case .candidate(let plan)=inspectLate("기존ㅎㅏ",NSRange(location:4,length:0),"기존",2) {
 check(plan.before=="기존" && plan.caret==2 && plan.observedReplayText=="하","late replay preserves the entire exact existing body")
}else{check(false,"existing-prefix late replay")}
if case .complete=inspectLate("기존하",NSRange(location:3,length:0),"기존",2){check(true,"normally composed input is already complete")}else{check(false,"normal composition is never repaired")}
if case .waiting=inspectLate("ㅎㅏ",NSRange(location:2,length:0),"",0,lateKeys,false){check(true,"other callers still require the existing Space boundary")}else{check(false,"default late detector behavior unchanged")}
for (text,selection,before,caret,keys) in [
 ("다름ㅎㅏ",NSRange(location:4,length:0),"기존",2,lateKeys),
 ("ㅎㅏ",NSRange(location:0,length:2),"",0,lateKeys),
 ("ㅎㅏ",NSRange(location:1,length:0),"",0,lateKeys),
 ("ㅎㅏX",NSRange(location:2,length:0),"X",0,lateKeys),
 ("ㅎㅏ",NSRange(location:2,length:0),"",0,[(5,false),(15,false)]),
 ("ㅎㅏ",NSRange(location:2,length:0),"",0,[(5,false),(40,false),(49,true)])
] {
 if case .candidate=inspectLate(text,selection,before,caret,keys){check(false,"changed body/caret/selection/keys rejected")}else{check(true,"changed body/caret/selection/keys rejected")}
}
// Exercise the real engine and atomic gate with injected AX/IME operations.
// No event is sent to macOS; normal cursor acknowledgment is still required.
for prefix in ["","기존"] {
 let engine=OnsetRecoveryEngine()
 var proofCase:Case?
 if prefix.isEmpty {
  let c=Case("normal",h:engine.focusHandoff);c.clock=ProcessInfo.processInfo.systemUptime;c.h.reset()
  for _ in 0..<10{c.h.advance(window:c.root,outside:c.outside)}
  proofCase=c
 }
 let field=proofCase?.field ?? AXUIElementCreateApplication(93500)
 let gate=OnsetInputGate(marker:engine.marker);engine.gate=gate;engine.enabled=true
 engine.testTargetBundleID={"com.openai.codex"};engine.testSource={KoreanKeyboardLayout.twoSetID}
 engine.testCanSelect={true};engine.canBeginRepair={true}
 var text=prefix+"ㅎㅏ",selection=NSRange(location:prefix.utf16.count+2,length:0),posted:[(Int,Bool)]=[],commits=0
 engine.testSnapshot={.init(element:field,text:text,selection:selection)}
 engine.testSetRange={_,range in selection=range;return .success}
 engine.testPostCompositionCommit={_,event in
  commits+=1
  if event.type == .keyUp{selection=NSRange(location:prefix.utf16.count+1,length:0)}
  return true
 }
 engine.testPost={event in
  let code=Int(event.getIntegerValueField(.keyboardEventKeycode));posted.append((code,event.type == .keyDown))
  if event.type == .keyDown {
   if code==5{text=prefix+"ㅎ";selection=NSRange(location:prefix.utf16.count+1,length:0)}
   if code==40{text=prefix+"하";selection=NSRange(location:prefix.utf16.count+1,length:0)}
  }
  _=gate.receive(event.type,event)
 }
 gate.configureEarly(true,sourceID:KoreanKeyboardLayout.twoSetID)
 engine.passedBaseline = .init(element:field,text:prefix.isEmpty ? "STALE":prefix,selection:NSRange(location:prefix.isEmpty ? 5:prefix.utf16.count,length:0));engine.passedField=field
 for code:UInt16 in [5,40] {for down in [true,false]{
  if code==40 && !down {
   check(engine.samplePassed(engine.testSnapshot!()),"held final key stays under observation")
   check(!engine.recovering && commits==0 && posted.isEmpty,"late replay cannot claim while a key remains pressed")
   check(engine.passedBaseline?.text==prefix,"fresh independent pre-key proof supersedes a stale published baseline")
  }
  let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=[];_=gate.receive(event.type,event)
 }}
 check(engine.samplePassed(engine.testSnapshot!()),"complete passed key history is claimed for late replay")
 let deadline=Date(timeIntervalSinceNow:0.5)
 while engine.recovering && Date()<deadline{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.005))}
 check(text==prefix+"하" && selection==NSRange(location:prefix.utf16.count+1,length:0),"engine late replay preserves body and exact final caret")
 check(commits==2 && posted.map{$0.0}==[5,5,40,40] && posted.map{$0.1}==[true,false,true,false],"native commit acknowledgment and original down/up replay order required")
 check(!engine.recovering && gate.healthy() && !gate.hasActiveReplayHold(),"late replay finishes without retaining later input")
}
for ignoredSelection in [false,true] {
 let engine=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(93600)
 let gate=OnsetInputGate(marker:engine.marker);engine.gate=gate;engine.enabled=true
 engine.testTargetBundleID={"com.openai.codex"};engine.testSource={KoreanKeyboardLayout.twoSetID}
 engine.testCanSelect={true};engine.canBeginRepair={true}
 var text="ㅎㅏ",selection=NSRange(location:2,length:0),posted=0,commits=0
 engine.testSnapshot={.init(element:field,text:text,selection:selection)}
 engine.testSetRange={_,range in
  if range.length>0{return ignoredSelection ? .success:.failure}
  selection=range;return .success
 }
 engine.testPostCompositionCommit={_,event in commits+=1;if event.type == .keyUp{selection=NSRange(location:1,length:0)};return true}
 engine.testPost={_ in posted+=1}
 gate.configureEarly(true,sourceID:KoreanKeyboardLayout.twoSetID)
 for code:UInt16 in [5,40]{for down in [true,false]{let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=[];_=gate.receive(event.type,event)}}
 engine.passedBaseline = .init(element:field,text:"",selection:NSRange(location:0,length:0));engine.passedField=field
 _=engine.samplePassed(engine.testSnapshot!())
 let deadline=Date(timeIntervalSinceNow:0.5)
 while engine.recovering && Date()<deadline{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.005))}
 check(text=="ㅎㅏ" && selection==NSRange(location:2,length:0),"late replay rejected/ignored selection restores original caret without rewriting text")
 check(posted==0 && commits==2 && engine.pending.isEmpty && engine.retainedInput.isEmpty,"failed late selection never starts replacement key replay or loses queued input")
 check(!engine.recovering && !engine.rollingBack,"rejected/ignored late selection cleanup is acknowledged")
}
func publishDraftShape(_ c:Case,_ text:String,step:Double=0.1){
 let prior=c.h.batch
 c.h.batch={element,names in
  let values=prior(element,names)
  return zip(names,values).map{name,value in
   if CFEqual(element,c.field) {
    if name==kAXValueAttribute{return text as CFString}
    if name==kAXNumberOfCharactersAttribute{return NSNumber(value:text.utf16.count)}
    if name==kAXSelectedTextRangeAttribute{return c.range(text.utf16.count,0)}
   }
   return value
  }
 }
 c.clock+=step;c.h.reset()
 for _ in 0..<10{c.h.advance(window:c.root,outside:c.outside)}
}
let publishedAfterKey=draftScene(),priorKeyTime=publishedAfterKey.clock+0.05
publishDraftShape(publishedAfterKey,"기존ㅎ")
check(publishedAfterKey.h.draftEntryBaseline(for:publishedAfterKey.field,before:priorKeyTime)?.text=="기존","post-key publication never overwrites the earlier complete draft proof")
let emptyAfterDraft=draftScene();publishDraftShape(emptyAfterDraft,"")
check(emptyAfterDraft.h.draftEntryBaseline(for:emptyAfterDraft.field,before:emptyAfterDraft.clock+0.05)==nil,"a newer pre-key empty state supersedes older draft evidence")
let draftAfterEmpty=Case("normal");publishDraftShape(draftAfterEmpty,"기존")
check(draftAfterEmpty.h.emptyEntryBaseline(for:draftAfterEmpty.field,before:draftAfterEmpty.clock+0.05)==nil,"a newer pre-key draft supersedes older empty evidence")
let fastDraftFlip=draftScene();publishDraftShape(fastDraftFlip,"",step:0.01);publishDraftShape(fastDraftFlip,"기존",step:0.01)
check(fastDraftFlip.h.draftEntryBaseline(for:fastDraftFlip.field,before:fastDraftFlip.clock+0.01)?.text=="기존","rapid draft-empty-draft publishes the latest pre-key state despite deduplication")
let fastEmptyFlip=Case("normal");publishDraftShape(fastEmptyFlip,"기존",step:0.01);publishDraftShape(fastEmptyFlip,"",step:0.01)
check(fastEmptyFlip.h.emptyEntryBaseline(for:fastEmptyFlip.field,before:fastEmptyFlip.clock+0.01) != nil,"rapid empty-draft-empty publishes the latest pre-key state despite deduplication")
print("\(failures==0 ? "PASS":"FAIL") \(checks) first-input focus handoff safety assertions; all AX injected; no keys posted")
exit(failures==0 ? 0:1)
