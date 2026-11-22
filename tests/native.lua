local J=require('am.json');local U=require('am.util');local C=require('am.native_contract');local N=require('am.native')
local function fixture(os)
  local platform=os=='Win64'and 'windows'or 'macos'
  local info={schema=C.schema,version='999.0.0',platform=platform,features={}}
  local apis={AM_HelperInfo=true}
  for name,f in pairs(C.features)do if not f.platform or f.platform==platform then
    info.features[name]=f.revision
    for _,api in ipairs(f.apis)do apis[api]=true end
  end end
  local r={GetOS=function()return os end,APIExists=function(name)return apis[name]or false end,
    AM_HelperInfo=function()return J.encode(info)end}
  return r,info,apis
end
for _,os in ipairs{'Win64','macOS-arm64'}do
  local r,info,apis=fixture(os)
  assert(N.inspect(r),'Compatible feature revisions must work independently of release version')
  assert(require('am.bar').available(r))
  info.features.bar=3
  local ok,err=N.inspect(r);assert(not ok and err:find('bar requires revision '..C.features.bar.revision,1,true))
  assert(not require('am.bar').available(r),'Old helper silently retained the withdrawn Search UI')
  info.version='0.11.10';info.features.bar=9
  assert(not N.inspect(r),'Helper without the normalization fade setting was accepted')
  info.version='0.11.17';info.features.bar=10
  assert(not N.inspect(r),'Helper requiring the removed Export settings was accepted')
  info.version='999.0.0'
  info.features.bar=C.features.bar.revision
  info.features.preview=1;assert(not N.inspect(r),'Old helper silently accepted multichannel preview')
  info.features.preview=2;assert(not N.inspect(r),'Old downmix helper silently accepted AmbiX M/S decoding')
  info.features.preview=C.features.preview.revision
  apis.AM_Preview_CreateWithChannels=nil;assert(not N.inspect(r),'Multichannel preview capability requires its registered API')
  apis.AM_Preview_CreateWithChannels=true
  apis.AM_Preview_CreateWithDownmix=nil;assert(not N.inspect(r),'AmbiX preview capability requires its registered API')
  apis.AM_Preview_CreateWithDownmix=true
  apis.AM_Preview_SetLatencyTrack=nil;assert(not N.inspect(r),'Claimed capability without registered API accepted')
  apis.AM_Preview_SetLatencyTrack=true
  info.platform=os=='Win64'and'macos'or'windows';assert(not N.inspect(r))
  info.platform=os=='Win64'and'windows'or'macos';info.schema=999;assert(not N.inspect(r))
  info.schema=C.schema;apis.AM_HelperInfo=nil
  assert(not require('am.bar').available(r),'Legacy same-name APIs must not imply current UI support')
  local writes=0;r.RecursiveCreateDirectory=function()writes=writes+1 end
  assert(not pcall(require('am.app').new,r,'/unused','/unused') and writes==0,'Compatibility failure changed settings before rejection')
end
local r,info=fixture('macOS-arm64');info.features.quiet_render=nil
assert(N.inspect(r),'Platform-only features must not be required on the other platform')
assert(N.describe(r):find('999.0.0',1,true))

-- Diagnostics can be run against an older helper, before either backend
-- has built anything, or after comparing the same selection on both.
do
  assert(not N.peak_build_summary('{"last_seek":null}') and not N.peak_build_summary(''))
  local peaks={last_cache_lookup='none',cache_hits=0,cache_misses=0,builds_completed=0,slowest_build_ms=0,
    last_store=J.null,last_peaksbuild=J.null}
  local function summary()return N.peak_build_summary(J.encode({peak_build=peaks}))end
  assert(summary():find('0 builds completed',1,true))
  peaks.last_cache_lookup='hit';peaks.cache_hits=1;peaks.cache_misses=1;peaks.builds_completed=2;peaks.slowest_build_ms=320
  peaks.last_store={mode='worker',path='/field.wav',samples=7680000,total_ms=30,samples_per_second=256e6}
  peaks.self_build_ms=24;peaks.self_samples_per_second=320e6
  peaks.last_peaksbuild={mode='peaksbuild-fallback',path='/field.wav',samples=7680000,total_ms=320,
    samples_per_second=24e6,run_ms=220,run_calls=9}
  local report=summary()
  for _,s in ipairs{'Peak cache hit (hits 1, misses 1)','2 builds completed, slowest 320.0 ms',
      'Peak store  /field.wav [worker]','7680000 samples, 24.0 ms decode (320.00 M samples/s)',
      '30.0 ms total (256.00 M samples/s)','REAPER PeaksBuild  /field.wav','220.0 ms in 9 Run calls',
      '320.0 ms total (24.00 M samples/s)'}do assert(report:find(s,1,true),s)end
