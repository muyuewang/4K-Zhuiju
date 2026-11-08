"""为 Windows 构建预建插件链接（junction 方案）

背景：
  Flutter 构建 Windows 插件时会在 windows/flutter/ephemeral/.plugin_symlinks/
  下为每个插件创建**符号链接**（symlink）。在 Windows 上创建 symlink 需要
  「开发者模式」或管理员权限，否则报错：

      Building with plugins requires symlink support.
      Please enable Developer Mode in your system settings.

  而 `mklink /J`（目录联接 / junction）**不需要任何特权**，且 Dart 的
  Link 类型能正常识别它（typeSync(followLinks:false) == link，
  targetSync() 返回真实路径），Flutter 的检查逻辑正好是：

      if (entityType == link) {
        if (canonicalize(link.targetSync()) == canonicalize(path) && exists) continue;
      }

  也就是说：只要在 Flutter 动手之前，把目标链接**按正确指向预先建好**，
  它的 `continue` 分支就会直接跳过创建，从而绕开权限问题。

用法（构建前跑一次即可，已存在的正确链接会被保留）：
    python code/tools/win_junctions.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", "flutter_app"))
DEPS = os.path.join(PROJECT, ".flutter-plugins-dependencies")
LINK_DIR = os.path.join(PROJECT, "windows", "flutter", "ephemeral",
                        ".plugin_symlinks")


def windows_plugins() -> list[tuple[str, str]]:
    if not os.path.isfile(DEPS):
        print(f"[!] 找不到 {DEPS}，先跑 flutter pub get")
        return []
    with open(DEPS, "r", encoding="utf-8") as f:
        data = json.load(f)
    out = []
    for p in data.get("plugins", {}).get("windows", []):
        name = p.get("name")
        path = (p.get("path") or "").rstrip("\\/")
        if name and path:
            out.append((name, path))
    return out


def is_link_ok(link_path: str, target: str) -> bool:
    """链接存在且指向正确（大小写/分隔符归一后比较）"""
    if not os.path.exists(link_path):
        return False
    try:
        real = os.path.realpath(link_path)
    except OSError:
        return False
    return os.path.normcase(os.path.normpath(real)) == \
        os.path.normcase(os.path.normpath(target))


def make_junction(link_path: str, target: str) -> bool:
    # /J 建目录联接；cmd 需要 Windows 路径与引号
    cmd = f'mklink /J "{link_path}" "{target}"'
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                       encoding="mbcs", errors="replace")
    ok = os.path.exists(link_path)
    if not ok:
        print(f"    [!] 失败: {r.stdout.strip()} {r.stderr.strip()}")
    return ok


def main() -> int:
    plugins = windows_plugins()
    if not plugins:
        print("没有 Windows 插件需要链接")
        return 0

    os.makedirs(LINK_DIR, exist_ok=True)
    print(f"链接目录: {LINK_DIR}")

    bad = 0
    for name, target in plugins:
        link_path = os.path.join(LINK_DIR, name)
        if is_link_ok(link_path, target):
            print(f"  [=] {name} 已就绪")
            continue
        # 已存在但指向不对（可能是旧版本残留），先删
        if os.path.exists(link_path):
            subprocess.run(f'rmdir "{link_path}"', shell=True,
                           capture_output=True)
            if os.path.exists(link_path):
                import shutil
                shutil.rmtree(link_path, ignore_errors=True)
        if make_junction(link_path, target):
            print(f"  [+] {name} -> {target}")
        else:
            bad += 1

    if bad:
        print(f"\n{bad} 个插件链接失败，构建可能仍然报 symlink 错误")
        return 1
    print("\n全部就绪，可以构建")
    return 0


if __name__ == "__main__":
    sys.exit(main())