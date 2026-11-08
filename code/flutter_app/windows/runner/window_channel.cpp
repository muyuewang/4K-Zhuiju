#include "window_channel.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>

namespace {

// 进入全屏前的窗口样式与摆放位置，退出时原样还原。
// 只还原样式是不够的：用户可能是在最大化状态下点的全屏，
// 退出后应该还是最大化，而不是变成一个居中的普通窗口。
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