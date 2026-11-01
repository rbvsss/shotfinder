"""Draws the app icon: a viewfinder with the found shot marked inside it."""
from pathlib import Path

from PIL import Image, ImageDraw

OUTPUT = Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "icon.png"
SCALE = 4
SIZE = 1024 * SCALE
INK = (12, 12, 11)
PAPER = (242, 238, 229)
SIGNAL = (255, 93, 46)


def main():
    image = Image.new("RGB", (SIZE, SIZE), INK)
    draw = ImageDraw.Draw(image)

    width, height = 540 * SCALE, 720 * SCALE
    left, top = (SIZE - width) // 2, (SIZE - height) // 2
    right, bottom = left + width, top + height
    arm = 150 * SCALE
    stroke = 44 * SCALE

    for x, y, dx, dy in [
        (left, top, 1, 1),
        (right, top, -1, 1),
        (left, bottom, 1, -1),
        (right, bottom, -1, -1),
    ]:
        draw.rectangle(sorted_box(x, y, x + dx * arm, y + dy * stroke), fill=PAPER)
        draw.rectangle(sorted_box(x, y, x + dx * stroke, y + dy * arm), fill=PAPER)

    shot_width, shot_height = 186 * SCALE, 248 * SCALE
    shot_left = left + width - shot_width - 92 * SCALE
    shot_top = top + 142 * SCALE
    draw.rectangle((shot_left, shot_top, shot_left + shot_width, shot_top + shot_height), fill=SIGNAL)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    image.resize((1024, 1024), Image.LANCZOS).save(OUTPUT)


def sorted_box(x0, y0, x1, y1):
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


if __name__ == "__main__":
    main()
