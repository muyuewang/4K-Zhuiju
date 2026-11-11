"""打包 Windows 发行 zip。

为什么不用 PowerShell 的 Compress-Archive：它写入的包内路径用反斜杠
（`dir\\data\\app.so`），部分跨平台解压工具和 Windows 自带解压都处理不干净。
Python 的 zipfile 可以显式指定正斜杠，和 Linux/macOS 产出的包一致。

版本号从 pubspec.yaml 读，不再硬编码：
上一版把 "1.7.0" 写死在这里，升到 1.7.1 后直接跑这个脚本，产物会被
塞进 dist/v1.7.0/ 并且包内目录名还带旧版本——发布时才发现，
而 zip 里那个目录名正是用户解压后看到的文件夹名。
"""
import os
import re
import sys
import zipfile

root_dir = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
pubspec = os.path.join(root_dir, "code", "flutter_app", "pubspec.yaml")

# pubspec 的 version 形如 1.8.0+12，取 + 之前的部分做展示版本
version = None
with open(pubspec, encoding="utf-8") as f:
    for line in f:
        m = re.match(r"^version:\s*([0-9][^\s+]*)", line)
        if m:
            version = m.group(1)
            break

if not version:
    sys.exit(f"无法从 {pubspec} 读取版本号")

src = os.path.join(
    root_dir, "code", "flutter_app", "build", "windows", "x64", "runner", "Release"
)
root = f"4KZhuiju-v{version}-windows-x64"
out_dir = os.path.join(root_dir, "dist", f"v{version}")
out = os.path.join(out_dir, f"{root}.zip")

if not os.path.isdir(src):
    sys.exit(f"源目录不存在: {src}")

# 产物必须齐全，缺一个装上去就是打不开的包
for must in ("zhuiju.exe", "flutter_windows.dll", "data/app.so"):
    p = os.path.join(src, must.replace("/", os.sep))
    if not os.path.isfile(p):
        sys.exit(f"缺少必需文件: {p}")

os.makedirs(out_dir, exist_ok=True)
if os.path.exists(out):
    os.remove(out)

count = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, _, files in os.walk(src):
        for name in files:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            z.write(full, root + "/" + rel)
            count += 1

print(f"版本 {version}")
print(f"写入 {count} 个文件")
print("大小 %.2f MB" % (os.path.getsize(out) / 1048576))
print("路径:", out)