#include "cursor.cpp"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#ifdef _WIN32
#include <fstream>
#endif
static int storage[4],state=1,paints=0,unlinks=0,timers=0;
static bool shown=true,exists=true,native_file=true;
static int native_selection=0;
static double fraction=.5,position=6,length=12;
static int scrollbar_at=0,scrollbar_page=800,scrollbar_max=800;
static std::string label="0:00.000  /  0:12.000",file="/test.wav";
extern "C" int AMPreviewWavePosition(char* path,int size,double* f,double* p,double* l) {
  std::snprintf(path,size,"/test.wav");*f=fraction;*p=position;*l=length;return state;
}
static int peak_reads=0,peak_opens=0,peak_closes=0;
static double peak_source_length=12;
static int source_rate=48000,source_channels=6;
static const char* fast_peaks_setting="0"; // Exercise the original path in the existing regressions.
static const auto main_thread=std::this_thread::get_id();
static int main_sample_reads=0,fail_from_frame=-1;
static std::atomic<int> worker_sample_reads{0};
static std::atomic<bool> hold_second_block{false},worker_waiting{false};
static double sample_value(int frame,int channel) {
  return (frame%1021-510+32*channel)/1024.0;
}
template<class Predicate> static void wait_for_audio(Predicate ready) {
  const auto deadline=PeakClock::now()+std::chrono::seconds(5);
  do {
    if(ready())return;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  } while(PeakClock::now()<deadline);
  std::cerr<<"Timed out waiting for the mock peak decoder\n";
  std::abort();
}
static int build_steps=0,build_finishes=0,build_steps_required=4;
static std::chrono::milliseconds build_step_delay{0};
static void check_completed_peak_build(const nlohmann::json& before,const nlohmann::json& after,
    std::int64_t expected_samples,double min_gap_ms=0) {
  const auto& last=after.at("last");
  assert(last.at("mode")=="peaksbuild-fallback");
  assert(last.at("length_s")==peak_source_length && last.at("channels")==source_channels && last.at("sample_rate_hz")==source_rate);
  assert(last.at("samples").is_number_integer() && last.at("samples")==expected_samples);
  assert(last.at("started_unix_ms").get<std::int64_t>()>0 && last.at("run_calls")==build_steps_required);
  const double run_ms=last.at("run_ms"),total_ms=last.at("total_ms");
  assert(run_ms>=build_steps_required*build_step_delay.count()-1 && total_ms>=run_ms+min_gap_ms);
  const double throughput=last.at("samples_per_second");
  assert(std::abs(throughput*total_ms/1000-expected_samples)<expected_samples*1e-9);
  assert(after.at("builds_completed")==before.at("builds_completed").get<int>()+1);
  assert(std::abs(after.at("total_run_ms").get<double>()-before.at("total_run_ms").get<double>()-run_ms)<1e-6);
  assert(after.at("slowest_build_ms")==std::max(before.at("slowest_build_ms").get<double>(),total_ms));
}
static std::vector<int> painted_channels;
static std::vector<std::string> painted_labels;
static int requested_font_height=0;
static int fonts_created=0,fonts_destroyed=0,gdi_created=0,gdi_destroyed=0;
// Deliberately emulate Windows COLORREF packing even on macOS.
static std::map<std::string,int> theme={{"col_mi_bg2",0x918171},{"col_tr1_peaks",0x403020},
  {"col_mi_label",0x302010},{"playcursor_color",0x80c020},{"col_explorer_sel",0xe0d0c0},{"col_explorer_seldm",0x26600}};
