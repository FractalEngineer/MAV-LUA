"""Render the actual monochrome Lua drawing calls; desktop font is approximate."""
import argparse
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--lua", default=str(ROOT / ".build" / "lua.exe"))
parser.add_argument("--font", default="C:/Windows/Fonts/consola.ttf")
args = parser.parse_args()
font = ImageFont.truetype(args.font, 10)
output = ROOT / "dist" / "previews"
output.mkdir(parents=True, exist_ok=True)
for width, height in [(128, 96), (128, 64), (212, 64)]:
    for page in ("navigation", "messages"):
        calls = subprocess.check_output([args.lua, "tools/render.lua", page, str(width), str(height)], cwd=ROOT, text=True)
        image = Image.new("1", (width, height))
        draw = ImageDraw.Draw(image)
        for call in calls.splitlines():
            fields = call.split("\t")
            if fields[0] == "L":
                draw.line(tuple(map(int, fields[1:])), fill=1)
            elif fields[0] == "T":
                x, y, flags = map(int, fields[1:4])
                text = fields[4]
                if flags:
                    draw.rectangle((x, y, x + len(text) * 6 - 1, y + 7), fill=1)
                draw.text((x, y), text, font=font, fill=0 if flags else 1, anchor="lt")
        image.resize((width * 5, height * 5), Image.Resampling.NEAREST).save(output / f"{width}x{height}-{page}.png")
print(output)
