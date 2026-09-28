"""Generate platform launcher icons from the canonical Chereda artwork."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
CANONICAL_ICON = ROOT / "assets" / "branding" / "chereda_app_icon.png"
BACKGROUND = (24, 32, 51, 255)


def resized(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.Resampling.LANCZOS)


def save_png(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    resized(image, size).save(path, format="PNG", optimize=True)


def opaque(image: Image.Image) -> Image.Image:
    background = Image.new("RGBA", image.size, BACKGROUND)
    background.alpha_composite(image)
    return background.convert("RGB")


def generate(source_path: Path) -> None:
    source = Image.open(source_path).convert("RGBA")
    if source.width != source.height:
        raise ValueError("The app icon source must be square")

    CANONICAL_ICON.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_path, CANONICAL_ICON)

    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in android_sizes.items():
        save_png(
            source,
            ROOT / "android" / "app" / "src" / "main" / "res" / folder / "ic_launcher.png",
            size,
        )

    ios = opaque(source)
    ios_sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    ios_dir = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for filename, size in ios_sizes.items():
        save_png(ios, ios_dir / filename, size)

    macos_dir = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_png(source, macos_dir / f"app_icon_{size}.png", size)

    save_png(source, ROOT / "web" / "icons" / "Icon-192.png", 192)
    save_png(source, ROOT / "web" / "icons" / "Icon-512.png", 512)
    save_png(ios, ROOT / "web" / "icons" / "Icon-maskable-192.png", 192)
    save_png(ios, ROOT / "web" / "icons" / "Icon-maskable-512.png", 512)
    save_png(source, ROOT / "web" / "favicon.png", 32)

    windows_icon = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    windows_icon.parent.mkdir(parents=True, exist_ok=True)
    source.save(
        windows_icon,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Path to a square PNG source")
    args = parser.parse_args()
    generate(args.source.resolve())


if __name__ == "__main__":
    main()
