local E=require('am.media_explorer');local U=require('am.util')
local toggles={[42026]=0,[42134]=0,[42091]=0}
local rows={'/library/a/same.wav','/library/b/same.wav'}
local index,search,directory=0,'same','/library'
local reads,fail=0,false
local r={GetToggleCommandStateEx=function(_,id)return toggles[id] or 0 end,
  JS_ListView_ListAllSelItems=function()return 1,tostring(index)end,
  JS_ListView_GetFocusedItem=function()return index end,
  JS_ListView_GetItemText=function(_,i,col)
    if col==3 then return 'wav'end
    reads=reads+1
    if fail and toggles[42026]==1 then error('row read failed')end
    local name=toggles[42026]==1 and rows[i+1] or 'same.wav'
    return toggles[42091]==1 and name or name:gsub('%.wav$','')
  end,
  file_exists=function(path)return path==rows[1]or path==rows[2]or path=='/library/same.wav'end}
local ex=setmetatable({r=r,control=function()return {}end,
  text=function(_,id)return id==1002 and directory or search end,
  command=function(_,id)
    toggles[id]=1-toggles[id]
    if toggles[id]==1 and (id==42026 or id==42134)then toggles[id==42026 and 42134 or 42026]=0 end
  end},E)
for _,display in ipairs{{0,0,0},{0,1,1},{1,0,0},{1,0,1}}do
  toggles={[42026]=display[1],[42134]=display[2],[42091]=display[3]}
  local before=U.copy(toggles);ex.selected=nil;index=0
  assert(ex:selection()==rows[1]and U.equal(toggles,before))
  assert(not ex:selection_changed(),'Unchanged row should not bypass the polling interval')
  local n=reads;assert(ex:selection()==rows[1]and reads==n+1,'Unchanged selection repeated the canonical read')
  index=1;assert(ex:selection_changed(),'Same-name row change must be detected immediately')
  assert(ex:selection()==rows[2]and U.equal(toggles,before),'Same-name rows reused a stale path')
end
toggles={[42026]=0,[42134]=1,[42091]=0};ex.selected=nil;fail=true
local before=U.copy(toggles)
assert(not pcall(ex.selection,ex)and U.equal(toggles,before),'Failed resolution leaked display settings')
assert(not ex:selection_changed(),'An unresolved row must wait for the regular retry interval')
fail=false;search='';index=0;directory='/library/a';ex.selected=nil
assert(ex:selection()==rows[1]and U.equal(toggles,before),'Hidden extension failed in an ordinary folder')
-- No accidental resolution relative to REAPER's working directory.
toggles[42091]=1;r.file_exists=function(path)return path=='same.wav'or path==rows[1]end
ex.selected=nil;assert(ex:selection()==rows[1])
local all=r.JS_ListView_ListAllSelItems
r.JS_ListView_ListAllSelItems=function()return 0,''end
assert(ex:selection_changed(),'Deselection must stop the previous source promptly')
assert(ex:selection()==nil and not ex:selection_changed(),'Empty selection kept forcing metadata polling')
r.JS_ListView_ListAllSelItems=all

-- New sessions do not force display preferences on attach or undo user edits
-- on close. Recovery of pre-fix snapshots still restores their forced settings.
local commands={};local attached=E.new({
  GetToggleCommandStateEx=function(_,id)return toggles[id]or 0 end,
  JS_WindowMessage_Send=function()return 300 end,
  JS_Window_GetFocus=function()end})
attached.window=function()return {}end;attached.control=function()return {}end
attached.text=function()return '-6'end;attached.transform=function()return {}end
attached.command=function(_,id)commands[#commands+1]=id end
attached.volume=function()end;attached.quiesce=function()end;attached.attach_transport=function()end
attached.fader=function()end;attached.set_transform=function()end
attached:attach()
for _,id in ipairs(commands)do assert(id~=42026 and id~=42134 and id~=42091)end
local saved=U.copy(attached.saved);toggles[42026]=1;toggles[42134]=0;commands={}
attached:restore()
for _,id in ipairs(commands)do assert(id~=42026 and id~=42134 and id~=42091,'Close overwrote a user display edit')end
saved.preserve_display=nil;attached.saved=saved;commands={};attached:restore()
assert(#commands>0,'Legacy recovery no longer restores display settings')

-- A same-titled Media Explorer in another REAPER must never supply settings or
-- receive commands. Include floating ownership, docking, hidden windows, cache
-- invalidation and opening our own window when only the foreign one is visible.
local parent={[0x21]=0x20,[0x11]=0x12,[0x12]=0x10}
local visible={[0x21]=true,[0x11]=true};local opens=0
local windows=E.new({GetOS=function()return 'Win64'end,GetMainHwnd=function()return 0x10 end,
  JS_Window_GetParent=function(w)return parent[w]end,
  JS_Localize=function(s)return s end,
  JS_Window_ListFind=function()return 2,'0x21,0x11'end,
  JS_Window_HandleFromAddress=function(w)return w end,
  JS_Window_IsWindow=function(w)return parent[w]~=nil end,
  JS_Window_IsVisible=function(w)return visible[w]end,
  OpenMediaExplorer=function()opens=opens+1;visible[0x11]=true;return 0x11 end})
assert(windows:window()==0x11 and opens==0)
visible[0x11]=false;assert(not windows:window() and opens==0)
assert(windows:window(true)==0x11 and opens==1)
parent[0x11]=0x10;windows.hwnd=nil;assert(windows:window()==0x11)

-- Autoplay has to be applied after selection-mode commands. Recovery can hold
-- both flags, even though current hosts normally expose exclusive modes.
attached.command=function(_,id)
  commands[#commands+1]=id
  if id==40015 or id==40070 then toggles[1011]=0;toggles[40015]=id==40015 and 1 or 0;toggles[40070]=id==40070 and 1 or 0
  else toggles[id]=1-(toggles[id]or 0)end
end
for _,mode in ipairs{40015,40070}do for _,auto in ipairs{0,1}do
  for _,other in ipairs{0,1}do
    toggles={[1011]=1-auto,[40015]=1,[40070]=0,[1068]=1-other,[42014]=1-other,
      [42182]=1-other,[42348]=1-other,[42055]=1-other,[42183]=1-other}
    attached.saved={preserve_display=true,toggles={['1011']=auto,[tostring(mode)]=1,
      ['1068']=other,['42014']=other,['42182']=other,['42348']=other,['42055']=other,['42183']=other}}
    commands={};attached:restore()
    assert(toggles[1011]==auto,'Selection-mode restore disabled autoplay')
    for _,id in ipairs{1068,42014,42182,42348,42055,42183}do assert(toggles[id]==other)end
    assert(not attached.saved);local count=#commands;attached:restore();assert(#commands==count,'Repeated restore changed settings')
  end
end end
attached.saved={toggles={['1011']=1}};attached.window=function()end
assert(not pcall(attached.restore,attached) and attached.saved,'Failed restore discarded its recovery snapshot')
