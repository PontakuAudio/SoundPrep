local Preview=require('am.preview');local Model=require('am.model');local U=require('am.util')
local now,position=0,3
local handle={};local valid=true;local writes={};local fail_write=false
local macro=Model.macro('test','Test')
local settings=Model.defaults().settings
local preview=setmetatable({handle=handle,path='/test.wav',source_channels=6,source_length=10,
  macro=U.copy(macro),gain_db=0,starts=1,native=false,
  r={time_precise=function()return now end},
  get_value=function(h,key)
    assert(h==handle)
    if not valid then return false end
    return true,key=='D_POSITION' and position or key=='D_LENGTH' and 10 or 0
  end,
  set_value=function(h,key,value)
    assert(h==handle)
    if fail_write then return false end
    writes[#writes+1]={key=key,value=value};return true
  end,
  stop_handle=function(h)assert(h==handle);valid=false end},Preview)
local function advance(seconds)
  now=now+seconds;preview:tick_gain(now)
end
assert(preview:fade_gain(12,400)and preview.gain_db==0 and #writes==0)
for _=1,19 do
  assert(preview:fade_gain(12,400)) -- Polling the same result must not postpone the ramp.
  advance(.02)
end
assert(math.abs(preview.gain_db-11.4)<1e-10 and preview.gain_target==12)
advance(.02)
if preview.gain_target then advance(.02)end
assert(preview.gain_db==12 and not preview.gain_target and now<=.420001)

assert(preview:fade_gain(0,500));advance(.025)
local before=preview.gain_db
now=now+.01
local target=before+4
assert(preview:fade_gain(target,400))
preview:tick_gain(now);assert(preview.gain_db==before,'Retargeting used time from the previous fade')
for _=1,10 do advance(.02)end
assert(math.abs(preview.gain_db-(before+2))<1e-10 and preview.gain_target==target)
for _=1,9 do advance(.02)end
assert(preview.gain_target==target)
advance(.02)
if preview.gain_target then advance(.02)end
assert(preview.gain_db==target and not preview.gain_target,'Retargeting did not finish on the new schedule')

assert(preview:fade_gain(-3,500))
before=preview.gain_db
advance(30) -- A modal drag must never release a large accumulated gain jump.
assert(math.abs(preview.gain_db-before+1.5)<1e-10 and preview.gain_target==-3)
before=preview.gain_db
advance(-1)
assert(preview.gain_db==before,'A clock moving backwards changed gain')
advance(1)
for _=1,20 do advance(.05)end
assert(preview.gain_db==-3 and preview.handle==handle and preview.starts==1 and position==3)
local previous=0
for _,write in ipairs(writes)do
  assert(write.key=='D_VOLUME','Automatic gain wrote a transport or transform property')
  local db=20*math.log(write.value,10)
  assert(math.abs(db-previous)<=1.500000001,'A gain step exceeded the click-reduction bound')
  previous=db
end

assert(preview:fade_gain(3,400));advance(.025)
local count=#writes
assert(preview:fade_gain(-3,0)and preview.gain_db==-3 and not preview.gain_target and #writes==count+1)
advance(.5);assert(#writes==count+1,'The immediate update left a fade running')

-- A normal Pitch edit must keep the in-flight normalization transition.
assert(preview:fade_gain(3,500));advance(.025)
local current=preview.gain_db
local edited=U.copy(macro);edited.source_transform.pitch_semitones=7
assert(preview:reconfigure(edited,3,settings))
assert(preview.gain_db==current and preview.gain_target==3)
advance(.025);assert(preview.gain_db>current and preview.gain_db<3)
-- An explicit new gain equal to the current level cancels the old target.
current=preview.gain_db
assert(preview:reconfigure(edited,current,settings))
assert(preview.gain_target==nil and preview.gain_db==current)
advance(1);assert(preview.gain_db==current)
assert(preview:update_gain(1)and preview.gain_db==1)

-- Reverse needs a new immutable SECTION, but must carry the audible gain.
assert(preview:fade_gain(6,500));advance(.025);current=preview.gain_db
local start=preview.start
preview.start=function(self,path,new_macro,gain,settings,range,at)
  assert(path=='/test.wav'and gain==current and at==7)
  self:stop();valid=true;self.handle=handle;self.gain_db=gain;self.macro=U.copy(new_macro)
  self.starts=self.starts+1;return true
end
edited.source_transform.reverse=true
settings.normalize_fade_ms=200
assert(preview:reconfigure(edited,6,settings))
assert(preview.gain_db==current and preview.gain_target==6)
preview.start=function()return false,'Source is no longer supported'end
edited.source_transform.reverse=false
local changed,reason=preview:reconfigure(edited,8,settings)
assert(changed==false and reason=='Source is no longer supported')
assert(preview.gain_db==current and preview.gain_target==6,'A rejected SECTION change retargeted the old source')
preview.start=start
advance(.025)
assert(math.abs(preview.gain_db-(current+(6-current)/8))<1e-10)

-- Stop, EOF and a rejected late setter never resurrect or retarget playback.
preview:stop()
assert(preview.gain_target==nil and not preview:fade_gain(8,500))
assert(not preview:tick_gain(now+1))
valid=true;preview.handle=handle;preview.gain_db=0
assert(preview:fade_gain(4,500));valid=false
advance(.025)
assert(preview.handle==nil and preview.gain_target==nil)
valid=true;preview.handle=handle
assert(preview:fade_gain(4,500));fail_write=true
advance(.025)
assert(preview.gain_db==0 and preview.gain_target==nil)
fail_write=false
assert(not pcall(preview.fade_gain,preview,0/0,500),'Non-finite gain was accepted')

-- Each retarget starts from the level the preceding tick actually wrote.
for i=1,60 do
  local before=preview.gain_db
  local target=6+i/10
  assert(preview:fade_gain(target,500))
  advance(1/60)
  assert(math.abs(preview.gain_db-(before+(target-before)/30))<1e-10)
end
assert(preview.gain_db>0 and preview.gain_db<12 and preview.gain_target==12)
