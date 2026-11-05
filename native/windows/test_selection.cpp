#include "selection.cpp"
#include <cassert>
#include <iostream>
static bool bar_pending=false,dragging=false,host_valid=true,eligible=true;
static int owner,other,actions=0,stops=0;
static void* foreground=&owner;
extern "C" bool AMBarPending(){return bar_pending;}
extern "C" const char* AMDropContext(){return dragging?"drag":"";}
static bool host_pointer(void* p,const char*){return host_valid && p==&owner;}
static void* host_project(int,char*,int){return foreground;}
static double host_clock(){return 1;}
static bool set_preview(void*,const char*,double){return true;}
static void stop_preview(void*){++stops;}
static void notify_selection() {
  NMLISTVIEW change{};change.hdr.hwndFrom=list;change.hdr.code=LVN_ITEMCHANGED;
  change.uChanged=LVIF_STATE;change.uNewState=LVIS_SELECTED;
  AMSelectionMessage(window,WM_NOTIFY,1001,reinterpret_cast<LPARAM>(&change),eligible);
}
static void host_action(int id,int,void* p) {
  assert(id==123 && p==&owner && executing);++actions;
  notify_selection(); // Commands generated while playing must not recurse.
  assert(complete("result",reinterpret_cast<void*>(42)));
}
static void* host_lookup(const char* name) {
  if(!std::strcmp(name,"ValidatePtr"))return reinterpret_cast<void*>(host_pointer);
  if(!std::strcmp(name,"EnumProjects"))return reinterpret_cast<void*>(host_project);
  if(!std::strcmp(name,"Main_OnCommandEx"))return reinterpret_cast<void*>(host_action);
  if(!std::strcmp(name,"time_precise"))return reinterpret_cast<void*>(host_clock);
  if(!std::strcmp(name,"AM_Preview_SetValue"))return reinterpret_cast<void*>(set_preview);
  if(!std::strcmp(name,"AM_Preview_Stop"))return reinterpret_cast<void*>(stop_preview);
  return nullptr;
}
static int host_register(const char*,void*){return 1;}
static void drain(HWND parent) {
  MSG message{};
  while(PeekMessageW(&message,parent,wake,wake,PM_REMOVE))AMSelectionMessage(parent,message.message,message.wParam,message.lParam,eligible);
}
int main() {
  HWND parent=CreateWindowExW(0,L"STATIC",L"selection test",WS_POPUP,0,0,100,100,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  HWND child=CreateWindowExW(0,L"STATIC",L"list",WS_CHILD,0,0,100,100,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
  assert(parent && child);AMSelectionRegister(host_register,host_lookup);
  ShowWindow(parent,SW_SHOWNOACTIVATE);
  assert(attach(parent,child,123));assert(publish("initial",&owner,nullptr));enable(true);
  for(int i=0;i<3;++i)notify_selection();assert(actions==0 && queued);drain(parent);
  assert(actions==1 && pending && !queued && preview==reinterpret_cast<void*>(42));
  assert(!publish("stale",&owner,nullptr));acknowledge();assert(!pending);
  assert(publish("adopted",&owner,preview));notify_selection();drain(parent);assert(actions==2);
  acknowledge();enable(false);notify_selection();drain(parent);assert(actions==2);
  enable(true);bar_pending=true;notify_selection();drain(parent);assert(actions==2);bar_pending=false;
  dragging=true;notify_selection();drain(parent);assert(actions==2);dragging=false;
  foreground=&other;notify_selection();drain(parent);assert(actions==2);foreground=&owner;
  host_valid=false;notify_selection();drain(parent);assert(actions==2);host_valid=true;
  notify_selection();eligible=false;drain(parent);assert(actions==2);eligible=true;
  notify_selection();assert(attach(parent,child,123));assert(publish("new session",&owner,nullptr));enable(true);
  drain(parent);assert(actions==2);notify_selection();drain(parent);assert(actions==3 && pending);
  AMSelectionUnhook();assert(pending && !window && preview==reinterpret_cast<void*>(42));
  detach();assert(stops==1 && !window && !pending && !enabled);detach();assert(stops==1);
  DestroyWindow(parent);
  std::cout<<"PASS: coalesced immediate selection, handoff, recursion, stale sessions, inactive project, stop/drag/control gates and unclaimed preview cleanup\n";
}