struct Fill {int x,y,w,h,color;double alpha;std::string mode;};
static std::vector<Fill> fills;
static std::vector<int> cleared_colors;
struct TestBitmap {int width,height;std::vector<int> pixels;};
struct Damage {int left,right,bottom;bool erase;};
static std::vector<Damage> damage;
static int blits=0;
static int composite_width=0,composite_source_width=0,allocated_width=0;
static int viewport_syncs=0;
static bool stale_scroll=false;
#ifndef _WIN32
static int backing_scale=1;
extern "C" int AMWavePixelScale(void*){return backing_scale;}
#endif
#ifdef __APPLE__
// The cursor harness uses synthetic window handles; exercise both presenters
// without passing those handles to AppKit.
namespace amoverlay {
static bool available=false,active=true;
static void* displayed=nullptr;
static int tracks=0;
bool create(void*,void*,void*(*)(const char*)){return available;}
bool track(void*,int width,int height){assert(width==800 && height==78);++tracks;return active;}
bool present(void* image,int,int,int,int){displayed=image;return true;}
void damage(int,int){}
void unlink(void* image){if(displayed==image)displayed=nullptr;}
void destroy(){assert(!displayed);}
}
#endif
extern "C" bool AMDrawWaveLabel(void*,const char*,int,int,int,int,unsigned int,unsigned int,int,void*(*)(const char*)){return false;}
class Peaks final:public PCM_source {
  const double duration=peak_source_length;
  const int rate=source_rate,channels=source_channels;
  const int failure=fail_from_frame;
  std::atomic<int> reader{0};
public:
  PCM_source* Duplicate()override{return new Peaks;}
  bool IsAvailable()override{return true;}
  const char* GetType()override{return "WAVE";}
  bool SetFileName(const char*)override{return false;}
  int GetNumChannels()override{return channels;}
  double GetSampleRate()override{return rate;}
  double GetLength()override{return duration;}
  int PropertiesWindow(HWND)override{return 0;}
  void GetSamples(PCM_source_transfer_t* t)override{
    assert(t->samples && t->nch==channels && t->samplerate==rate && t->length>0);
    const int first=static_cast<int>(std::llround(t->time_s*t->samplerate));
    assert(first>=0 && first+t->length<=std::llround(duration*t->samplerate));
    const bool main=std::this_thread::get_id()==main_thread;
    const int owner=main?1:2,previous=reader.exchange(owner);
    assert(previous==0 || previous==owner);
    if(main)++main_sample_reads;
    else {
      ++worker_sample_reads;
      const int block=ampeaks::block_frames(channels);
      assert(first%block==0 && t->length==std::min<long long>(block,std::llround(duration*t->samplerate)-first));
      if(first==block && hold_second_block) {
        worker_waiting=true;
        wait_for_audio([]{return !hold_second_block.load();});
        worker_waiting=false;
      }
    }
    if(failure>=0 && first>=failure){t->samples_out=0;return;}
    for(int i=0;i<t->length;++i)for(int ch=0;ch<t->nch;++ch)
      t->samples[i*t->nch+ch]=sample_value(first+i,ch);
    t->samples_out=t->length;
  }
  void GetPeakInfo(PCM_source_peaktransfer_t*)override{}
  void SaveState(ProjectStateContext*)override{}
  int LoadState(const char*,ProjectStateContext*)override{return 0;}
  void Peaks_Clear(bool)override{}
  int PeaksBuild_Begin()override{build_steps=0;return 1;}
  int PeaksBuild_Run()override{
    ++build_steps;
    if(build_step_delay.count()>0)std::this_thread::sleep_for(build_step_delay);
    return build_steps<build_steps_required;
  }
  void PeaksBuild_Finish()override{++build_finishes;}
};
static void* api(const char* name) {
  if(!std::strcmp(name,"GetExtState"))return reinterpret_cast<void*>(+[](const char* section,const char* key){
    assert(std::this_thread::get_id()==main_thread && !std::strcmp(section,"SoundPrep") && !std::strcmp(key,"fast_peaks"));
    return fast_peaks_setting;
  });
  if(!std::strcmp(name,"BR_Win32_SendMessage"))return reinterpret_cast<void*>(+[](void*,unsigned message,std::uintptr_t wp,std::intptr_t lp)->std::intptr_t{
    assert(message==0x5 && wp==0 && lp==((100<<16)|800));++viewport_syncs;
    if(stale_scroll){scrollbar_at=200;scrollbar_page=400;scrollbar_max=800;stale_scroll=false;}
    return 0;
  });
  if(!std::strcmp(name,"GetThemeColor"))return reinterpret_cast<void*>(+[](const char* key,int flags){assert(flags==0);auto i=theme.find(key);return i==theme.end()?-1:i->second;});
  if(!std::strcmp(name,"ColorFromNative"))return reinterpret_cast<void*>(+[](int value,int* r,int* g,int* b){*r=value&255;*g=(value>>8)&255;*b=(value>>16)&255;});
  if(!std::strcmp(name,"JS_LICE_CreateFont"))return reinterpret_cast<void*>(+[]()->void*{++fonts_created;return &storage[3];});
  if(!std::strcmp(name,"JS_LICE_DestroyFont"))return reinterpret_cast<void*>(+[](void*){++fonts_destroyed;});
  if(!std::strcmp(name,"JS_GDI_CreateFont"))return reinterpret_cast<void*>(+[](int height,int,int,bool,bool,bool,const char*)->void*{requested_font_height=height;++gdi_created;return &storage[3];});
  if(!std::strcmp(name,"JS_GDI_DeleteObject"))return reinterpret_cast<void*>(+[](void*){++gdi_destroyed;});
  if(!std::strcmp(name,"LICE__SetFromHFont"))return reinterpret_cast<void*>(+[](void*,void*,int flags){assert(flags==0);});
  if(!std::strcmp(name,"LICE__SetTextColor") || !std::strcmp(name,"LICE__SetBkColor"))return reinterpret_cast<void*>(+[](void*,unsigned int)->unsigned int{return 0;});
  if(!std::strcmp(name,"JS_LICE_DrawText"))return reinterpret_cast<void*>(+[](void*,void*,const char* text,int size,int x,int y,int right,int bottom){assert(x==static_cast<int>(std::lround(8*label_dpi/96.0)) && right==allocated_width-x && bottom>y);painted_labels.emplace_back(text,size);return 12;});
  if(!std::strcmp(name,"PCM_Source_CreateFromFile"))return reinterpret_cast<void*>(+[](const char*)->PCM_source*{
    assert(std::this_thread::get_id()==main_thread);++peak_opens;return new Peaks;
  });
  if(!std::strcmp(name,"PCM_Source_Destroy"))return reinterpret_cast<void*>(+[](PCM_source* src){
    assert(std::this_thread::get_id()==main_thread && src);++peak_closes;delete src;
  });
  if(!std::strcmp(name,"PCM_Source_GetPeaks"))return reinterpret_cast<void*>(+[](PCM_source*,double rate,double start,int channels,int count,int,double* values){
    ++peak_reads;assert(rate>0 && start>=0 && channels==6);
    for(int i=0;i<count;++i)for(int c=0;c<channels;++c){values[i*channels+c]=(c+1)*.1;values[(count+i)*channels+c]=-(c+1)*.1;}
    return count;
  });
  if(!std::strcmp(name,"JS_LICE_FillRect"))return reinterpret_cast<void*>(+[](void* bitmap,int x,int y,int w,int h,int color,double alpha,const char* mode){
    fills.push_back({x,y,w,h,color,alpha,mode});
    auto& b=*static_cast<TestBitmap*>(bitmap);
    for(int row=std::max(0,y);row<std::min(b.height,y+h);++row)
      for(int col=std::max(0,x);col<std::min(b.width,x+w);++col)b.pixels[row*b.width+col]=color;
    if(w==1 && color==theme_pixel("col_tr1_peaks",0xff404040))painted_channels.push_back(h);
  });
  if(!std::strcmp(name,"JS_LICE_DrawChar"))return reinterpret_cast<void*>(+[](void*,int,int,char,int,double,const char* mode){assert(!std::strcmp(mode,"COPY"));});
  if(!std::strcmp(name,"JS_Window_IsWindow"))return reinterpret_cast<void*>(+[](void*){return exists;});
  if(!std::strcmp(name,"JS_Window_IsVisible"))return reinterpret_cast<void*>(+[](void*){return shown;});
  if(!std::strcmp(name,"JS_Window_GetClientSize"))return reinterpret_cast<void*>(+[](void*,int* w,int* h){*w=800;*h=100;return true;});
  if(!std::strcmp(name,"JS_Window_InvalidateRect"))return reinterpret_cast<void*>(+[](void*,int l,int t,int r,int b,bool erase){assert(l>=0 && l<r && t==0 && r<=800 && b>0 && b<=100);damage.push_back({l,r,b,erase});return true;});
  if(!std::strcmp(name,"JS_Window_GetScrollInfo"))return reinterpret_cast<void*>(+[](void*,const char*,int* p,int* page,int* min,int* max,int* track){*p=scrollbar_at;*page=scrollbar_page;*max=scrollbar_max;*min=*track=0;return true;});
  if(!std::strcmp(name,"JS_Window_GetTitle"))return reinterpret_cast<void*>(+[](void*,char* out,int size){std::snprintf(out,size,"%s",label.c_str());});
  if(!std::strcmp(name,"JS_Window_SetTitle"))return reinterpret_cast<void*>(+[](void*,const char* t){label=t;return true;});
  if(!std::strcmp(name,"JS_LICE_CreateBitmap"))return reinterpret_cast<void*>(+[](bool system,int width,int height)->void*{if(system)allocated_width=width;return new TestBitmap{width,height,std::vector<int>(width*height)};});
  if(!std::strcmp(name,"JS_LICE_DestroyBitmap"))return reinterpret_cast<void*>(+[](void* b){delete static_cast<TestBitmap*>(b);});
  if(!std::strcmp(name,"JS_LICE_Clear"))return reinterpret_cast<void*>(+[](void* b,int color){cleared_colors.push_back(color);auto& pixels=static_cast<TestBitmap*>(b)->pixels;std::fill(pixels.begin(),pixels.end(),color);});
  if(!std::strcmp(name,"JS_LICE_Blit"))return reinterpret_cast<void*>(+[](void* dst,int dx,int dy,void* src,int sx,int sy,int w,int h,double alpha,const char* mode){
    assert(alpha==1 && !std::strcmp(mode,"COPY"));++blits;
    auto& d=*static_cast<TestBitmap*>(dst);auto& s=*static_cast<TestBitmap*>(src);
    assert(dx>=0 && dy>=0 && sx>=0 && sy>=0 && dx+w<=d.width && dy+h<=d.height && sx+w<=s.width && sy+h<=s.height);
    for(int y=0;y<h;++y)for(int x=0;x<w;++x)d.pixels[(dy+y)*d.width+dx+x]=s.pixels[(sy+y)*s.width+sx+x];
  });
  if(!std::strcmp(name,"JS_Composite"))return reinterpret_cast<void*>(+[](void*,int,int,int w,int,void*,int,int,int sw,int,bool automatic){assert(!automatic);composite_width=w;composite_source_width=sw;++paints;return 1;});
  if(!std::strcmp(name,"JS_Composite_Unlink"))return reinterpret_cast<void*>(+[](void*,void*,bool){++unlinks;});
  if(!std::strcmp(name,"MediaExplorerGetLastPlayedFileInfo"))return reinterpret_cast<void*>(+[](char* path,int size,int* mode,double* a,double* b,double*,double*,double*,double*,char*,int){std::snprintf(path,size,"%s",file.c_str());*mode=native_selection;*a=.25;*b=.75;return native_file;});
  if(!std::strcmp(name,"GetToggleCommandStateEx"))return reinterpret_cast<void*>(+[](int,int){return 0;});
  return nullptr;
}
#ifdef _WIN32
static void test_font_raster() {
  // Verify real Windows font metrics as well as the stubbed rendering calls.
  constexpr int width=1200,height=560;
  HDC dc=CreateCompatibleDC(nullptr);assert(dc);
  BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=width;
  info.bmiHeader.biHeight=height;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
  void* pixels=nullptr;HBITMAP bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&pixels,nullptr,0);assert(bitmap && pixels);
  auto old_bitmap=SelectObject(dc,bitmap);std::fill_n(static_cast<unsigned int*>(pixels),width*height,0xffeeeeeeu);
  SetTextColor(dc,RGB(32,32,32));SetBkColor(dc,RGB(238,238,238));
  int row=0;
  for(int dpi:{96,120,144,192,288}) {
    const int font_pixels=MulDiv(13,dpi,96),box=MulDiv(22,dpi,96),top=20+row++*108;
    HFONT old_font=CreateFontW(11,0,0,0,400,FALSE,FALSE,FALSE,ANSI_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Yu Gothic UI");
    HFONT font=CreateFontW(-font_pixels,0,0,0,400,FALSE,FALSE,FALSE,ANSI_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,L"Yu Gothic UI");
    assert(font && old_font);auto previous=SelectObject(dc,font);TEXTMETRICW metrics{};assert(GetTextMetricsW(dc,&metrics));
    assert(metrics.tmHeight<=box && metrics.tmHeight-metrics.tmInternalLeading>=font_pixels-1);
    RECT bounds{500,top,1180,top+box};DrawTextW(dc,L"Mono ch 1  Boom & 風鈴",-1,&bounds,DT_SINGLELINE|DT_NOPREFIX);
    SelectObject(dc,old_font);bounds={20,top,480,top+30};
    const std::wstring label=std::to_wstring(MulDiv(dpi,100,96))+L"%  old: Mono ch 1  Boom & 風鈴";
    DrawTextW(dc,label.c_str(),-1,&bounds,DT_SINGLELINE|DT_NOPREFIX);
    SelectObject(dc,previous);DeleteObject(old_font);DeleteObject(font);
  }
  GdiFlush();BITMAPFILEHEADER header{};header.bfType=0x4d42;header.bfOffBits=sizeof(header)+sizeof(BITMAPINFOHEADER);header.bfSize=header.bfOffBits+width*height*4;
  std::ofstream out("wave-label-fonts.bmp",std::ios::binary);assert(out);
  out.write(reinterpret_cast<const char*>(&header),sizeof(header));out.write(reinterpret_cast<const char*>(&info.bmiHeader),sizeof(info.bmiHeader));out.write(static_cast<const char*>(pixels),width*height*4);assert(out);
  SelectObject(dc,old_bitmap);DeleteObject(bitmap);DeleteDC(dc);
}
#endif

