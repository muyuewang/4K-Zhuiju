"""打包 Windows 发行 zip。

为什么不用 PowerShell 的 Compress-Archive：它写入的包内路径用反斜杠
（`dir\\data\\app.so`），部分跨平台解压工具和 Windows 自带解压都处理不干净。
Python 的 zipfile 可以显式指定正斜杠，和 Linux/macOS 产出的包一致。
"""
import os
import sys
import zipfile

root_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = os.path.join(root_dir, "code", "flutter_app", "build", "windows", "x64", "runner", "Release")
root = "4KZhuiju-v1.6.0-windows-x64"
out = os.path.join(root_dir, "dist", "v1.6.0", "4KZhuiju-v1.6.0-windows-x64.zip")

if not os.path.isdir(src):
    sys.exit(f"源目录不存在: {src}")

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

print(f"写入 {count} 个文件")
print("大小 %.2f MB" % (os.path.getsize(out) / 1048576))
print("路径:", out)