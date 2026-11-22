#pragma once
// Identical acceptance inputs run against the actual Cocoa and Win32 parsers.
#include "settings_layout.h"
#include "editor_layout.h"
#include "vendor/json.hpp"
#include <fstream>
#include <stdexcept>
#include <string>
#include <string_view>

static_assert(ameditor::page_count==3 && std::string_view(ameditor::pages[0])=="Sound"
  && std::string_view(ameditor::pages[1])=="Normalize" && std::string_view(ameditor::pages[2])=="Manage");
static_assert(amsettings::page_count==4 && std::string_view(amsettings::pages[3])=="About");
static_assert(amsettings::count==10);
inline constexpr int normalization_fade_index=amsettings::count-2;
static_assert(std::string_view(amsettings::controls[normalization_fade_index].key)=="normalize_fade_ms");
static_assert(amsettings::controls[normalization_fade_index].page==0);
static_assert(amsettings::controls[amsettings::count-1].kind==amsettings::link);
static_assert(amsettings::controls[amsettings::count-1].page==3 && !amsettings::controls[amsettings::count-1].key);
static_assert(std::string_view(amsettings::controls[amsettings::count-1].label)=="Support on Ko-fi");
static_assert(std::string_view(amsettings::controls[amsettings::count-1].url)=="https://ko-fi.com/kuma_pontakuaudio");

inline void test_bar_contract(bool(*set_state)(const char*)) {
  std::ifstream input("tests/native-bar-cases.json");
  if(!input)throw std::runtime_error("Missing shared native bar cases; run from the repository root");
  const auto fixture=nlohmann::json::parse(input);
  for(const auto& test:fixture.at("cases")) {
    auto state=fixture.at("base");
    if(test.contains("set"))state.update(test.at("set"));
    if(test.contains("remove"))for(const auto& key:test.at("remove"))state.erase(key.get<std::string>());
    if(set_state(state.dump().c_str())!=test.at("accept").get<bool>())
      throw std::runtime_error("Native bar contract: "+test.at("name").get<std::string>());
  }
}