static ampeaks::PeakPair expected_range(int first,int end,int channel) {
  float low=1,high=-1;
  for(int frame=first;frame<end;++frame) {
    const auto value=static_cast<float>(sample_value(frame,channel));
    low=std::min(low,value);
    high=std::max(high,value);
  }
  return {low,high};
}
static void check_bins(const PeakStore& store,int first_bin,int end_bin) {
  for(int bin=first_bin;bin<end_bin;++bin)for(int ch=0;ch<6;++ch) {
    const auto expected=expected_range(bin*256,std::min((bin+1)*256,store.frames),ch);
    const auto actual=store.peaks[bin*6+ch];
    assert(actual.low==expected.low && actual.high==expected.high);
  }
}
static void paint_selected(int width,double start=0,double span=1) {
  assert(paint_peaks(peak_path.c_str(),width,100,start,span,0,0,-999999,wave_style()));
}
static void check_column(int width,int column,int first,int end) {
  for(int ch=0;ch<6;++ch) {
    const auto expected=expected_range(first,end,ch);
    assert(peak_values[column*6+ch]==expected.high && peak_values[(width+column)*6+ch]==expected.low);
  }
}
static void check_self_stats(const char* mode,int frames) {
  const auto diag=nlohmann::json::parse(am_peak_build_diagnostics());
  const auto& last=diag.at("last");
  assert(diag.at("mode")==mode && last.at("mode")==mode && last.at("samples")==frames*6);
  assert(last.at("run_calls")==0 && last.at("run_ms")==0 && last.at("started_unix_ms").get<std::int64_t>()>0);
  const double ms=diag.at("self_build_ms"),per_second=diag.at("self_samples_per_second");
  assert(ms>0 && last.at("total_ms").get<double>()>=ms);
  assert(std::abs(ms*per_second/1000-frames*6)<1e-5);
}

