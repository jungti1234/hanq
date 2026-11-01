import AppKit
var checks=0
func check(_ v:Bool,_ message:String){checks+=1;if !v{print("FAIL",message);exit(1)}}
let countName="AXUIElementCountForSearchPredicate",elementsName="AXUIElementsForSearchPredicate"
let root=AXUIElementCreateApplication(710),document=AXUIElementCreateApplication(711),field=AXUIElementCreateApplication(712),other=AXUIElementCreateApplication(713)
func classify(_ value:OnsetEditorSearch.Result)->Int{
 switch value{case .unsupported:return 1;case .unavailable:return 2;case .none:return 3;case .multiple:return 4;case .unique(let element):check(CFEqual(element,field),"exact provider element retained");return 5}
}
for (mode,expected) in [("unique",5),("none",3),("multiple",4),("not_advertised",1),("names_error",2),("unsupported",1),("count_error",2),("count_boolean",2),("count_fraction",2),("count_large",2),("array_empty",2),("array_multiple",2),("wrong_element",2),("late",2)] {
 var search=OnsetEditorSearch(),clock=10.0,calls=0
 search.now={clock}
 search.attributes={_ in mode=="names_error" ? (.cannotComplete,nil):(.success,mode=="not_advertised" ? []:[countName,elementsName])}
 search.query={element,name,args in
  calls+=1;check(CFEqual(element,document),"query stays on supplied document")
  let a=args as NSDictionary
  check(a["AXResultsLimit"] as? Int==2 && a["AXSearchKey"] as? String=="AXTextFieldSearchKey","bounded structural predicate")
  check(a["AXSearchText"]==nil,"no application, URL or body search")
  if mode=="late"{clock+=0.01}
  if name==countName {
   if mode=="unsupported"{return (.parameterizedAttributeUnsupported,nil)}
   if mode=="count_error"{return (.cannotComplete,nil)}
   if mode=="count_boolean"{return (.success,kCFBooleanTrue)}
   return (.success,NSNumber(value:mode=="none" ? 0:mode=="multiple" ? 2:mode=="count_fraction" ? 0.5:mode=="count_large" ? 3:1))
  }
  if mode=="wrong_element"{return (.success,["invalid"] as CFArray)}
  return (.success,(mode=="array_empty" ? []:mode=="array_multiple" ? [field,other]:[field]) as CFArray)
 }
 check(classify(search.lookup(document))==expected,"distinct provider result: \(mode)")
 check(calls<=2,"no retries or unbounded search")
 if ["none","multiple","unsupported","count_error","count_boolean","count_fraction","count_large","late"].contains(mode){check(calls==1,"stop before element query when count unproved")}
}

for mode in ["unique","unsupported","multiple","wrong_window","hidden","native"] {
 let h=OnsetFocusHandoff();var clock=10.0,queries=0,moved=false
 h.now={clock};h.ready={true};h.frontPID={42};h.owner={_ in 42};h.writable={_,_ in true};h.children={_ in []}
 func read(_ node:AXUIElement,_ name:String)->CFTypeRef? {
  if name==kAXWindowAttribute{return CFEqual(node,field) && (mode=="wrong_window" || moved) ? other:root}
  if name==kAXRoleAttribute{return (CFEqual(node,root) ? kAXWindowRole:CFEqual(node,document) ? "AXWebArea":CFEqual(node,field) ? kAXTextAreaRole:kAXGroupRole) as CFString}
  if name==kAXChildrenAttribute {
   if CFEqual(node,root){return [mode=="native" ? field:document] as CFArray}
   if CFEqual(node,document){return (mode=="unsupported" || mode=="multiple" ? [field]:Array(repeating:other,count:3000)) as CFArray}
   return [] as CFArray
  }
  if name=="AXHidden"{return NSNumber(value:mode=="hidden" && CFEqual(node,field))}
  if name==kAXEnabledAttribute{return kCFBooleanTrue}
  if name==kAXValueAttribute{return "" as CFString}
  if name==kAXNumberOfCharactersAttribute{return NSNumber(value:0)}
  if name==kAXSelectedTextRangeAttribute{var r=CFRange(location:0,length:0);return AXValueCreate(.cfRange,&r)!}
  return nil
 }
 h.read=read;h.batch={node,names in names.map{read(node,$0)}}
 h.editorSearch.now={clock};h.editorSearch.attributes={_ in (.success,mode=="unsupported" ? []:[countName,elementsName])}
 h.editorSearch.query={node,name,_ in
  queries+=1;check(CFEqual(node,document),"only document capability queried")
  return name==countName ? (.success,NSNumber(value:mode=="multiple" ? 2:1)):(.success,[field] as CFArray)
 }
 for _ in 0..<20 {h.advance(window:root,outside:document);if h.sceneCompleted{break}}
 let baseline=h.emptyEntryBaseline(for:field,before:clock+0.1)
 check((baseline != nil) == !["wrong_window","hidden"].contains(mode),"ordinary field validation follows query: \(mode)")
 if mode=="unique" {
  check(h.searchAttempts==1 && queries==2 && h.sceneVisited<10,"query avoids materializing oversized document subtree")
  check(h.candidate==nil,"provider uniqueness is not whole-window focus authority")
  moved=true;check(h.emptyEntryBaseline(for:field,before:clock+0.1)==nil,"query history also rejects changed window")
 }
 if mode=="native"{check(queries==0 && h.searchAttempts==0,"ordinary native tree needs no provider query")}
 if mode=="unsupported"{check(queries==0,"unadvertised provider uses bounded tree fallback")}
 if mode=="multiple"{check(h.candidate==nil,"multiple provider results cannot authorize a unique scene")}
 clock+=0.1
}
print("PASS \(checks) capability search, bounded fallback and same-window observation checks; all AX injected; no OS keys")
