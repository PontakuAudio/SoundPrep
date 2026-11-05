-- Real Windows decoder/FX timing in a disposable host. No user media or bank.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath()
assert(r.file_exists(host..'/.audition-macro-test') and r.GetOS():match('^Win'))
package.path=root..'/lib/?.lua;'..package.path
local U=require('am.util');local J=require('am.json');local App=require('am.app');local Model=require('am.model')
local data=host..'/preview-performance';local app,done,pending
local host_api=r
r=setmetatable({}, {__index=host_api})
for _,name in ipairs{'TrackFX_SetEnabled','TrackFX_SetOffline','PCM_Source_CreateFromFile','JS_File_Stat','JS_WindowMessage_Send'}do
  r[name]=function(...)
    local at=host_api.time_precise();local result=table.pack(host_api[name](...))
    if pending then
      pending.api_ms=pending.api_ms or {};pending.api_calls=pending.api_calls or {}
      pending.api_ms[name]=(pending.api_ms[name]or 0)+(host_api.time_precise()-at)*1000
      pending.api_calls[name]=(pending.api_calls[name]or 0)+1
    end
    return table.unpack(result,1,result.n)
  end
end
local report={status='RUNNING',version=r.GetAppVersion(),samples=J.array{}}
local paths={host.."/media 素材/test one's 音.wav",host..'/media 素材/second.wav'}
local began=r.time_precise();local round=0;local selected=paths[1];local optimized_clear,macro_id
local options=J.decode(U.read(host..'/.preview-options.json')or '{}')
local Selection=require('am.selection')
local custom=r.file_exists(host..'/.preview-custom-bank')
local samples_per_mode=type(options.samples)=='number'and options.samples or (custom and 3 or 10)
local policy_samples=samples_per_mode*3
local policy=U.read(host..'/.preview-policy')or 'compare'
local native_selection=r.file_exists(host..'/.preview-native-selection');local stage_due=0
local function file_row(list,path)
  local basename=path:match('[^/\\]+$');local stem=basename:gsub('%.wav$','')
  for i=0,r.JS_ListView_GetItemCount(list)-1 do
    local text=r.JS_ListView_GetItemText(list,i,0)
    if text==basename or text==stem or U.path_equal(text,path)then return i end
  end
  error('Native list did not contain the test file: '..basename)
end
local function profile(object,name)
  local fn=object[name]
  object[name]=function(...)
    local at=r.time_precise()
    if pending then
      pending.stages_ms=pending.stages_ms or {}
      pending.stages_ms[name]=pending.stages_ms[name]or (at-pending.started)*1000
    end
    local values=table.pack(fn(...))
    if pending then
      pending.methods_ms=pending.methods_ms or {}
      pending.methods_ms[name]=(pending.methods_ms[name]or 0)+(r.time_precise()-at)*1000
    end
    return table.unpack(values,1,values.n)
  end
end
local function legacy()return policy=='legacy_all_fx' or policy=='compare' and round<=policy_samples end
-- Frozen pre-optimization algorithm: all tracks, no chain suspension, and
-- offline/online recreation of bypassed plugins. Keep comparisons honest as
-- the production reset implementation changes.
local function legacy_reset(bank)
  local routes={}
  for _,t in pairs(bank.macros)do routes[t]=r.GetMediaTrackInfo_Value(t,'B_MAINSEND')end
  for t in pairs(routes)do r.SetMediaTrackInfo_Value(t,'B_MAINSEND',0)end
  local function reset(t,fx)
    if r.TrackFX_GetOffline(t,fx)then return end
    local container,count=r.TrackFX_GetNamedConfigParm(t,fx,'container_count')
    if container then
      for i=0,assert(tonumber(count))-1 do
        local ok,child=r.TrackFX_GetNamedConfigParm(t,fx,'container_item.'..i)
        assert(ok);reset(t,assert(tonumber(child)))
      end
      return
    end
    local _,kind=r.TrackFX_GetNamedConfigParm(t,fx,'fx_type')
    if r.TrackFX_GetEnabled(t,fx)and(kind=='VST' or kind=='VST3' or kind=='CLAP')then
      r.TrackFX_SetEnabled(t,fx,false);r.TrackFX_SetEnabled(t,fx,true)
    else r.TrackFX_SetOffline(t,fx,true);r.TrackFX_SetOffline(t,fx,false)end
  end
  local ok,err=xpcall(function()
    for t in pairs(routes)do
      for fx=0,r.TrackFX_GetCount(t)-1 do reset(t,fx)end
      bank:live_pdc(t)
    end
  end,debug.traceback)
  for t,value in pairs(routes)do r.SetMediaTrackInfo_Value(t,'B_MAINSEND',value)end
  assert(ok,err)
