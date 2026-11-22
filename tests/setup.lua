local Setup=require('am.setup')
local Native=require('am.native');local C=require('am.native_contract');local J=require('am.json')
local open,rename,remove,reaper_before=io.open,os.rename,os.remove,reaper
local app_before,path_before=package.loaded['am.app'],package.path
local ok,err=xpcall(function()
  local files,info,platform,fail_write,fail_close,fail_rename,fail_remove
  local reads,changes=0,0
  local r={GetOS=function()return platform end,APIExists=function()return info~=nil end,
    AM_HelperInfo=function()return J.encode(info)end,
    GetResourcePath=function()return '/profile'end,
    file_exists=function(path)return files[path]~=nil end,
    RecursiveCreateDirectory=function(path)assert(path=='/profile/UserPlugins')end}
  io.open=function(path,mode)
    if mode=='rb'then
      reads=reads+1
      if not files[path]then return nil,'missing file'end
      return {read=function()return files[path]end,close=function()return true end}
    end
    assert(mode=='wb' and path:match('%.soundprep%-new$'),'Setup wrote directly to a loadable helper')
    changes=changes+1
    return {write=function(_,bytes)
      files[path]=fail_write and 'partial' or bytes
      if fail_write then return nil,'disk full'end
      return true
    end,close=function()if fail_close then return nil,'close failed'end;return true end}
  end
  os.rename=function(from,to)
    changes=changes+1
    if fail_rename==from then return nil,'rename failed'end
    assert(files[from]~=nil,'Setup tried to move a missing helper')
    assert(files[to]==nil or (fail_remove==to and platform~='Win64'),'Setup overwrote an existing helper')
    files[to]=files[from];files[from]=nil;return true
  end
  os.remove=function(path)
    changes=changes+1
    if fail_remove==path then return nil,'remove failed'end
    files[path]=nil;return true
  end
  for _,os_name in ipairs{'OSX64','macOS-arm64','Win64'}do
    platform=os_name
    local name='reaper_audition_macro'..(platform=='Win64' and '.dll' or '.dylib')
    local source='/package/build/'..name;local target='/profile/UserPlugins/'..name
    local staged=target..'.soundprep-new';local backup=target..'.soundprep-old'
    local bundled,stale='bundled helper\0bytes','stale helper\0bytes'
    info=nil;files={[source]=bundled}
    assert(Setup.prepare_native(r,'/package')=='installed')
    assert(files[target]==bundled and not files[staged])
    assert(not Setup.install_native_if_missing(r,'/package') and files[target]==bundled)
    files[target]=nil
    assert(Setup.install_native_if_missing(r,'/package') and files[target]==bundled)
    files[target]=nil
    for _,failure in ipairs{'write','close','rename'}do
      fail_write=failure=='write';fail_close=failure=='close';fail_rename=failure=='rename' and staged
      local copied=pcall(Setup.prepare_native,r,'/package')
      assert(not copied and not files[target] and not files[staged],'Failed install left a partial helper')
    end
    fail_write=false;fail_close=false;fail_rename=nil
    files={}
    local copied,message=pcall(Setup.prepare_native,r,'/package')
    assert(not copied and message:find('Reinstall the SoundPrep package through ReaPack',1,true))

    info={schema=C.schema,version=C.version,platform=platform=='Win64' and 'windows' or 'macos',features={}}
    for feature,spec in pairs(C.features)do info.features[feature]=spec.revision end
    info.features.bar=C.features.bar.revision-1
    assert(not Setup.install_native_if_missing(r,'/package'),'Install-only setup tried to replace a loaded helper')
    files={[source]=bundled,[target]=stale,[backup]='older backup'}
    if platform~='Win64' then fail_remove=backup end -- macOS can rename over the old backup.
    assert(Setup.prepare_native(r,'/package')=='updated')
    fail_remove=nil
    assert(files[target]==bundled and files[backup]==stale and not files[staged])

    reads,changes=0,0
    assert(Setup.prepare_native(r,'/package')=='pending')
    assert(reads==2 and changes==0 and files[target]==bundled and files[backup]==stale and not files[staged])

    info.features.bar=C.features.bar.revision
    reads=0;fail_remove=backup
    assert(Setup.prepare_native(r,'/package')=='current' and files[backup]==stale and reads==0)
    fail_remove=nil
    assert(Setup.prepare_native(r,'/package')=='current')
    assert(reads==0 and not files[backup] and files[target]==bundled)

    info.features.bar=C.features.bar.revision-1
    local _,manual=Native.inspect(r)
    for _,failure in ipairs{target,staged}do
      files[target]=stale;fail_rename=failure
      local status,reason=Setup.prepare_native(r,'/package')
      assert(status==nil and reason==manual)
      assert(files[target]==stale and not files[staged] and not files[backup],'Failed swap did not preserve the helper')
    end
    fail_rename=nil
    files[source]=nil;changes=0
    local status,reason=Setup.prepare_native(r,'/package')
    assert(status==nil and reason==manual and changes==0 and files[target]==stale)
  end
  platform='Win32';files={}
  local supported,message=pcall(Setup.prepare_native,r,'/package')
  assert(not supported and message:find('x64',1,true))

  platform='macOS-arm64';info=nil
  local source='./build/reaper_audition_macro.dylib'
  local target='/profile/UserPlugins/reaper_audition_macro.dylib'
  files={[source]='bundled helper'}
  local notice
  r.GetExtState=function()return ''end
  r.ShowMessageBox=function(text,title,kind)assert(title=='SoundPrep' and kind==0);notice=text end
  r.AddRemoveReaScript=function()error('Launcher registered an optional action')end
  r.atexit=function()error('Helper setup started an application lifecycle')end
  package.loaded['am.app']={EXT='AuditionMacro.v1',new=function()error('Helper setup started the application')end}
  reaper=r
  dofile('./SoundPrep.lua')
  assert(notice==Setup.restart_notice and files[target]=='bundled helper')
  files[target]='stale helper'
  for _=1,2 do
    notice=nil;dofile('./SoundPrep.lua')
    assert(notice==Setup.update_restart_notice and files[target]=='bundled helper')
  end
  files[target]='stale helper';fail_rename=target
  dofile('./SoundPrep.lua')
  local _,manual=Native.inspect(r)
  assert(notice:find(manual,1,true) and files[target]=='stale helper')
  fail_rename=nil

  local registrations=0
  r.AddRemoveReaScript=function()registrations=registrations+1;return registrations end
  for launch=1,2 do
    notice=nil;dofile('./SoundPrep - Install actions.lua')
    assert(notice:find(Setup.update_restart_notice,1,true)==1 and files[target]=='bundled helper')
    assert(registrations==14*launch)
  end
end,debug.traceback)
io.open,os.rename,os.remove,reaper=open,rename,remove,reaper_before
package.loaded['am.app'],package.path=app_before,path_before
assert(ok,err)
