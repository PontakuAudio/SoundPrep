// Exercise the actual Cocoa controls without REAPER or system input events.
#import "bar.mm"
#include <cassert>
#include <cstdio>
#include "test_bar_contract.h"
static unsigned int labelPixels[320*24];
static void* labelApi(const char* name) {
  if(!strcmp(name,"LICE__GetBits"))return reinterpret_cast<void*>(+[](void*)->unsigned int*{return labelPixels;});
  if(!strcmp(name,"LICE__GetRowSpan"))return reinterpret_cast<void*>(+[](void*){return 320;});
  if(!strcmp(name,"LICE__GetHeight"))return reinterpret_cast<void*>(+[](void*){return 24;});
  if(!strcmp(name,"LICE__IsFlipped"))return reinterpret_cast<void*>(+[](void*){return false;});
  return nullptr;
}

@interface BarHostFixture : NSView
@end
@implementation BarHostFixture
- (BOOL)isFlipped{return YES;}
@end

static NSMutableDictionary *state(NSUInteger count) {
  NSMutableArray *macros=[NSMutableArray array];
  for (NSUInteger i=0;i<count;i++)
    [macros addObject:@{@"id":[NSString stringWithFormat:@"macro_%lu",(unsigned long)i],
      @"label":[NSString stringWithFormat:@"長い日本語のMacro名 %lu 🎧",(unsigned long)i+1]}];
  return [@{@"macros":macros,@"active":@"raw",@"status":@"Ready",@"reverse":@NO,@"preserve_pitch":@NO,
    @"normalize":@NO,@"target":@(-16),@"monitor":@(-6),@"paused":@NO,@"search":@{@"open":@NO}} mutableCopy];
}
static void update(NSDictionary *value) {
  NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  assert(AMBarSetState([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String));
}
static void resize(CGFloat width,CGFloat height) {
  bar.list.frame=NSMakeRect(12,70,width,height);
  assert(bar.baseFrame.size.width==width && bar.baseFrame.size.height==height);
}
static void checkLayout(NSUInteger count) {
  assert(!bar.hidden);
  assert(bar.list.frame.size.height+bar.frame.size.height==bar.baseFrame.size.height);
  NSMutableArray<NSView *> *visible=[NSMutableArray array];
  for (NSControl *c in bar.controls) if (!c.hidden) [visible addObject:c];
  for (NSUInteger i=0;i<bar.presets.count;i++) {
    NSButton *b=bar.presets[i]; assert(b.hidden==(i>=count));
    if (!b.hidden) { assert(b.frame.origin.y==bar.raw.frame.origin.y); [visible addObject:b]; }
  }
  if (!bar.status.hidden) [visible addObject:bar.status];
  for (NSUInteger i=0;i<visible.count;i++) {
    assert(NSContainsRect(bar.bounds,visible[i].frame));
    for (NSUInteger j=0;j<i;j++) assert(!NSIntersectsRect(visible[i].frame,visible[j].frame));
  }
}
int main(){@autoreleasepool {
  assert(AMDrawWaveLabel(nullptr,"Mono ch 5  風鈴 🎤",8,2,304,14,0xffeeeeee,0xff20262c,1,labelApi));
  int bright=0;for(auto pixel:labelPixels)if((pixel&0xffffff)>0xc0c0c0)++bright;
  assert(bright>30 && labelPixels[0]==0 && labelPixels[23*320]==0);
  const auto darkLabel=std::vector<unsigned int>(std::begin(labelPixels),std::end(labelPixels));
  assert(AMDrawWaveLabel(nullptr,"Mono ch 5  風鈴 🎤",8,2,304,14,0xff202020,0xffeeeeee,1,labelApi));
  assert(!std::equal(darkLabel.begin(),darkLabel.end(),labelPixels));
  assert(AMDrawWaveLabel(nullptr,"Mono ch 5  風鈴 🎤",8,2,304,14,0xffeeeeee,0xff20262c,1,labelApi));
  assert(std::equal(darkLabel.begin(),darkLabel.end(),labelPixels)); // Cached labels retain their theme.
  [NSApplication sharedApplication];
  NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1024,700)
    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;
  BarHostFixture *host=[[BarHostFixture alloc]initWithFrame:window.contentView.bounds];window.contentView=host;
  NSView *list=[[NSView alloc]initWithFrame:NSMakeRect(12,70,980,400)];[host addSubview:list];
  const NSRect original=list.frame;const BOOL posting=list.postsFrameChangedNotifications;
  assert(AMBarAttach((__bridge void *)host,(__bridge void *)list));
  test_bar_contract(AMBarSetState);
  // Rejection must happen before controls/state change, including nested state.
  NSDictionary *before=bar.state;
  NSMutableDictionary *bad=state(0);bad[@"paused"]=@YES;bad[@"search"]=@{@"open":@[]};
  NSData *badData=[NSJSONSerialization dataWithJSONObject:bad options:0 error:nil];
  assert(!AMBarSetState([[NSString alloc]initWithData:badData encoding:NSUTF8StringEncoding].UTF8String));
  assert(bar.state==before && !bar.paused && bar.raw.enabled);
  assert(!AMBarSetState("[]") && !AMBarSetState("{\"macros\":42}"));
  for (NSUInteger count : {0u,3u,9u}) {
    NSMutableDictionary *value=state(count);update(value);
    for (CGFloat width : {980.,680.,540.,416.,360.,300.}) {
      for (CGFloat height : {400.,129.,79.,54.}) {
        resize(width,height);checkLayout(count);
        if(height<80)assert(bar.frame.size.height==30);
        assert(bar.status.hidden==(height<130 || width<360));
      }
    }
    resize(299,400);assert(bar.hidden && NSEqualRects(list.frame,bar.baseFrame));
    resize(680,53);assert(bar.hidden && NSEqualRects(list.frame,bar.baseFrame));
    resize(980,400);checkLayout(count);
  }
  NSMutableDictionary *value=state(3);update(value);
  NSButton *chosen=bar.presets[1];[chosen performClick:nil];assert(std::string(AMBarPoll())=="macro:macro_1");
  value[@"active"]=@"macro_1";update(value);assert(chosen.state==NSControlStateValueOn && bar.raw.state==NSControlStateValueOff);
  [chosen performClick:nil];assert(std::string(AMBarPoll())=="macro:macro_1");update(value);
  assert(chosen.state==NSControlStateValueOn && bar.presets[0].state==NSControlStateValueOff);
  [bar.raw performClick:nil];assert(std::string(AMBarPoll())=="raw");
  value[@"active"]=@"raw";update(value);assert(bar.raw.state==NSControlStateValueOn);
  [bar.controls[amcontract::channels] performClick:nil];assert(std::string(AMBarPoll())=="channels");
  assert([bar.targets.title isEqual:@"Norm -16.0 LUFS"] && [bar.monitor.title isEqual:@"Monitor -6.0 dB"]);
  value[@"target_label"]=@"Norm 36.00 sones";update(value);
  assert([bar.targets.title isEqual:@"Norm 36.00 sones"] && bar.targets.numberOfItems==2);
  [bar.targets selectItem:bar.targets.lastItem];[bar picked:bar.targets];
  assert(std::string(AMBarPoll())=="target:custom" && [bar.targets.title isEqual:@"Norm 36.00 sones"]);
  value[@"target_label"]=@"Norm 12.00 sones";update(value);assert([bar.targets.title isEqual:@"Norm 12.00 sones"]);
  [value removeObjectForKey:@"target_label"];value[@"target"]=@(-15.5);value[@"monitor"]=@(-18.5);update(value);
  assert([bar.targets.title isEqual:@"Norm -15.5 LUFS"] && [bar.monitor.title isEqual:@"Monitor -18.5 dB"]);
  [bar picked:bar.targets];assert(std::string(AMBarPoll())=="target:-15.5");
  [bar picked:bar.monitor];assert(std::string(AMBarPoll())=="monitor:-18.5");
  value[@"target"]=@(-16);value[@"monitor"]=@(-6);update(value);
  NSMenuItem* targetItem=bar.targets.selectedItem;NSMenuItem* monitorItem=bar.monitor.selectedItem;
  value[@"status"]=@"Applying Normalize";value[@"search"]=@{@"open":@YES};update(value);
  assert(bar.targets.selectedItem==targetItem && bar.monitor.selectedItem==monitorItem);
  assert(NSClassFromString(@"AMSearchPanel")==Nil && std::string(AMBarPoll()).empty());
  [value removeObjectForKey:@"search"];
  // Source-channel changes must reflow even when the macro list is unchanged.
  assert(bar.downmix.hidden && bar.downmix.state==NSControlStateValueOff);
  assert(nlohmann::json::parse(AMBarGeometry())["downmix_visible"]==false && nlohmann::json::parse(AMBarGeometry())["downmix"]==false);
  resize(700,400);assert(bar.frame.size.height==72);
  value[@"multichannel"]=@YES;update(value);
  assert(!bar.downmix.hidden && bar.frame.size.height==98);checkLayout(3);
  assert([bar.downmix.title isEqual:@"Downmix"] && [bar.downmix.accessibilityLabel isEqual:@"Downmix"]);
  [bar.downmix performClick:nil];assert(std::string(AMBarPoll())=="downmix");
  value[@"downmix"]=@YES;update(value);assert(bar.downmix.state==NSControlStateValueOn);
  assert(nlohmann::json::parse(AMBarGeometry())["downmix_visible"]==true && nlohmann::json::parse(AMBarGeometry())["downmix"]==true);
  [bar.downmix performClick:nil];assert(std::string(AMBarPoll())=="downmix");
  value[@"downmix"]=@NO;update(value);assert(bar.downmix.state==NSControlStateValueOff);
  resize(300,129);assert(bar.frame.size.height==80 && [bar.downmix.title isEqual:@"DM"]);checkLayout(3);
  value[@"multichannel"]=@NO;update(value);assert(bar.downmix.hidden && bar.frame.size.height==80);checkLayout(3);
  value[@"multichannel"]=@YES;update(value);
  for (CGFloat width : {980.,737.,736.,680.,540.,416.,360.,359.,300.}) {
    for (CGFloat height : {400.,129.,79.,54.}) {
      resize(width,height);checkLayout(3);
      assert(bar.downmix.hidden==(height<80));
    }
  }
  resize(980,400);
  [bar.targets selectItem:bar.targets.lastItem];[bar picked:bar.targets];
  assert(std::string(AMBarPoll())=="target:custom" && [bar.targets.selectedItem.representedObject isEqual:@"-16.0"]);
  value[@"paused"]=@YES;update(value);
  for (NSButton *b in bar.presets) if (!b.hidden) assert(!b.enabled);
  [chosen performClick:nil];assert(std::string(AMBarPoll()).empty());
  assert(!bar.targets.enabled && !bar.monitor.enabled && !bar.downmix.enabled);
  [bar.downmix performClick:nil];assert(std::string(AMBarPoll()).empty());
  assert(bar.controls[amcontract::quit].enabled);[bar.controls[amcontract::quit] performClick:nil];assert(std::string(AMBarPoll())=="quit");
  value=state(9);NSMutableArray *macros=[value[@"macros"] mutableCopy];
  macros[0]=@{@"id":@"emoji",@"label":@"🎧音声  素材"};value[@"macros"]=macros;update(value);resize(300,400);
  assert([bar.presets[0].title isEqual:@"🎧音声"] && [bar.presets[1].title isEqual:@"長い日"] && [bar.raw.title isEqual:@"Raw"]);
  assert([bar.presets[0].toolTip isEqual:@"🎧音声  素材"] && [bar.presets[0].accessibilityLabel isEqual:bar.presets[0].toolTip]);
  value=state(3);update(value);resize(980,400);
  assert(bar.downmix.hidden && bar.downmix.state==NSControlStateValueOff);
  NSTextField *search=[[NSTextField alloc]initWithFrame:NSMakeRect(12,20,300,24)];[host addSubview:search];
  search.stringValue=@"metal slam";assert([window makeFirstResponder:search]);
  NSTextView *editor=(NSTextView *)search.currentEditor;assert(editor);editor.selectedRange=NSMakeRange(2,4);
  [bar rememberFocus];[chosen performClick:nil];assert(std::string(AMBarPoll())=="macro:macro_1");
  assert(window.firstResponder==editor && NSEqualRanges(editor.selectedRange,NSMakeRange(2,4)));
  // A native popover belongs to the Media Explorer bar, with distinct mic IDs.
  NSMutableDictionary* panel=[@{@"open":@YES,@"source":@"/six.wav:6",@"file":@"six.wav",@"summary":@"Ch 1, 3, 5",
    @"items":@[@{@"channel":@1,@"name":@"Boom & L",@"selected":@YES},@{@"channel":@2,@"name":@"",@"selected":@NO},
      @{@"channel":@3,@"name":@"風鈴 🎤",@"selected":@YES},@{@"channel":@4,@"name":@"Boom & L",@"selected":@NO}],
    @"previous":@NO,@"next":@NO,@"all":@NO,@"downmix":@NO,@"can_downmix":@YES,@"can_swap":@NO,
    @"enabled":@YES,@"playing":@NO,@"page":@"1–6 / 6",@"notice":@""}mutableCopy];
  [window orderFront:nil];value[@"channels"]=panel;update(value);
  AMChannelPanel* picker=bar.channelPanel;
  assert(picker.popover.shown);
  assert([picker.microphones[0].title isEqual:@"Boom & L\nch 1"] && [picker.microphones[1].title isEqual:@"2"]);
  assert([picker.microphones[2].toolTip isEqual:@"ch 3 — 風鈴 🎤"] && picker.microphones[4].hidden);
  [picker.microphones[3] performClick:nil];auto event=std::string(AMBarPoll());assert(event.rfind("channels@",0)==0);
  auto parsed=nlohmann::json::parse(event.substr(9));assert(parsed["channel"]==4 && parsed["source"]=="/six.wav:6");
  for(NSButton* b in picker.microphones)if(!b.hidden)assert(NSContainsRect(picker.view.bounds,b.frame));
  for(NSButton* b in picker.actions.allValues)assert(NSContainsRect(picker.view.bounds,b.frame));
  NSString* longName=[@"長いマイク名 🎤 " stringByPaddingToLength:200 withString:@"長いマイク名 🎤 " startingAtIndex:0];
  panel[@"items"]=@[@{@"channel":@1,@"name":longName,@"selected":@YES}];update(value);
  NSArray* lines=[picker.microphones[0].title componentsSeparatedByString:@"\n"];
  assert(lines.count==2 && [lines[1] isEqual:@"ch 1"] && [lines[0] hasSuffix:@"…"]);
  assert([lines[0] sizeWithAttributes:@{NSFontAttributeName:picker.microphones[0].font}].width<=NSWidth(picker.microphones[0].bounds)-18);
  assert([picker.microphones[0].toolTip containsString:longName]);
  panel[@"source"]=@"/other.wav:1";panel[@"items"]=@[@{@"channel":@1,@"name":@"",@"selected":@YES}];update(value);
  assert([picker.microphones[0].title isEqual:@"1"] && picker.microphones[1].hidden);
  [picker.microphones[0] performClick:nil];event=AMBarPoll();assert(nlohmann::json::parse(event.substr(9))["source"]=="/other.wav:1");
  [picker.actions[@"close"] performClick:nil];assert(!picker.popover.shown && std::string(AMBarPoll())=="channels:close");
  panel[@"open"]=@NO;update(value);assert(std::string(AMBarPoll()).empty());
  // Modeless settings survive focus changes, keep local text drafts, and close explicitly.
  NSMutableDictionary* settings=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"tests/native-settings-state.json"] options:NSJSONReadingMutableContainers error:nil];
  [window makeKeyAndOrderFront:nil];value[@"settings"]=settings;update(value);AMSettingsPanel* prefs=bar.settingsPanel;
  assert(prefs.window.visible && !prefs.window.hidesOnDeactivate && prefs.window.parentWindow==window);
  assert(prefs.controls[2].doubleValue==-6 && [prefs.notice.stringValue isEqual:settings[@"notice"]]);
  assert([prefs.cache.stringValue containsString:@"解析 🎤"] && prefs.choose.enabled && prefs.defaults.enabled);
  assert(prefs.tabs.numberOfTabViewItems==4);
  NSButton* support=(NSButton*)prefs.controls.lastObject;
  assert([support isKindOfClass:NSButton.class] && [support.title isEqual:@"Support on Ko-fi"]);
  assert(support.superview==prefs.tabs.tabViewItems[3].view && support.target==prefs && support.action==@selector(openLink:));
  NSButton* resetDefaults=prefs.resetDefaults;
  assert([resetDefaults.title isEqual:@"Reset to defaults"] && resetDefaults.enabled);
  assert(resetDefaults.superview==prefs.tabs.tabViewItems[3].view && [prefs.tabs.tabViewItems[3].label isEqual:@"About"]);
  assert(resetDefaults.superview.subviews.count==5); // Ko-fi button and description, version, diagnostics, reset.
  assert(prefs.diagnostics.superview==resetDefaults.superview && [prefs.diagnostics.stringValue isEqual:settings[@"diagnostics"]]);
  assert([prefs.version.stringValue isEqual:settings[@"version"]] && NSMinY(prefs.version.frame)==92);
  assert(NSMinY(prefs.diagnostics.frame)==126 && NSMinY(resetDefaults.frame)==160);
  NSView* playback=prefs.tabs.tabViewItems[0].view;
  NSSlider* fadeSlider=(NSSlider*)prefs.controls[normalization_fade_index];
  NSTextField* fadeField=prefs.numbers[@(normalization_fade_index)];
  assert(fadeSlider.superview==playback && fadeField.superview==playback);
  assert(fadeSlider.doubleValue==500 && fadeSlider.minValue==0 && fadeSlider.maxValue==2000);
  assert([fadeField.stringValue isEqual:@"500.0"]);
  NSTextField *fadeHelp=nil;
  NSString* fadeHelpText=[NSString stringWithUTF8String:amsettings::controls[normalization_fade_index].help];
  for(NSView* child in playback.subviews)if([child isKindOfClass:NSTextField.class]) {
    NSTextField* field=(NSTextField*)child;
    if([field.stringValue isEqual:fadeHelpText])fadeHelp=field;
  }
  NSControl* keepFX=prefs.controls[7];
  assert(fadeHelp && keepFX.superview==playback && NSMaxY(fadeHelp.frame)<=NSMinY(keepFX.frame));
  fadeField.stringValue=@"1250";[prefs numberChanged:fadeField];
  auto fadeEvent=nlohmann::json::parse(std::string(AMBarPoll()).substr(9));
  assert(fadeEvent["op"]=="set" && fadeEvent["key"]=="normalize_fade_ms" && fadeEvent["value"]==1250);
  [prefs.tabs selectTabViewItemAtIndex:3];
  [resetDefaults performClick:nil];
  auto resetEvent=std::string(AMBarPoll());
  assert(resetEvent.rfind("settings@",0)==0 && nlohmann::json::parse(resetEvent.substr(9))["op"]=="reset_defaults");
  [prefs.tabs selectTabViewItemAtIndex:0];
  for(NSTabViewItem* tab in prefs.tabs.tabViewItems)for(NSView* child in tab.view.subviews)assert(NSContainsRect(tab.view.bounds,child.frame));
  [window makeKeyAndOrderFront:nil];update(value);assert(prefs.window.visible);
  auto oldFrame=prefs.window.frame;[prefs.window setFrameOrigin:NSMakePoint(oldFrame.origin.x+8,oldFrame.origin.y+8)];
  settings[@"values"][@"monitor_gain_db"]=@(-12);update(value);assert(prefs.window.frame.origin.x==oldFrame.origin.x+8);
  assert([prefs.numbers[@2].stringValue isEqual:@"-12.0"]);
  [prefs.controls[1] performClick:nil];auto settingEvent=std::string(AMBarPoll());
  assert(settingEvent.rfind("settings@",0)==0 && nlohmann::json::parse(settingEvent.substr(9))["key"]=="loop");
  prefs.numbers[@2].stringValue=@"-18.5";[prefs numberChanged:prefs.numbers[@2]];
  assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(9))["value"]==-18.5);
  prefs.numbers[@2].stringValue=@"-18abc";[prefs numberChanged:prefs.numbers[@2]];
  assert(std::string(AMBarPoll()).empty() && [prefs.numbers[@2].stringValue isEqual:@"-12.0"]);
  value[@"paused"]=@YES;update(value);assert(prefs.window.visible && !prefs.controls[0].enabled && !prefs.choose.enabled);
  assert(support.enabled && !resetDefaults.enabled);
  [prefs.window performClose:nil];assert(!prefs.window.visible && std::string(AMBarPoll())=="settings:close");
  update(value);assert(!prefs.window.visible);settings[@"open"]=@NO;update(value);
  value[@"paused"]=@NO;settings[@"open"]=@YES;settings[@"focus"]=@2;update(value);assert(prefs.window.visible);
  [prefs.window makeFirstResponder:prefs.numbers[@2]];
  NSTextView* numberEditor=(NSTextView*)prefs.window.firstResponder;assert([numberEditor isKindOfClass:NSTextView.class]);
  numberEditor.string=@"-18.5";numberEditor.selectedRange=NSMakeRange(5,0);
  NSEvent* selectAll=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:prefs.window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
  assert([prefs editShortcut:selectAll] && NSEqualRanges(numberEditor.selectedRange,NSMakeRange(0,5)));
  [window makeKeyAndOrderFront:nil];assert(prefs.window.visible && prefs.keyboardMonitor);
  // Same typed controller state drives the persistent native preset editor.
  NSMutableDictionary* editorState=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"tests/native-editor-state.json"] options:NSJSONReadingMutableContainers error:nil];
  editorState[@"presets"][2][@"label"]=@"Heavy"; // Names are editable; duplicate titles must retain distinct IDs.
  value[@"editor"]=editorState;update(value);AMEditorPanel* edit=bar.editorPanel;
  assert(edit.presets.count==4 && edit.presets[1].state==NSControlStateValueOn && edit.presets[2].state==NSControlStateValueOff);
  assert(edit.presets[0].frame.origin.y==edit.presets[3].frame.origin.y);
  assert(edit.window.visible && edit.window.parentWindow==window && edit.tabs.numberOfTabViewItems==3);
  assert([edit.controls[0].stringValue isEqual:@"Heavy"] && edit.controls[4].doubleValue==.72);
  NSView* sound=edit.tabs.tabViewItems[0].view;
  assert(edit.controls[1].superview==sound && edit.controls[2].superview==sound && edit.controls[6].superview==sound);
  assert(NSEqualRects(edit.controls[1].frame,NSMakeRect(14,12,300,26)) && NSEqualRects(edit.controls[2].frame,NSMakeRect(330,12,300,26)));
  assert(edit.measurement.superview==edit.tabs.tabViewItems[1].view && edit.actions.lastObject.superview==edit.measurement.superview);
  for(int page : {1,3,4,0}){
    editorState[@"page"]=@(page);editorState[@"focus"]=@([editorState[@"focus"] integerValue]+1);update(value);
    assert([edit.tabs indexOfTabViewItem:edit.tabs.selectedTabViewItem]==(page>=3?2:page));
    if(page==1){[edit.actions.lastObject performClick:nil];assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["op"]=="analyse");}
  }
  for(NSTabViewItem* tab in edit.tabs.tabViewItems)for(NSView* child in tab.view.subviews)assert(NSContainsRect(tab.view.bounds,child.frame));
  [window makeKeyAndOrderFront:nil];update(value);assert(edit.window.visible);
  edit.numbers[@4].stringValue=@"0.63";[edit fieldChanged:edit.numbers[@4]];
  auto editEvent=nlohmann::json::parse(std::string(AMBarPoll()).substr(7));assert(editEvent["id"]=="heavy" && editEvent["key"]=="rate" && editEvent["value"]==.63);
  edit.numbers[@4].stringValue=@"0.6bad";[edit fieldChanged:edit.numbers[@4]];assert(std::string(AMBarPoll()).empty());
  [edit.tabs selectTabViewItemAtIndex:2];
  assert(edit.controls[0].superview==edit.tabs.selectedTabViewItem.view);
  [edit.controls[0] setStringValue:@"マイク 🎤"];[edit fieldChanged:(NSTextField*)edit.controls[0]];
  assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["value"]=="マイク 🎤");
  [edit.tabs selectTabViewItemAtIndex:0];
  [edit.presets[2] performClick:nil];assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["value"]=="dark");
  // A direct preset click commits the old preset's field before selecting the new ID.
  [edit.window makeFirstResponder:edit.numbers[@4]];[(NSTextView*)edit.window.firstResponder setString:@"0.81"];
  [edit.presets[0] performClick:nil];editEvent=nlohmann::json::parse(std::string(AMBarPoll()).substr(7));
  assert(editEvent["id"]=="heavy" && editEvent["key"]=="rate" && editEvent["value"]==.81);
  assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["value"]=="raw");
  editorState[@"id"]=@"raw";update(value);assert(!edit.controls[0].enabled && !edit.fx.enabled && !edit.controls[5].enabled && !edit.controls[6].enabled && edit.controls[7].enabled);
  assert(edit.presets[0].state==NSControlStateValueOn && edit.presets[1].state==NSControlStateValueOff);
  editorState[@"values"][@"metric"]=@"zwicker_p95";update(value);assert(!edit.numbers[@9].enabled && edit.numbers[@10].enabled);
  value[@"paused"]=@YES;update(value);assert(edit.window.visible && !edit.controls[7].enabled);
  for(NSButton* b in edit.presets)assert(!b.enabled);
  [edit.window performClose:nil];assert(!edit.window.visible && std::string(AMBarPoll())=="editor:close");
  update(value);assert(!edit.window.visible);editorState[@"open"]=@NO;update(value);
  value[@"paused"]=@NO;editorState[@"open"]=@YES;editorState[@"focus"]=@2;editorState[@"id"]=@"heavy";update(value);
  [edit.window makeFirstResponder:edit.numbers[@4]];NSTextView* rateEditor=(NSTextView*)edit.window.firstResponder;rateEditor.string=@"0.83";
  editorState[@"values"][@"rate"]=@1.2;update(value);assert([rateEditor.string isEqual:@"0.83"]);
  [edit.window makeFirstResponder:edit.tabs];assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["value"]==.83);
  NSArray* originalPresets=[editorState[@"presets"] copy];
  NSMutableArray* manyPresets=[originalPresets mutableCopy];
  while(manyPresets.count<10)[manyPresets addObject:@{@"id":[NSString stringWithFormat:@"preset%lu",(unsigned long)manyPresets.count],@"label":@"長いプリセット名 — Microphone 🎤 ambience"}];
  editorState[@"presets"]=manyPresets;update(value);
  assert(edit.presets.count==10 && edit.presets.lastObject.frame.origin.y>0);
  for(NSButton* b in edit.presets)assert(NSContainsRect(edit.presetStrip.bounds,b.frame) && !b.hidden && [b.toolTip isEqual:b.title]);
  assert(NSMaxY(edit.presetStrip.frame)<NSMinY(edit.save.frame));
  [edit.presets[9] performClick:nil];assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["value"]=="preset9");
  editorState[@"presets"]=@[originalPresets[0],originalPresets[3],originalPresets[1]];update(value);
  [edit.presets[1] performClick:nil];assert(nlohmann::json::parse(std::string(AMBarPoll()).substr(7))["value"]=="reverse");
  assert(edit.presets.count==3 && edit.presets[2].state==NSControlStateValueOn);
  [edit.window setContentSize:NSMakeSize(700,450)];
  NSScrollView* editorScroll=(NSScrollView*)edit.window.contentView;
  assert([editorScroll isKindOfClass:NSScrollView.class] && editorScroll.documentView.frame.size.height==700+edit.presetOffset && editorScroll.hasVerticalScroller);
  [edit.window setContentSize:NSMakeSize(700,700)];
  [value removeObjectForKey:@"channels"];[value removeObjectForKey:@"settings"];[value removeObjectForKey:@"editor"];update(value);
  assert(!picker.popover.shown && !prefs.window.visible && !edit.window.visible && std::string(AMBarPoll()).empty());
  value[@"settings"]=settings;value[@"editor"]=editorState;update(value);
  assert(prefs.window.visible && edit.window.visible && edit.presets.count==3);
  NSWindow* editorWindow=edit.window;
  NSWindow* settingsWindow=prefs.window;
  [search removeFromSuperview];[window makeFirstResponder:nil];
  resize(original.size.width,original.size.height);
  assert(AMBarAttach((__bridge void *)host,(__bridge void *)list));
  assert(bar.baseFrame.size.height==original.size.height);AMBarDetach();
  assert(NSEqualRects(list.frame,original) && list.postsFrameChangedNotifications==posting);
  assert(std::string(AMBarGeometry())=="{}" && !settingsWindow.visible && !editorWindow.visible);[window close];
  puts("PASS: direct preset clicks, Downmix state and visibility, responsive Cocoa layout, Unicode labels, paused controls, focus and list restoration");
}}