static void test_inline_store() {
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  fast_peaks_setting="";
  constexpr int frames=32785; // Partial final bin, even with only one channel selected.
  peak_source_length=frames/48000.0;
  const int opens=peak_opens,reads=main_sample_reads,finishes=build_finishes;
  const auto hits=cache_hits,misses=cache_misses;
  assert(AMWaveSetChannels("/a.wav",3,3,"v1"));
  assert(peak_store && peak_store->ready_frames==frames && peak_opens==opens+1);
  assert(main_sample_reads==reads+1 && build_finishes==finishes && worker_sample_reads==0);
  assert(peak_store->peaks.size()==129*6);
  check_bins(*peak_store,0,129);
  check_self_stats("inline",frames);

  paint_selected(64);
  assert(main_sample_reads==reads+1 && peak_count==64);
  // Pixel zero overlaps bins 0, 1 and the first frame of bin 2.
  check_column(64,0,0,768);
  paint_selected(64,.125,1./64);
  assert(main_sample_reads==reads+2 && peak_count==64);
  check_column(64,0,4098,4107);

  auto* original=peak_store.get();
  assert(AMWaveSetChannelSubset("/a.wav","2,4,6","v1") && peak_store.get()==original);
  paint_selected(64,.125,1./64);
  assert(main_sample_reads==reads+2 && peak_opens==opens+1);
  assert(cache_hits==hits && cache_misses==misses+1);
  assert(AMWaveSetChannels("/b.wav",1,1,"v1"));
  assert(AMWaveSetChannels("",0,0,""));
  AMCursorDetach();
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  assert(AMWaveSetChannels("/a.wav",6,6,"v1") && peak_store.get()==original);
  assert(main_sample_reads==reads+3 && peak_opens==opens+2);
  const auto cached=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(cached.at("cache_hits")==hits+1 && cached.at("cache_misses")==misses+2);
  assert(cached.at("last_cache_lookup")=="hit" && cached.at("mode")=="cache");
  assert(AMWaveSetChannels("/a.wav",6,6,"v2") && peak_store.get()!=original);
  assert(cache_misses==misses+3);
  assert(AMWaveSetChannelNames("/a.wav","v2",R"(["","","","","","Room"])"));
  const auto builds_before_toggle=peak_builds_completed;
  const int peak_reads_before=peak_reads,sample_reads_before=main_sample_reads;
  fast_peaks_setting="0";
  assert(AMWaveSetChannels("/a.wav",6,6,"v2") && !peak_store && build_finishes==finishes+1);
  painted_labels.clear();
  paint_selected(64);
  assert(painted_labels==std::vector<std::string>({"Mono ch 6  Room"}));
  assert(peak_reads==peak_reads_before+1 && main_sample_reads==sample_reads_before);
  const auto ab=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(ab.at("last_cache_lookup")=="bypass" && ab.at("cache_misses")==misses+3);
  assert(ab.at("last")==ab.at("last_peaksbuild") && ab.at("last_store").at("mode")=="inline");
  for(const char* key:{"last_store","last_peaksbuild"})
    assert(ab.at(key).at("path")=="/a.wav" && ab.at(key).at("stamp")=="v2");
  fast_peaks_setting="1";
  const int opens_before=peak_opens;
  assert(AMWaveSetChannels("/a.wav",6,6,"v2") && peak_store && peak_opens==opens_before);
  assert(peak_builds_completed==builds_before_toggle+1);
  const auto reused=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(reused.at("last")==ab.at("last") && reused.at("last_store")==ab.at("last_store"));

  fail_from_frame=0;
  const int failed_reads=peak_reads;
  assert(AMWaveSetChannels("/broken.wav",1,1,"v1") && !peak_store);
  paint_selected(64);
  assert(main_sample_reads==sample_reads_before+1 && build_finishes==finishes+2 && peak_reads==failed_reads+1);
  fail_from_frame=-1;
  AMCursorDetach();
  am_close_peak_sources();
  assert(peak_closes==peak_opens);
}

static void test_worker_store() {
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  constexpr int frames=4*262144;
  peak_source_length=frames/48000.0;
  const int opens=peak_opens,reads=main_sample_reads,old_peak_reads=peak_reads;
  hold_second_block=true;
  assert(AMWaveSetChannels("/test.wav",1,1,"worker"));
  wait_for_audio([]{return worker_waiting.load();});
  assert(peak_store && peak_store->ready_frames==262144 && peak_opens==opens+2);
  assert(AMWaveSetChannels("/test.wav",6,6,"worker") && peak_opens==opens+2);
  painted_labels.clear();
  paint_selected(800);
  assert(peak_count==200 && painted_labels==std::vector<std::string>({"Mono ch 6 ..."}));
  check_bins(*peak_store,1023,1024);
  paint_selected(800,.5,1./128); // Entire zoomed viewport is still unavailable.
  assert(peak_count==0 && main_sample_reads==reads);
  paint_selected(800,.125,1./128);
  assert(peak_count==800 && main_sample_reads==reads+1);
  check_column(800,0,frames/8,frames/8+11);
  paint_selected(800);
  assert(peak_count==200);

  hold_second_block=false;
  wait_for_audio([]{return peak_store->ready_frames.load()==peak_store->frames;});
  check_self_stats("worker",frames);
  painted_labels.clear();
  paint_selected(800);
  assert(peak_count==800 && painted_labels==std::vector<std::string>({"Mono ch 6"}));
  assert(worker_sample_reads==4 && peak_reads==old_peak_reads);
  check_bins(*peak_store,1024,1025);
  check_bins(*peak_store,4095,4096);
  // 128 frames per pixel, but over four million interleaved samples.
  peak_values.resize(8192*6*2);
  assert(read_store_columns(*peak_store,frames,8192,0,1,peak_values)==8192);
  check_column(8192,0,0,256);
  assert(main_sample_reads==reads+1);
  const auto builds=peak_builds_completed;
  assert(AMWaveSetChannels("",0,0,"") && AMWaveSetChannels("/test.wav",2,2,"worker"));
  assert(peak_opens==opens+2 && peak_builds_completed==builds);

  // Cancel during GetSamples and attach a different stamp before it returns.
  hold_second_block=true;
  assert(AMWaveSetChannels("/test.wav",1,1,"cancel"));
  wait_for_audio([]{return worker_waiting.load();});
  peak_source_length=(frames+17)/48000.0;
  assert(AMWaveSetChannels("/test.wav",1,1,"replacement"));
  assert(peak_store->ready_frames==0);
  hold_second_block=false;
  wait_for_audio([]{
    tick();
    return peak_store && peak_store->ready_frames.load()==peak_store->frames;
  });
  check_self_stats("worker",frames+17);
  check_bins(*peak_store,4096,4097);
  assert(peak_builds_completed==builds+1);
  assert(worker_sample_reads==4+2+5);

  fail_from_frame=262144;
  const int finishes=build_finishes;
  assert(AMWaveSetChannels("/test.wav",1,1,"failed-worker"));
  wait_for_audio([]{tick();return !peak_store;});
  assert(build_finishes==finishes+1 && peak_reads>old_peak_reads && peak_count==800);
  assert(nlohmann::json::parse(am_peak_build_diagnostics()).at("last").at("mode")=="peaksbuild-fallback");
  fail_from_frame=-1;
  AMCursorDetach();
  am_close_peak_sources();
  assert(peak_closes==peak_opens);
}

