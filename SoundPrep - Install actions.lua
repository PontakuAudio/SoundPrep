-- @description SoundPrep - Optional keyboard and maintenance actions
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local scripts={'SoundPrep.lua','SoundPrep - Restore native preview.lua','SoundPrep - Diagnostics.lua','SoundPrep - Render selected drops.lua',
  'SoundPrep - Restore selected source FX.lua','SoundPrep - Offline inactive source FX.lua'}
local r=reaper
package.path=root..'/lib/?.lua;'..package.path
local Setup=require('am.setup')
local ok,status,native_error=pcall(Setup.prepare_native,r,root)
if not ok then r.ShowMessageBox(tostring(status),'SoundPrep',0);return end
for _,file in ipairs(scripts)do assert(r.AddRemoveReaScript(true,0,root..'/'..file,true)>0)end
local names={'Reverse','AB','Play Stop','Replay','Stop','Analyse','Edit','Quit'}
for _,name in ipairs(names)do
  local path=root..'/actions/SoundPrep - '..name..'.lua'
  assert(r.AddRemoveReaScript(true,32063,path,true)>0)
end
local notice=Setup.restart_notice_for(status) or native_error or 'Launch SoundPrep.lua for normal use.'
r.ShowMessageBox(notice..'\n\n'..
  'Optional actions registered: 5 Main maintenance actions and '..#names..' Media Explorer shortcuts.\n\n'..
  'Assign keys in the Media Explorer Action List if needed. These actions do not start SoundPrep. Existing shortcuts were preserved.','SoundPrep',0)
