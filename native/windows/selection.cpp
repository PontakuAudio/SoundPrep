// Immediate main-thread selection dispatch. The action reuses the Lua playback
// implementation in a short-lived VM; its native preview continues independently
// and the companion adopts the result on its next tick. No audio-thread Lua.
#include <windows.h>
#include <commctrl.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

extern "C" bool AMBarPending();
extern "C" const char* AMDropContext();
namespace {
void* (*lookup)(const char*)=nullptr;
int (*register_api)(const char*,void*)=nullptr;
bool (*valid)(void*,const char*)=nullptr;
void* (*current_project)(int,char*,int)=nullptr;
void (*run_action)(int,int,void*)=nullptr;
double (*clock_now)()=nullptr;
HWND window=nullptr,list=nullptr;
void *project=nullptr,*preview=nullptr;
int command=0;
unsigned wake=0;
std::uintptr_t generation=0;
bool enabled=false,queued=false,executing=false,pending=false;
std::string state;
unsigned long long notifications=0,dispatches=0;
double last_event=0,last_dispatch=0,last_return=0;
bool publish(const char* text,void* owner,void* handle) {
  if(!window || executing || pending || !text || std::strlen(text)>4*1024*1024 ||
     !owner || !valid || !valid(owner,"ReaProject*"))return false;
  state=text;project=owner;preview=handle;return true;
}
bool complete(const char* text,void* handle) {
  if(!executing || !text || std::strlen(text)>4*1024*1024)return false;
  state=text;preview=handle;pending=true;return true;
}
void unhook() {
  enabled=false;queued=false;++generation;window=list=nullptr;command=0;
  // Keep an unadopted result until the companion consumes it. Otherwise its
  // old preview handle would outlive a selection that already replaced it.
}
void detach() {
  unhook();
  // An action may have created a preview that Lua has not adopted yet.
  if(pending && preview && lookup) {
    auto set=reinterpret_cast<bool(*)(void*,const char*,double)>(lookup("AM_Preview_SetValue"));
    auto stop=reinterpret_cast<void(*)(void*)>(lookup("AM_Preview_Stop"));
    if(set)set(preview,"D_FADEOUTLEN",0);if(stop)stop(preview);
  }
  window=list=nullptr;project=preview=nullptr;command=0;state.clear();pending=false;
}
bool attach(void* parent,void* child,int action) {
  if(executing || !IsWindow(static_cast<HWND>(parent)) || !IsWindow(static_cast<HWND>(child)) ||
     !IsChild(static_cast<HWND>(parent),static_cast<HWND>(child)) || action<=0 || !lookup)return false;
  valid=reinterpret_cast<decltype(valid)>(lookup("ValidatePtr"));
  current_project=reinterpret_cast<decltype(current_project)>(lookup("EnumProjects"));
  run_action=reinterpret_cast<decltype(run_action)>(lookup("Main_OnCommandEx"));
  clock_now=reinterpret_cast<decltype(clock_now)>(lookup("time_precise"));
  if(!valid || !current_project || !run_action || !clock_now)return false;
  if(!wake)wake=RegisterWindowMessageW(L"SoundPrep.Selection.Wake.v1");
  if(!wake)return false;
  detach();window=static_cast<HWND>(parent);list=static_cast<HWND>(child);command=action;
  notifications=dispatches=0;last_event=last_dispatch=last_return=0;return true;
}
void enable(bool on){enabled=on && window && project && !state.empty();}
const char* read(){return state.c_str();}
void acknowledge(){if(!executing)pending=false;}
const char* diagnostics() {
  static char text[512];std::snprintf(text,sizeof(text),
    "{\"revision\":1,\"enabled\":%s,\"pending\":%s,\"notifications\":%llu,\"dispatches\":%llu,\"event\":%.9f,\"dispatch\":%.9f,\"returned\":%.9f}",
    enabled?"true":"false",pending?"true":"false",notifications,dispatches,last_event,last_dispatch,last_return);
  return text;
}
void api(const char* name,void* fn,void* vararg,const char* definition) {
  const std::string key=name;register_api(("API_"+key).c_str(),fn);
  register_api(("APIvararg_"+key).c_str(),vararg);register_api(("APIdef_"+key).c_str(),const_cast<char*>(definition));
}
void* boolean(bool v){return reinterpret_cast<void*>(static_cast<std::intptr_t>(v));}
}
extern "C" void AMSelectionDetach(){detach();}
extern "C" void AMSelectionUnhook(){unhook();}
extern "C" bool AMSelectionMessage(void* parent,unsigned message,std::uintptr_t wp,std::intptr_t lp,bool eligible) {
  if(parent!=window)return false;
  if(message==WM_DESTROY){unhook();return false;}
  if(message==wake) {
    if(wp!=generation)return true;
    queued=false;
    if(!eligible || !enabled || executing || !IsWindowVisible(window) || state.empty() || AMBarPending() ||
       *AMDropContext() || !valid(project,"ReaProject*") || current_project(-1,nullptr,0)!=project)return true;
    executing=true;++dispatches;last_dispatch=clock_now();
    run_action(command,0,project);
    last_return=clock_now();executing=false;
    return true;
  }
  if(message==WM_NOTIFY && lp && eligible && enabled && !executing) {
    const auto* change=reinterpret_cast<const NMLISTVIEW*>(lp);
    if(change->hdr.hwndFrom==list && change->hdr.code==LVN_ITEMCHANGED &&
       (change->uChanged&LVIF_STATE) && ((change->uNewState^change->uOldState)&(LVIS_SELECTED|LVIS_FOCUSED))) {
      ++notifications;last_event=clock_now();
      // Coalesce deselect/select/focus notifications; run after REAPER finishes
      // updating the list, without waiting for its periodic ReaScript timer.
      if(!queued)queued=PostMessageW(window,wake,generation,0)!=0;
    }
  }
  return false;
}
extern "C" void AMSelectionRegister(int(*reg)(const char*,void*),void*(*get)(const char*)) {
  register_api=reg;lookup=get;
#define AM_SEL_API(name,fn,wrapper,def) api(name,reinterpret_cast<void*>(fn),reinterpret_cast<void*>(+wrapper),def)
  AM_SEL_API("AM_SelectionAttach",attach,[](void** p,int n)->void*{return boolean(n==3 && attach(p[0],p[1],static_cast<int>(reinterpret_cast<std::intptr_t>(p[2]))));},"bool\0void*,void*,int\0window,list,command\0Attach the Windows selection observer.");
  AM_SEL_API("AM_SelectionPublish",publish,[](void** p,int n)->void*{return boolean(n==3 && publish(static_cast<const char*>(p[0]),p[1],p[2]));},"bool\0const char*,ReaProject*,void*\0state,project,previewOptional\0Publish an idle companion playback snapshot.");
  AM_SEL_API("AM_SelectionComplete",complete,[](void** p,int n)->void*{return boolean(n==2 && complete(static_cast<const char*>(p[0]),p[1]));},"bool\0const char*,void*\0state,previewOptional\0Return playback state from the synchronous selection action.");
  AM_SEL_API("AM_SelectionEnable",enable,[](void** p,int n)->void*{if(n==1)enable(p[0]!=nullptr);return nullptr;},"void\0bool\0enabled\0Arm selection dispatch only while the companion is idle.");
  AM_SEL_API("AM_SelectionRead",read,[](void**,int)->void*{return const_cast<char*>(read());},"const char*\0\0\0Read the current playback snapshot.");
  AM_SEL_API("AM_SelectionAcknowledge",acknowledge,[](void**,int)->void*{acknowledge();return nullptr;},"void\0\0\0Acknowledge that the companion adopted the pending preview.");
  AM_SEL_API("AM_SelectionDetach",detach,[](void**,int)->void*{detach();return nullptr;},"void\0\0\0Detach and dispose of any unclaimed preview.");
  AM_SEL_API("AM_SelectionDiagnostics",diagnostics,[](void**,int)->void*{return const_cast<char*>(diagnostics());},"const char*\0\0\0Read native selection event timing.");
#undef AM_SEL_API
  api("AM_SelectionProject",reinterpret_cast<void*>(+[]()->void*{return project;}),reinterpret_cast<void*>(+[](void**,int)->void*{return project;}),"ReaProject*\0\0\0Read the selection session project.");
  api("AM_SelectionPreview",reinterpret_cast<void*>(+[]()->void*{return preview;}),reinterpret_cast<void*>(+[](void**,int)->void*{return preview;}),"void*\0\0\0Read the current preview handle for adoption.");
  api("AM_SelectionWindow",reinterpret_cast<void*>(+[]()->void*{return window;}),reinterpret_cast<void*>(+[](void**,int)->void*{return window;}),"void*\0\0\0Read the attached Media Explorer window.");
  api("AM_SelectionPending",reinterpret_cast<void*>(+[]()->bool{return pending;}),reinterpret_cast<void*>(+[](void**,int)->void*{return boolean(pending);}),"bool\0\0\0Whether an action result needs adoption.");
  api("AM_SelectionDispatching",reinterpret_cast<void*>(+[]()->bool{return executing;}),reinterpret_cast<void*>(+[](void**,int)->void*{return boolean(executing);}),"bool\0\0\0True only inside the native-triggered selection action.");
}