static void test_store_eviction() {
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  peak_source_length=257/48000.0;
  for(int i=0;i<8;++i)assert(AMWaveSetChannels(std::to_string(i).c_str(),1,1,"v1"));
  const int opens=peak_opens;
  assert(AMWaveSetChannels("0",1,1,"v1") && peak_opens==opens);
  assert(AMWaveSetChannels("8",1,1,"v1") && peak_cache.size()==8);
  assert(AMWaveSetChannels("0",1,1,"v1") && peak_opens==opens+1);
  assert(AMWaveSetChannels("1",1,1,"v1") && peak_opens==opens+2);
  // A file without a usable stamp must be reopened on a later selection.
  assert(AMWaveSetChannels("/unstamped.wav",1,1,""));
  assert(AMWaveSetChannels("",0,0,""));
  assert(AMWaveSetChannels("/unstamped.wav",1,1,"") && peak_opens==opens+4);
  AMCursorDetach();
  am_close_peak_sources();
  assert(peak_closes==peak_opens);
}

// Model PCM_Source_GetPeaks independently by scanning the fixture's original
// PCM at the requested start time and peak rate, in REAPER's two-plane layout.
static int fixture_peaks(PCM_source* source,double rate,double start,int channels,int width,int extra,double* values) {
  ++peak_reads;
  assert(extra==0 && channels==source->GetNumChannels());
  const double hz=source->GetSampleRate(),first=start*hz,step=hz/rate;
  const int frames=static_cast<int>(std::llround(source->GetLength()*hz));
  int column=0;
  for(;column<width;++column) {
    const int begin=static_cast<int>(std::floor(first+column*step));
    if(begin>=frames)break;
    const int end=std::min(frames,static_cast<int>(std::ceil(first+(column+1)*step)));
    for(int ch=0;ch<channels;++ch) {
      double low=sample_value(begin,ch),high=low;
      for(int i=begin+1;i<end;++i) {
        const double value=sample_value(i,ch);
        low=std::min(low,value);
        high=std::max(high,value);
      }
      values[column*channels+ch]=high;
      values[(width+column)*channels+ch]=low;
    }
  }
  return column;
}

static void test_backend_agreement() {
  assert(AMCursorAttach(&storage[0],&storage[1],+[](const char* name)->void*{
    return !std::strcmp(name,"PCM_Source_GetPeaks")?reinterpret_cast<void*>(fixture_peaks):api(name);
  }));
  constexpr int frames=32768,width=64;
  peak_source_length=frames/48000.0;
  const int before=peak_reads;
  fast_peaks_setting="1";
  assert(AMWaveSetChannelSubset("/test.wav","1,3,5","parity") && peak_store);
  const struct {double start,span;int columns;} views[]={
    {0,1,64},                              // Two full base bins per pixel.
    {.25,.5,64},                           // Scrolled, one base bin per pixel.
    {513.5/frames,1./64,64},               // Sub-bin pixels, fractional edges.
    {(frames-65.5)/frames,1./64,9}         // Last partial pixel before EOF.
  };
  std::vector<std::vector<double>> store_values;
  for(const auto& view:views) {
    paint_selected(width,view.start,view.span);
    assert(peak_count==view.columns);
    store_values.push_back(peak_values);
  }
  assert(peak_reads==before);
  fast_peaks_setting="0";
  assert(AMWaveSetChannelSubset("/test.wav","1,3,5","parity") && !peak_store);
  const int reads=main_sample_reads;
  for(size_t i=0;i<store_values.size();++i) {
    paint_selected(width,views[i].start,views[i].span);
    assert(peak_count==views[i].columns && peak_values==store_values[i]);
  }
  assert(peak_reads==before+4 && main_sample_reads==reads);
  fast_peaks_setting="";
  AMCursorDetach();
  am_close_peak_sources();
}

static void test_sample_budgets_and_deselection() {
  static_assert(ampeaks::block_frames(2)==262144 && ampeaks::block_frames(128)==16384);
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  source_channels=2;
  peak_source_length=20;
  assert(AMWaveSetChannels("/sfx.wav",1,1,"48k"));
  assert(peak_store && peak_store->ready_frames==960000 && last_store_build.samples==1'920'000);
  source_rate=192000;
  hold_second_block=true;
  const int reads=worker_sample_reads;
  assert(AMWaveSetChannels("/sfx.wav",1,1,"192k"));
  wait_for_audio([]{return worker_waiting.load();});
  assert(peak_store && peak_store->ready_frames==262144 && current_peak_build.samples==7'680'000);
  // A queued replacement loses its selection before the private decoder is free.
  assert(AMWaveSetChannels("/transient.wav",1,1,"192k") && peak_store->ready_frames==0);
  assert(AMWaveSetChannels("",0,0,""));
  const int opens=peak_opens;
  hold_second_block=false;
  wait_for_audio([]{tick();return !worker_store;});
  tick();
  assert(!peak_source && !peak_store && peak_opens==opens && worker_sample_reads==reads+2);
  assert(peak_cache.size()==1 && peak_cache.front()->stamp=="48k");

  // Fewer than 200M frames, but over 200M samples across this stereo file.
  peak_source_length=600;
  assert(AMWaveSetChannels("/large.wav",1,1,"192k") && !peak_store);
  assert(last_reaper_build.samples==230'400'000 && worker_sample_reads==reads+2);
  AMCursorDetach();
  am_close_peak_sources();
  assert(peak_closes==peak_opens);
  source_rate=48000;source_channels=6;
}

