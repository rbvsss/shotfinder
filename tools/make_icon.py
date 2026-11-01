"""Draws the app icon and its dark and tinted versions: a viewfinder with the found shot marked inside."""
from pathlib import Path

from PIL import Image, ImageDraw

OUTPUT = Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets" / "AppIcon.appiconset"
SCALE = 4
SIZE = 1024 * SCALE
INK = (11, 11, 12, 255)
CLEAR = (0, 0, 0, 0)
WHITE = (255, 255, 255, 255)
BLUE = (0, 145, 255, 255)
GREY = (190, 190, 190, 255)


def draw(background, marks, shot):
    image = Image.new("RGBA", (SIZE, SIZE), background)
    canvas = ImageDraw.Draw(image)

    width, height = 600 * SCALE, 760 * SCALE
    left, top = (SIZE - width) // 2, (SIZE - height) // 2
    right, bottom = left + width, top + height
    arm = 200 * SCALE
    stroke = 66 * SCALE

    for x, y, dx, dy in [
        (left, top, 1, 1),
        (right, top, -1, 1),
        (left, bottom, 1, -1),
        (right, bottom, -1, -1),
    ]:
        canvas.rounded_rectangle(sorted_box(x, y, x + dx * arm, y + dy * stroke), radius=stroke // 2, fill=marks)
        canvas.rounded_rectangle(sorted_box(x, y, x + dx * stroke, y + dy * arm), radius=stroke // 2, fill=marks)

    shot_width, shot_height = 216 * SCALE, 288 * SCALE
    shot_left = right - shot_width - 110 * SCALE
    shot_top = top + 150 * SCALE
    canvas.rounded_rectangle(
        (shot_left, shot_top, shot_left + shot_width, shot_top + shot_height),
        radius=36 * SCALE,
        fill=shot,
    )
    return image.resize((1024, 1024), Image.LANCZOS)


def sorted_box(x0, y0, x1, y1):
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    draw(INK, WHITE, BLUE).convert("RGB").save(OUTPUT / "icon.png")
    draw(CLEAR, WHITE, BLUE).save(OUTPUT / "icon-dark.png")
    draw(CLEAR, WHITE, GREY).save(OUTPUT / "icon-tinted.png")


if __name__ == "__main__":
    main()
