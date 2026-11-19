local Fast=require('am.selection');local J=require('am.json');local Bank=require('am.bank')
local project={};local input={guid='input'};local raw={guid='raw'};local fx={guid='fx'}
local tracks={input,raw,fx};local pending,state,handle,requests,detaches=true,nil,{},0,0
local active_project=project;local window={};local attached_window=window
local enabled,publications=false,0
local r={ValidatePtr=function(p)return p==project end,
  EnumProjects=function()return active_project end,
  ValidatePtr2=function(_,track)for _,t in ipairs(tracks)do if t==track then return true end end;return false end,
  GetTrackGUID=function(track)return track.guid end,GetTrack=function(_,i)return tracks[i+1]end,
  CountTracks=function()return #tracks end,
  GetMediaTrackInfo_Value=function(track)for i,t in ipairs(tracks)do if t==track then return i end end end,
  AM_SelectionEnable=function(on)enabled=on end,AM_SelectionPending=function()return pending end,
  AM_SelectionWindow=function()return attached_window end,
  AM_SelectionAttach=function(w)attached_window=w;state=nil;return true end,
  AM_SelectionPublish=function(text,owner,preview)
    assert(owner==project and not pending);state=text;handle=preview;publications=publications+1;return true
  end,
  AM_SelectionRead=function()return state end,AM_SelectionPreview=function()return handle end,
  AM_SelectionAcknowledge=function()pending=false end,
  AM_SelectionDetach=function()detaches=detaches+1;pending=false end}
local app={r=r,session='owner',project=project,root='.',data='data',definition={settings={}},path='old.wav',
  source_channels=2,selected_id='preset',transform_override={pitch_semitones=-3},
  preview={path='old.wav',starts=10,fx_track=fx,macro={source_transform={rate=.75}},gain_target=-7},
  explorer={selected={index=2,path='old.wav'},polled_index=2,window=function()return window end,control=function()return 'list'end},
  selection_attached=true,check_project=function()return true end}
app.bank=setmetatable({r=r,project=project,tracks={input,raw,fx},input=input,raw=raw,chosen=fx,macros={preset=fx},
  dirty_buffers={[fx]=true},channel_state={[fx]={applied=4,minimum=2,pin_minimum=4,pins='pins'}},channels=4},Bank)
app.request_analysis=function(self)
  requests=requests+1;assert(self.path=='new.wav'and self.preview.handle==handle,'Analysis preceded adoption')
end
app.close=function(self)self.closed=true end
local snapshot=Fast.snapshot(app)
snapshot.app.path='new.wav';snapshot.app.source_channels=4;snapshot.app.paused_source=nil
snapshot.preview.path='new.wav';snapshot.preview.starts=11;snapshot.preview.gain_target=nil
snapshot.bank.dirty={};snapshot.needs_analysis=true
state=J.encode(snapshot)
-- A user may reorder tracks between immediate playback and Lua adoption.
tracks={fx,input,raw}
assert(Fast.consume(app)and not pending and requests==1)
assert(app.path=='new.wav'and app.preview.path==app.path and app.preview.starts==11 and app.preview.handle==handle)
assert(app.preview.gain_target==nil and app.preview.fx_track==fx and app.bank.chosen==fx)
assert(app.bank.input==input and app.bank.raw==raw and app.bank.macros.preset==fx)
assert(not next(app.bank.dirty_buffers)and app.bank.channel_state[fx].pin_minimum==4)
assert(app.transform_override.pitch_semitones==-3 and not Fast.consume(app)and requests==1)

local build,encode=Fast.snapshot,J.encode;local snapshots,encodes=0,0
Fast.snapshot=function(...)snapshots=snapshots+1;return build(...)end
J.encode=function(...)encodes=encodes+1;return encode(...)end
local function publish_change()
  local before=publications
  Fast.publish(app)
  assert(enabled and publications==before+1 and snapshots==publications and encodes==publications)
  Fast.consume(app);assert(not enabled)
  Fast.publish(app)
  assert(enabled and publications==before+1 and snapshots==publications and encodes==publications,
    'An unchanged publish rebuilt, encoded or sent the snapshot')
end
publish_change()
app.definition.settings.autoplay=true;publish_change();assert(J.decode(state).definition.settings.autoplay)
app.preset_drafts={preset={source_transform={rate=1}}};publish_change()
app.preset_drafts.preset.source_transform.rate=.5;publish_change()
assert(J.decode(state).app.preset_drafts.preset.source_transform.rate==.5)
tracks={raw,fx,input};publish_change();assert(J.decode(state).tracks[1].index==2)
fx.guid='new-fx-guid';publish_change();assert(J.decode(state).tracks[3].guid==fx.guid)
local next_handle={};app.preview.handle=next_handle;publish_change();assert(handle==next_handle)
app.preview.eof_path=app.path;publish_change();assert(J.decode(state).preview.eof_path==app.path)
active_project={};local before=publications;Fast.publish(app);assert(not enabled and publications==before)
active_project=project;Fast.publish(app);assert(enabled and publications==before)
window={};publish_change()
-- A handoff overwrites the native snapshot even if later Lua changes bring
-- every input back to the values published before the handoff.
local returned=J.decode(state);returned.app.message='from observer';state=encode(returned);pending=true
assert(Fast.consume(app)and app.message=='from observer');app.message=nil;publish_change()
local with_fx=state
tracks={raw,input};app.bank.tracks={input,raw};app.bank.macros.preset=nil;app.bank.channel_state[fx]=nil
app.bank.chosen=raw;app.preview.fx_track=nil;publish_change();assert(#J.decode(state).tracks==2)
Fast.snapshot=build;J.encode=encode

-- Deletion before adoption fails closed, disposing of the unclaimed native
-- preview instead of allowing an old/destroyed handle into another play call.
pending=true;state=with_fx;assert(not Fast.consume(app))
assert(app.closed and app.preview.handle==nil and not app.selection_attached and detaches==1)
-- Internal actions cannot be manually invoked to start a second owner.
Fast.dispatch({APIExists=function()return true end,AM_SelectionDispatching=function()return false end})
