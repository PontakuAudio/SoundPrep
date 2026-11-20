#pragma once
// Shared wording and layout keep both native renderers in step.
namespace amsettings {
enum Kind { toggle,number,link };
struct Control { const char* key;const char* label;const char* help;Kind kind;int page,y;double low,high;const char* url=nullptr; };
inline constexpr const char* pages[]={"Playback","Drops","Cache","Advanced","About"};
inline constexpr int page_count=sizeof(pages)/sizeof(pages[0]);
inline constexpr Control controls[]={
  {"autoplay","Follow file selection","Start preview when a new file is selected. Default: On.",toggle,0,12,0,0},
  {"loop","Loop preview","Repeat the current preview or selected range. Default: Off.",toggle,0,78,0,0},
  {"monitor_gain_db","Monitor level (dB)","Listening level only; excluded from rendered media. Default: -6 dB.",number,0,144,-60,0},
  {"preview_fade_ms","Preview edge fade (ms)","Fade the edges of preview playback. Default: 0 ms.",number,0,230,0,50},
  {"auto_render_drops","Automatically render uncached drops","May stop playback and pause editing while rendering. Cached drops keep playing. Default: On.",toggle,1,12,0,0},
  {"insert_handles","Retain processed audio outside the selected range","Off: render only the selected range. Source + FX keeps the entire original. Default: Off.",toggle,1,90,0,0},
  {"fade_ms","Rendered edge fade (ms)","Fade the edges of rendered drops. Default: 5 ms.",number,1,168,0,50},
  {"keep_fx_running","Keep inactive FX processing","Uses more CPU. Keeps inactive preset FX running. Default: Off.",toggle,3,12,0,0},
  {nullptr,"Support on Ko-fi","SoundPrep is free. If it saves you time, you can support its development on Ko-fi.",link,4,12,0,0,
    "https://ko-fi.com/kuma_pontakuaudio"}
};
inline constexpr int count=sizeof(controls)/sizeof(controls[0]);
}