int main() {
#ifdef __APPLE__
  const struct {const char* ini;const char* raw;bool hidden;} renderers[]={
    {"[REAPER]\nrenderer_cocoa=metal\n","metal",true},
    {"[REAPER]\nrenderer_cocoa=Metal","Metal",false},
    {"[other]\nrenderer_cocoa=metal\n[REAPER]\r\nrenderer_cocoa = Classic\r\n","Classic",false},
    {"[REAPER]\nother=metal\n","unknown",false},
    {"renderer_cocoa=metal\n[REAPER]\n[other]\nrenderer_cocoa=metal\n","unknown",false}
  };
  for(const auto& [ini,raw,hidden]:renderers) {
    renderer_cocoa=parse_cocoa_renderer(ini);
    const auto cursor=nlohmann::json::parse(AMCursorState());
    assert(cursor.at("renderer_cocoa")==raw);
    assert(cursor.at("overlay_hidden_by_gpu")==hidden);
  }
#endif
#ifdef _WIN32
  test_font_raster();
#endif
  AMCursorRegister(+[](const char* name,void*){timers+=*name=='-'?-1:1;return 1;});
  assert(AMCursorAttach(&storage[0],&storage[1],api));tick();
  const auto cursor=nlohmann::json::parse(AMCursorState());
  assert(cursor.at("presentation")=="composite");
#ifdef __APPLE__
  assert(cursor.at("renderer_cocoa")=="unknown"); // No resource path in the mock host.
#else
  assert(cursor.at("renderer_cocoa")=="n/a");
#endif
  assert(cursor.at("overlay_hidden_by_gpu")==false);
#ifdef __APPLE__
  renderer_cocoa="metal";
  assert(nlohmann::json::parse(AMCursorState()).at("overlay_hidden_by_gpu")==true);
#endif
  assert(paints==1 && last_x==400 && label=="0:06.000  /  0:12.000" && timers==1);
  tick();assert(paints==1); // No repaint/allocations when position is unchanged.
  AMCursorRestoreClock();assert(label=="0:00.000  /  0:12.000");
  label="0:03.000  /  0:12.000";tick();AMCursorRestoreClock();assert(label=="0:03.000  /  0:12.000");
  // A native range drag must own the entire waveform, including repainting.
  // Pausing cursor movement alone leaves the old composite over its selection.
  AMCursorSuspend(true);assert(!linked);const int before_drag=paints;
  fraction=.75;tick();assert(!linked && paints==before_drag);
  label="native range drag";tick();assert(label=="native range drag" && paints==before_drag);
  label="0:03.000  /  0:12.000";
  AMCursorSuspend(false);tick();assert(last_x==600);
  state=-1;fraction=.2;tick();assert(last_x==600);state=0;tick();assert(last_x==600);
  file="/different.wav";tick();assert(!linked && unlinks==2 && label=="0:03.000  /  0:12.000");
  file="/test.wav";state=1;tick();shown=false;tick();assert(!linked);shown=true;tick();
  label="native changed it";AMCursorDetach();assert(label=="native changed it" && timers==0);
  assert(pixel(.5,200,400,0,800,800)==400 && pixel(.1,200,400,0,800,800)<0);
  assert(pixel(.5,0,0,0,800,800)==-999999);
  // Scroll endpoints are signed ints; their difference need not fit an int.
  // A page spanning half the file maps its quarter point to half the width.
  assert(pixel(.5,std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),
    std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),800)==800);
  assert(pixel(.25,std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),
    std::numeric_limits<int>::min(),std::numeric_limits<int>::max(),800)==400);
  assert(pixel(1e100,0,1,0,800,800)==-999999);
  assert(pixel(NAN,0,800,0,800,800)==-999999);
  // Independently scale scroll units and pixels, including zoom and scrolling.
  assert(AMCursorAttach(&storage[0],&storage[1],api));fraction=.5;
  scrollbar_max=scrollbar_page=1600;tick();assert(last_x==400);
  scrollbar_at=400;scrollbar_page=800;tick();assert(last_x==400);
  fraction=.1;tick();assert(!linked);
  fraction=.75;scrollbar_at=0;scrollbar_page=1600;
  AMCursorZoom(42093);tick();assert(last_x==600 && view_width==800 && view_units==1600);
  // A short source finishes at attach even when its build exceeds the timed burst.
  fraction=0;
  build_steps_required=12;build_step_delay=std::chrono::milliseconds(30);
  const auto initial=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(initial.at("last").is_null() && initial.at("builds_completed")==0);
  assert(initial.at("total_run_ms")==0 && initial.at("slowest_build_ms")==0);
  assert(AMWaveSetChannels("/test.wav",5,2,"v1"));
  assert(!peak_building && build_steps==build_steps_required && build_finishes==1);
  check_completed_peak_build(initial,nlohmann::json::parse(am_peak_build_diagnostics()),3'456'000);
  build_steps_required=4;build_step_delay=std::chrono::milliseconds(0);
  tick();assert(peak_linked && peak_cursor==0 && peak_count==800 && peak_reads==1 && peak_opens==1);
  assert(painted_labels==std::vector<std::string>({"L ch 5","R ch 2"}));
  // Selected peaks stay visible while stopped without re-reading the source.
  state=0;*last_path=0;tick();
  assert(peak_linked && peak_reads==1);
  assert(painted_channels[0]>painted_channels[800]);
  assert(cleared_colors.back()==static_cast<int>(0xff718191));
  assert(peak_style.peaks==static_cast<int>(0xff203040) && peak_style.text==static_cast<int>(0xff102030));
  int reads=peak_reads,paints_before=paints;
  assert(AMWaveSetChannels("/test.wav",5,2,"v1"));tick();assert(peak_reads==reads && paints==paints_before);
  // Theme edits repaint a stopped preview without reopening or re-reading PCM.
  theme["col_mi_bg2"]=0x181818;tick();assert(peak_reads==reads && paints==paints_before+1);
  assert(cleared_colors.back()==static_cast<int>(0xff181818));
  paints_before=paints;tick();assert(paints==paints_before);
  // A range tints the finished waveform, not only the empty background.
  fills.clear();assert(paint_peaks("/test.wav",800,100,0,1,.25,.75,-999999,wave_style()));
  const auto selection=fills.back();
  assert(selection.x==200 && selection.w==400 && selection.color==static_cast<int>(0xffc0d0e0));
  assert(selection.alpha==102.0/256 && selection.mode=="COPY");
  theme["col_explorer_seldm"]=0x28003;fills.clear();tick();
  assert(paint_peaks("/test.wav",800,100,0,1,.25,.75,-999999,wave_style()));
  assert(fills.back().mode=="MUL" && fills.back().alpha==.5 && peak_reads==reads);
  theme["col_explorer_seldm"]=0x26600;
  // Both native selection flags tint selected channels and anchor zoom.
  for(int flag:{128,256,384}) {
    native_selection=flag;fills.clear();tick();
    assert(peak_a==.25 && peak_b==.75);
    AMCursorZoom(42092);
    assert(std::abs(view_start-.225)<1e-9 && std::abs(view_span-.55)<1e-9);
    AMCursorZoom(42093);
  }
  native_selection=0;tick();
  const auto clean_peaks=static_cast<TestBitmap*>(peak_bitmap)->pixels;
  const auto redraws=peak_repaints;
  painted_channels.clear();painted_labels.clear();damage.clear();const int composites=paints;
  state=1;
  // Include overlapping moves, reverse motion, wraparound and a clipped cursor
  // at the right edge. Restoring the strip must leave no cursor trails.
  for(double f:{.25,.25125,.25,.9,0.0,.99875,1.0,-.1}) {
    fraction=f;tick();
    const auto& b=*static_cast<TestBitmap*>(peak_bitmap);
    for(int y=0;y<b.height;++y)for(int x=0;x<b.width;++x)
      assert(b.pixels[y*b.width+x]==(peak_cursor>=0 && x>=peak_cursor && x<peak_cursor+2?wave_style().cursor:clean_peaks[y*b.width+x]));
  }
  assert(peak_reads==reads && peak_repaints==redraws && paints==composites && blits>0);
  assert(painted_channels.empty() && painted_labels.empty() && !damage.empty());
  for(const auto& d:damage)assert(d.right-d.left<=2 && !d.erase);
  fraction=.3;tick();
  // A busy audio thread cannot hold up a new channel waveform/peak build.
  state=-1;labels_dirty=true;const auto busy_redraws=peak_repaints;tick();
  assert(peak_repaints==busy_redraws+1 && peak_cursor==240);state=1;
  // Native selection feedback is transient during the modal Windows mouse
  // loop. A full opaque channel overlay must not hide it, even if the timer
  // runs while the audio thread holds its lock or the source changes.
  for(int playing:{1,0,-1}) {
    state=playing;const int before=paints,opened=peak_opens;
    AMCursorSuspend(true);assert(!linked && !peak_linked);
    AMCursorSuspend(true); // Repeated suspend must not clear source ownership.
    fraction=.6;tick();tick();
    assert(!linked && !peak_linked && paints==before && peak_reads==reads && peak_opens==opened);
    assert(peak_source && peak_channels==std::vector<int>({5,2}));
    AMCursorSuspend(false);state=1;tick();
    assert(peak_linked && peak_reads==reads && peak_opens==opened && peak_cursor==480);
  }
  assert(AMWaveSetChannels("/test.wav",4,4,"v1"));painted_channels.clear();tick();
  assert(painted_channels.size()==800 && peak_left==peak_right && peak_opens==1);
  scrollbar_at=400;scrollbar_page=800;tick();assert(peak_start==.25 && peak_span==.5);
  file="/different.wav";native_selection=128;tick();
  assert(peak_linked && peak_a==0 && peak_b==0 && peak_cursor==-999999);
  file="/test.wav";native_selection=0;tick();assert(peak_linked);
  shown=false;tick();assert(!peak_linked);shown=true;tick();assert(peak_linked);
  assert(!AMWaveSetChannels("/test.wav",7,7,"v1"));assert(peak_left==4);
  assert(AMWaveSetChannels("/test.wav",1,2,"v2"));tick();assert(peak_opens==2 && peak_closes==1);
  assert(AMWaveSetChannelSubset("/test.wav","1,3,5","v2"));painted_channels.clear();tick();
  assert(peak_channels==std::vector<int>({1,3,5}) && painted_channels.size()==2400);
  assert(painted_channels[0]<painted_channels[800] && painted_channels[800]<painted_channels[1600]);
  assert(std::strstr(AMCursorState(),"\"selected_lanes\":3"));
  const char* names=R"(["Boom & L","","風鈴 🎤","Spare","Room ##R",""])";
  int before_names=peak_reads;painted_labels.clear();
  assert(AMWaveSetChannelNames("/test.wav","v2",names));tick();
  assert(peak_reads==before_names && painted_labels==std::vector<std::string>({"Input ch 1  Boom & L","Input ch 3  風鈴 🎤","Input ch 5  Room ##R"}));
  paints_before=paints;assert(AMWaveSetChannelNames("/test.wav","v2",names));tick();assert(paints==paints_before);
  for(const char* bad:{"{}","[42]","[]","[1,2,3,4,5,6]","[\"bad\\nname\",\"\",\"\",\"\",\"\",\"\"]"})assert(!AMWaveSetChannelNames("/test.wav","v2",bad));
  assert(!AMWaveSetChannelNames("/other.wav","v2",names) && !AMWaveSetChannelNames("/test.wav","old",names));
  assert(AMWaveSetChannels("/test.wav",5,2,"v2"));painted_labels.clear();tick();
  assert(painted_labels==std::vector<std::string>({"L ch 5  Room ##R","R ch 2"}));
  assert(AMWaveSetChannels("/test.wav",3,3,"v2"));painted_labels.clear();tick();assert(painted_labels[0]=="Mono ch 3  風鈴 🎤");
  native_file=false;tick();assert(peak_linked && peak_channels==std::vector<int>({3}));native_file=true;
  for(const char* bad:{"","1,1","1,7","1,","0","129","1;3","3,2,1"})
    assert(!AMWaveSetChannelSubset("/test.wav",bad,"v2"));
  assert(AMWaveSetChannels("",0,0,""));assert(!peak_linked && !peak_source && peak_closes==2);
  assert(AMWaveSetChannels("/test.wav",1,1,"v3"));AMCursorDetach();assert(peak_closes==3 && !peak_bitmap && !cursor_underlay);
  assert(fonts_created==1 && fonts_destroyed==1 && gdi_created==gdi_destroyed);
