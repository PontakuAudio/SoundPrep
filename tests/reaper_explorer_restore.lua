-- Verify native preferences in a disposable REAPER, including coupled modes.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]tests[/\\]')
local r=reaper;local host=r.GetResourcePath();assert(r.file_exists(host..'/.audition-macro-test'))
package.path=root..'/lib/?.lua;'..package.path
local E=require('am.media_explorer');local App=require('am.app');local U=require('am.util');local J=require('am.json')
local ex=E.new(r);local app,done,before,native_closed;local index,phase=0,'start'
local due=r.time_precise()+.7;local deadline=r.time_precise()+45
local report={status='RUNNING',checks=J.array{},version=r.GetAppVersion()}
local cases={}
for _,exit in ipairs{'quit','closed','recovery','stale_recovery'}do
  for _,mode in ipairs{40015,40070}do for _,autoplay in ipairs{false,true}do
    cases[#cases+1]={mode=mode,autoplay=autoplay,exit=exit}
  end end
end
local ids={1011,40015,40070,42014,40068,42026,42134,42182,42348,1068,42055,42183,42091,40032,1012,42171}
local function snapshot()
  local s={toggles={},transform=ex:transform(),fader=r.JS_WindowMessage_Send(ex:control(1045),'0x0400',0,0,0,0)}
  for _,id in ipairs(ids)do s.toggles[tostring(id)]=r.GetToggleCommandStateEx(32063,id)end
  return s
end
local function finish(ok,err)
  if done then return end;done=true
  if app then pcall(app.close,app)end
  report.status=ok and 'PASS'or'FAIL';report.error=err
  assert(U.write(host..'/windows-review.json',J.encode(report)))
end
r.atexit(function()finish(false,'Restore test interrupted')end)
local ok,err=xpcall(function()
  r.SetMediaTrackInfo_Value(r.GetMasterTrack(0),'D_VOL',0)
  r.JS_Window_Show(r.GetMainHwnd(),'SHOW')
  r.OpenMediaExplorer(host.."/media 素材/test one's 音.wav",false)
end,debug.traceback)
if not ok then finish(false,err);return end
local function tick()
  local ok,err=xpcall(function()
    assert(r.time_precise()<deadline,'Restore test timed out')
    if r.time_precise()<due then return end
    if phase=='start'then
      index=index+1;if not cases[index]then finish(true);return end
      local c=cases[index];ex:window(true);ex:command(c.mode);ex:toggle(1011,c.autoplay)
      for _,id in ipairs{42014,42182,42348,1068,42055,42183}do
        if r.GetToggleCommandStateEx(32063,id)>=0 then ex:toggle(id,index%2==0)end
      end
      ex:set_transform{pitch_semitones=3,rate=1.25,preserve_pitch=true};ex:fader(300)
      native_closed=nil
      if c.exit=='closed'then ex:command(40069);phase='native_reopen'else phase='attach'end
      due=r.time_precise()+.1
    elseif phase=='native_reopen'then
      assert(not ex:window(),'Native close did not finish');ex:window(true)
      phase='native_baseline';due=r.time_precise()+.1
    elseif phase=='native_baseline'then
      -- REAPER itself resets Pitch/Rate and quantizes its fader when reopening.
      -- Compare the closed-window case with that native round trip, not with
      -- ephemeral control values that REAPER does not persist.
      native_closed=snapshot()
      ex:set_transform{pitch_semitones=3,rate=1.25,preserve_pitch=true};ex:fader(300)
      phase='attach'
    elseif phase=='attach'then
      before=snapshot()
      if cases[index].exit=='stale_recovery'then
        -- A previous interrupted session must not replace the settings the
        -- user has chosen before this launch (especially volume/autoplay).
        local stale={volume='-30',fader_position=100,transform=before.transform,toggles=U.copy(before.toggles),preserve_display=true}
        stale.toggles['1011']=1-before.toggles['1011']
        assert(U.write(host..'/restore-data/recovery.json',J.encode{schema_version=1,session='previous-session',explorer=stale}))
      end
      app=App.new(r,root,host..'/restore-data')
      app.bar=require('am.bar').new(r,app);app.bar:tick()
      require('am.selection').attach(app)
      app:tick()
      assert(r.GetToggleCommandStateEx(32063,1011)==0,'Attach did not disable native autoplay: '..J.encode(snapshot()))
      app.explorer:set_transform{pitch_semitones=-7,rate=.8,preserve_pitch=false}
      app.explorer:toggle(1068,not(before.toggles['1068']==1))
      if cases[index].exit=='closed'then app.explorer:command(40069)end
      phase='close';due=r.time_precise()+.1
    elseif phase=='close'then
      local c=cases[index]
      if c.exit=='closed'then assert(not ex:window(),'Fixture did not close Media Explorer')end
      if c.exit=='recovery'then
        -- Persisted snapshots must work without the original Explorer object.
        local saved=J.decode(J.encode(app.explorer.saved));app.explorer.saved=nil
        r.AM_TransportDetach();app:close();app=nil
        local recovery=E.new(r);recovery.saved=saved;recovery:restore()
      else app:close();app=nil end
      phase='reopen';due=r.time_precise()+.1
    elseif phase=='reopen'then
      if cases[index].exit=='closed'then assert(not ex:window(),'Quit reopened the closed Media Explorer')end
      ex:window(true);phase='verify'
    else
      local after=snapshot()
      report.checks[#report.checks+1]={case=cases[index],before=before,after=after,native_closed=native_closed}
      assert(U.equal(native_closed or before,after),'Native preferences changed after '..cases[index].exit..': '..J.encode(report.checks[#report.checks]))
      phase='start'
    end
  end,debug.traceback)
  if not ok then finish(false,err)elseif not done then r.defer(tick)end
end
r.defer(tick)