end
local function progress(stage)
  assert(U.write(host..'/windows-review-progress.json',J.encode{stage=stage,round=round}))
end
local function finish(ok,err)
  if done then return end;done=true
  if app then app:close()end
  report.status=ok and 'PASS' or 'FAIL';report.error=err
  assert(U.write(host..'/windows-review.json',J.encode(report)))
end
r.atexit(function()finish(false,'Preview benchmark stopped early')end)
local ok,err=xpcall(function()
  progress('copy_media');assert(U.copy_file(paths[1],paths[2]))
  progress('audio_init');r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.JS_Window_Show(r.GetMainHwnd(),'SHOW')
  if native_selection then
    assert(r.TrackFX_AddByName(r.GetMasterTrack(0),'JS: am_response_probe',false,1)>=0)
    r.gmem_attach('AuditionMacro.ResponseTest');r.gmem_write(0,0)
  end
  progress('open_explorer')
  r.OpenMediaExplorer(paths[1],false)
  progress('initialize_bank')
  App.initialize(r,root,data)
  local bank=custom and assert(Model.load(data..'/bank.json'))or Model.defaults()
  bank.settings.autoplay=true;bank.settings.preview_fade_ms=0;bank.settings.keep_fx_running=false
  if type(options.poll_ms)=='number'then bank.settings.poll_ms=options.poll_ms end
  report.poll_ms=bank.settings.poll_ms;report.interval_only=options.interval_only==true
  bank.settings.cache_directory='';bank.settings.channel_selections={};bank.settings.loop=false
  -- Nine real JSFX instances expose the cost of resetting unused presets.
  local chain=assert(U.read(root..'/resources/chains/dark.RfxChain'))
  if not custom then
    bank.macros=J.array{};bank.slots={}
    for i=1,9 do
      local m=Model.macro('bench'..i,'Benchmark '..i)
      bank.macros[#bank.macros+1]=m;assert(U.write(data..'/'..m.fx_chain,chain))
    end
  end
  for _,m in ipairs(bank.macros)do m.normalization.enabled=false;m.source_peak_guard.enabled=false end
  macro_id=assert(bank.macros[1]).id
  report.fixture=custom and 'copied_user_bank' or 'nine_jsfx';report.macros=#bank.macros
  bank.raw.normalization.enabled=false;bank.raw.source_peak_guard.enabled=false
  assert(Model.save(data..'/bank.json',bank));progress('start_app');app=App.new(r,root,data)
  if options.interval_only==true then app.explorer.selection_changed=function()return false end end
  report.fx_count=0
  for _,t in pairs(app.bank.macros)do report.fx_count=report.fx_count+r.TrackFX_GetCount(t)end
  report.selected_fx=J.array{}
  local chosen=app.bank.macros[macro_id]
  for fx=0,r.TrackFX_GetCount(chosen)-1 do
    local _,name=r.TrackFX_GetFXName(chosen,fx,'')
    local _,pdc=r.TrackFX_GetNamedConfigParm(chosen,fx,'pdc')
    local entry={name=name,pdc=tonumber(pdc),enabled=r.TrackFX_GetEnabled(chosen,fx)}
    report.selected_fx[#report.selected_fx+1]=entry
  end
  progress('app_ready')
  local transport=app.native_transport
  app.native_transport=function(self,command)
    if pending then pending.transport=pending.transport or J.array{};pending.transport[#pending.transport+1]=command end
    return transport(self,command)
  end
  report.native_selection=native_selection
  -- Isolate SoundPrep from list redraw/OS input scheduling, retaining real
  -- decoding, FX resets, routing and the native audio callback.
  if native_selection then
    app.explorer:toggle(42026,false);app.explorer:toggle(42091,false)
    for _,name in ipairs{'selection','full_selection_name','ensure_waveform'}do profile(app.explorer,name)end
    for _,name in ipairs{'read_source_channels','sync_channel_waveform','request_analysis','play'}do profile(app,name)end
    profile(app.preview,'start')
  else
    app.explorer.selection=function()return selected end
    app.explorer.ensure_waveform=function()end
    app.explorer.preview_range=function()return true,nil end
    app.explorer.tempo_factor=function()return 1 end
  end
  optimized_clear=app.bank.clear_buffers
  app.bank.clear_buffers=function(self)
    local at=r.time_precise()
    if legacy()then legacy_reset(self)else optimized_clear(self)end
    if pending then pending.reset_ms=(r.time_precise()-at)*1000 end
  end
  -- Measure an attached browser after initial folder/plug-in callbacks settle.
  -- Startup time is separate from selecting the next file in an open browser.
  if native_selection then stage_due=r.time_precise()+1 end
  if native_selection and not options.interval_only then
    report.event_selection=Selection.attach(app)
  end
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()-began<150,'Preview benchmark timed out')
    if pending then
      if native_selection then
        if report.event_selection and not pending.first_tick_ms then
          assert(r.AM_SelectionPending(),'Native selection did not complete before the companion tick: '..r.AM_SelectionDiagnostics())
          local timing=J.decode(r.AM_SelectionDiagnostics())
          pending.native_dispatch_ms=(timing.dispatch-pending.started)*1000
          pending.native_action_ms=(timing.returned-timing.dispatch)*1000
        end
        local at=r.time_precise();pending.first_tick_ms=pending.first_tick_ms or (at-pending.started)*1000
        app:tick();Selection.publish(app);pending.tick_ms=(pending.tick_ms or 0)+(r.time_precise()-at)*1000
        if not U.path_equal(app.preview.path,selected)then
          assert(r.time_precise()-pending.started<5,'Selected file never started: '..J.encode{sample=pending,message=app.message,path=app.path,preview_path=app.preview.path,expected=selected,selection=app.explorer:selection()});return
        end
      end
      local d=J.decode(r.AM_Preview_Diagnostics())
      if not d.active or d.blocks==0 then
        assert(r.time_precise()-pending.started<5,'Preview produced no callback: '..J.encode{sample=pending,diagnostics=d});return
      end
      pending.first_callback_ms=(d.first_callback-pending.started)*1000
      pending.callback_max_ms=d.max_callback_ms;pending.fx_latency_ms=d.fx_latency*1000
      if pending.mode=='one_macro' then
        local track=app.bank.macros[macro_id]
        for fx,entry in ipairs(report.selected_fx)do
          local _,pdc=r.TrackFX_GetNamedConfigParm(track,fx-1,'pdc')
          entry.playing_pdc=tonumber(pdc)
        end
      end
      if native_selection then
        for i=pending.probe_index,r.gmem_read(0)-1 do
          local at,peak=r.gmem_read(1+i*5),r.gmem_read(3+i*5)
          if at>=pending.started and peak>1e-5 then pending.output_ms=(at-pending.started)*1000;break end
        end
        assert(pending.output_ms or r.time_precise()-pending.started<5,'No signal reached the output probe')
        if not pending.output_ms then return end
        pending.probe_index=nil;app.preview:stop(true)
      end
      pending.started=nil
      assert(U.write(host..'/windows-review-progress.json',J.encode(pending)))
      report.samples[#report.samples+1]=pending;pending=nil
      stage_due=r.time_precise()+(native_selection and 1 or .1)
    end
    if r.time_precise()<stage_due then if native_selection then app:tick();Selection.publish(app)end;return end
    round=round+1;if round>policy_samples*(policy=='compare'and 2 or 1)then finish(true);return end
    local sample=(round-1)%policy_samples+1
    if sample==1 then app.definition.settings.keep_fx_running=false;app:activate(nil)end
    if sample==samples_per_mode+1 then app:activate(macro_id)end
    if sample==samples_per_mode*2+1 then app.definition.settings.keep_fx_running=true;app.bank:activate(macro_id,0)end
    Selection.publish(app)
    selected=paths[round%2+1]
    -- Native folder refresh/peak generation can reorder rows between trials.
    -- Locate the unique fixture name again, outside the measured selection.
    local list=native_selection and app.explorer:control(1001)
    local row=list and file_row(list,selected)
    pending={policy=legacy()and 'legacy_all_fx' or 'on_demand',mode=sample<=samples_per_mode and 'raw' or sample<=samples_per_mode*2 and 'one_macro' or 'keep_running',started=r.time_precise()}
    if native_selection then
      pending.probe_index=r.gmem_read(0)
      r.JS_ListView_SetItemState(list,-1,0,3);r.JS_ListView_SetItemState(list,row,3,3)
    else app.last_poll=0;app:tick()end
    pending.control_ms=(r.time_precise()-pending.started)*1000
    if not native_selection then assert(app.preview:playing(),'Preview did not start')end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
tick()
