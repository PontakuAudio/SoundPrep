local U=require('am.util');local Model=require('am.model');local App=require('am.app')
local Bank=require('am.bank');local Preview=require('am.preview')
local function fx(kind,enabled,offline)
  return {kind=kind,enabled=enabled~=false,offline=offline==true,buffer=1,param=.73,guid=kind..'-guid'}
end
local active={B_MAINSEND=1,I_FXEN=1,fx={[0]=fx('VST3'),[1]=fx('AU'),[2]=fx('VST',false)},count=3}
local inactive={B_MAINSEND=0,I_FXEN=0,fx={[0]=fx('CLAP'),[1]=fx('Container'),[100]=fx('JS'),[101]=fx('JS',true,true)},count=2}
inactive.fx[1].children={100,101}
local before={active=U.copy(active),inactive=U.copy(inactive)}
local refresh_depth=0;local offline_vst=0
local r={PreventUIRefresh=function(delta)refresh_depth=refresh_depth+delta end,
  ValidatePtr=function()return true end,ValidatePtr2=function()return true end,
  GetMediaTrackInfo_Value=function(t,key)return t[key]end,
  SetMediaTrackInfo_Value=function(t,key,value)t[key]=value end,
  TrackFX_GetCount=function(t)return t.count end,
  TrackFX_GetOffline=function(t,i)return t.fx[i].offline end,
  TrackFX_GetEnabled=function(t,i)return t.fx[i].enabled end,
  TrackFX_GetNamedConfigParm=function(t,i,key)
    local f=t.fx[i]
    if key=='fx_type'then return true,f.kind end
    if key=='container_count' and f.children then return true,tostring(#f.children)end
    local child=key:match('^container_item%.(%d+)$')
    if child then return true,tostring(f.children[tonumber(child)+1])end
    return false,''
  end,
  TrackFX_SetEnabled=function(t,i,enabled)
    assert(t.B_MAINSEND==0,'A buffer reset reached the output')
    if t.vst_only then assert(t.I_FXEN==0,'VST resets repeatedly contend with a live chain')end
    local f=t.fx[i];f.enabled=enabled;if not enabled then f.buffer=0 end
  end,
  TrackFX_SetOffline=function(t,i,offline)
    if t.fx[i].kind=='VST' or t.fx[i].kind=='VST3'then offline_vst=offline_vst+1 end
    assert(t.B_MAINSEND==0,'An instance reset reached the output')
    t.fx[i].offline=offline;if offline then t.fx[i].buffer=0 end
  end}
local bank=setmetatable({r=r,macros={active=active,inactive=inactive},loads=7,live_pdc=function()end},Bank)
bank:reset_buffers(bank.macros)
for name,t in pairs(bank.macros)do
  local saved=before[name]
  assert(t.B_MAINSEND==saved.B_MAINSEND and t.I_FXEN==saved.I_FXEN)
  for i,f in pairs(t.fx)do
    local original=saved.fx[i]
    assert(f.enabled==original.enabled and f.offline==original.offline and f.param==original.param and f.guid==original.guid)
    if f.kind~='Container' and not f.offline then assert(f.buffer==0,'A branch retained the old source')end
  end
end
assert(bank.loads==7 and inactive.fx[101].buffer==1,'An offline instance was brought online')
assert(offline_vst==0 and refresh_depth==0,'VST reset recreated an instance or leaked UI suppression')
local vst_only={vst_only=true,B_MAINSEND=1,I_FXEN=1,fx={[0]=fx('VST3'),[1]=fx('VST',false)},count=2}
bank:reset_buffers({vst_only})
assert(vst_only.B_MAINSEND==1 and vst_only.I_FXEN==1 and vst_only.fx[0].enabled and not vst_only.fx[1].enabled)
assert(vst_only.fx[0].buffer==0 and vst_only.fx[1].buffer==0 and offline_vst==0 and refresh_depth==0)
local named=r.TrackFX_GetNamedConfigParm
r.TrackFX_GetNamedConfigParm=function(t,i,key)if key=='container_item.0'then return false,''end;return named(t,i,key)end
assert(not pcall(bank.reset_buffers,bank,bank.macros))
assert(active.B_MAINSEND==1 and inactive.B_MAINSEND==0,'Failed inspection lost output routing')
assert(refresh_depth==0,'Failed reset leaked UI suppression')
r.TrackFX_GetNamedConfigParm=named

-- Source changes mute immediately without rebuilding unused FX. The branch
-- is flushed once before routing it; keep-running flushes every pending branch.
active.fx[0].buffer=1;inactive.fx[0].buffer=1
bank:clear_buffers()
assert(active.B_MAINSEND==0 and inactive.B_MAINSEND==0)
assert(active.fx[0].buffer==1 and inactive.fx[0].buffer==1)
bank:flush_pending(false,active)
assert(active.fx[0].buffer==0 and inactive.fx[0].buffer==1)
active.fx[0].buffer=.5;bank:flush_pending(false,active)
assert(active.fx[0].buffer==.5,'Same-source preset switch reset an already clean branch')
bank:flush_pending(true)
assert(inactive.fx[0].buffer==0 and active.fx[0].buffer==.5)
bank:clear_buffers();bank:clear_buffers();bank:flush_pending(false,inactive)
assert(bank.dirty_buffers[active] and not bank.dirty_buffers[inactive])
r.TrackFX_GetNamedConfigParm=function()error('reset failed')end
assert(not pcall(bank.flush_pending,bank,false,active))
assert(bank.dirty_buffers[active] and active.B_MAINSEND==0)
r.TrackFX_GetNamedConfigParm=named

local order={}
local preview=setmetatable({handle={},set_value=function(_,key,value)
  assert(key=='D_FADEOUTLEN' and value==0);order[#order+1]='hard'
  return true
end,stop_handle=function()order[#order+1]='stop'end},Preview)
preview:stop(true);assert(table.concat(order,',')=='hard,stop' and not preview.handle)
preview.handle={};order={};preview:stop();assert(table.concat(order,',')=='stop')

local next_path,mtime,now='B.wav',1,1
local clears,starts=0,0;local project={}
local app=setmetatable({r={EnumProjects=function()return project end,ValidatePtr=function()return true end,GetExtState=function()return ''end,
  time_precise=function()return now end,JS_File_Stat=function()return 0,100,0,mtime end,
  PCM_Source_CreateFromFile=function()return {}end,GetMediaSourceNumChannels=function()return 2 end,
  PCM_Source_Destroy=function()end},
  project=project,path='A.wav',identity={path='A.wav',size=100,mtime=1},last_poll=0,
  definition=Model.defaults(),publish=function()end,loudness={poll=function()end},
  explorer={selection=function()return next_path end,transport_event=function()end},
  bank={tracks={},valid=function()return true end,clear_buffers=function()clears=clears+1 end,
    set_channels=function(_,count)assert(count==2)end},
  preview={stop=function(_,immediate)assert(immediate)end,playing=function()return false end},
  sync_range=function()return false end,sync_wave=function()end,sync_transform=function()end,commands=function()end,
  play=function()starts=starts+1;assert(clears>0)end},App)
app.definition.settings.autoplay=false
app:tick();assert(clears==1 and starts==0,'Selecting without autoplay did not clear the old source')
now=2;app:tick();assert(clears==1,'An unchanged file flushed its FX again')
app.definition.settings.autoplay=true;next_path='C.wav';now=3;app:tick()
assert(clears==2 and starts==1,'Autoplay started before the source boundary reset')
mtime=2;now=4;app:tick();assert(clears==3,'Replacing the selected file did not clear its buffers')
next_path=nil;now=5;app:tick();assert(clears==4,'An empty selection retained the previous audio')
now=6;app:tick();assert(clears==4)
next_path='D.wav';now=7;app:tick();assert(clears==4,'A first source reset an already empty bank')

-- Startup reads the pre-existing selection without interpreting it as a click.
app.path=nil;app.identity=nil;clears=0;starts=0
app.sync_range=App.sync_range
app.explorer.preview_range=function()return true,{.1,.9}end
app:select_source(next_path)
assert(app.path=='D.wav'and app.identity and app.range[1]==.1 and starts==0 and clears==0)
now=8;app:tick();assert(starts==0,'First poll replayed the startup selection')
next_path='E.wav';now=9;app:tick()
assert(starts==1 and clears==1,'A later user selection no longer followed autoplay')

-- Slow analysis setup must not delay autoplay. Selection without autoplay
-- still requests analysis, so normalization and subsequent D&D remain ready.
local requested=0
app.definition.raw.normalization.enabled=true
app.effective_macro=nil
app.request_analysis=function()requested=requested+1 end
app.play=function(self)
  assert(requested==0,'Analysis setup blocked autoplay')
  self:request_analysis()
end
next_path='F.wav';now=10;app:tick();assert(requested==1)
requested=0;app.definition.settings.autoplay=false
next_path='G.wav';now=11;app:tick();assert(requested==1)

-- A row change gets the next defer tick even with a long metadata interval.
-- Completed analysis may start another worker; keep that I/O after playback.
app.definition.settings.autoplay=true;app.definition.settings.poll_ms=200
local polled,played=0,0
app.loudness.poll=function()polled=polled+1;assert(played==1,'Worker/result I/O delayed the new audition')end
app.explorer.selection_changed=function()return true end
app.play=function()assert(polled==0);played=played+1 end
next_path='H.wav';now=11.01;app:tick()
assert(played==1 and polled==1 and app.path=='H.wav','Row change waited for metadata polling')
app.explorer.selection_changed=function()return false end
next_path='I.wav';now=11.02;app:tick()
assert(app.path=='H.wav','Unchanged row unnecessarily resolved metadata')
