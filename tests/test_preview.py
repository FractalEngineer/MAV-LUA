"""Text stays binary and aligned; intermediate shades belong to the navball."""
from pathlib import Path
import subprocess
import sys
import unittest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_font import load_font


class PixelPreview(unittest.TestCase):
    def test_native_glyph_pixels(self):
        glyphs = load_font()
        self.assertEqual(glyphs["A"].size, (6, 8))
        self.assertEqual(glyphs["i"].size, (4, 8))
        self.assertEqual(glyphs[" "].size, (3, 8))
        for glyph in glyphs.values():
            self.assertTrue(set(glyph.getdata()) <= {0, 255})
            self.assertEqual(glyph.height, 8)

    def test_grey_only_inside_instrument(self):
        runner = ROOT / (".build/lua.exe" if sys.platform == "win32" else ".build/lua")
        subprocess.run([sys.executable, "tools/preview.py", "--lua", str(runner)], cwd=ROOT, check=True, capture_output=True)
        folder = ROOT / "dist/previews"
        nav = Image.open(folder / "128x96-navigation-native.png")
        grey_pixels = [(x, y) for y in range(nav.height) for x in range(nav.width)
                       if nav.getpixel((x, y)) not in (0, 255)]
        self.assertTrue(grey_pixels)
        self.assertTrue(all((x - 32) ** 2 + (y - 52) ** 2 <= 23 ** 2 for x, y in grey_pixels))
        messages = Image.open(folder / "128x96-messages-native.png")
        self.assertTrue(set(messages.getdata()) <= {0, 255})

    def test_parameters_use_only_native_binary_pixels(self):
        runner = ROOT / (".build/lua53.exe" if sys.platform == "win32" else ".build/lua53")
        subprocess.run([sys.executable, "tools/preview.py", "--lua", str(runner), "--parameters"],
                       cwd=ROOT, check=True, capture_output=True)
        for path in (ROOT / 'dist/previews').glob('*-parameters-*-native.png'):
            pixels = Image.open(path)
            self.assertEqual(set(pixels.getdata()), {0, 255}, str(path))


if __name__ == "__main__":
    unittest.main()
