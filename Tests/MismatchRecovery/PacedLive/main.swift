import AppKit
import Carbon
final class Field:NSTextView {
 var replayRound=0; var rawCount=0; var replayCount=0; var activationEvents:[[String:Any]]=[]; var replayEvents:[[String:Any]]=[]
 override func flagsChanged(with event:NSEvent){
  if event.keyCode==59,let cg=event.cgEvent,UInt64(bitPattern:cg.getIntegerValueField(.eventSourceUserData))>>32==0x48414E51 {
   activationEvents.append(["sourcePID":cg.getIntegerValueField(.eventSourceUnixProcessID),"uptime":ProcessInfo.processInfo.systemUptime])
  }
  super.flagsChanged(with:event)
 }
 override func keyDown(with event:NSEvent) {
  guard [15,40,1].contains(Int(event.keyCode)) else { super.keyDown(with:event);return }
  let marker=event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
  let replay=UInt64(bitPattern:marker)>>32 == 0x48414E51
  if replay { if event.keyCode==15 { replayRound+=1 }; replayCount+=1; replayEvents.append(["round":replayRound,"code":Int(event.keyCode),"time":ProcessInfo.processInfo.systemUptime,"sourcePID":event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0]) }
  else { rawCount+=1 }
  if (!replay && replayRound==0 && rawCount<=3) || (replay && replayRound<=2) {
   let text = replay ? [15:"r",40:"k",1:"s"][Int(event.keyCode)]! : [15:"ㄱ",40:"ㅏ",1:"ㄴ"][Int(event.keyCode)]!
   insertText(text,replacementRange:selectedRange());return
  }
  super.keyDown(with:event)
 }
}
final class Delegate:NSObject,NSApplicationDelegate {
 let root=URL(fileURLWithPath:CommandLine.arguments[1])
 var window:NSWindow!;let field=Field(); var timer:Timer?
 func applicationDidFinishLaunching(_ n:Notification) {
  window=NSWindow(contentRect:NSRect(x:200,y:200,width:600,height:260),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  window.title="한Q 복구 · 마지막 재시도와 후속 입력 검사"
  let label=NSTextField(wrappingLabelWithString:"고정 RKS 입력만 시험합니다. 분리 자모와 처음 두 재입력 실패를 이 시험 문서에서만 만듭니다. 창과 입력기 상태를 보존합니다.")
  label.frame=NSRect(x:20,y:190,width:560,height:50);window.contentView!.addSubview(label)
  field.frame=NSRect(x:20,y:20,width:560,height:160);field.isRichText=false;field.font=NSFont.systemFont(ofSize:26)
  field.string="앞🙂뒤";field.setSelectedRange(NSRange(location:3,length:0));window.contentView!.addSubview(field)
  window.makeKeyAndOrderFront(nil);window.makeFirstResponder(field);NSApp.activate(ignoringOtherApps:true)
  // Real editors initialize their input context on first input. The forced
  // ASCII fixture must do so before bypassing that first normal key path.
  if !CommandLine.arguments.contains("--cold"){_ = field.inputContext?.selectedKeyboardInputSource}
  timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in self?.record()}
 }
 func record(){
  let known=["앞🙂뒤","앞🙂ㄱ뒤","앞🙂ㄱㅏ뒤","앞🙂ㄱㅏㄴ뒤","앞🙂r뒤","앞🙂rk뒤","앞🙂rks뒤","앞🙂가뒤","앞🙂간뒤","앞🙂가나뒤"]
  let row:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"body":known.contains(field.string) ? field.string:"unexpected","caret":field.selectedRange().location,"selectionLength":field.selectedRange().length,"rawCount":field.rawCount,"replayCount":field.replayCount,"replayRounds":field.replayRound,"source":InputSourceAccess.currentID(),"layout":InputSourceAccess.currentLayoutID(),"override":InputSourceAccess.currentOverrideID() ?? "nil","cold":CommandLine.arguments.contains("--cold"),"passed":field.string=="앞🙂간뒤" && field.selectedRange()==NSRange(location:4,length:0) && field.replayRound==3,"physicalKeys":false,"replayEvents":field.replayEvents,"activationEvents":field.activationEvents,"continued":field.string=="앞🙂가나뒤" && field.selectedRange()==NSRange(location:5,length:0)]
  if let data=try? JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:root.appendingPathComponent("result.json"),options:.atomic) }
 }
}
guard [2,3].contains(CommandLine.arguments.count),(CommandLine.arguments.count==2 || CommandLine.arguments[2]=="--cold"),CommandLine.arguments[1].hasPrefix("/private/tmp/hanq-paced-live.") else{exit(2)}
let app=NSApplication.shared;let delegate=Delegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