end

-- Renderer diagnostics belong to the attached waveform. Bar refreshes and
-- transient messages must not replace the warning or re-read the cursor JSON.
do
  local Explorer=require('am.media_explorer');local Model=require('am.model')
  local host,helper=fixture('macOS-arm64')
  local cursor,reads,wave=nil,0,0
  host.AM_WaveCursorState=function()reads=reads+1;return J.encode(cursor)end
  host.AM_WaveAttach=function()return true end
  host.EnumProjects=function()return 1 end
  local definition=Model.defaults()
  local app={project=1,definition=definition,message='',loudness={},preview={playing=function()return false end},
    effective=function()return Model.effective(definition,nil)end,gain=function()return 0,'off'end,measurement=function()end}
  local bar=require('am.bar').new(host,app)
  local warning='Waveform overlay is hidden by REAPER GPU acceleration (macOS). Set Preferences > Advanced UI/system tweaks > GPU acceleration to Force Classic, then restart REAPER.'
  local function attach(state)
    cursor=state;wave=wave+1;app.explorer:attach_wave()
  end
  for _,revision in ipairs{9,10,11}do
    helper.features.waveform=revision
    local compatible,_,detected=N.inspect(host)
    app.explorer=Explorer.new(host,compatible or detected)
    app.explorer.native_transport=1
    app.explorer.control=function(_,id)return id==1046 and wave or 'clock'end
    app.message='Source changed. Replay to reload.'
    attach({renderer_cocoa='metal',overlay_hidden_by_gpu=true})
    local diagnostics=N.describe(host,J.encode(cursor))
    local expected=revision>=10 and 'metal (waveform overlay is hidden by GPU acceleration)' or 'unknown'
    assert(diagnostics:find('REAPER renderer (renderer_cocoa): '..expected,1,true))
    local before=reads
    assert(bar:state().status==(revision>=10 and warning or app.message))
    app.message='Could not save preset'
    app.explorer:attach_wave()
    assert(bar:state().status==(revision>=10 and warning or app.message) and reads==before)
    for _,state in ipairs{{renderer_cocoa='classic',overlay_hidden_by_gpu=false},
        {renderer_cocoa='unknown',overlay_hidden_by_gpu=false},{renderer_cocoa='metal'},
        {overlay_hidden_by_gpu=J.null},{overlay_hidden_by_gpu='unknown'},{}}do
      attach(state)
      assert(bar:state().status==app.message)
    end
  end
end

-- A newly declared control must have a shared Lua handler. Both native GUIs
-- send these commands; platform-specific handlers would defeat the contract.
local project={}
local app={project=project,definition={settings={}},bank={activate=function()end},
  search_session={command=function()end},save=function()end,
  effective=function()return {source_transform={preserve_pitch=false},normalization={enabled=false},output_gain_db=0}end}
for _,name in ipairs{'activate','ab','reverse','set_preserve_pitch','set_normalization','set_downmix'}do app[name]=function()end end
local bar=require('am.bar').new({EnumProjects=function()return project end},app)
for _,control in ipairs(C.bar.controls)do
  local command=control.command
  if control.kind=='popup'then command=command..':'..C.bar.options[command][1]end
  assert(pcall(bar.dispatch,bar,command),'Contract control has no shared handler: '..command)
end
assert(not pcall(bar.dispatch,bar,'unsupported-control'),'Unknown helper commands must be visible instead of silently ignored')
