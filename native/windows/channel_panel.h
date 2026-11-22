// Owned native popup, anchored to Media Explorer. No global keyboard hooks.
struct ChannelPanel {
  HWND window=nullptr,anchor=nullptr,file=nullptr,summary=nullptr,page=nullptr,notice=nullptr,tips=nullptr;
  HFONT font=nullptr;bool paused=false,closing=false,paged=false;
  Json state=Json::object();std::array<HWND,8> microphones{};std::array<std::wstring,8> labels{};
  std::array<int,8> indices{};std::array<HWND,6> actions{};
  static constexpr const char* commands[]={"previous","next","all","swap","play","close"};
  ~ChannelPanel(){close(false);}
  HWND child(const wchar_t* cls,const wchar_t* text,DWORD style,int id,int x,int y,int w,int h){
    HWND c=CreateWindowExW(0,cls,text,WS_CHILD|WS_VISIBLE|style,amwin::scale(anchor,x),amwin::scale(anchor,y),amwin::scale(anchor,w),amwin::scale(anchor,h),window,reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),amwin::module(),nullptr);
    SendMessageW(c,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);SetWindowSubclass(c,keyProc,1,reinterpret_cast<DWORD_PTR>(this));return c;
  }
  void position(){
    if(!window || !IsWindow(anchor))return;
    RECT a{};GetWindowRect(anchor,&a);int width=amwin::scale(anchor,536),height=amwin::scale(anchor,paged?302:268);
    MONITORINFO monitor{sizeof(monitor)};GetMonitorInfoW(MonitorFromWindow(anchor,MONITOR_DEFAULTTONEAREST),&monitor);
    int x=std::max(monitor.rcWork.left,std::min(a.left,monitor.rcWork.right-width));
    int y=a.bottom+height<=monitor.rcWork.bottom?a.bottom:std::max(monitor.rcWork.top,a.top-height);
    SetWindowPos(window,nullptr,x,y,width,height,SWP_NOZORDER|SWP_NOACTIVATE);
  }
  void create(HWND a,HFONT f){
    anchor=a;font=f;WNDCLASSW wc{};wc.lpfnWndProc=proc;wc.hInstance=amwin::module();wc.lpszClassName=L"SoundPrepMicrophones";wc.hbrBackground=GetSysColorBrush(COLOR_BTNFACE);wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);RegisterClassW(&wc);
    window=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_CONTROLPARENT,wc.lpszClassName,L"Select microphones",WS_POPUP|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN,0,0,1,1,GetAncestor(anchor,GA_ROOT),nullptr,wc.hInstance,this);
    if(!window)throw std::runtime_error("Cannot create microphone controls");position();
    file=child(L"STATIC",L"",SS_ENDELLIPSIS|SS_NOPREFIX,0,12,10,496,18);
    summary=child(L"STATIC",L"",SS_ENDELLIPSIS|SS_NOPREFIX,0,12,32,496,18);
    tips=CreateWindowExW(WS_EX_TOPMOST,TOOLTIPS_CLASSW,nullptr,WS_POPUP|TTS_ALWAYSTIP|TTS_NOPREFIX,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,window,nullptr,wc.hInstance,nullptr);
    SendMessageW(tips,TTM_SETMAXTIPWIDTH,0,500);
    for(int i=0;i<8;++i){
      microphones[i]=child(L"BUTTON",L"",WS_TABSTOP|BS_AUTOCHECKBOX|BS_PUSHLIKE|BS_MULTILINE,2100+i,12+(i%4)*125,58+(i/4)*46,121,40);
      TOOLINFOW tip{sizeof(tip)};tip.uFlags=TTF_IDISHWND|TTF_SUBCLASS;tip.hwnd=window;tip.uId=reinterpret_cast<UINT_PTR>(microphones[i]);tip.lpszText=const_cast<wchar_t*>(L"");SendMessageW(tips,TTM_ADDTOOLW,0,reinterpret_cast<LPARAM>(&tip));
    }
    const wchar_t* titles[]={L"< Previous 8",L"Next 8 >",L"All channels",L"Swap L / R",L"Play",L"Done"};
    const int shift=paged?0:34;
    const int rects[][4]={{12,156,112,26},{396,156,112,26},{12,190-shift,121,26},{137,190-shift,121,26},{262,190-shift,121,26},{387,190-shift,121,26}};
    for(int i=0;i<6;++i)actions[i]=child(L"BUTTON",titles[i],WS_TABSTOP|(i==2?BS_AUTOCHECKBOX|BS_PUSHLIKE:BS_PUSHBUTTON),2200+i,rects[i][0],rects[i][1],rects[i][2],rects[i][3]);
    page=child(L"STATIC",L"",SS_CENTER,0,132,161,252,18);notice=child(L"STATIC",L"",SS_ENDELLIPSIS|SS_NOPREFIX,0,12,230-shift,496,20);
    if(!paged){ShowWindow(actions[0],SW_HIDE);ShowWindow(actions[1],SW_HIDE);ShowWindow(page,SW_HIDE);}
  }
  std::wstring fit(std::wstring text,int width){
    HDC dc=GetDC(window);auto old=SelectObject(dc,font);SIZE size{};
    GetTextExtentPoint32W(dc,text.c_str(),static_cast<int>(text.size()),&size);
    if(size.cx>width){
      do{if(!text.empty()){text.pop_back();if(!text.empty() && text.back()>=0xd800 && text.back()<=0xdbff)text.pop_back();}
        auto candidate=text+L"…";GetTextExtentPoint32W(dc,candidate.c_str(),static_cast<int>(candidate.size()),&size);
      }while(!text.empty() && size.cx>width);text+=L"…";
    }
    SelectObject(dc,old);ReleaseDC(window,dc);return text;
  }
  void update(const Json& next,bool disabled,HWND a,HFONT f){
    state=next;paused=disabled;
    if(!next.value("open",false) || paused || !IsWindowVisible(a)){close(false);return;}
    const bool previous=next.at("previous").get<bool>(),hasNext=next.at("next").get<bool>();
    const bool newPaged=next.value("paged",previous || hasNext);
    if(newPaged!=paged){close(false);paged=newPaged;}
    const bool fresh=!window;if(fresh)create(a,f);bool enabled=next.at("enabled");
    amwin::text(file,next.at("file"));amwin::text(summary,next.at("summary"));amwin::text(page,next.at("page"));
    amwin::text(notice,next.at("notice").get<std::string>().empty()?"Click microphones to add or remove them. Changes apply immediately.":next.at("notice").get<std::string>());
    const auto& items=next.at("items");
    for(int i=0;i<8;++i){HWND b=microphones[i];bool visible=i<static_cast<int>(items.size());ShowWindow(b,visible?SW_SHOWNOACTIVATE:SW_HIDE);if(!visible){indices[i]=0;continue;}
      const auto& item=items[i];indices[i]=item.at("channel");auto name=amwin::wide(item.at("name"));auto number=std::to_wstring(indices[i]);
      labels[i]=L"ch "+number+(name.empty()?L"":L" — "+name);
      auto title=name.empty()?number:fit(name,amwin::scale(anchor,104))+L"\nch "+number;
      // Ampersands in microphone metadata are literal, not accelerators.
      for(size_t pos=0;(pos=title.find(L'&',pos))!=std::wstring::npos;pos+=2)title.insert(pos,1,L'&');
      SetWindowTextW(b,title.c_str());EnableWindow(b,enabled);SendMessageW(b,BM_SETCHECK,item.at("selected").get<bool>()?BST_CHECKED:BST_UNCHECKED,0);
      TOOLINFOW tip{sizeof(tip)};tip.hwnd=window;tip.uId=reinterpret_cast<UINT_PTR>(b);tip.lpszText=labels[i].data();SendMessageW(tips,TTM_UPDATETIPTEXTW,0,reinterpret_cast<LPARAM>(&tip));
    }
    for(int i=0;i<6;++i)EnableWindow(actions[i],enabled || i==5);
    EnableWindow(actions[0],enabled && previous);EnableWindow(actions[1],enabled && hasNext);
    EnableWindow(actions[3],enabled && next.at("can_swap").get<bool>());
    SendMessageW(actions[2],BM_SETCHECK,next.at("all").get<bool>()?BST_CHECKED:BST_UNCHECKED,0);
    amwin::text(actions[4],next.at("playing").get<bool>()?"Stop":"Play");
    if(fresh){ShowWindow(window,SW_SHOW);SetFocus(items.empty()?actions[5]:microphones[0]);}
  }
  void send(const char* op,int channel=0){
    if(paused || !state.value("enabled",false))return;
    Json event={{"op",op},{"source",state.at("source")}};if(channel)event["channel"]=channel;enqueue("channels@"+event.dump());
  }
  void close(bool notify){
    if(!window || closing)return;closing=true;HWND old=window;window=nullptr;DestroyWindow(old);tips=nullptr;closing=false;
    if(notify)enqueue("channels:close");
  }
  static LRESULT CALLBACK keyProc(HWND w,UINT m,WPARAM p,LPARAM l,UINT_PTR,DWORD_PTR data){
    auto self=reinterpret_cast<ChannelPanel*>(data);
    if(m==WM_NCDESTROY)RemoveWindowSubclass(w,keyProc,1);
    if(m==WM_KEYDOWN){
      if(p==VK_ESCAPE){self->close(true);return 0;}
      if(p==VK_TAB){HWND next=GetNextDlgTabItem(self->window,w,(GetKeyState(VK_SHIFT)&0x8000)!=0);if(next)SetFocus(next);return 0;}
    }
    return DefSubclassProc(w,m,p,l);
  }
  static LRESULT CALLBACK proc(HWND w,UINT m,WPARAM p,LPARAM l){
    auto self=reinterpret_cast<ChannelPanel*>(GetWindowLongPtrW(w,GWLP_USERDATA));
    if(m==WM_NCCREATE){self=static_cast<ChannelPanel*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
    if(m==WM_CTLCOLORSTATIC || m==WM_CTLCOLORBTN)return dialogControlColor(w,m,p,l);
    if(self && (m==WM_CLOSE || (m==WM_ACTIVATE && LOWORD(p)==WA_INACTIVE))){self->close(true);return 0;}
    if(self && m==WM_COMMAND && HIWORD(p)==BN_CLICKED){
      try{int id=LOWORD(p);if(id>=2100 && id<2108){if(self->indices[id-2100])self->send("toggle",self->indices[id-2100]);}
        else if(id>=2200 && id<2206){if(id==2205)self->close(true);else self->send(commands[id-2200]);}
      }catch(...){}return 0;
    }
    return DefWindowProcW(w,m,p,l);
  }
};
