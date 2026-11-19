-- Native selection notifications invoke a short, synchronous ReaScript action.
-- Reuse the same playback/FX code in that action, then hand its live state back
-- to the companion. The audio starts before the companion's next defer tick.
local J=require('am.json');local U=require('am.util')
local M={}
local app_fields={'path','identity','source_channels','range','paused_position','paused_source','paused_length',
  'last_seek','applied_gain','applied_status','playback_identity','playback_analysis','message','tempo_factor',
  'transform_override','reverse_override','effective_macro','effective_id','effective_reverse','edit_preview',
  'preset_drafts','selected_id','previous_id','advance_path'}
local preview_fields={'starts','path','ended_path','eof_path','macro','range','source_length','gain_db','source_channels',
  'channel_selection','output_channels','downmix_mode','gain_target','gain_tick_time'}
local bank_fields={'channels','fx_bypassed','routing_dirty','keep_running','active_gain','active','active_gain_db','loads','switches'}
local explorer_fields={'selected','polled_index','last_transform','range_key','range_length'}
local function fields(object,names)
  local result={};for _,key in ipairs(names)do result[key]=object[key]end;return result
end
local function restore(object,values,names)
  for _,key in ipairs(names)do object[key]=values[key]end
end
function M.snapshot(app,slots)
  local r,bank=app.r,app.bank;local tracks=J.array{};slots=slots or {}
  for i,track in ipairs(bank.tracks)do
    assert(bank:valid(track),'Preview track was removed')
    slots[track]=i;tracks[i]={guid=r.GetTrackGUID(track),index=r.GetMediaTrackInfo_Value(track,'IP_TRACKNUMBER')-1}
  end
  local b=fields(bank,bank_fields)
  b.input=slots[bank.input];b.raw=slots[bank.raw];b.chosen=slots[bank.chosen];b.macros={};b.dirty={};b.channel_state={}
  for id,track in pairs(bank.macros)do b.macros[id]=assert(slots[track])end
  for track,value in pairs(bank.dirty_buffers or {})do b.dirty[tostring(assert(slots[track]))]=value end
  for track,value in pairs(bank.channel_state or {})do b.channel_state[tostring(assert(slots[track]))]=value end
  local p=fields(app.preview,preview_fields);p.fx_track=slots[app.preview.fx_track]
  return {revision=1,session=app.session,root=app.root,data=app.data,definition=app.definition,tracks=tracks,
    app=fields(app,app_fields),bank=b,preview=p,explorer=fields(app.explorer,explorer_fields),needs_analysis=app.selection_needs_analysis or false}
end
-- Compare the live inputs against saved values without constructing a snapshot.
-- Definition settings and drafts can be edited in place between publishes.
local function same_value(a,b)
  if a==b then return true end
  if type(a)~='table' or type(b)~='table' or a==J.null or b==J.null or getmetatable(a)~=getmetatable(b) then return false end
  for k,v in pairs(a)do if not same_value(v,b[k])then return false end end
  for k in pairs(b)do if a[k]==nil then return false end end
  return true
end
local function same_fields(object,saved,names)
  for _,key in ipairs(names)do if not same_value(object[key],saved[key])then return false end end
  return true
end
local function same_track_map(values,saved,slots,track_keys)
  local count=0
  if values then
    for key,value in pairs(values)do
      if track_keys then
        if not slots[key]then return false end
        key=tostring(slots[key])
      else
        value=slots[value];if not value then return false end
      end
      if not same_value(value,saved[key])then return false end
      count=count+1
    end
  end
  for _ in pairs(saved)do count=count-1 end
  return count==0
