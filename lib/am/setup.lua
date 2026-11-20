-- Bundled-helper setup shared by the launcher and optional action installer.
local P=require('am.platform')
local N=require('am.native')
local U=require('am.util')
local C=require('am.native_contract')
local M={}
local restart='Save your work and restart REAPER, then run SoundPrep.lua again.'
M.restart_notice='SoundPrep is ready. '..restart
M.update_restart_notice='The SoundPrep native helper was updated to the bundled contract version '..C.version..'. '..restart
function M.restart_notice_for(status)
  if status=='installed'then return M.restart_notice end
  if status=='updated' or status=='pending'then return M.update_restart_notice end
end

local function supported_platform(r)
  local platform=r.GetOS()
  local windows=P.windows(r)
  if windows and platform~='Win64' then
    error('SoundPrep requires the x64 edition of REAPER on Windows.',0)
  end
  return windows or platform:match('OSX') or platform:match('macOS')
end

local function helper_paths(r,root)
  local name=P.helper_name(r)
  local directory=r.GetResourcePath()..'/UserPlugins'
  return root..'/build/'..name,directory..'/'..name,directory
end

local function read_bundle(source)
  local input=io.open(source,'rb')
  if not input then
    return nil,'Native helper is missing. Reinstall the SoundPrep package through ReaPack, then restart REAPER.'
  end
  local bytes,read_error=input:read('*a');input:close()
  if not bytes or #bytes==0 then return nil,read_error or 'The bundled native helper is empty.' end
  return bytes
end

local function place_helper(target,bytes,backup)
  -- Finish the copy before making it visible as a loadable REAPER extension.
  local temporary=target..'.soundprep-new'
  local output,open_error=io.open(temporary,'wb')
  if not output then return nil,open_error end
  local written,write_error=output:write(bytes)
  local closed,close_error=output:close()
  if not written or not closed then
    os.remove(temporary)
    return nil,write_error or close_error
  end
  if backup then
    -- Rename the live DLL so its loaded image can stay mapped until restart.
    os.remove(backup)
    local moved,move_error=os.rename(target,backup)
    if not moved then os.remove(temporary);return nil,move_error end
  end
  local moved,move_error=os.rename(temporary,target)
  if not moved then
    -- If restoring the target also fails, leave the previous bytes in the backup.
    if backup then os.rename(backup,target) end
    os.remove(temporary)
    return nil,move_error
  end
  return true
end

local function install_helper(r,source,target,directory)
  local bytes=assert(read_bundle(source))
  r.RecursiveCreateDirectory(directory,0)
  local installed,install_error=place_helper(target,bytes)
  if not installed then error(install_error,0) end
end

function M.install_native_if_missing(r,root)
  if not supported_platform(r) or r.APIExists('AM_HelperInfo')then return false end
  local source,target,directory=helper_paths(r,root)
  if r.file_exists(target)then return false end
  install_helper(r,source,target,directory)
  return true
end

function M.prepare_native(r,root)
  local supported=supported_platform(r)
  local loaded,native_error=N.inspect(r)
  if not supported then
    if loaded then return 'current' end
    return nil,native_error
  end
  local source,target,directory=helper_paths(r,root)
  local backup=target..'.soundprep-old'
  if loaded then
    os.remove(backup)
    return 'current'
  end
  if not r.file_exists(target)then
    install_helper(r,source,target,directory)
    return 'installed'
  end
  local bundled=read_bundle(source)
  local installed=U.read(target)
  if not bundled or not installed then return nil,native_error end
  if bundled==installed then return 'pending' end
  if place_helper(target,bundled,backup)then return 'updated' end
  return nil,native_error
end
return M
