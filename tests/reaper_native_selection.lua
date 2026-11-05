-- Exercise the native event -> action -> companion handoff in an owned host.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
package.path=root..'/lib/?.lua;'..package.path
local App=require('am.app');local Model=require('am.model');local U=require('am.util');local J=require('am.json')
local Fast=require('am.selection');local Loudness=require('am.loudness')
local paths={host.."/media 素材/test one's 音.wav",host..'/media 素材/second.wav'}
local app,done,step,pending=false,false,0,nil
local report={status='RUNNING',checks=J.array{}};local began=r.time_precise();local due=0;local fx,guid,track
local function finish(ok,err)
  if done then return end;done=true;if app then app:close()end
  report.status=ok and 'PASS'or'FAIL';report.error=err;assert(U.write(host..'/windows-review.json',J.encode(report)))
end
local function select_file(path)
  local list=app.explorer:control(1001);local row
  if path then
    local basename=path:match('[^/\\]+$');local stem=basename:gsub('%.wav$','')
    for i=0,r.JS_ListView_GetItemCount(list)-1 do local name=r.JS_ListView_GetItemText(list,i,0)
      if name==basename or name==stem or U.path_equal(name,path)then row=i;break end
    end
    assert(row,'Fixture file missing')
  end
  r.JS_ListView_SetItemState(list,-1,0,3)
  if row then r.JS_ListView_SetItemState(list,row,3,3)end
end
local function check_value(handle,key,wanted)
  local ok,value=r.AM_Preview_GetValue(handle,key);assert(ok and math.abs(value-wanted)<1e-6,key..' changed')
end
local ok,err=xpcall(function()
  assert(U.copy_file(paths[1],paths[2]));r.JS_Window_Show(r.GetMainHwnd(),'SHOW');r.OpenMediaExplorer(paths[1],false)
  local data=host..'/selection-data';App.initialize(r,root,data)
  local b=assert(Model.load(data..'/bank.json'));b.settings.preview_fade_ms=0;b.settings.loop=true;b.settings.cache_directory=''
  b.raw.normalization.enabled=true;b.raw.normalization.target_lufs=-23;assert(Model.save(data..'/bank.json',b))
  app=App.new(r,root,data);r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  track=app.bank.macros.dark
  for i=r.TrackFX_GetCount(track)-1,0,-1 do r.TrackFX_Delete(track,i)end
  fx=r.TrackFX_AddByName(track,'VST: ReaDelay (Cockos)',false,1);assert(fx>=0)
  r.TrackFX_SetParam(track,fx,3,.07);r.TrackFX_SetEnabled(track,fx,false);guid=r.TrackFX_GetFXGUID(track,fx)
  for _,path in ipairs(paths)do
    local value={status='ready',identity=assert(Loudness.identity(r,path)),profile=Loudness.PROFILE,
      analyzer_key=Loudness.ANALYZER_KEY,channels=1,duration=2,max_momentary_lufs=-30,true_peak_dbtp=-12}
    app.loudness:remember(value,nil,true)
  end
  assert(Fast.attach(app))
  -- An action may still have its empty Undo-suppression callback pending.
  -- Relaunching it must be inert outside native dispatch and never show a
  -- running-script dialog or terminate the companion.
  r.Main_OnCommandEx(app.selection_command,0,app.project)
  r.Main_OnCommandEx(app.selection_command,0,app.project)
  assert(not app.preview:playing()and not r.AM_SelectionPending())
  due=r.time_precise()+1
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()-began<30,'Selection integration timed out')
    if r.time_precise()<due then app:tick();Fast.publish(app);return end
    if pending then
      assert(r.Undo_CanUndo2(app.project)==pending.undo,'Audition added an Undo point')
      if step==5 then
        assert(not r.AM_SelectionPending(),'Queued Stop was overtaken by selection')
        app:tick();assert(not app.preview:playing(),'Queued Stop did not stop playback')
      else
        assert(r.AM_SelectionPending(),'Selection waited for the companion: '..r.AM_SelectionDiagnostics())
        local value=J.decode(r.AM_SelectionRead());local handle=r.AM_SelectionPreview()
        assert(U.path_equal(value.app.path,pending.path),'Wrong selected source')
        if step==2 or step==6 then assert(not handle,'Autoplay-off/deselection retained old audio')
        else
          assert(handle,'Selection did not start audio')
          if step==1 then check_value(handle,'D_VOLUME',U.gain(7))end
          if step==3 then check_value(handle,'D_PITCH',-2);check_value(handle,'D_PLAYRATE',1)
            assert(r.TrackFX_GetFXGUID(track,fx)==guid and not r.TrackFX_GetEnabled(track,fx))
            assert(math.abs(r.TrackFX_GetParam(track,fx,3)-.07)<1e-6,'Unsaved VST setting changed')
          end
          if step==4 then assert(value.preview.macro.source_transform.reverse,'Reverse was lost')end
        end
        local starts=value.preview.starts
        assert(Fast.consume(app));assert(app.preview.handle==handle and app.preview.starts==starts)
        app:tick();assert(app.preview.starts==starts,'Companion replayed the already-started source')
        if step==7 then
          local count=J.decode(r.AM_SelectionDiagnostics()).dispatches
          assert(count==pending.dispatches+1,'Rapid selection was not coalesced')
        end
      end
      report.checks[#report.checks+1]=step;pending=nil;Fast.publish(app)
    end
    step=step+1
    if step>7 then finish(true);return end
    local path=step%2==1 and paths[2]or paths[1]
    if step==2 then app.definition.settings.autoplay=false end
    if step==3 then app.definition.settings.autoplay=true;app:activate('dark')end
    if step==4 then app:activate('reverse')end
    if step==6 then path=nil end
    Fast.publish(app)
    if step==5 then r.JS_WindowMessage_Send(app.explorer:window(),'WM_COMMAND',1009,0,0,0)end
    pending={path=path,dispatches=J.decode(r.AM_SelectionDiagnostics()).dispatches,undo=r.Undo_CanUndo2(app.project)}
    if step==7 then select_file(paths[2]);select_file(paths[1])end
    select_file(path)
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
r.atexit(function()finish(false,'Selection integration interrupted')end);r.defer(tick)
