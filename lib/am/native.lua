-- One capability check for startup, the embedded bar, installer and diagnostics.
local J=require('am.json');local P=require('am.platform');local C=require('am.native_contract')
local M={}
function M.inspect(r)
  local platform=P.windows(r)and 'windows'or 'macos'
  local problems={};local info
  if not r.APIExists('AM_HelperInfo')then
    problems[#problems+1]='Helper cannot report its supported features (AM_HelperInfo missing)'
  else
    local ok,value=pcall(function()return J.decode(r.AM_HelperInfo())end)
    if not ok or type(value)~='table' or value.schema~=C.schema or type(value.features)~='table' or
      type(value.version)~='string' or value.platform~=platform then
      problems[#problems+1]='Invalid or incompatible helper contract'
    else info=value end
  end
  if info then
    local names={};for name in pairs(C.features)do names[#names+1]=name end;table.sort(names)
    for _,name in ipairs(names)do
      local feature=C.features[name]
      if not feature.platform or feature.platform==platform then
        local revision=info.features[name]
        if type(revision)~='number' or revision~=revision or revision==math.huge or revision<feature.revision then
          problems[#problems+1]=('Feature %s requires revision %d'):format(name,feature.revision)
        end
        for _,api in ipairs(feature.apis)do if not r.APIExists(api)then problems[#problems+1]='Missing '..api end end
      end
    end
  end
  if #problems==0 then return info end
  local installer=platform=='windows'and 'tools/install_native.ps1'or 'tools/install_native.sh'
  return nil,table.concat(problems,'; ')..'. Save your work, close REAPER, update '..P.helper_name(r)..
    ' using '..installer..', then restart REAPER.',info
end
function M.require(r)
  local info,err=M.inspect(r);assert(info,err);return info
end
function M.wave_renderer(info,cursor)
  local revision=info and info.features.waveform
  if type(revision)=='number' and revision>=10 and cursor then
    local ok,state=pcall(J.decode,cursor)
    if ok and type(state)=='table' then
      return type(state.renderer_cocoa)=='string' and state.renderer_cocoa or 'unknown',state.overlay_hidden_by_gpu==true
    end
  end
  return 'unknown',false
end
function M.peak_build_summary(raw)
  local ok,wave=pcall(J.decode,raw)
  local peaks=ok and type(wave)=='table' and wave.peak_build
  if type(peaks)~='table' or not peaks.last_cache_lookup then return end
  local lines={('Peak cache %s (hits %d, misses %d). %d builds completed, slowest %.1f ms.'):format(
    peaks.last_cache_lookup,peaks.cache_hits,peaks.cache_misses,peaks.builds_completed,peaks.slowest_build_ms)}
  local function timing(build,work)
    return ('%s [%s]  %d samples, %s, %.1f ms total (%.2f M samples/s)'):format(
      build.path,build.mode,build.samples,work,build.total_ms,build.samples_per_second/1e6)
  end
  local store,legacy=peaks.last_store,peaks.last_peaksbuild
  if store and store~=J.null then
    lines[#lines+1]='Peak store  '..timing(store,('%.1f ms decode (%.2f M samples/s)'):format(
      peaks.self_build_ms,peaks.self_samples_per_second/1e6))
  end
  if legacy and legacy~=J.null then
    lines[#lines+1]='REAPER PeaksBuild  '..timing(legacy,('%.1f ms in %d Run calls'):format(legacy.run_ms,legacy.run_calls))
  end
  return table.concat(lines,'\n')
end
function M.describe(r,cursor)
  local info,err,detected=M.inspect(r);detected=info or detected
  local lines={'Lua package: '..C.version,'Expected native contract schema: '..C.schema}
  if detected then
    lines[#lines+1]='Loaded helper: '..detected.version..' / '..detected.platform
    lines[#lines+1]='Loaded features: '..J.encode(detected.features)
  end
  lines[#lines+1]=info and 'Native compatibility: OK' or 'Native compatibility: '..err
  local renderer,hidden=M.wave_renderer(detected,cursor)
  lines[#lines+1]='REAPER renderer (renderer_cocoa): '..renderer..(hidden and ' (waveform overlay is hidden by GPU acceleration)' or '')
  return table.concat(lines,'\n')
end
return M
