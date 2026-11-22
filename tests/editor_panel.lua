local Editor=require('am.editor_panel');local App=require('am.app');local Model=require('am.model');local J=require('am.json');local U=require('am.util');local Bar=require('am.bar')
local project={};local active=project;local calls={};local clock=0
local a=setmetatable({definition=Model.defaults(),project=project,selected_id='heavy',message='',data='/unused',tempo_factor=1,
  r={time_precise=function()return clock end,EnumProjects=function()return active end},loudness={},
  bank={activate=function()end,chain=function()return 'SHOW -1\n'end},preview={playing=function()return false end,latency_track=function()end},
  explorer={set_transform=function()end,focus_list=function()calls.focus=true end},refresh_processing=function()end,
  measurement=function()return nil end,gain=function()return 0,'off'end},App)
local bar=Bar.new(a.r,a)
local function event(op,key,value,id)bar:dispatch('editor@'..J.encode{op=op,key=key,value=value,id=id or a.selected_id or 'raw'})end
bar:dispatch('edit');local state=Editor.state(a);assert(state.open and state.page==-1 and state.id=='heavy')
local fixture=J.decode(assert(U.read('tests/native-editor-state.json')))
assert(U.equal(state.values,fixture.values) and U.equal(state.presets,fixture.presets))
bar:dispatch('edit');assert(Editor.state(a).focus==2)
local original=U.copy(a.definition)
event('set','name','マイク 🎤 Test');event('set','pitch',-7.5);event('set','rate',.63);event('set','preserve',true)
event('set','gain',-3);event('set','normalize',true);event('set','metric','zwicker_p95');event('set','sones',12.5)
event('set','tail',2.5)
state=Editor.state(a);assert(state.dirty and state.values.name=='マイク 🎤 Test' and state.values.rate==.63 and state.values.preserve)
assert(state.values.tail==2.5 and a:preset_draft('heavy').export.tail_seconds==2.5)
for key,value in pairs{final=true,limiter=true,export_ceiling=-1.5}do
  assert(state.values[key]==nil and not pcall(event,'set',key,value))
end
assert(U.equal(a.definition,original),'Native editing prematurely saved the bank')
local draft=J.encode(a:preset_draft('heavy'))
for _,bad in ipairs{{'name',''},{'name',string.rep('a',129)},{'name','x\ny'},{'pitch',25},{'rate',0},{'preserve',1},{'metric','bogus'},{'sones',0},{'gain',13},{'tail',31},{'unknown',1}}do
  assert(not pcall(event,'set',bad[1],bad[2]));assert(J.encode(a:preset_draft('heavy'))==draft,'Invalid input poisoned the draft')
end
assert(not pcall(event,'set','gain',-12,'dark'));assert(J.encode(a:preset_draft('heavy'))==draft)
event('select',nil,'dark');assert(a.selected_id=='dark');event('select',nil,'heavy');assert(a:effective().name=='マイク 🎤 Test'and a:effective().source_transform.rate==.63)
bar:dispatch('editor:close');assert(not Editor.state(a));bar:dispatch('target:custom');assert(Editor.state(a).page==1 and a:effective().output_gain_db==-3)
a.r.GetUserFileNameForRead=function()return true,'/tmp/test.RfxChain'end
a.import_chain=function(_,id,path)assert(id=='heavy' and path=='/tmp/test.RfxChain');calls.import=true end
a.bank.edit=function(_,id)assert(id=='heavy');calls.fx=true end
a.save_preset=function(_,id)assert(id=='heavy');calls.save=true end
a.revert_preset=function(_,id)assert(id=='heavy');calls.revert=true end
a.new_macro=function(_,id)calls[id and 'duplicate' or 'new']=true end
a.move=function(_,id,delta)assert(id=='heavy');calls[delta<0 and 'up' or 'down']=true end
for _,op in ipairs{'transport','play','ab','analyse'}do a[op]=function()calls[op]=true end end
for _,op in ipairs{'save','revert','fx','import','new','duplicate','up','down','play','replay','ab','analyse','focus'}do event(op)end
for _,op in ipairs{'save','revert','fx','import','new','duplicate','up','down','transport','play','ab','analyse','focus'}do assert(calls[op],op)end
assert(not pcall(event,'confirm_delete'));event('delete');assert(Editor.state(a).deleting);event('cancel_delete');assert(not Editor.state(a).deleting)
event('delete');event('select',nil,'dark');assert(not Editor.state(a).deleting);assert(not pcall(event,'confirm_delete'))
event('select',nil,'heavy');event('delete');a.delete=function(_,id)assert(id=='heavy');calls.delete=true end;event('confirm_delete');assert(calls.delete)
-- Project mismatch blocks editing but closing still works.
active={};local before=J.encode(a:preset_draft('heavy'));event('set','gain',-9);assert(before==J.encode(a:preset_draft('heavy')))
bar:dispatch('editor:close');assert(not Editor.state(a));active=project
-- Raw only saves normalization. Preserve Pitch stays a temporary transform.
a.ab=App.ab;event('select',nil,'raw');Editor.open(a);event('set','normalize',true);event('set','preserve',true)
assert(a:effective().source_transform.preserve_pitch and a:preset_draft('raw').normalization.enabled)
assert(not pcall(event,'set','name','Renamed raw') and not pcall(event,'set','gain',-3))
assert(not pcall(event,'set','tail',1))
event('set','reverse',true);assert(a:effective().source_transform.reverse and not a:preset_draft('raw').source_transform.reverse)
assert(a.definition.raw.normalization.enabled==false)
