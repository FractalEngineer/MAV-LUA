"""Render Lua draw calls with crisp FreedomTX font pixels; grey only in the ball."""
import argparse
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageOps
from native_font import load_font

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--lua", default=str(ROOT / ".build" / "lua.exe"))
parser.add_argument("--font", choices=("std", "sqt5"), default="std")
args = parser.parse_args()
glyphs = load_font(args.font)
widths = "".join(str(glyphs[chr(c)].width) for c in range(32, 127))
output = ROOT / "dist" / "previews"
output.mkdir(parents=True, exist_ok=True)
for width, height in [(128, 96), (128, 64), (212, 64)]:
    for page in ("navigation", "messages"):
        calls = subprocess.check_output([args.lua, "tools/render.lua", page, str(width), str(height), widths], cwd=ROOT, text=True)
        image = Image.new("L", (width, height))
        draw = ImageDraw.Draw(image)
        for call in calls.splitlines():
            fields = call.split("\t")
            if fields[0] == "L":
                flags = int(fields[5])
                shade = 255 - ((flags >> 16) & 15) * 17
                draw.line(tuple(map(int, fields[1:5])), fill=shade)
            elif fields[0] == "T":
                x, y, flags = map(int, fields[1:4])
                text = fields[4]
                for character in text:
                    glyph = glyphs.get(character, glyphs["?"]).convert("L")
                    image.paste(ImageOps.invert(glyph) if flags & 2 else glyph, (x, y))
                    x += glyph.width
        # Preserve the native image for pixel inspection and export a crisp zoom.
        image.save(output / f"{width}x{height}-{page}-native.png")
        image.resize((width * 5, height * 5), Image.Resampling.NEAREST).save(output / f"{width}x{height}-{page}.png")
print(output)
