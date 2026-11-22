local root_names={'',' - Install actions',' - Diagnostics',' - Restore native preview',' - Render selected drops',
  ' - Restore selected source FX',' - Offline inactive source FX'}
local actions={
  {'Reverse','reverse'},{'AB','ab'},{'Play Stop','play'},{'Replay','replay'},{'Stop','stop'},
  {'Analyse','analyse'},{'Edit','edit'},{'Quit','quit'},
}
for i=0,9 do actions[#actions+1]={'Slot '..i,'slot:'..i}end

-- Only SoundPrep entrypoints ship; obsolete forwarding files are removed.
local function check_entrypoint(directory,suffix)
  local path=directory..'SoundPrep'..suffix..'.lua'
  assert(loadfile(path),'Missing action: '..path)
  local legacy=io.open(directory..'Audition Macro'..suffix..'.lua','rb')
  if legacy then legacy:close();error('Obsolete action alias remains: '..suffix)end
end
for _,suffix in ipairs(root_names)do check_entrypoint('./',suffix)end
for _,action in ipairs(actions)do check_entrypoint('./actions/',' - '..action[1])end

local old_reaper,old_path=reaper,package.path
local modules={}
for _,name in ipairs{'am.action','am.app','am.setup'}do modules[name]=package.loaded[name]end
local ok,err=xpcall(function()
  local sent={}
  reaper={}
  package.loaded['am.action']={send=function(r,command)
    assert(r==reaper);sent[#sent+1]=command
  end}
  for _,action in ipairs(actions)do
    local before=#sent
    dofile('./actions/SoundPrep - '..action[1]..'.lua')
    assert(#sent==before+1 and sent[#sent]==action[2],'Action command changed: '..action[1])
  end

  -- Keep the stored heartbeat identity and reuse an existing session.
  package.loaded['am.app']={EXT='AuditionMacro.v1',new=function()error('Duplicate application started')end}
  reaper={GetExtState=function(section,key)
    assert(section=='AuditionMacro.v1' and key=='heartbeat');return '100'
  end,time_precise=function()return 101 end}
  for _=1,2 do
    local before=#sent;dofile('./SoundPrep.lua')
    assert(#sent==before+1 and sent[#sent]=='edit','Launcher did not reuse the active application')
  end

  -- Reinstalling preserves the SoundPrep action IDs and assigned shortcuts.
  local registered={['0:./Audition Macro.lua']=41,['32063:./actions/Audition Macro - Play Stop.lua']=42}
  local calls,new_id=0,100
  package.loaded['am.setup']={prepare_native=function()return 'current'end,restart_notice_for=function()end}
  reaper={AddRemoveReaScript=function(add,section,path,commit)
      assert(add==true and commit==true,'Installer removed an existing action')
      assert(section==0 or section==32063,'Incorrect action section')
      assert(not path:find('Audition Macro',1,true) and path:find('SoundPrep',1,true),'Installer registered a legacy alias')
      assert(loadfile(path),'Installer registered a missing action')
      local key=section..':'..path
      if not registered[key]then new_id=new_id+1;registered[key]=new_id end
      calls=calls+1;return registered[key]
    end,
    ShowMessageBox=function(message,title)
      assert(title=='SoundPrep' and message:find('Launch SoundPrep.lua',1,true))
    end}
  dofile('./SoundPrep - Install actions.lua')
  assert(calls==24 and new_id==124,'Expected 6 Main and 18 Media Explorer registrations')
  local main_id=registered['0:./SoundPrep.lua']
  local play_id=registered['32063:./actions/SoundPrep - Play Stop.lua']
  local shortcuts={[main_id]='Ctrl+Alt+A',[play_id]='Space',[41]='Alt+A',[42]='Alt+Space'}
  dofile('./SoundPrep - Install actions.lua')
  assert(calls==48 and new_id==124,'Reinstall changed action identities')
  assert(registered['0:./Audition Macro.lua']==41 and registered['32063:./actions/Audition Macro - Play Stop.lua']==42,
    'Installer changed an existing legacy action registration')
  assert(shortcuts[41]=='Alt+A' and shortcuts[42]=='Alt+Space','Installer changed legacy shortcuts')
  assert(shortcuts[registered['0:./SoundPrep.lua']]=='Ctrl+Alt+A')
  assert(shortcuts[registered['32063:./actions/SoundPrep - Play Stop.lua']]=='Space')
end,debug.traceback)
reaper,package.path=old_reaper,old_path
for _,name in ipairs{'am.action','am.app','am.setup'}do package.loaded[name]=modules[name]end
if not ok then error(err,0)end
