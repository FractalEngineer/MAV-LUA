"""FreedomTX's 5x7 bitmap glyphs, including its 0xff skipped-column convention."""
from pathlib import Path
from PIL import Image


def load_font(name="std"):
    path = Path(__file__).resolve().parent / "fonts" / f"freedomtx-{name}-05x07.png"
    sheet = Image.open(path).convert("1")
    glyphs = {}
    for code in range(32, 127):
        x0, y0 = (code - 32) % 16 * 5, (code - 32) // 16 * 8
        columns = [sum(1 << y for y in range(8) if not sheet.getpixel((x0 + x, y0 + y)))
                   for x in range(5)]
        columns = [column for column in columns if column != 255]
        glyph = Image.new("1", (len(columns) + 1, 8))
        for x, column in enumerate(columns):
            for y in range(8):
                if column & (1 << y):
                    glyph.putpixel((x, y), 255)
        glyphs[chr(code)] = glyph
    return glyphs
