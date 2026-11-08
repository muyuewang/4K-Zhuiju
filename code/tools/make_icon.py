"""4K追剧 应用图标生成器

设计说明：
  深色底（与 App 主题 kBg #0E0F13 一致）+ 橙色强调（kAccent #FF6B3D）。
  主体是「4K」粗体字 + 右侧播放三角，三者作为**一个整体居中排布**。
  不堆胶片、镜头等细节图形 —— 图标在列表里只有 48px，细节全糊成一团。

  绘制在 4096 画布上 4 倍超采样，最后 LANCZOS 缩放，消除圆角与文字锯齿。
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os

S = 4096          # 超采样画布
OUT = 1024        # 主图标边长

BG_DARK = (14, 15, 19)      # kBg
BG_MID = (26, 28, 36)       # kCard 略提亮
ACCENT = (255, 107, 61)     # kAccent
ACCENT_HI = (255, 166, 96)  # 渐变高光
WHITE = (255, 255, 255)

FONT_CANDIDATES = (
    r"C:\Windows\Fonts\ariblk.ttf",   # Arial Black
    r"C:\Windows\Fonts\impact.ttf",
    r"C:\Windows\Fonts\arialbd.ttf",
)


def _font(size):
    for p in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()


def _vgrad(w, h, top, bottom):
    """竖向线性渐变（先画 1px 宽再拉伸，比逐像素快）"""
    col = Image.new("RGB", (1, h))
    d = ImageDraw.Draw(col)
    for y in range(h):
        t = y / max(1, h - 1)
        d.point((0, y), tuple(
            int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return col.resize((w, h), Image.BILINEAR)


def _radial_glow(size, color, strength=120):
    """左上角径向光晕，给深色底一点层次，避免死黑"""
    glow = Image.new("RGB", (size, size), (0, 0, 0))
    d = ImageDraw.Draw(glow)
    steps = 48
    cx, cy = int(size * 0.26), int(size * 0.20)
    for i in range(steps, 0, -1):
        t = i / steps
        r = int(size * 0.78 * t)
        a = (1 - t) ** 2.0
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=(int(color[0] * a), int(color[1] * a),
                        int(color[2] * a)))
    return glow.filter(ImageFilter.GaussianBlur(size // 30))


def _background(size):
    base = _vgrad(size, size, BG_MID, BG_DARK).convert("RGB")
    return Image.blend(base, _radial_glow(size, ACCENT), 0.42)


def _text_mask(canvas_size, text, font):
    """返回 (mask, bbox)：mask 为整幅画布大小，bbox 为文字实际包围盒"""
    m = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(m).text((0, 0), text, font=font, fill=255)
    bbox = m.getbbox()
    if bbox is None:
        return m, (0, 0, 1, 1)
    return m, bbox


def _fit_font(text, canvas_size, target_ratio):
    """迭代逼近：让文字宽度接近 canvas_size * target_ratio"""
    target = canvas_size * target_ratio
    size = int(canvas_size * 0.40)
    font = _font(size)
    for _ in range(20):
        _, bbox = _text_mask(canvas_size, text, font)
        w = bbox[2] - bbox[0]
        if w <= 0:
            break
        if abs(w - target) < canvas_size * 0.003:
            break
        size = max(8, int(size * target / w))
        font = _font(size)
    return font


def draw_mark(img, canvas_size, scale=1.0, gap_ratio=0.10):
    """在 img 上绘制「4K + 播放三角」整体，水平垂直居中。

    scale < 1 用于 Android 自适应图标前景层（需留安全区）。
    """
    text = "4K"
    # 文字与三角作为一个整体，整体宽度取画布 72% * scale
    group_target = canvas_size * 0.72 * scale
    # 先按「文字占整体约 78%」估算字号
    font = _fit_font(text, canvas_size, 0.72 * scale * 0.78)
    mask, bbox = _text_mask(canvas_size, text, font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]

    # 播放三角尺寸：高度取文字高度 58%，宽高比 0.86（视觉上等边）
    tri_h = th * 0.58 * scale
    tri_w = tri_h * 0.86
    gap = th * gap_ratio

    group_w = tw + gap + tri_w
    # 整体居中
    gx = (canvas_size - group_w) / 2
    gy = (canvas_size - th) / 2

    # ---- 文字：橙色竖向渐变，蒙版精确到 bbox，避免渐变错位 ----
    grad = _vgrad(tw, th, ACCENT_HI, ACCENT)
    text_layer = Image.new("RGB", (tw, th), (0, 0, 0))
    crop_mask = mask.crop(bbox)
    text_layer.paste(grad, (0, 0), crop_mask)
    img.paste(text_layer, (int(gx), int(gy)), crop_mask)

    # ---- 播放三角：右侧垂直居中，白色 ----
    d = ImageDraw.Draw(img)
    tx = gx + tw + gap
    ty = gy + th / 2
    d.polygon(
        [(tx, ty - tri_h / 2),
         (tx, ty + tri_h / 2),
         (tx + tri_w, ty)],
        fill=WHITE,
    )
    return img


def make_icon(size, rounded=0.22, mark_scale=1.0):
    """完整图标（含圆角背景）"""
    canvas = _background(size)
    canvas = draw_mark(canvas, size, scale=mark_scale)

    if rounded <= 0:
        return canvas.convert("RGBA")

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * rounded), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(canvas, (0, 0), mask)
    return out


def make_foreground(size, mark_scale=0.62):
    """Android 自适应图标前景层：透明底 + 缩小居中的标记（留安全区）"""
    canvas = Image.new("RGB", (size, size), (0, 0, 0))
    canvas = draw_mark(canvas, size, scale=mark_scale)
    # 取非黑像素做 alpha；阈值 12 可滤掉抗锯齿产生的极暗噪点
    alpha = canvas.convert("L").point(lambda v: 255 if v > 12 else 0)
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fg.paste(canvas, (0, 0), alpha)
    return fg


def make_background_layer(size):
    """Android 自适应图标背景层：渐变底，不透明"""
    return _background(size).convert("RGBA")


if __name__ == "__main__":
    out_dir = os.path.dirname(os.path.abspath(__file__))

    master = make_icon(S, rounded=0.22)
    master.resize((OUT, OUT), Image.LANCZOS).save(
        os.path.join(out_dir, "app_icon_1024.png"))
    print("app_icon_1024.png")

    # 圆形版（网页 favicon / 部分启动器）
    cmask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(cmask).ellipse([0, 0, S - 1, S - 1], fill=255)
    circ = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    circ.paste(make_icon(S, rounded=0).convert("RGB"), (0, 0), cmask)
    circ.resize((OUT, OUT), Image.LANCZOS).save(
        os.path.join(out_dir, "app_icon_round_1024.png"))
    print("app_icon_round_1024.png")

    # 自适应图标两层
    make_foreground(S).resize((OUT, OUT), Image.LANCZOS).save(
        os.path.join(out_dir, "app_icon_fg_1024.png"))
    make_background_layer(S).resize((OUT, OUT), Image.LANCZOS).save(
        os.path.join(out_dir, "app_icon_bg_1024.png"))
    print("adaptive fg/bg done")