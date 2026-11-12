#include "window_channel.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <string>

#include "utils.h"

namespace {

/// 系统代理设置所在的注册表键（HKCU）。
///
/// 只读当前用户：系统级代理（HKLM）改了要重启才生效，普通用户也没有
/// 写权限，读它反而可能拿到一份过期的值。
constexpr wchar_t kInternetSettings[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

/// 读注册表字符串值（REG_SZ / REG_EXPAND_SZ）。
///
/// 用 RegGetValueW 而不是 RegOpenKeyEx + RegQueryValueEx：前者是"只读一个
/// 值"的专用 API，不需要自己开关键句柄，也自带 RRF_RT_* 类型过滤。
///
/// 返回 false 表示键/值不存在或类型不符，调用方按"没配代理"处理。
bool ReadRegString(const wchar_t* name, std::wstring* out) {
  DWORD type = 0;
  DWORD size = 0;
  // 第一遍只问大小：ERROR_SUCCESS 表示值是空串，ERROR_MORE_DATA 才是有内容
  LONG rc = RegGetValueW(HKEY_CURRENT_USER, kInternetSettings, name,
                         RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ, &type, nullptr,
                         &size);
  if (rc != ERROR_SUCCESS && rc != ERROR_MORE_DATA) return false;
  if (size == 0) {
    out->clear();
    return true;
  }
  std::wstring buf(size / sizeof(wchar_t), L'\0');
  rc = RegGetValueW(HKEY_CURRENT_USER, kInternetSettings, name,
                    RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ, &type, buf.data(),
                    &size);
  if (rc != ERROR_SUCCESS) return false;
  // 带回来的 buffer 以 NUL 结尾，按 C 语义截断
  const size_t nul = buf.find(L'\0');
  if (nul != std::wstring::npos) buf.resize(nul);
  *out = std::move(buf);
  return true;
}

/// 读注册表 DWORD 值。值不存在或类型不符时返回 false。
bool ReadRegDword(const wchar_t* name, DWORD* out) {
  DWORD type = 0;
  DWORD size = sizeof(DWORD);
  return RegGetValueW(HKEY_CURRENT_USER, kInternetSettings, name,
                      RRF_RT_REG_DWORD, &type, out, &size) == ERROR_SUCCESS;
}

/// 进入全屏前的窗口样式与摆放位置，退出时原样还原。
/// 只还原样式是不够的：用户可能是在最大化状态下点的全屏，
/// 退出后应该还是最大化，而不是变成一个居中的普通窗口。
struct SavedWindowState {
  LONG_PTR style = 0;
  LONG_PTR ex_style = 0;
  WINDOWPLACEMENT placement = {};
  bool valid = false;
};

SavedWindowState g_saved;
flutter::MethodChannel<flutter::EncodableValue>* g_channel = nullptr;

/// 当前是否处于（本程序进入的）全屏
bool g_fullscreen = false;

/// 窗口最小尺寸（物理像素）。0 表示未设置。
int g_min_width = 0;
int g_min_height = 0;

}  // namespace

void WindowChannel::ReadSystemProxy(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // ProxyEnable 正常是 REG_DWORD。先按 DWORD 读——这是 IE/Clash/v2rayN
  // 实际写下的类型。读不到再退回字符串形态，兼容被手工改过的机器。
  bool on = false;
  DWORD enable = 0;
  if (ReadRegDword(L"ProxyEnable", &enable)) {
    on = enable != 0;
  } else {
    std::wstring s;
    if (ReadRegString(L"ProxyEnable", &s)) {
      on = (s == L"1" || s == L"0x1" || s == L"0x00000001");
    }
  }
  if (!on) {
    // 没配代理，或明确关闭：回空串，Dart 侧据此走直连
    result->Success(flutter::EncodableValue(""));
    return;
  }

  std::wstring server;
  if (!ReadRegString(L"ProxyServer", &server) || server.empty()) {
    // ProxyEnable=1 但没有 ProxyServer，属于脏配置，按直连处理。
    // 注意：有的软件写 AutoConfigURL（PAC）而不写 ProxyServer，
    // PAC 需要 JS 引擎才能求值，本项目不支持，同样退回直连。
    result->Success(flutter::EncodableValue(""));
    return;
  }
  result->Success(flutter::EncodableValue(Utf8FromUtf16(server.c_str())));
}

int WindowChannel::MinWidth() { return g_min_width; }
int WindowChannel::MinHeight() { return g_min_height; }
bool WindowChannel::IsFullscreen() { return g_fullscreen; }

void WindowChannel::Register(flutter::BinaryMessenger* messenger, HWND window) {
  static flutter::MethodChannel<flutter::EncodableValue> channel(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  g_channel = &channel;

  channel.SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
        const std::string& method = call.method_name();

        if (method == "setFullscreen") {
          bool on = false;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("on"));
            if (it != args->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) {
                on = *b;
              }
            }
          }
          SetFullscreen(window, on);
          result->Success(flutter::EncodableValue(g_fullscreen));
          return;
        }

        if (method == "isFullscreen") {
          result->Success(flutter::EncodableValue(g_fullscreen));
          return;
        }

        if (method == "readSystemProxy") {
          ReadSystemProxy(std::move(result));
          return;
        }

        if (method == "setMinimumSize") {
          double w = 880, h = 560;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto itw = args->find(flutter::EncodableValue("width"));
            auto ith = args->find(flutter::EncodableValue("height"));
            if (itw != args->end()) {
              if (const auto* d = std::get_if<double>(&itw->second)) w = *d;
            }
            if (ith != args->end()) {
              if (const auto* d = std::get_if<double>(&ith->second)) h = *d;
            }
          }
          // 逻辑像素 → 物理像素。高 DPI 屏（150%/200%）上不换算的话，
          // 设成 880 逻辑宽实际只挡住 880 物理宽，窗口仍能被拉得极窄。
          UINT dpi = GetDpiForWindow(window);
          double scale = dpi == 0 ? 1.0 : dpi / 96.0;
          g_min_width = std::max(static_cast<int>(w * scale), 320);
          g_min_height = std::max(static_cast<int>(h * scale), 240);
          result->Success();
          return;
        }

        result->NotImplemented();
      });
}

