local I=require('am.insert');local P=require('am.drop_pending');local Selected=require('am.drop_render')
local L=require('am.loudness');local D=require('am.render_item')
local base='<ITEM\nPOSITION 0\nSEL 1\nLENGTH 2\n<TAKEFX\n<JS effect\n1 2 3\n>\n>\n>\n'
assert(I.render_guard(base)==I.render_guard(base:gsub('POSITION 0','POSITION 42'):gsub('SEL 1','SEL 0')))
assert(I.render_guard(base)~=I.render_guard(base:gsub('LENGTH 2','LENGTH 1')))
assert(I.render_guard(base)~=I.render_guard(base:gsub('1 2 3','1 9 3')))
local saved={I.prepare,I.add_rendered,I.build_missing_peaks,L.identity,D.stamp,Selected.recipe}
local ok,err=xpcall(function()
  local items={{guid='moved',chunk=base:gsub('POSITION 0','POSITION 42')},{guid='trimmed',chunk=base:gsub('LENGTH 2','LENGTH 1')}}
  local added,blocks,closed,restored=0,0,0,0
  local busy,refused
  local function write(item,chunk)
    restored=restored+1
    if item==refused then return false end
    item.chunk=chunk;return true
  end
  local identity={path='/source.wav',size=100,mtime=1}
  local r={CountMediaItems=function()return #items end,GetMediaItem=function(_,i)return items[i+1]end,
    GetSetMediaItemInfo_String=function(item)return true,item.guid end,CountTakes=function()return 1 end,
    GetItemStateChunk=function(item)return true,item.chunk end,SetItemStateChunk=write,
    Undo_BeginBlock2=function()assert(blocks==closed);blocks=blocks+1 end,
    Undo_EndBlock2=function()assert(blocks==closed+1);closed=closed+1 end,
    SetExtState=function(section,key,value)assert(section=='AuditionMacro.Drop.v1' and key=='busy' and value=='1');busy=true end,
    DeleteExtState=function(section,key)assert(section=='AuditionMacro.Drop.v1' and key=='busy' and busy);busy=false end}
  I.prepare=function()return {}end;D.stamp=function()end
  I.add_rendered=function(_,_,item)assert(item.guid=='moved');added=added+1 end
  I.build_missing_peaks=function()end;L.identity=function()return identity end
  local batch={directory='fixture',entries={}}
  for _,guid in ipairs{'moved','trimmed','undone'}do batch.entries[#batch.entries+1]={item=guid,guard=I.render_guard(base),snapshot={path='/source.wav',identity=identity},length=2,handles=true}end
  local app={project='project'};local p=P.new(r,app);p:complete(batch)
  assert(added==1 and blocks==1 and app.message:find('2 edited/removed',1,true))
  I.prepare=function()error('fixture render failure')end;p:complete(batch)
  assert(restored==1 and app.message:find('Source + FX retained',1,true),'Failure must restore playable Source + FX')

  -- Both items now qualify. Fail after changing both, then refuse the first restore.
  items[2].chunk=base;refused=items[1];restored=0
  I.prepare=function()return {}end
  I.add_rendered=function(_,_,item)
    item.chunk='partially rendered'
    if item==items[2]then error('fixture render failure')end
  end
  p:complete(batch)
  assert(blocks==3 and closed==3 and busy==false,'Pending render cleanup was skipped')
  assert(restored==2 and items[1].chunk=='partially rendered' and items[2].chunk==base)
  assert(app.message:find('fixture render failure',1,true) and app.message:find('Cannot write item FX state',1,true))

  -- Repeat through Render selected drops with the SWS chunk API.
  items[1].chunk=base;restored=0
  r.EnumProjects=function()return app.project end;r.GetPlayStateEx=function()return 0 end;r.GetExtState=function()return ''end
  r.CountSelectedMediaItems=r.CountMediaItems;r.GetSelectedMediaItem=r.GetMediaItem
  r.GetTake=function(item)return item end;r.ValidatePtr2=function()return true end
  r.GetSetMediaItemTakeInfo_String=function()return true,'{"pending":true,"snapshot":"fixture/drop.json"}'end
  Selected.recipe=function()return {},2,true,0,2 end
  r.SetItemStateChunk=nil
  r.SNM_CreateFastString=function(text)return {text=text}end;r.SNM_DeleteFastString=function()end
  r.SNM_GetFastString=function(fs)return fs.text end
  r.SNM_GetSetObjectState=function(item,fs,set)
    if set then return write(item,fs.text)end
    fs.text=item.chunk;return true
  end
  local rendered,why=pcall(Selected.selected,r)
  assert(not rendered and blocks==4 and closed==4,'Selected render must close undo before raising')
  assert(restored==2 and items[1].chunk=='partially rendered' and items[2].chunk==base)
  local message=why:match('^[^\n]+') -- The action displays the first line.
  assert(message:find('fixture render failure',1,true) and message:find('Cannot write item FX state',1,true))
  items={};p:complete(batch);assert(added==1 and blocks==4,'Absent items must not create an undo point')
end,debug.traceback)
I.prepare,I.add_rendered,I.build_missing_peaks,L.identity,D.stamp,Selected.recipe=table.unpack(saved)
assert(ok,err)
