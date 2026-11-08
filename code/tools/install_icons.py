"""把主图标铺到各平台需要的尺寸

Android：
  mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png  普通图标
  mipmap-*/ic_launcher_foreground.png                      自适应前景
  mipmap-*/ic_launcher_round.png                           圆形图标
  values/ic_launcher_background.xml + mipmap-anydpi-v26/   自适应图标声明

Windows：
  windows/runner/resources/app_icon.ico（多尺寸 ICO）

网页（可选）：
  web/favicon.png、web/icons/*
"""
from PIL import Image
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "flutter_app"))

MASTER = os.path.join(HERE, "app_icon_1024.png")
ROUND = os.path.join(HERE, "app_icon_round_1024.png")
FG = os.path.join(HERE, "app_icon_fg_1024.png")
BG = os.path.join(HERE, "app_icon_bg_1024.png")

# Android 各密度下 launcher 图标的边长（48dp 基准）
ANDROID_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
# 自适应图标层级尺寸是 108dp
ADAPTIVE_SIZES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}


def load(p):
    return Image.open(p).convert("RGBA")


def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path, "PNG")


def android():
    master = load(MASTER)
    rnd = load(ROUND)
    fg = load(FG)
    bg = load(BG)
    res = os.path.join(ROOT, "android", "app", "src", "main", "res")

    for density, sz in ANDROID_SIZES.items():
        d = os.path.join(res, f"mipmap-{density}")
        save(master, os.path.join(d, "ic_launcher.png"), sz)
        save(rnd, os.path.join(d, "ic_launcher_round.png"), sz)

    for density, sz in ADAPTIVE_SIZES.items():
        d = os.path.join(res, f"mipmap-{density}")
        save(fg, os.path.join(d, "ic_launcher_foreground.png"), sz)
        # 背景层直接铺满，Android 会自动裁切
        save(bg, os.path.join(d, "ic_launcher_background.png"), sz)

    print("android mipmaps done")


def vista_ico():
    """生成 Vista+ 多尺寸 ICO（PNG 压缩格式），供 Windows exe 使用"""
    sizes = [16, 24, 32, 48, 64, 128, 256]
    # Windows 用方形非圆角更贴合系统惯例，这里保留圆角但去掉透明边
    src = load(MASTER)

    imgs = []
    for s in sizes:
        imgs.append(src.resize((s, s), Image.LANCZOS))

    # 手写 ICO：ICONDIR + ICONDIRENTRY*(n) + PNG 数据
    # 注：PIL 的 save(format='ICO', sizes=...) 也能用，但它的 entries
    # 顺序与尺寸覆盖不完全可控，这里显式写出，避免 256 缺失。
    pngs = []
    for im in imgs:
        tmp = os.path.join(HERE, f"_ico_{im.width}.png")
        im.save(tmp, "PNG")
        with open(tmp, "rb") as f:
            pngs.append(f.read())
        os.remove(tmp)

    header = struct.pack("<HHH", 0, 1, len(imgs))
    offset = 6 + 16 * len(imgs)
    entries = b""
    for im, data in zip(imgs, pngs):
        w = 0 if im.width >= 256 else im.width
        h = 0 if im.height >= 256 else im.height
        entries += struct.pack("<BBBBHHII",
                               w, h, 0, 0, 1, 32, len(data), offset)
        offset += len(data)

    out = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(header + entries + b"".join(pngs))
    print(f"windows ico done -> {out} ({os.path.getsize(out)} bytes)")


def web_assets():
    web = os.path.join(ROOT, "web")
    if not os.path.isdir(web):
        print("web/ 不存在，跳过")
        return
    master = load(MASTER)
    save(master, os.path.join(web, "favicon.png"), 32)
    save(master, os.path.join(web, "icons", "Icon-192.png"), 192)
    save(master, os.path.join(web, "icons", "Icon-512.png"), 512)
    save(load(FG), os.path.join(web, "icons", "Icon-maskable-192.png"), 192)
    save(load(FG), os.path.join(web, "icons", "Icon-maskable-512.png"), 512)
    print("web icons done")


if __name__ == "__main__":
    android()
    vista_ico()
    web_assets()
    print("ALL DONE")