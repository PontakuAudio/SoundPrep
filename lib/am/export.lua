local U=require('am.util');local J=require('am.json');local C=require('am.chunk');local L=require('am.loudness')
local Channels=require('am.render_channels');local Selection=require('am.channel_selection')
local M={}
function M.snapshot(r,path,macro,chain,source_gain,identity,range,settings)
  assert(L.same(identity,L.identity(r,path)),'Source changed; select it again before export')
  local snapshot={schema_version=1,path=path,identity=U.copy(identity),macro=U.copy(macro),chain=chain or '',
    source_gain_db=source_gain,range=range and U.copy(range) or J.null,fade_ms=settings.fade_ms,
    created_at=os.date('!%Y-%m-%dT%H:%M:%SZ'),monitor_gain_excluded=true}
  if next(settings.channel_selections or {})then
    local source=assert(r.PCM_Source_CreateFromFile(path),'Cannot decode selected input channels')
    local channels=r.GetMediaSourceNumChannels(source);r.PCM_Source_Destroy(source)
    local selection=Selection.get(settings,channels)
    if selection then
      local output=Selection.output(selection)
      snapshot.channel_mix={revision=selection.channels and 4 or 3,source_channels=channels,output_channels=output,mode=3,
        selection=U.copy(selection),fx_channels=math.ceil(output/2)*2}
      if output>2 then snapshot.chain='';snapshot.source_processing={fx_bypassed=true,bypass_reason='independent_microphones'}end
    end
  end
  return snapshot
end
function M.populate(r,snapshot,track)
  r.GetSetMediaTrackInfo_String(track,'P_NAME',snapshot.macro.name,true)
  r.SetMediaTrackInfo_Value(track,'D_VOL',U.gain(snapshot.macro.output_gain_db))
  local ret,chunk=r.GetTrackStateChunk(track,'',false);assert(ret)
  assert(r.SetTrackStateChunk(track,C.replace(chunk,C.fresh(Channels.chain(r,snapshot,false),r.genGuid)),false))
  if snapshot.channel_mix then r.SetMediaTrackInfo_Value(track,'I_NCHAN',Channels.width(snapshot))end
  r.TrackFX_Show(track,0,0)
  for i=0,r.TrackFX_GetCount(track)-1 do r.TrackFX_Show(track,i,2)end
  local item=assert(r.AddMediaItemToTrack(track));local take=assert(r.AddTakeToMediaItem(item))
  local source=assert(r.PCM_Source_CreateFromFile(snapshot.path),'Cannot decode source')
  local length,is_qn=r.GetMediaSourceLength(source)
  if is_qn or length<=0 then r.PCM_Source_Destroy(source);error('Not an audio source')end
  local t=snapshot.macro.source_transform;local a,b=0,length
  if snapshot.range~=J.null then a=snapshot.range[1];b=snapshot.range[2]end
  if t.reverse or snapshot.range~=J.null then
    local section=r.PCM_Source_CreateFromType('SECTION')
    if not section then r.PCM_Source_Destroy(source);error('Cannot create source section')end
    local configured=r.CF_PCM_Source_SetSectionInfo(section,source,a,b-a,t.reverse)
    r.PCM_Source_Destroy(source)
    if not configured then r.PCM_Source_Destroy(section);error('Cannot configure source section')end
    source=section
  end
  if not r.SetMediaItemTake_Source(take,source)then
    r.PCM_Source_Destroy(source);error('Cannot assign export media')
  end -- Take owns source from here.
  r.SetMediaItemTakeInfo_Value(take,'I_CHANMODE',Channels.take_mode(snapshot))
  r.SetMediaItemTakeInfo_Value(take,'D_VOL',U.gain(snapshot.source_gain_db))
  r.SetMediaItemTakeInfo_Value(take,'D_PLAYRATE',t.rate)
  r.SetMediaItemTakeInfo_Value(take,'D_PITCH',t.pitch_semitones)
  r.SetMediaItemTakeInfo_Value(take,'B_PPITCH',t.preserve_pitch and 1 or 0)
  r.SetMediaItemTakeInfo_Value(take,'I_PITCHMODE',snapshot.take_pitch_mode or -1)
  local duration=(b-a)/t.rate
  r.SetMediaItemInfo_Value(item,'D_POSITION',0);r.SetMediaItemInfo_Value(item,'D_LENGTH',duration)
  r.SetMediaItemInfo_Value(item,'D_FADEINLEN',snapshot.fade_ms/1000)
  r.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',snapshot.fade_ms/1000)
  r.SetMediaItemInfo_Value(item,'B_LOOPSRC',0)
  return item,duration
end
return M