end
local function unchanged(app,published)
  local r,bank,preview=app.r,app.bank,app.preview
  local saved,slots=published.state,published.slots
  if published.project~=app.project or published.handle~=preview.handle or published.definition~=app.definition or
      saved.session~=app.session or saved.root~=app.root or saved.data~=app.data or
      saved.needs_analysis~=(app.selection_needs_analysis or false) or #bank.tracks~=#saved.tracks then return false end
  for i,track in ipairs(bank.tracks)do
    local before=saved.tracks[i]
    if slots[track]~=i or not bank:valid(track) or r.GetTrackGUID(track)~=before.guid or
        r.GetMediaTrackInfo_Value(track,'IP_TRACKNUMBER')-1~=before.index then return false end
  end
  local b=saved.bank
  return slots[bank.input]==b.input and slots[bank.raw]==b.raw and slots[bank.chosen]==b.chosen and
    slots[preview.fx_track]==saved.preview.fx_track and same_fields(bank,b,bank_fields) and
    same_track_map(bank.macros,b.macros,slots,false) and same_track_map(bank.dirty_buffers,b.dirty,slots,true) and
    same_track_map(bank.channel_state,b.channel_state,slots,true) and same_fields(preview,saved.preview,preview_fields) and
    same_fields(app,saved.app,app_fields) and same_fields(app.explorer,saved.explorer,explorer_fields) and
    same_value(app.definition,saved.definition)
end
local function resolve_tracks(r,project,snapshot)
  local tracks={}
  for i,entry in ipairs(snapshot.tracks)do
    local track=r.GetTrack(project,entry.index)
    if not track or r.GetTrackGUID(track)~=entry.guid then
      track=nil
      for n=0,r.CountTracks(project)-1 do local candidate=r.GetTrack(project,n)
        if r.GetTrackGUID(candidate)==entry.guid then track=candidate;break end
      end
    end
    assert(track and r.ValidatePtr2(project,track,'MediaTrack*'),'Preview track was removed')
    tracks[i]=track
  end
  return tracks
end
function M.restore(app,snapshot,handle)
  assert(snapshot.revision==1 and snapshot.session==app.session,'Stale selection state')
  local tracks=resolve_tracks(app.r,app.project,snapshot)
  -- The observer may have replaced its snapshot and the native waveform state.
  app.selection_published=nil;app.channel_waveform=nil
  local b=snapshot.bank;local bank=app.bank
  restore(app,snapshot.app,app_fields);restore(app.preview,snapshot.preview,preview_fields)
  restore(bank,b,bank_fields);restore(app.explorer,snapshot.explorer,explorer_fields)
  bank.tracks=tracks;bank.input=assert(tracks[b.input]);bank.raw=assert(tracks[b.raw]);bank.chosen=tracks[b.chosen]
  bank.macros={};for id,i in pairs(b.macros)do bank.macros[id]=assert(tracks[i])end
  bank.dirty_buffers={};for i,value in pairs(b.dirty)do bank.dirty_buffers[assert(tracks[tonumber(i)])]=value end
  bank.channel_state={};for i,value in pairs(b.channel_state)do bank.channel_state[assert(tracks[tonumber(i)])]=value end
  app.preview.track=bank.input;app.preview.fx_track=tracks[snapshot.preview.fx_track];app.preview.handle=handle
  app.selection_needs_analysis=snapshot.needs_analysis or false
end
function M.consume(app)
  if not app.selection_attached then return false end
  local r=app.r;r.AM_SelectionEnable(false)
  if not r.ValidatePtr(app.project,'ReaProject*')then r.AM_SelectionDetach();app.selection_attached=nil;app.selection_published=nil;return false end
  if not r.AM_SelectionPending()then return false end
  local ok,err=pcall(function()
    M.restore(app,J.decode(r.AM_SelectionRead()),r.AM_SelectionPreview())
  end)
  if not ok then
    r.AM_SelectionDetach();app.selection_attached=nil;app.selection_published=nil;app.preview.handle=nil
    app.message=tostring(err);app:close();return false
  end
  r.AM_SelectionAcknowledge()
  if app.selection_needs_analysis then
    app.selection_needs_analysis=nil
    if not app.closed and not app.cleaned then app:request_analysis()end
  end
  return true
