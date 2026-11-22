#pragma once
#include <algorithm>
#include <cstring>
namespace ameditor {
// Direct preset buttons wrap by their native text width, above the editor actions.
struct PresetLayout {
 struct Rect {int x,y,w,h;};
 int x=0,y=0;
 Rect add(int textWidth){
   int width=std::clamp(textWidth+32,72,216);
   if(x && x+width>660){x=0;y+=36;}
   Rect r{x,y,width,30};x+=width+6;return r;
 }
 int height()const{return y+38;}
};
enum Kind { toggle,number,text,choice };
struct Control { const char* key;const char* label;Kind kind;int page,y;double low,high;bool macroOnly;int x=14,w=610; };
inline constexpr const char* pages[]={"Sound","Normalize","Manage"};
inline constexpr int page_count=sizeof(pages)/sizeof(pages[0]);
// Previously saved page indices 3 and 4 both open Manage.
inline constexpr int current_page(int page){return std::min(page,page_count-1);}
inline constexpr int helpY[]={242,240,292};
inline constexpr int measurementY=292;
inline constexpr const char* meters[]={"LUFS MaxM","Zwicker Max","Zwicker P95"};
inline constexpr const char* metrics[]={"lufs_m_max","zwicker_max","zwicker_p95"};
inline constexpr Control controls[]={
 {"name","Preset name",text,2,12,0,0,true},
 {"reverse","Reverse",toggle,0,12,0,0,false,14,300},
 {"preserve","Preserve Pitch",toggle,0,12,0,0,false,330,300},
 {"pitch","Pitch (semitones)",number,0,58,-24,24,true},
 {"rate","Rate",number,0,104,.1,4,true},
 {"gain","Output gain (dB)",number,0,150,-60,12,true},
 {"tail","Export tail (seconds)",number,0,196,0,30,true},
 {"normalize","Normalize source",toggle,1,12,0,0,false},
 {"metric","Loudness meter",choice,1,50,0,0,false},
 {"lufs","Target (LUFS-M)",number,1,96,-60,0,false},
 {"sones","Target (sones)",number,1,142,.01,256,false}
};
inline constexpr int count=sizeof(controls)/sizeof(controls[0]);
struct Action {const char* op;const char* title;int page,x,y,w;bool macroOnly;};
inline constexpr Action actions[]={
 {"new","New preset",2,14,58,154,false},{"duplicate","Duplicate",2,184,58,154,true},
 {"up","Move up",2,14,104,154,true},{"down","Move down",2,184,104,154,true},
 {"import","Import FX chain…",2,14,150,154,true},{"delete","Delete preset…",2,184,150,154,true},
 {"confirm_delete","Confirm delete",2,14,252,154,true},{"cancel_delete","Keep preset",2,184,252,154,false},
 {"analyse","Analyse / refresh",1,14,188,168,false}
};
inline constexpr const char* help[]={
 "Changes audition live and stay when switching presets or closing this panel. Save preset stores the complete sound, including FX. Quit saves every preset. Export tail lets effects ring out after the source ends when rendering a drop with handles.\n\nRaw saves normalization. Its Reverse / Preserve Pitch switches are temporary.",
 "Zwicker Max suits short effects; P95 includes silence. Use an FX limiter if you need to cap output peaks. Use Analyse / refresh to update the source measurement.",
 "New, duplicate and order are saved immediately. Imported FX remain a draft until Save preset."
};
inline bool enabled(const Control& s,bool raw,bool zwicker){
 if(s.macroOnly && raw)return false;
 if(!strcmp(s.key,"lufs"))return !zwicker;
 if(!strcmp(s.key,"sones"))return zwicker;
 return true;
}
}