void WindowChannel::SetFullscreen(HWND window, bool on) {
  if (window == nullptr) return;
  if (on == g_fullscreen) return;

  if (on) {
    g_saved.style = GetWindowLongPtr(window, GWL_STYLE);
    g_saved.ex_style = GetWindowLongPtr(window, GWL_EXSTYLE);
    g_saved.placement.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(window, &g_saved.placement);
    g_saved.valid = true;

    // 去掉标题栏与边框，铺满窗口所在的那块显示器。
    // 用 MonitorFromWindow 而不是 PRIMARY：多显示器下用户可能把窗口
    // 拖到副屏再点全屏，按主屏尺寸铺会跑到另一块屏上去。
    MONITORINFO mi = {sizeof(mi)};
    if (GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY),
                       &mi)) {
      SetWindowLongPtr(window, GWL_STYLE, g_saved.style & ~WS_OVERLAPPEDWINDOW);
      SetWindowLongPtr(window, GWL_EXSTYLE,
                       g_saved.ex_style & ~WS_EX_WINDOWEDGE);
      SetWindowPos(window, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    }
    g_fullscreen = true;
  } else {
    if (g_saved.valid) {
      SetWindowLongPtr(window, GWL_STYLE, g_saved.style);
      SetWindowLongPtr(window, GWL_EXSTYLE, g_saved.ex_style);
      SetWindowPlacement(window, &g_saved.placement);
      SetWindowPos(window, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
    }
    g_fullscreen = false;
  }
}

void WindowChannel::NotifyEscape(HWND window) {
  if (g_channel == nullptr || !g_fullscreen) return;
  SetFullscreen(window, false);
  g_channel->InvokeMethod("exitedFullscreen",
                          std::make_unique<flutter::EncodableValue>());
}