#ifndef _WIN32
  backing_scale=2;state=1;fraction=.5;scrollbar_at=0;scrollbar_page=scrollbar_max=800;
  assert(AMCursorAttach(&storage[0],&storage[1],api));assert(AMWaveSetChannels("/test.wav",3,3,"retina"));tick();
  assert(peak_count==1600 && composite_width==800 && composite_source_width==1600);
  assert(last_x==400 && peak_cursor==800 && peak_height==156);
  reads=peak_reads;tick();assert(peak_reads==reads);
  const auto retina_redraws=peak_repaints;damage.clear();fraction=.50125;tick();
  assert(peak_cursor==802 && peak_repaints==retina_redraws && cursor_underlay);
  for(const auto& d:damage)assert(d.right-d.left<=2 && !d.erase);
  fraction=.5;tick();
  backing_scale=1;tick();assert(peak_count==800 && peak_cursor==400 && peak_reads==reads+1);
  // Native menu/wheel zoom can leave CoolSB stale until the unchanged size is
  // reapplied. Refresh only after input, then use the updated position/page.
  stale_scroll=true;int syncs=viewport_syncs;AMCursorViewportChanged();tick();
  assert(viewport_syncs==syncs+1 && peak_start==.25 && peak_span==.5 && peak_cursor==400);
  tick();assert(viewport_syncs==syncs+1);
  AMCursorDetach();assert(fonts_created==fonts_destroyed && gdi_created==gdi_destroyed);
