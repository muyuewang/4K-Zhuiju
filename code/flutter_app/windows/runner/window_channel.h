#ifndef RUNNER_WINDOW_CHANNEL_H_
#define RUNNER_WINDOW_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <memory>

// 桌面窗口能力通道：窗口全屏 / 最小尺寸。
//
// 为什么必须走原生：
//   Flutter 的 SystemChrome.setEnabledSystemUIMode 只作用于移动端的系统栏，
//   在 Windows 上既不会隐藏标题栏也不会改变窗口大小。之前播放页点「全屏」
//   只切了 Flutter 内部的 _fullscreen 状态，窗口纹丝不动——用户看到的就是
//   「全屏按钮没反应」。真正的全屏需要 SetWindowLong 去掉 WS_OVERLAPPEDWINDOW
//   并铺满显示器。
class WindowChannel {
 public:
  static constexpr char const* kChannelName = "zhuiju/window";

  // 在窗口创建后调用一次，注册方法通道。
  static void Register(flutter::BinaryMessenger* messenger, HWND window);

  // 设置窗口全屏状态（内部按需保存/还原窗口样式）。
  static void SetFullscreen(HWND window, bool on);

  // 全屏时按 Esc：退出全屏并通知 Dart 侧同步状态。
  static void NotifyEscape(HWND window);

  static int MinWidth();
  static int MinHeight();
  static bool IsFullscreen();

  // 读取系统代理设置（HKCU\...\Internet Settings 的 ProxyEnable / ProxyServer）。
  //
  // 为什么必须在原生层做，而不是 Dart 里 `Process.run('reg', ...)`：
  //   "启动外部进程执行命令行" 是杀毒软件行为监控里权重极高的一条规则。
  //   本程序没有数字签名，一旦拉起 reg.exe，Defender 就会把
  //   「无签名程序 + 创建子进程执行命令」判成 "执行来自攻击者的命令"
  //   （实测 2026-11-12 用户机器报 Trojan 并隔离）。
  //   改成进程内直接调 RegGetValueW 后，全程不产生任何子进程，
  //   行为特征回归「普通桌面程序读自己的配置」。
  static void ReadSystemProxy(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

#endif  // RUNNER_WINDOW_CHANNEL_H_