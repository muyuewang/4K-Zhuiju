#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_channel.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 注册桌面窗口能力通道（全屏 / 最小尺寸）
  WindowChannel::Register(flutter_controller_->engine()->messenger(),
                          GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_KEYDOWN:
      // 全屏时按 Esc 退出：桌面用户不会去找「退出全屏」按钮，
      // 第一反应就是 Esc。Dart 侧收到通知后同步自己的 _fullscreen 状态。
      if (wparam == VK_ESCAPE) {
        WindowChannel::NotifyEscape(hwnd);
        return 0;
      }
      break;

    case WM_GETMINMAXINFO: {
      // 限制窗口最小尺寸。不限制的话用户能把窗口拖到几十像素宽，
      // 此时所有布局都会 overflow，界面变成一片黄黑条纹。
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      if (WindowChannel::MinWidth() > 0) {
        info->ptMinTrackSize.x = WindowChannel::MinWidth();
      }
      if (WindowChannel::MinHeight() > 0) {
        info->ptMinTrackSize.y = WindowChannel::MinHeight();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}