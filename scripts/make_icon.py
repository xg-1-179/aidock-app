"""生成 AIDock 的启动图标（深色圆角底 + 终端提示符「> _」）。

flutter create 只会放 Flutter 的默认图标，真机上就是那个蓝色 F。
这里用几何图形画，不依赖字体，CI 上装个 pillow 就能跑。
"""
import pathlib
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("pillow not installed; skip icon", file=sys.stderr)
    raise SystemExit(0)

RES = pathlib.Path("android/app/src/main/res")
SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
BG = (11, 15, 20, 255)        # AidockColors.bg
ACCENT = (77, 163, 255, 255)  # AidockColors.accent
SOFT = (127, 209, 255, 255)


def draw(size: int) -> Image.Image:
    # 4 倍超采样再缩，边缘才不锯齿。
    ss = 4
    n = size * ss
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(n * 0.22)
    d.rounded_rectangle([0, 0, n - 1, n - 1], radius=radius, fill=BG)

    w = max(2, int(n * 0.085))
    d.line(
        [(int(n * 0.33), int(n * 0.30)), (int(n * 0.53), int(n * 0.50)), (int(n * 0.33), int(n * 0.70))],
        fill=ACCENT, width=w, joint="curve",
    )
    d.line(
        [(int(n * 0.60), int(n * 0.70)), (int(n * 0.79), int(n * 0.70))],
        fill=SOFT, width=int(n * 0.075),
    )
    return img.resize((size, size), Image.LANCZOS)


def main() -> int:
    made = []
    for folder, size in SIZES.items():
        target = RES / folder / "ic_launcher.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        draw(size).save(target)
        made.append(f"{folder}/{size}")
    print("icon:", ", ".join(made))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
