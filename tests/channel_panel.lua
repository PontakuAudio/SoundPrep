local Panel=require('am.channel_panel');local Names=require('am.channel_names');local Selection=require('am.channel_selection')
local Model=require('am.model');local J=require('am.json');local U=require('am.util');local Bar=require('am.bar');local App=require('am.app')
local Explorer=require('am.media_explorer')
local project={};local settings=Model.defaults().settings;local writes=0
local app={definition={settings=settings},path='/recording.wav',source_channels=6,project=project,identity={size=100,mtime=1},
  preview={playing=function()return false end}}
function app:set_channel_selection(list)assert(Selection.valid(self.source_channels,{channels=list}));settings.channel_selections=settings.channel_selections or {};settings.channel_selections[tostring(self.source_channels)]={channels=list};writes=writes+1;return true end
function app:set_downmix(value)settings.channel_selections[tostring(self.source_channels)]=nil;settings.preview_downmix=value;return true end
local modes={}
function app:set_downmix_mode(mode)modes[#modes+1]=mode;settings.preview_downmix_mode=mode;return true end
local read=Names.read;Names.read=function()return {[1]='Boom & A',[3]='Boom & A',[5]='風鈴 🎤'}end
local r={EnumProjects=function()return project end};local bar=setmetatable({r=r,app=app},Bar)
bar:dispatch('channels');local state=Panel.state(app);assert(state.open and state.items[1].name=='Boom & A'and state.items[2].name==''and #state.items==6)
assert(state.paged==false)
assert(not app.channels_requested and not app.editor_requested,'Mic selection must not open the preset editor')
local function command(op,channel,source)bar:dispatch('channels@'..J.encode{op=op,channel=channel,source=source or Panel.state(app).source})end
command('toggle',1);command('toggle',3);command('toggle',5)
assert(U.equal(Selection.list(Selection.get(settings,6)),{1,3,5}))
state=Panel.state(app);assert(state.items[1].selected and not state.items[2].selected and state.items[5].name=='風鈴 🎤')
command('toggle',3);command('swap');assert(U.equal(Selection.list(Selection.get(settings,6)),{5,1}))
command('solo',5);assert(U.equal(Selection.list(Selection.get(settings,6)),{5}))
command('toggle',1);assert(U.equal(Selection.list(Selection.get(settings,6)),{1,5}))
command('toggle',5);command('toggle',1);assert(app.channel_panel_notice and #Selection.list(Selection.get(settings,6))==1)
local solo_writes=writes;command('solo',1)
assert(writes==solo_writes and not app.channel_panel_notice and U.equal(Selection.list(Selection.get(settings,6)),{1}))
local source=state.source;local before=writes;app.path='/other.wav';command('toggle',2,source);assert(writes==before)
app.source_channels=128;app:set_channel_selection({127});state=Panel.state(app);assert(state.items[1].channel==121 and state.items[8].channel==128 and not state.next)
assert(state.paged==true)
command('previous');assert(Panel.state(app).items[1].channel==113)
command('solo',113);assert(U.equal(Selection.list(Selection.get(settings,128)),{113}))
command('next');assert(Panel.state(app).items[1].channel==121)
command('next');assert(not Panel.state(app).next)
project={};before=writes;command('toggle',128);assert(writes==before)
bar:dispatch('channels:close');assert(not app.channel_panel_open)
project=app.project;app.source_channels=6;app.path='/recording.wav'
command('all');assert(not Selection.get(settings,6)and not settings.preview_downmix)
app:set_downmix(true);state=Panel.state(app);assert(state.downmix and state.summary=='Downmix all channels')
app.source_channels=4;assert(Panel.state(app).mix=='Auto: Discrete')
command('mode');assert(Panel.state(app).mix=='AmbiX')
command('mode');assert(Panel.state(app).mix=='Discrete')
command('mode');assert(Panel.state(app).mix=='Auto: Discrete')
assert(U.equal(modes,{'ambix','discrete','auto'}))
app.source_channels=0;state=Panel.state(app);assert(not state.enabled and #state.items==0)
-- Wave labels are dense and indexed by original file channel, independent of order.
app.source_channels=6;app:set_channel_selection({5,1});app.r=r
local subset,labels;local subsets,names,csvs=0,0,0;local fail_subset=false
local csv=Selection.csv;Selection.csv=function(...)csvs=csvs+1;return csv(...)end
r.AM_WaveSetChannels=function()end
r.AM_WaveSetChannelSubset=function(...)subset={...};subsets=subsets+1;return not fail_subset end
r.AM_WaveSetChannelNames=function(path,stamp,json)
  assert(path==(app.path or '') and stamp==(app.identity and '100:'..app.identity.mtime or ''))
  labels=J.decode(json);names=names+1;return true
end
local wave='wave';local explorer=Explorer.new(r);app.explorer=explorer;explorer.native_transport='window'
explorer.control=function(_,id)return id==1046 and wave or 'clock'end
r.APIExists=function(key)return key=='AM_WaveAttach'end;r.AM_WaveAttach=function()return true end
explorer:attach_wave()
App.sync_channel_waveform(app)
assert(subset[2]=='5,1'and #labels==6 and labels[1]=='Boom & A'and labels[2]==''and labels[5]=='風鈴 🎤')
App.sync_channel_waveform(app);assert(subsets==1 and names==1 and csvs==1,'Unchanged waveform resent its channels or labels')
Selection.get(settings,6).channels[2]=3;App.sync_channel_waveform(app)
assert(subset[2]=='5,3'and subsets==2 and names==2 and csvs==2)
app:set_downmix(false);App.sync_channel_waveform(app)
assert(subset[2]=='1,2,3,4,5,6'and labels[5]=='風鈴 🎤','All-source waveform keeps names without changing audio selection')
App.sync_channel_waveform(app);assert(subsets==3 and names==3 and csvs==3)
wave='reattached';explorer:attach_wave();App.sync_channel_waveform(app)
assert(subsets==4 and names==4,'The new waveform did not receive its initial channels and labels')
app.identity.mtime=2;fail_subset=true;App.sync_channel_waveform(app)
fail_subset=false;App.sync_channel_waveform(app);App.sync_channel_waveform(app)
assert(subsets==6 and names==6 and subset[3]=='100:2','Failed sends must retry and successful sends must be cached')
-- Two files can share a stamp. Only the overlay's selected path is sent to native.
local original,identity=app.path,app.identity
app.path='/second.wav';App.sync_channel_waveform(app);App.sync_channel_waveform(app)
assert(subsets==7 and subset[1]==app.path and subset[3]=='100:2')
app.path=nil;app.identity=nil;app.source_channels=0
App.sync_channel_waveform(app);App.sync_channel_waveform(app)
assert(subsets==8 and subset[1]=='' and subset[2]=='' and subset[3]=='')
app.path=original;app.identity=identity;app.source_channels=6;App.sync_channel_waveform(app)
assert(subsets==9 and subset[1]==original and subset[3]=='100:2')
assert(not Selection.get(settings,6))
Names.read=read;Selection.csv=csv
-- Mono files keep their sole channel; failed saves leave the panel available.
app.source_channels=1;command('toggle',1);command('toggle',1)
assert(#Panel.state(app).items==1 and Selection.list(Selection.get(settings,1))[1]==1)
bar:dispatch('channels');assert(app.channel_panel_open)
local set=app.set_channel_selection;app.set_channel_selection=function()error('Cannot save settings')end
app.source_channels=6
local ok,err=pcall(command,'toggle',2)
assert(not ok and tostring(err):find('Cannot save settings',1,true)and app.channel_panel_open)
app.set_channel_selection=set