#endif
#ifdef _WIN32
  // A monitor change recreates fonts and repaints labels without re-decoding
  // the waveform. Include fractional desktop scaling and a missing-DPI fallback.
  assert(AMCursorAttach(&storage[0],&storage[1],api));
  assert(AMWaveSetChannels("/test.wav",1,1,"dpi"));
  tick();tick();
  const auto saved_dpi=window_dpi;
  for(unsigned int dpi:{96u,120u,144u,192u,288u,0u,96u}) {
    static unsigned int value;value=dpi;window_dpi=+[](void*){return value;};
    const int before=peak_reads;tick();
    assert(requested_font_height==-static_cast<int>(std::lround(13*(dpi?dpi:96)/96.0)));
    assert(peak_width==800 && composite_width==800 && composite_source_width==800);
    assert(peak_reads==before);
    const int made=gdi_created,painted=paints;tick();
    assert(gdi_created==made && paints==painted);
  }
  window_dpi=saved_dpi;AMCursorDetach();
  assert(fonts_created==fonts_destroyed && gdi_created==gdi_destroyed);
#endif
  // At 192 kHz even 15 s of six-channel audio needs a burst and more ticks.
  // Peak building still advances when audio snapshots are busy.
  // Missing optional blit support retains the complete-paint fallback.
  assert(AMCursorAttach(&storage[0],&storage[1],+[](const char* name)->void*{
    return !std::strcmp(name,"JS_LICE_Blit")?nullptr:api(name);
  }));
  state=-1;peak_source_length=15;source_rate=192000;
  build_steps_required=12;build_step_delay=std::chrono::milliseconds(30);
  const int finishes_before=build_finishes;
  const auto before_burst=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(before_burst.at("builds_completed")==finishes_before);
  assert(AMWaveSetChannelSubset("/test.wav","1","busy"));
  const int steps_after_attach=build_steps;
  assert(peak_building && steps_after_attach>1 && steps_after_attach<build_steps_required-1 && build_finishes==finishes_before);
  const auto gap_start=std::chrono::steady_clock::now();
  const auto during=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(during.at("last")==before_burst.at("last") && during.at("builds_completed")==finishes_before);
  assert(during.at("total_run_ms")>before_burst.at("total_run_ms"));
  const double gap_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-gap_start).count();
  painted_labels.clear();tick();
  assert(peak_building && build_steps==steps_after_attach+1 && build_finishes==finishes_before);
  assert(painted_labels==std::vector<std::string>({"Mono ch 1 ..."}));
  // Each remaining mock step exceeds the tick budget.
  for(int step=build_steps;step<build_steps_required-1;++step)tick();
  assert(peak_building && build_steps==build_steps_required-1 && build_finishes==finishes_before);
  reads=peak_reads;painted_labels.clear();tick();
  assert(!peak_building && build_steps==build_steps_required && build_finishes==finishes_before+1 && peak_reads==reads+1);
  const auto completed=nlohmann::json::parse(am_peak_build_diagnostics());
  check_completed_peak_build(before_burst,completed,17'280'000,gap_ms);
  assert(painted_labels==std::vector<std::string>({"Mono ch 1"}));
  assert(peak_linked && peak_count>0 && !cursor_underlay && last_fraction<0);
  state=1;fraction=.2;tick();const auto fallback_redraws=peak_repaints;
  fraction=.4;tick();assert(peak_repaints==fallback_redraws+1);
  // The sample count includes every source channel and can exceed 32 bits.
  peak_source_length=18000;source_rate=48000;build_steps_required=1;build_step_delay=std::chrono::milliseconds(0);
  fast_peaks_setting=""; // Also verify the self-build sanity cap.
  assert(AMWaveSetChannelSubset("/test.wav","1","long"));
  const auto long_build=nlohmann::json::parse(am_peak_build_diagnostics());
  assert(long_build.at("last").at("samples")==5'184'000'000LL);
  assert(long_build.at("mode")=="peaksbuild-fallback" && main_sample_reads==0 && worker_sample_reads==0);
  AMCursorDetach();assert(fonts_created==fonts_destroyed && gdi_created==gdi_destroyed);
  assert(nlohmann::json::parse(am_peak_build_diagnostics())==long_build);
  test_inline_store();
  test_worker_store();
  test_backend_agreement();
  test_sample_budgets_and_deselection();
  test_store_eviction();
  theme.clear();assert(wave_style().background==static_cast<int>(0xffcccccc));
  assert(wave_style().selection_mode==0x26600);
#ifdef __APPLE__
  amoverlay::available=true;
  const int paints_before_overlay=paints;
  assert(AMCursorAttach(&storage[0],&storage[1],api));tick();
  renderer_cocoa="metal";
  const auto overlay_cursor=nlohmann::json::parse(AMCursorState());
  assert(overlay_cursor.at("presentation")=="overlay");
  assert(overlay_cursor.at("overlay_hidden_by_gpu")==false);
  assert(linked && amoverlay::displayed==bitmap);
  const int tracked=amoverlay::tracks;
  tick();assert(amoverlay::tracks==tracked+1);
  amoverlay::active=false;tick();assert(!amoverlay::displayed);
  amoverlay::active=true;tick();assert(amoverlay::displayed==bitmap);
  assert(AMWaveSetChannels("/test.wav",1,1,"overlay"));tick();
  assert(peak_store && peak_linked && amoverlay::displayed==peak_bitmap);
  file="/different.wav";native_selection=128;tick();
  assert(amoverlay::displayed==peak_bitmap && peak_a==0 && peak_b==0 && peak_cursor==-999999);
  file="/test.wav";tick();
  assert(peak_a==.25 && peak_b==.75 && peak_cursor>=0);
  native_selection=0;
  AMCursorSuspend(true);assert(!amoverlay::displayed);
  tick();assert(!amoverlay::displayed);
  AMCursorSuspend(false);tick();assert(amoverlay::displayed==peak_bitmap);
  exists=false;tick();assert(!amoverlay::displayed);
  exists=true;tick();assert(amoverlay::displayed==peak_bitmap);
  AMCursorDetach();assert(!amoverlay::displayed && paints==paints_before_overlay);
  am_close_peak_sources();
#endif
  std::cout<<"PASS: cursor mapping, unchanged-frame budget, clock ownership, pause, hidden/stale sources, detach\n";
}
