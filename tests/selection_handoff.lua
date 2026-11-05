local Fast=require('am.selection');local J=require('am.json');local Bank=require('am.bank')
local project={};local input={guid='input'};local raw={guid='raw'};local fx={guid='fx'}
local tracks={input,raw,fx};local pending,state,handle,requests,detaches=true,nil,{},0,0
local r={ValidatePtr=function(p)return p==project end,
  ValidatePtr2=function(_,track)for _,t in ipairs(tracks)do if t==track then return true end end;return false end,
  GetTrackGUID=function(track)return track.guid end,GetTrack=function(_,i)return tracks[i+1]end,
  CountTracks=function()return #tracks end,
  GetMediaTrackInfo_Value=function(track)for i,t in ipairs(tracks)do if t==track then return i end end end,
  AM_SelectionEnable=function()end,AM_SelectionPending=function()return pending end,
  AM_SelectionRead=function()return state end,AM_SelectionPreview=function()return handle end,
  AM_SelectionAcknowledge=function()pending=false end,
  AM_SelectionDetach=function()detaches=detaches+1;pending=false end}
local app={r=r,session='owner',project=project,root='.',data='data',definition={settings={}},path='old.wav',
  source_channels=2,selected_id='preset',transform_override={pitch_semitones=-3},
  preview={path='old.wav',starts=10,fx_track=fx,macro={source_transform={rate=.75}},gain_target=-7},
  explorer={selected={index=2,path='old.wav'},polled_index=2},selection_attached=true}
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
-- Deletion before adoption fails closed, disposing of the unclaimed native
-- preview instead of allowing an old/destroyed handle into another play call.
pending=true;tracks={input,raw};assert(not Fast.consume(app))
assert(app.closed and app.preview.handle==nil and not app.selection_attached and detaches==1)
-- Internal actions cannot be manually invoked to start a second owner.
Fast.dispatch({APIExists=function()return true end,AM_SelectionDispatching=function()return false end})
