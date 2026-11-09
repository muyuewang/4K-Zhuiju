"""生成 Android TV 桌面横幅（banner）。

电视桌面（Leanback Launcher）要求每个 App 必须提供 banner，
缺失时应用仍能启动，但在桌面上显示为灰色占位块，很难看。

规范：320x180 dp，16:9。按密度各出一份，1080p 电视取 xhdpi（640x360）。
视觉沿用 App 图标：深色渐变底 + 橙色 4K + 白色播放三角 + 中文名。
"""
import os

from PIL import Image, ImageDraw, ImageFont

OUT_BASE = r"C:\Users\fengxin\WorkBuddy\vivos7\code\flutter_app\android\app\src\main\res"
FONT_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"

# 与 lib/theme.dart 中的 kAccent 一致
ACCENT = (0xFF, 0x6B, 0x3D)
ACCENT_LIGHT = (0xFF, 0x8A, 0x4C)

# 目标尺寸：dp 320x180，各密度对应像素
DENSITIES = {
    "drawable": (320, 180),
    "drawable-hdpi": (480, 270),
    "drawable-xhdpi": (640, 360),
    "drawable-xxhdpi": (960, 540),
}


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make(w, h):
    img = Image.new("RGB", (w, h), (14, 15, 19))
    d = ImageDraw.Draw(img)

    # 背景：左上偏暖、右下接近黑，和图标一致的斜向渐变
    top_left = (58, 34, 26)
    bottom_right = (12, 13, 17)
    for y in range(h):
        for_x_t = y / max(h - 1, 1)
        # 逐行画横向渐变，行数有限，成本可接受
        for x in range(0, w, max(1, w // 320)):
            t = (x / max(w - 1, 1) + for_x_t) / 2
            d.line([(x, y), (min(x + w // 320, w), y)],
                   fill=lerp(top_left, bottom_right, t))

    s = h / 180.0  # 以 dp 为基准的缩放系数

    # 左侧留白
    left = 26 * s

    # "4K" 大字
    size_4k = int(74 * s)
    f_4k = ImageFont.truetype(FONT_BOLD, size_4k)
    txt_4k = "4K"
    bbox = d.textbbox((0, 0), txt_4k, font=f_4k)
    w_4k = bbox[2] - bbox[0]
    h_4k = bbox[3] - bbox[1]
    y_4k = (h - h_4k) / 2 - bbox[1]
    d.text((left - bbox[0], y_4k), txt_4k, font=f_4k, fill=ACCENT)

    # 播放三角（白色），贴在 4K 右侧
    tri_h = 34 * s
    tri_w = 30 * s
    tri_x = left + w_4k + 10 * s
    tri_y = (h - tri_h) / 2
    d.polygon(
        [(tri_x, tri_y), (tri_x, tri_y + tri_h), (tri_x + tri_w, tri_y + tri_h / 2)],
        fill=(248, 248, 250),
    )

    # 中文名，放右下角，右对齐
    size_cn = int(30 * s)
    f_cn = ImageFont.truetype(FONT_BOLD, size_cn)
    txt_cn = "追剧"
    cb = d.textbbox((0, 0), txt_cn, font=f_cn)
    cn_w = cb[2] - cb[0]
    cn_h = cb[3] - cb[1]
    d.text(
        (w - 24 * s - cn_w - cb[0], h - 22 * s - cn_h - cb[1]),
        txt_cn,
        font=f_cn,
        fill=ACCENT_LIGHT,
    )

    # 底部细线，增强「电视卡片」的层次感
    d.rectangle([0, h - max(1, int(2 * s)), w, h], fill=ACCENT)

    return img


def main():
    for folder, (w, h) in DENSITIES.items():
        target = os.path.join(OUT_BASE, folder)
        os.makedirs(target, exist_ok=True)
        path = os.path.join(target, "tv_banner.png")
        make(w, h).save(path, "PNG", optimize=True)
        print(f"{path}  {w}x{h}  {os.path.getsize(path)} B")


if __name__ == "__main__":
    main()