end
function M.publish(app)
  if not app.selection_attached or app.closed or app.cleaned then return end
  local r=app.r
  if r.EnumProjects(-1)~=app.project or not app:check_project()then r.AM_SelectionEnable(false);return end
  local window=app.explorer:window()
  if not window then r.AM_SelectionEnable(false);return end
  if r.AM_SelectionWindow()~=window then
    assert(r.AM_SelectionAttach(window,app.explorer:control(1001),app.selection_command),'Cannot reattach selection observer')
    app.selection_published=nil
  end
  local published=app.selection_published
  if not published or not unchanged(app,published) or r.AM_SelectionPending() then
    local slots={};local snapshot=M.snapshot(app,slots)
    assert(r.AM_SelectionPublish(J.encode(snapshot),app.project,app.preview.handle),'Cannot publish selection state')
    app.selection_published={state=U.copy(snapshot),slots=slots,definition=app.definition,project=app.project,handle=app.preview.handle}
  end
  r.AM_SelectionEnable(true)
end
function M.attach(app)
  local r=app.r
  if not r.APIExists('AM_SelectionAttach')then return false end -- Older helpers/macOS keep polling.
  local command=r.AddRemoveReaScript(true,0,app.root..'/internal/Process selection.lua',false)
  assert(command>0,'Cannot register selection processor')
  assert(r.AM_SelectionAttach(app.explorer:window(),app.explorer:control(1001),command),'Cannot attach selection observer')
  app.selection_attached=true;app.selection_command=command;app.selection_published=nil;M.publish(app);return true
end
function M.close(app)
  if not app.selection_attached then return end
  M.consume(app);app.r.AM_SelectionDetach();app.selection_attached=nil;app.selection_published=nil
end
function M.dispatch(r)
  -- Manual execution of the internal action is inert. The native observer owns
  -- its project/window, one dispatch at a time, and the preview handle lifetime.
  if not r.APIExists('AM_SelectionDispatching')or not r.AM_SelectionDispatching()then return end
  local app
  local ok,err=xpcall(function()
    local value=J.decode(r.AM_SelectionRead());local project=r.AM_SelectionProject()
    assert(value.revision==1 and r.ValidatePtr(project,'ReaProject*') and r.EnumProjects(-1)==project,'Inactive selection project')
    if r.GetExtState('AuditionMacro.v1','queue')~='' or r.GetExtState('AuditionMacro.Drop.v1','busy')=='1' then return end
    local App=require('am.app');local Bank=require('am.bank');local Preview=require('am.preview')
    local Explorer=require('am.media_explorer');local Loudness=require('am.loudness')
    app=setmetatable({r=r,root=value.root,data=value.data,session=value.session,project=project,definition=value.definition},App)
    app.bank=setmetatable({r=r,project=project,definition=app.definition,session=app.session},Bank)
    app.preview=Preview.new(r,project,nil);app.explorer=Explorer.new(r)
    local window=r.AM_SelectionWindow()
    app.explorer.hwnd=window;app.explorer.native_transport=window;app.explorer.owns_audio=true
    -- Cache reads/gain decisions use the existing implementation. Worker starts
    -- stay in the companion, so two VMs never own/cancel the same analysis job.
    app.loudness=setmetatable({r=r,root=app.root,data=app.data,settings=app.definition.settings,session=app.session,
      analyzer_key=Loudness.ANALYZER_KEY,memory={},keys=setmetatable({},{__mode='k'})},Loudness)
    app.request_analysis=function(self)self.selection_needs_analysis=true end
    M.restore(app,value,r.AM_SelectionPreview())
    local path,reason=app.explorer:selection()
    if path==app.path then return end
    local autoplay=app.definition.settings.autoplay or app.advance_path==path
    app:select_source(path,reason,true)
    if app.identity then
      if autoplay then app.advance_path=nil;app:play()
      elseif app:effective().normalization.enabled or app:effective().source_peak_guard.enabled then app.selection_needs_analysis=true end
    end
    assert(r.AM_SelectionComplete(J.encode(M.snapshot(app)),app.preview.handle),'Cannot return selection state')
  end,debug.traceback)
  if not ok then
    if app then
      -- Return a stopped/error state when playback failed after clearing the old
      -- source, rather than leaving the companion with its destroyed handle.
      app.message=tostring(err)
      local saved=pcall(function()assert(r.AM_SelectionComplete(J.encode(M.snapshot(app)),app.preview.handle))end)
      if saved then return end
      pcall(app.preview.stop,app.preview,true)
    end
    r.AM_SelectionEnable(false)
    r.ShowConsoleMsg('SoundPrep selection: '..tostring(err)..'\n')
  end
end
return M
