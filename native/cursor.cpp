#include "path_equal.h"
#include "channel_subset.h"
#include "vendor/json.hpp"
// Overlay selected source peaks and the playhead without intercepting gestures.
// REAPER continues to own the ruler, zoom, range, scrollbar and drag source.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>
#include <list>
#include <memory>
#include <optional>
#include <vector>
#include <string>
#include <thread>
#ifdef __APPLE__
#include <fstream>
#include <sstream>
#include <string_view>
#endif
#include "peak_store.h"
#ifdef __APPLE__
#include "platform.h"
#endif

extern "C" int AMPreviewWavePosition(char*,int,double*,double*,double*);
#ifndef _WIN32
extern "C" int AMWavePixelScale(void*);
#endif
extern "C" bool AMDrawWaveLabel(void*,const char*,int,int,int,int,unsigned int,unsigned int,int,void*(*)(const char*));
namespace {
#ifdef __APPLE__
std::string renderer_cocoa="unknown";

std::string parse_cocoa_renderer(std::string_view ini) {
  auto trim=[](std::string_view text) {
    const auto first=text.find_first_not_of(" \t\r");
    return first==text.npos?std::string_view{}:text.substr(first,text.find_last_not_of(" \t\r")-first+1);
  };
  if(ini.substr(0,3)=="\xef\xbb\xbf")ini.remove_prefix(3);
  bool in_reaper=false;
  while(!ini.empty()) {
    const auto end=ini.find('\n');
    const auto line=trim(ini.substr(0,end));
    ini.remove_prefix(end==ini.npos?ini.size():end+1);
    if(!line.empty() && line.front()=='[')in_reaper=line=="[REAPER]";
    if(!in_reaper)continue;
    const auto equals=line.find('=');
    if(equals!=line.npos && trim(line.substr(0,equals))=="renderer_cocoa")
      return std::string(trim(line.substr(equals+1)));
  }
  return "unknown";
}

std::string read_cocoa_renderer(void*(*lookup)(const char*)) {
  auto resource_path=reinterpret_cast<const char*(*)()>(lookup("GetResourcePath"));
  const char* path=resource_path?resource_path():nullptr;
  if(!path || !*path)return "unknown";
  std::ifstream file(std::string(path)+"/reaper.ini");
  if(!file)return "unknown";
  std::ostringstream contents;
  contents<<file.rdbuf();
  return parse_cocoa_renderer(contents.str());
}
#endif

void*(*font_lookup)(const char*);
void *wave=nullptr,*clock_view=nullptr,*bitmap=nullptr;
int (*host_register)(const char*,void*);
bool (*window_valid)(void*),(*visible)(void*);
bool (*scroll_info)(void*,const char*,int*,int*,int*,int*,int*);
bool (*client_size)(void*,int*,int*),(*invalidate)(void*,int,int,int,int,bool);
std::intptr_t (*send_message)(void*,unsigned,std::uintptr_t,std::intptr_t);
bool viewport_dirty=true;
void (*get_title)(void*,char*,int);
bool (*set_title)(void*,const char*);
void* (*create_bitmap)(bool,int,int);
void (*destroy_bitmap)(void*),(*clear_bitmap)(void*,int);
int (*composite)(void*,int,int,int,int,void*,int,int,int,int,bool);
void (*unlink_bitmap)(void*,void*,bool);
bool (*file_info)(char*,int,int*,double*,double*,double*,double*,double*,double*,char*,int);
int (*toggle)(int,int);
int (*theme_color)(const char*,int);
void (*color_from_native)(int,int*,int*,int*);
struct WaveStyle {
  int background,peaks,text,cursor,selection,selection_mode;
  bool operator==(const WaveStyle& s)const {
    return background==s.background && peaks==s.peaks && text==s.text && cursor==s.cursor &&
      selection==s.selection && selection_mode==s.selection_mode;
  }
};
WaveStyle peak_style{};
int cursor_color=0;
int theme_pixel(const char* key,unsigned int fallback) {
  const int value=theme_color?theme_color(key,0):-1;
  if(value==-1 || !color_from_native)return static_cast<int>(fallback);
  int r=0,g=0,b=0;color_from_native(value,&r,&g,&b);
  return static_cast<int>(0xff000000u|((r&255)<<16)|((g&255)<<8)|(b&255));
}
WaveStyle wave_style() {
  // Media Explorer uses the unselected media-item colors for every channel.
  // Convert native colors through REAPER: Windows and macOS pack RGB differently.
  const int mode=theme_color?theme_color("col_explorer_seldm",0):-1;
  return {theme_pixel("col_mi_bg2",0xffcccccc),theme_pixel("col_tr1_peaks",0xff404040),
    theme_pixel("col_mi_label",0xff202020),theme_pixel("playcursor_color",0xff000000),
    theme_pixel("col_explorer_sel",0xffffffff),mode==-1?0x26600:mode};
}
bool linked=false,registered=false,suspended=false;
#ifdef __APPLE__
bool overlay_window=false;
#else
constexpr bool overlay_window=false;
#endif
#ifdef _WIN32
constexpr int ruler_height=16;
#else
constexpr int ruler_height=22;
#endif
int last_x=-999999;
char native_clock[256]{},written_clock[256]{},last_path[4096]{};
double last_fraction=-1,last_position=0,last_length=0;
double view_start=0,view_span=0;
int view_at=-1,view_page=-1,view_width=-1;
double view_units=-1;
int actual_width=0,scroll_at=0,scroll_page=0,scroll_min=0,scroll_max=0;
char view_path[4096]{};

std::shared_ptr<PCM_source> peak_source;
PCM_source* (*open_source)(const char*);
void (*close_source)(PCM_source*);
std::shared_ptr<PCM_source> open_peak_source(const char* path) {
  auto* source=open_source(path);
  if(!source)return {};
  return {source,close_source};
}
const char* (*get_ext_state)(const char*,const char*);
int (*get_peaks)(PCM_source*,double,double,int,int,int,double*);
void (*fill_rect)(void*,int,int,int,int,int,double,const char*);
void (*blit)(void*,int,int,void*,int,int,int,int,double,const char*);
void (*draw_char)(void*,int,int,char,int,double,const char*);
void* (*create_font)();
void* (*gdi_font)(int,int,int,bool,bool,bool,const char*);
void (*destroy_font)(void*),(*delete_gdi)(void*),(*set_font)(void*,void*,int);
unsigned int (*font_color)(void*,unsigned int),(*font_background)(void*,unsigned int);
int (*draw_text)(void*,void*,const char*,int,int,int,int,int);
void *label_font=nullptr,*label_gdi=nullptr;
int label_dpi=0,label_font_height=0,peak_label_dpi=0,peak_scale=0;
#ifdef _WIN32
unsigned int (*window_dpi)(void*)=+[](void* window){return GetDpiForWindow(static_cast<HWND>(window));};
#endif
void* peak_bitmap=nullptr;
void* cursor_underlay=nullptr;
unsigned long long peak_repaints=0,cursor_updates=0;
std::vector<std::string> peak_names;
std::string peak_names_json;
bool labels_dirty=true,label_native=false;
std::string peak_path,peak_stamp;
std::vector<double> peak_values;
std::vector<int> peak_channels;
int peak_left=0,peak_right=0,peak_width=0,peak_height=0,peak_count=0,peak_cursor=-999999;
double peak_start=-1,peak_span=-1,peak_a=-1,peak_b=-1;
bool peak_linked=false,peak_building=false,peak_dirty=true;

using PeakClock=std::chrono::steady_clock;
struct PeakBuildStats {
  double length_s=0;
  int channels=0;
  double sample_rate_hz=0;
  std::int64_t samples=0,started_unix_ms=0;
  PeakClock::time_point started{};
  std::uint64_t run_calls=0;
  PeakClock::duration run_time{},total_time{},decode_time{};
  const char* mode="none";
  std::string path{},stamp{};
};
PeakBuildStats current_peak_build,last_store_build,last_reaper_build;
const PeakBuildStats* last_peak_build=nullptr;
std::uint64_t peak_builds_completed=0;
PeakClock::duration total_peak_run_time{},slowest_peak_build{};

void record_peak_build(PeakBuildStats& last_for_backend) {
  last_for_backend=current_peak_build;
  last_peak_build=&last_for_backend;
  ++peak_builds_completed;
  slowest_peak_build=std::max(slowest_peak_build,current_peak_build.total_time);
}

void advance_peak_build(std::optional<std::chrono::milliseconds> budget) {
  if(!peak_building)return;
  const auto deadline=budget?std::optional{PeakClock::now()+*budget}:std::nullopt;
  // A timed build can yield only between synchronous REAPER build steps.
  do {
    const auto run_start=PeakClock::now();
    const int remaining=peak_source->PeaksBuild_Run();
    const auto run_time=PeakClock::now()-run_start;
    ++current_peak_build.run_calls;
    current_peak_build.run_time+=run_time;
    // Session Run time includes work on sources replaced before completion.
    total_peak_run_time+=run_time;
    if(!remaining) {
      peak_source->PeaksBuild_Finish();
      current_peak_build.total_time=PeakClock::now()-current_peak_build.started;
      record_peak_build(last_reaper_build);
      peak_building=false;
      peak_dirty=true;
      return;
    }
  } while(!deadline || PeakClock::now()<*deadline);
}
void start_peak_timer(const char* mode) {
  current_peak_build.mode=mode;
  const auto wall_start=std::chrono::system_clock::now().time_since_epoch();
  current_peak_build.started_unix_ms=std::chrono::duration_cast<std::chrono::milliseconds>(wall_start).count();
  current_peak_build.started=PeakClock::now();
}
void begin_peaksbuild() {
  start_peak_timer("peaksbuild-fallback");
  peak_building=peak_source->PeaksBuild_Begin()!=0;
  // Preserve the old 48 kHz attach budget (240 channel-seconds) at any rate.
  constexpr int synchronous_sample_limit=11'520'000;
  if(current_peak_build.samples>0 && current_peak_build.samples<=synchronous_sample_limit)advance_peak_build(std::nullopt);
  else advance_peak_build(std::chrono::milliseconds(250));
}

using ampeaks::PeakStore;
constexpr int inline_sample_limit=2'000'000,store_sample_limit=200'000'000;
constexpr size_t cache_byte_limit=64*1024*1024,cache_entry_limit=8;
std::list<std::shared_ptr<PeakStore>> peak_cache; // most recently selected first
std::shared_ptr<PeakStore> peak_store,worker_store;
std::shared_ptr<PCM_source> worker_source;
std::thread store_thread;
int painted_store_frames=-1;
bool fast_peaks_enabled=true;
std::uint64_t cache_hits=0,cache_misses=0;
const char* last_cache_lookup="none";

void finish_store_worker(bool wait) {
  if(!worker_store)return;
  const int ready=worker_store->ready_frames.load(std::memory_order_acquire);
  if(!wait && ready>=0 && ready<worker_store->frames)return;
  store_thread.join();
  worker_source.reset();
  worker_store.reset();
}

// At most one decoder is in flight. A new selection can paint immediately
// while a cancelled GetSamples finishes. The timer starts the latest request.
void service_store_worker() {
  finish_store_worker(false);
  if(worker_store || !peak_store || peak_store->ready_frames.load()!=0)return;
  try {
    // open_source and close_source are global REAPER APIs. Create and destroy
    // the private source here; only the worker uses its PCM_source methods.
    worker_source=open_peak_source(peak_store->path.c_str());
    if(worker_source) {
      store_thread=std::thread(ampeaks::build_store,std::ref(*peak_store),std::ref(*worker_source));
      worker_store=peak_store;
      return;
    }
  } catch(...) {}
  worker_source.reset();
  peak_store->ready_frames.store(-1);
}

void record_store_if_complete(int ready) {
  if(ready!=peak_store->frames || peak_store->recorded)return;
  peak_store->recorded=true;
  current_peak_build.decode_time=peak_store->decode_time;
  current_peak_build.samples=static_cast<std::int64_t>(ready)*peak_store->channels;
  current_peak_build.total_time=peak_store->finished-current_peak_build.started;
  record_peak_build(last_store_build);
}

int observe_store() {
  if(!peak_store)return 0;
  const int ready=peak_store->ready_frames.load(std::memory_order_acquire);
  if(ready>=0) {
    record_store_if_complete(ready);
    return ready;
  }
  peak_cache.pop_front();
  peak_store.reset();
  peak_dirty=true;
  begin_peaksbuild();
  return 0;
}

bool start_store() {
  const double frame_count=current_peak_build.length_s*current_peak_build.sample_rate_hz;
  if(current_peak_build.sample_rate_hz<1 || !(frame_count>0 && frame_count<=store_sample_limit+0.5))return false;
  const int frames=static_cast<int>(std::llround(frame_count));
  const auto samples=static_cast<std::int64_t>(frames)*current_peak_build.channels;
  if(!frames || samples>store_sample_limit)return false;
  const bool inline_build=samples<=inline_sample_limit;
  start_peak_timer(inline_build?"inline":"worker");
  try {
    auto store=std::make_shared<PeakStore>(peak_path,peak_stamp,peak_source,frames,
      current_peak_build.channels,current_peak_build.sample_rate_hz);
    size_t bytes=store->peaks.size()*sizeof(ampeaks::PeakPair);
    if(bytes>cache_byte_limit)return false;
    for(const auto& entry:peak_cache)bytes+=entry->peaks.size()*sizeof(ampeaks::PeakPair);
    while(peak_cache.size()>=cache_entry_limit || bytes>cache_byte_limit) {
      bytes-=peak_cache.back()->peaks.size()*sizeof(ampeaks::PeakPair);
      peak_cache.pop_back();
    }
    peak_cache.push_front(store);
    peak_store=store;
  } catch(...) {return false;}
  if(inline_build) {
    build_store(*peak_store,*peak_source);
  } else {
    service_store_worker();
  }
  observe_store();
  return true;
}

bool present(void* image,int x,int width,int height,int source_width,int source_height) {
#ifdef __APPLE__
  if(overlay_window)return amoverlay::present(image,x,width,source_width,source_height);
#endif
  return composite(wave,x,0,width,height,image,0,0,source_width,source_height,false)>0;
}
void invalidate_bitmap(int left,int right,int bottom,bool erase) {
#ifdef __APPLE__
  if(overlay_window){amoverlay::damage(left,right);return;}
#endif
  invalidate(wave,left,0,right,bottom,erase);
}
void unlink_image(void* image) {
#ifdef __APPLE__
  if(overlay_window){amoverlay::unlink(image);return;}
#endif
  if(wave && window_valid(wave))unlink_bitmap(wave,image,true);
}
void hide_peaks() {
  if(peak_linked)unlink_image(peak_bitmap);
  peak_linked=false;
}
void release_peak_source() {
  if(peak_store) {
    const int ready=peak_store->ready_frames.load(std::memory_order_acquire);
    if(ready==peak_store->frames)record_store_if_complete(ready);
    else peak_store->cancelled=true;
    // An unstamped selection is usable until release. Its identity cannot
    // be verified on a later attach.
    if(ready!=peak_store->frames || peak_store->stamp.empty())
      peak_cache.pop_front();
    peak_store.reset();
  }
  finish_store_worker(false);
  if(peak_source) {
    if(peak_building)peak_source->PeaksBuild_Finish();
    peak_source.reset();
  }
  peak_building=false;
  painted_store_frames=-1;
  peak_dirty=true;
}
void clear_peaks() {
  hide_peaks();
  release_peak_source();
  if(peak_bitmap){destroy_bitmap(peak_bitmap);peak_bitmap=nullptr;}
  if(cursor_underlay){destroy_bitmap(cursor_underlay);cursor_underlay=nullptr;}
  peak_path.clear();peak_stamp.clear();peak_values.clear();peak_channels.clear();peak_names.clear();peak_names_json.clear();labels_dirty=true;peak_left=peak_right=peak_count=0;
  peak_width=peak_height=0;peak_start=peak_span=-1;
}
void viewport(const char* path,int at,int page,int minimum,int maximum,int width,double& start,double& span) {
  const double units=static_cast<double>(maximum)-minimum;
  start=units>0?(static_cast<double>(at)-minimum)/units:0;
  span=units>0 && page>0?std::min(1.0,page/units):1;
  if(view_at>=0 && units==view_units && page!=view_page)view_span=0;
  if(view_span>0 && am_path_equal(path,view_path) && width>0 && units>0 && std::abs(page-view_span*units)<=2) {
    if(view_at>=0 && at!=view_at)view_start=start;
    start=view_start;span=view_span;
    view_at=at;view_page=page;view_width=width;view_units=units;
  } else if(view_at>=0 && (page!=view_page || units!=view_units))view_span=0;
}

bool paint_peaks(const char* path,int width,int height,double start,double span,double a,double b,int cursor,const WaveStyle& style) {
  if(!peak_source || !am_path_equal(path,peak_path.c_str()) || width<1 || width>16384 || height<24 || height>4096) {
    hide_peaks();return false;
  }
  // Reserve REAPER's time ruler at the bottom; all coordinates are client units.
  const int client_width=width,client_height=height-ruler_height;
#ifdef _WIN32
  const int scale_factor=1; // Win32 client coordinates are already device pixels.
#else
  const int scale_factor=AMWavePixelScale(wave);
#endif
  // Bitmap pixels and UI font sizing are independent on Windows: the client
  // is already in device pixels, but readable text must follow its monitor DPI.
#ifdef _WIN32
  const unsigned int reported_dpi=window_dpi(wave);
  const int text_dpi=static_cast<int>(reported_dpi?reported_dpi:96);
#else
  const int text_dpi=96*scale_factor;
#endif
  auto text_px=[text_dpi](int value){return static_cast<int>(std::lround(value*text_dpi/96.0));};
#ifdef _WIN32
  // Negative GDI height sizes the glyphs themselves, excluding internal leading.
  const int font_height=-text_px(13),label_height=text_px(22),minimum_lane=text_px(26),text_top=text_px(2);
#else
  const int font_height=text_px(11),label_height=text_px(14),minimum_lane=text_px(24),text_top=text_px(3);
#endif
  width*=scale_factor;
  const int h=client_height*scale_factor;
  if(cursor>=0 && cursor<client_width)cursor*=scale_factor;else cursor=-999999;
  const int ready=observe_store();
  const int channels=peak_store?peak_store->channels:peak_source->GetNumChannels();
  if(!peak_store)advance_peak_build(std::chrono::milliseconds(24));
  const bool reload=peak_dirty || (peak_store && ready!=painted_store_frames) ||
    scale_factor!=peak_scale || width!=peak_width || start!=peak_start || span!=peak_span;
  const bool repaint=reload || labels_dirty || text_dpi!=peak_label_dpi || !(style==peak_style) || h!=peak_height || a!=peak_a || b!=peak_b || !peak_linked;
  if(!repaint && cursor==peak_cursor)return true;
  // Keep just the pixels covered by the cursor. Moving it must not redraw
  // every peak and microphone label, or invalidate the whole waveform.
  const int cursor_width=2*scale_factor;
  auto cursor_visible=[width](int x){return x>=0 && x<width;};
  auto save_cursor=[&] {
    if(cursor_underlay && cursor_visible(cursor))
      blit(cursor_underlay,0,0,peak_bitmap,cursor,0,std::min(cursor_width,width-cursor),h,1,"COPY");
    if(cursor_visible(cursor))fill_rect(peak_bitmap,cursor,0,cursor_width,h,style.cursor,1,"COPY");
  };
  if(!repaint && cursor_underlay && blit) {
    const int old=peak_cursor;
    if(cursor_visible(old))blit(peak_bitmap,old,0,cursor_underlay,0,0,std::min(cursor_width,width-old),h,1,"COPY");
    save_cursor();peak_cursor=cursor;++cursor_updates;
    for(int x:{old,cursor})if(cursor_visible(x))
      invalidate_bitmap(x/scale_factor,std::min(client_width,x/scale_factor+2),client_height,false);
    return true;
  }
  if(!peak_bitmap || width!=peak_width || h!=peak_height || scale_factor!=peak_scale) {
    hide_peaks();if(peak_bitmap)destroy_bitmap(peak_bitmap);
    if(cursor_underlay){destroy_bitmap(cursor_underlay);cursor_underlay=nullptr;}
    peak_bitmap=create_bitmap(true,width,h);if(!peak_bitmap)return false;
    if(blit)cursor_underlay=create_bitmap(false,cursor_width,h);
  }
  if(reload) {
    peak_values.assign(static_cast<size_t>(width)*channels*2,0);
    if(peak_store) {
      peak_count=read_store_columns(*peak_store,ready,width,start,span,peak_values);
      painted_store_frames=ready;
    } else {
      const double length=peak_source->GetLength();
      peak_count=get_peaks(peak_source.get(),width/(length*span),start*length,channels,width,0,peak_values.data())&0xfffff;
      peak_count=std::clamp(peak_count,0,width);
    }
  }
  clear_bitmap(peak_bitmap,style.background);
  const int sa=static_cast<int>(std::clamp((a-start)/span*width,0.0,static_cast<double>(width)));
  const int sb=static_cast<int>(std::clamp((b-start)/span*width,0.0,static_cast<double>(width)));
  const int lanes=static_cast<int>(peak_channels.size());
  for(int lane=0;lane<lanes;++lane) {
    const int channel=peak_channels[lane]-1,top=lane*h/lanes,bottom=(lane+1)*h/lanes;
    const int mid=(top+bottom)/2;const double scale=std::max(0,(bottom-top)/2-2*scale_factor);
    const int color=style.peaks;
    for(int x=0;x<peak_count;++x) {
      const auto index=static_cast<size_t>(x)*channels+channel;
      const double hi=peak_values[index],lo=peak_values[static_cast<size_t>(width)*channels+index];
      if(!std::isfinite(hi) || !std::isfinite(lo))continue;
      const int y1=static_cast<int>(std::lround(mid-std::clamp(hi,-1.0,1.0)*scale));
      const int y2=static_cast<int>(std::lround(mid-std::clamp(lo,-1.0,1.0)*scale));
      if(bottom>top)fill_rect(peak_bitmap,x,std::clamp(std::min(y1,y2),top,bottom-1),1,std::min(bottom-top,std::abs(y2-y1)+1),color,1,"COPY");
    }
    if(bottom-top<minimum_lane)continue;
    const std::string role=lanes==1?"Mono":lanes>2?"Input":lane?"R":"L";
    const std::string number="ch "+std::to_string(channel+1);
    std::string label=role+" "+number;
    if(channel<static_cast<int>(peak_names.size()) && !peak_names[channel].empty())label=role+" "+number+"  "+peak_names[channel];
    if(peak_building || (peak_store && ready<peak_store->frames))label+=" ...";
#ifdef _WIN32
    label_native=AMDrawWaveLabel(peak_bitmap,label.c_str(),text_px(8),top+text_px(2),width-text_px(16),label_height,style.text,style.background,text_dpi,font_lookup);
    if(label_native){label_font_height=font_height;continue;}
#else
    label_native=AMDrawWaveLabel(peak_bitmap,label.c_str(),8*scale_factor,top+2*scale_factor,width-16*scale_factor,14*scale_factor,style.text,style.background,scale_factor,font_lookup);
    if(label_native){label_font_height=font_height;continue;}
#endif
    if(label_font && label_dpi!=text_dpi) {
      destroy_font(label_font);delete_gdi(label_gdi);label_font=label_gdi=nullptr;
    }
    if(!label_font && create_font && gdi_font && set_font && destroy_font && delete_gdi && draw_text && font_color && font_background) {
      #ifdef _WIN32
      const char* face="Yu Gothic UI";
#else
      const char* face="Hiragino Sans";
#endif
      label_font=create_font();label_gdi=gdi_font(font_height,400,0,false,false,false,face);label_dpi=text_dpi;label_font_height=font_height;
      // The JS wrapper forces PRECALCALL (ASCII-only). The public REAPER
      // setter keeps the live HFONT and permits Unicode glyph caching.
      if(label_font && label_gdi)set_font(label_font,label_gdi,0);
      else {if(label_font)destroy_font(label_font);if(label_gdi)delete_gdi(label_gdi);label_font=label_gdi=nullptr;}
    }
    if(label_font) {
      int units=0;for(unsigned char c:label)if(c<128)++units;else if((c&0xc0)!=0x80)units+=2;
      fill_rect(peak_bitmap,text_px(4),top+text_px(2),std::max(0,std::min(width-text_px(8),text_px(units*8+12))),label_height,style.background,1,"COPY");
      font_color(label_font,style.text);font_background(label_font,style.background);
      draw_text(peak_bitmap,label_font,label.c_str(),static_cast<int>(label.size()),text_px(8),top+text_top,std::max(text_px(8),width-text_px(8)),top+text_px(2)+label_height);
    } else {
      const auto fallback=role+" "+number+(peak_store && ready<peak_store->frames?" ...":"");
      fill_rect(peak_bitmap,4,top+3,std::min(width-4,static_cast<int>(fallback.size())*8+8),12,style.background,1,"COPY");
      for(size_t i=0;i<fallback.size() && 8+static_cast<int>(i)*8<width-8;++i)draw_char(peak_bitmap,8+static_cast<int>(i)*8,top+5,fallback[i],style.text,1,"COPY");
    }
  }
  // Like the native preview, tint both the peaks and background with the
  // theme's selection blend mode and opacity, rather than replacing the bed.
  if(b>a && sb>sa) {
    const char* modes[]={"COPY","ADD","DODGE","MUL","OVERLAY","HSVADJ"};
    const int mode=style.selection_mode&255;
    const double alpha=((style.selection_mode>>8)&255)/256.0;
    fill_rect(peak_bitmap,sa,0,sb-sa,h,style.selection,alpha,modes[mode<6?mode:0]);
  }
  save_cursor();++peak_repaints;
  peak_linked=present(peak_bitmap,0,client_width,client_height,width,h);
  if(peak_linked)invalidate_bitmap(0,client_width,height,true);
  peak_width=width;peak_height=h;peak_scale=scale_factor;peak_label_dpi=text_dpi;peak_start=start;peak_span=span;peak_a=a;peak_b=b;peak_cursor=cursor;peak_style=style;peak_dirty=false;labels_dirty=false;
  return peak_linked;
}

void restore_clock() {
  if(clock_view && window_valid(clock_view) && *written_clock) {
    char text[256]{};get_title(clock_view,text,sizeof(text));
    if(!std::strcmp(text,written_clock))set_title(clock_view,native_clock);
  }
  *written_clock=0;
}
void unpaint() {
  if(linked)unlink_image(bitmap);
  linked=false;last_x=-999999;
}
// Scrollbar coordinates need not equal client pixels (e.g. Windows/DPI).
int rounded_pixel(double value) {
  if(!std::isfinite(value) || value<std::numeric_limits<int>::min() || value>std::numeric_limits<int>::max())return -999999;
  return static_cast<int>(std::lround(value));
}
int pixel(double fraction,int position,int page,int minimum,int maximum,int width) {
  if(page<=0 || maximum<=minimum || width<=0 || !std::isfinite(fraction))return -999999;
  return rounded_pixel((fraction*(static_cast<double>(maximum)-minimum)-(static_cast<double>(position)-minimum))*width/page);
}
void format(char* out,int size,double t,bool rounded) {
  const long long ms=std::llround(std::max(0.0,t)*1000);
  const auto seconds=ms/1000;
  if(rounded)std::snprintf(out,size,"%lld:%02lld",seconds/60,seconds%60);
  else std::snprintf(out,size,"%lld:%02lld.%03lld",seconds/60,seconds%60,ms%1000);
}
void tick() {
  service_store_worker();
  observe_store();
  // REAPER owns transient range feedback inside its native mouse loop. Do not
  // cover it with the old playhead or an opaque selected-channel composite,
  // even when its last-played API still reports the pre-drag range.
  if(suspended)return;
  if(!wave || !window_valid(wave) || !window_valid(clock_view) || !visible(wave)) {
    unpaint();hide_peaks();restore_clock();return;
  }
  char path[4096]{},extra[128]{};int mode=0;double a=0,b=1,pitch=0,gain=0,rate=1,bpm=0;
  if(!file_info(path,sizeof(path),&mode,&a,&b,&pitch,&gain,&rate,&bpm,extra,sizeof(extra))) {
    unpaint();restore_clock();*last_path=0;
    // Native preview may be cleared while the owned channel controls have
    // focus. Lua still supplies the current selected file and clears it on
    // deselection, so keep its selected lanes visible while stopped.
    if(!peak_source){hide_peaks();return;}
    std::snprintf(path,sizeof(path),"%s",peak_path.c_str());
    mode=0;
  }
  char playing_path[4096]{};double fraction=0,position=0,length=0;
  const int playing=AMPreviewWavePosition(playing_path,sizeof(playing_path),&fraction,&position,&length);
  // Audio owns the lock: retain the last cursor snapshot, but let a newly
  // selected waveform and its incremental peak build progress independently.
  const auto style=wave_style();
  if(cursor_color!=style.cursor){unpaint();clear_bitmap(bitmap,style.cursor);cursor_color=style.cursor;}
  if(playing>0 && am_path_equal(path,playing_path)) {
    std::snprintf(last_path,sizeof(last_path),"%s",path);
    last_fraction=fraction;last_position=position;last_length=length;
  } else if(!am_path_equal(path,last_path)) {
    unpaint();restore_clock();*last_path=0;
  }
  int at=0,page=0,minimum=0,maximum=0,track=0;
  int width=0,height=0;
  // SWELL can leave CoolSB's position/page stale after native zoom actions.
  // Reapply the unchanged client size after input so REAPER refreshes its own
  // scrollbar state before we map peaks to the native ruler.
#ifndef _WIN32
  if(viewport_dirty && send_message && client_size(wave,&width,&height) &&
      width>0 && width<=65535 && height>0 && height<=65535) {
    viewport_dirty=false;
    send_message(wave,0x5,0,(static_cast<std::uintptr_t>(height)<<16)|static_cast<unsigned>(width));
  }
#endif
  bool drawable=scroll_info(wave,"h",&at,&page,&minimum,&maximum,&track) && client_size(wave,&width,&height);
#ifdef __APPLE__
  if(drawable)drawable=amoverlay::track(wave,width,height-ruler_height);
#endif
  if(drawable) {
    actual_width=width;scroll_at=at;scroll_page=page;scroll_min=minimum;scroll_max=maximum;
    // Mic Select can restart the preview while file_info still names another file.
    const char* paint_path=peak_source?peak_path.c_str():path;
    double start=0,span=1;viewport(paint_path,at,page,minimum,maximum,width,start,span);
    const int x=!*last_path || suspended?-999999 : view_span>0 && am_path_equal(path,view_path)?
      rounded_pixel((last_fraction-start)/span*width):pixel(last_fraction,at,page,minimum,maximum,width);
    const bool has_range=(mode&384) && am_path_equal(path,peak_path.c_str());
    const int peak_x=am_path_equal(last_path,peak_path.c_str())?x:-999999;
    const bool selected=paint_peaks(paint_path,width,height,start,span,has_range?a:0,has_range?b:0,peak_x,style);
    if(!*last_path || suspended){if(!suspended)unpaint();return;}
    if(selected){unpaint();last_x=x;}
    // Do not clamp an offscreen source position
    // to an edge (that would falsely indicate a different part of the sound).
    else if(x<0 || x>=width)unpaint();
    else if(!linked || x!=last_x) {
      // JS_Composite(autoUpdate) can report failure when an overlapping area
      // is already dirty on macOS. Register the bitmap and invalidate through
      // the dedicated API, whose already-dirty path has a defined result.
      const int old=linked?last_x:x;
      linked=present(bitmap,x,2,-1,1,1);
      int w=0,h=0;
      if(linked && client_size(wave,&w,&h))invalidate_bitmap(std::max(0,std::min(old,x)),std::min(w,std::max(old,x)+2),h,true);
      last_x=x;
    }
  } else {unpaint();hide_peaks();}
  if(!*last_path || suspended)return;
  char current[256]{},start[64]{},duration[64]{},next[256]{};
  get_title(clock_view,current,sizeof(current));
  if(std::strcmp(current,written_clock))std::snprintf(native_clock,sizeof(native_clock),"%s",current);
  const bool rounded=toggle(32063,40032)==1;
  format(start,sizeof(start),last_position,rounded);format(duration,sizeof(duration),last_length,false);
  std::snprintf(next,sizeof(next),"%s  /  %s",start,duration);
  if(std::strcmp(current,next))set_title(clock_view,next);
  std::snprintf(written_clock,sizeof(written_clock),"%s",next);
}
}
extern "C" void AMCursorRestoreClock(){restore_clock();}
extern "C" void AMCursorViewportChanged(){viewport_dirty=true;}
extern "C" void AMCursorZoom(int command) {
  AMCursorViewportChanged();
  view_span=0;view_at=-1;
  if((command!=42092 && command!=42093) || !file_info)return;
  int mode=0;double a=0,b=1,p=0,g=0,r=1,bpm=0;char extra[128]{};
  if(!file_info(view_path,sizeof(view_path),&mode,&a,&b,&p,&g,&r,&bpm,extra,sizeof(extra)))return;
  if(command==42093){view_start=0;view_span=1;}
  else if((mode&384) && b>a) {
    view_span=std::min(1.0,(b-a)*1.1);
    view_start=std::clamp(a-(b-a)*.05,0.0,1-view_span);
  }
}
extern "C" void AMCursorAnchor(const char* path,double fraction,int x) {
  if(view_span>0 && view_width>0 && am_path_equal(path,view_path))
    view_start=fraction-static_cast<double>(x)/view_width*view_span;
}
extern "C" void AMCursorRefresh(){
  // Snapshot on mouse-up so an immediate Pause keeps this exact bookmark.
  // Leave REAPER's freshly formatted native clock readable until the timer.
  char path[4096]{};double fraction=0,position=0,length=0;
  if(AMPreviewWavePosition(path,sizeof(path),&fraction,&position,&length)==1) {
    std::snprintf(last_path,sizeof(last_path),"%s",path);
    last_fraction=fraction;last_position=position;last_length=length;
  }
}
extern "C" void AMCursorSuspend(bool on){
  suspended=on;
  if(on){unpaint();hide_peaks();restore_clock();}
}
extern "C" void AMCursorClear(){unpaint();restore_clock();*last_path=0;last_fraction=-1;}
// REAPER can unload JS_ReaScriptAPI first. Source teardown also has to work
// when the window and bitmap callbacks are no longer callable.
void am_close_peak_sources() {
  if(registered){host_register("-timer",reinterpret_cast<void*>(tick));registered=false;}
  release_peak_source();
  finish_store_worker(true);
  peak_cache.clear();
}
extern "C" void AMCursorDetach() {
  if(label_font){destroy_font(label_font);label_font=nullptr;}
  if(label_gdi){delete_gdi(label_gdi);label_gdi=nullptr;}
  if(registered){host_register("-timer",reinterpret_cast<void*>(tick));registered=false;}
  clear_peaks();AMCursorClear();wave=clock_view=nullptr;suspended=false;label_native=false;label_font_height=0;
  finish_store_worker(true);
#ifdef __APPLE__
  if(overlay_window){amoverlay::destroy();overlay_window=false;}
#endif
  view_span=0;view_at=view_page=view_width=view_units=-1;*view_path=0;
  actual_width=scroll_at=scroll_page=scroll_min=scroll_max=0;
  peak_repaints=cursor_updates=0;
  viewport_dirty=true;
  if(bitmap){destroy_bitmap(bitmap);bitmap=nullptr;}
}
extern "C" void AMCursorRegister(int(*reg)(const char*,void*)){host_register=reg;}
extern "C" bool AMCursorAttach(void* w,void* c,void*(*lookup)(const char*)) {
  AMCursorDetach();
#ifdef __APPLE__
  renderer_cocoa=read_cocoa_renderer(lookup);
#endif
  font_lookup=lookup;
#define GET(variable,name) variable=reinterpret_cast<decltype(variable)>(lookup(name))
  GET(window_valid,"JS_Window_IsWindow");GET(visible,"JS_Window_IsVisible");
  GET(scroll_info,"JS_Window_GetScrollInfo");GET(get_title,"JS_Window_GetTitle");GET(set_title,"JS_Window_SetTitle");
  GET(client_size,"JS_Window_GetClientSize");GET(invalidate,"JS_Window_InvalidateRect");
  GET(send_message,"BR_Win32_SendMessage");
  GET(create_bitmap,"JS_LICE_CreateBitmap");GET(destroy_bitmap,"JS_LICE_DestroyBitmap");GET(clear_bitmap,"JS_LICE_Clear");
  GET(composite,"JS_Composite");GET(unlink_bitmap,"JS_Composite_Unlink");
  GET(open_source,"PCM_Source_CreateFromFile");GET(close_source,"PCM_Source_Destroy");GET(get_peaks,"PCM_Source_GetPeaks");
  GET(get_ext_state,"GetExtState");
  GET(fill_rect,"JS_LICE_FillRect");GET(draw_char,"JS_LICE_DrawChar");
  GET(blit,"JS_LICE_Blit");
  GET(create_font,"JS_LICE_CreateFont");GET(destroy_font,"JS_LICE_DestroyFont");GET(set_font,"LICE__SetFromHFont");
  GET(gdi_font,"JS_GDI_CreateFont");GET(delete_gdi,"JS_GDI_DeleteObject");GET(draw_text,"JS_LICE_DrawText");
  GET(font_color,"LICE__SetTextColor");GET(font_background,"LICE__SetBkColor");
  GET(file_info,"MediaExplorerGetLastPlayedFileInfo");GET(toggle,"GetToggleCommandStateEx");
  GET(theme_color,"GetThemeColor");GET(color_from_native,"ColorFromNative");
#undef GET
  if(!host_register || !window_valid || !visible || !scroll_info || !client_size || !invalidate || !get_title || !set_title ||
      !create_bitmap || !destroy_bitmap || !clear_bitmap || !composite || !unlink_bitmap || !file_info || !toggle)return false;
  if(!window_valid(w) || !window_valid(c))return false;
  bitmap=create_bitmap(true,1,1);if(!bitmap)return false;
  cursor_color=wave_style().cursor;clear_bitmap(bitmap,cursor_color);
  wave=w;clock_view=c;
#ifdef __APPLE__
  overlay_window=amoverlay::create(w,bitmap,lookup);
#endif
  registered=host_register("timer",reinterpret_cast<void*>(tick))!=0;
  if(!registered){AMCursorDetach();return false;}return true;
}
extern "C" bool AMWaveSetChannelSubset(const char* path,const char* csv,const char* stamp) {
  if(!path || !*path){clear_peaks();return true;}
  std::vector<int> channels;
  if(!amchannels::parse(csv,channels) || !registered || !open_source || !close_source || !get_peaks || !fill_rect || !draw_char || !stamp)return false;
  const int highest=*std::max_element(channels.begin(),channels.end());
  const char* setting=get_ext_state?get_ext_state("SoundPrep","fast_peaks"):nullptr;
  const bool enabled=!setting || std::strcmp(setting,"0")!=0;
  std::shared_ptr<PCM_source> source;
  if(am_path_equal(path,peak_path.c_str()) && peak_stamp==stamp && peak_source) {
    if(highest>(peak_store?peak_store->channels:peak_source->GetNumChannels()))return false;
    if(enabled==fast_peaks_enabled) {
      if(channels!=peak_channels) {
        peak_channels=channels;peak_left=channels.front();peak_right=channels.back();
        // Even a deep-zoom sample read already contains every channel.
        if(peak_store)labels_dirty=true;
        else peak_dirty=true;
      }
      return true;
    }
    // Switch backends in place, keeping the selected file and its microphone labels.
    source=peak_source;
    release_peak_source();
  } else clear_peaks();
  fast_peaks_enabled=enabled;
  auto cached=peak_cache.end();
  if(enabled)cached=std::find_if(peak_cache.begin(),peak_cache.end(),[&](const auto& entry) {
    return entry->stamp==stamp && am_path_equal(path,entry->path.c_str());
  });
  if(cached!=peak_cache.end())source=(*cached)->paint_source;
  else if(!source)source=open_peak_source(path);
  if(!source)return false;
  const int source_channels=cached!=peak_cache.end()?(*cached)->channels:source->GetNumChannels();
  const double length=source->GetLength();
  if(source_channels>128 || highest>source_channels ||
      !std::isfinite(length) || length<=0)return false;
  peak_source=source;peak_path=path;peak_stamp=stamp;peak_channels=channels;peak_left=channels.front();peak_right=channels.back();
  current_peak_build={length,source_channels,source->GetSampleRate()};
  current_peak_build.path=path;
  current_peak_build.stamp=stamp;
  const double samples=std::round(length*current_peak_build.sample_rate_hz)*source_channels;
  if(samples>0 && samples<static_cast<double>(std::numeric_limits<std::int64_t>::max()))
    current_peak_build.samples=std::llround(samples);
  if(cached!=peak_cache.end()) {
    ++cache_hits;
    last_cache_lookup="hit";
    peak_store=*cached;
    peak_cache.splice(peak_cache.begin(),peak_cache,cached);
    current_peak_build.mode="cache";
  } else {
    last_cache_lookup=enabled?"miss":"bypass";
    if(enabled)++cache_misses;
    if(!enabled || !start_store())begin_peaksbuild();
  }
  return true;
}
extern "C" bool AMWaveSetChannelNames(const char* path,const char* stamp,const char* text) {
  if(!path || !stamp || !text || std::strlen(text)>131072)return false;
  if(!*path){if(!peak_names.empty()){peak_names.clear();peak_names_json.clear();labels_dirty=true;}return true;}
  if(!peak_source || !am_path_equal(path,peak_path.c_str()) || peak_stamp!=stamp)return false;
  if(peak_names_json==text)return true;
  try {
    const auto value=nlohmann::json::parse(text);
    if(!value.is_array() || value.size()!=static_cast<size_t>(peak_source->GetNumChannels()))return false;
    std::vector<std::string> names;
    for(const auto& name:value){if(!name.is_string())return false;const auto str=name.get<std::string>();
      if(str.size()>4096 || str.find_first_of("\r\n")!=std::string::npos || str.find('\0')!=std::string::npos)return false;
      names.push_back(str);
    }
    if(names!=peak_names){peak_names=std::move(names);labels_dirty=true;}
    peak_names_json=text;
    return true;
  }catch(...){return false;}
}
extern "C" bool AMWaveSetChannels(const char* path,int left,int right,const char* stamp) {
  if(left==0 && right==0)return AMWaveSetChannelSubset("","","");
  char csv[32];
  if(left==right)std::snprintf(csv,sizeof(csv),"%d",left);
  else std::snprintf(csv,sizeof(csv),"%d,%d",left,right);
  return AMWaveSetChannelSubset(path,csv,stamp);
}
std::string am_peak_build_diagnostics() {
  if(peak_store)record_store_if_complete(peak_store->ready_frames.load(std::memory_order_acquire));
  using Milliseconds=std::chrono::duration<double,std::milli>;
  auto describe=[](const PeakBuildStats& build)->nlohmann::json {
    if(!build.started_unix_ms)return nullptr;
    const double seconds=std::chrono::duration<double>(build.total_time).count();
    return {{"length_s",build.length_s},{"channels",build.channels},{"sample_rate_hz",build.sample_rate_hz},
      {"path",build.path},{"stamp",build.stamp},
      {"samples",build.samples},{"started_unix_ms",build.started_unix_ms},{"run_calls",build.run_calls},
      {"run_ms",Milliseconds(build.run_time).count()},{"total_ms",Milliseconds(build.total_time).count()},
      {"samples_per_second",seconds>0?build.samples/seconds:0},{"mode",build.mode}};
  };
  const double self_seconds=std::chrono::duration<double>(last_store_build.decode_time).count();
  return nlohmann::json{{"last",last_peak_build?describe(*last_peak_build):nlohmann::json(nullptr)},
    {"last_store",describe(last_store_build)},{"last_peaksbuild",describe(last_reaper_build)},
    {"builds_completed",peak_builds_completed},{"mode",current_peak_build.mode},
    {"cache_hits",cache_hits},{"cache_misses",cache_misses},{"last_cache_lookup",last_cache_lookup},
    {"self_build_ms",Milliseconds(last_store_build.decode_time).count()},
    {"self_samples_per_second",self_seconds>0?last_store_build.samples/self_seconds:0},
    {"total_run_ms",Milliseconds(total_peak_run_time).count()},
    {"slowest_build_ms",Milliseconds(slowest_peak_build).count()}}.dump(-1,' ',false,nlohmann::json::error_handler_t::replace);
}
extern "C" const char* AMCursorState() {
  static char result[1024];
  std::snprintf(result,sizeof(result),"{\"attached\":%s,\"visible\":%s,\"x\":%d,\"fraction\":%.12f,\"position\":%.9f,\"length\":%.9f,\"client_width\":%d,\"scroll_at\":%d,\"scroll_page\":%d,\"scroll_min\":%d,\"scroll_max\":%d,\"selected_visible\":%s,\"selected_lanes\":%d,\"selected_left\":%d,\"selected_right\":%d,\"peak_count\":%d,\"view_start\":%.12f,\"view_span\":%.12f}",
    registered?"true":"false",(linked || (peak_linked && peak_cursor>=0 && peak_cursor<peak_width))?"true":"false",last_x,last_fraction,last_position,last_length,actual_width,scroll_at,scroll_page,scroll_min,scroll_max,peak_linked?"true":"false",static_cast<int>(peak_channels.size()),peak_left,peak_right,peak_count,peak_start,peak_span);
  static std::string json;
  auto value=nlohmann::json::parse(result);value["selected_names"]=nlohmann::json::array();
  value["presentation"]=overlay_window?"overlay":"composite";
#ifdef __APPLE__
  value["renderer_cocoa"]=renderer_cocoa;
  value["overlay_hidden_by_gpu"]=renderer_cocoa=="metal" && !overlay_window;
#else
  value["renderer_cocoa"]="n/a";
  value["overlay_hidden_by_gpu"]=false;
#endif
  value["peak_repaints"]=peak_repaints;value["cursor_updates"]=cursor_updates;
  for(int channel:peak_channels)value["selected_names"].push_back(channel<=static_cast<int>(peak_names.size())?peak_names[channel-1]:"");
  value["name_font"]=label_native || label_font!=nullptr;
#ifdef _WIN32
  value["name_renderer"]=label_native?"DirectWrite":"LICE";
#else
  value["name_renderer"]=label_native?"Cocoa":"LICE";
#endif
  value["name_font_pixels"]=std::abs(label_font_height);value["name_dpi"]=peak_label_dpi;
  json=value.dump(-1,' ',false,nlohmann::json::error_handler_t::replace);return json.c_str();
}
