from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from lua53 import HEADER, validate


class ModernBytecode(unittest.TestCase):
    def test_compiled_app(self):
        data = (ROOT / ".build/MAV-post.lua").read_bytes()
        self.assertGreater(validate(data)["functions"], 1)
        self.assertEqual(data[:len(HEADER)], HEADER)
        for invalid in (data[:-1], data + b"\0", data[:12] + b"\x08" + data[13:]):
            with self.assertRaises(ValueError):
                validate(invalid)

    def test_long_strings_and_numeric_types(self):
        suffix = ".exe" if sys.platform == "win32" else ""
        with tempfile.TemporaryDirectory() as folder:
            source, output = Path(folder) / "long.lua", Path(folder) / "long.luac"
            source.write_text('local s="' + "x" * 500 + '"; assert(#s==500); return 123, 1.25')
            subprocess.run([str(ROOT / f".build/luac53{suffix}"), "-s", "-o", str(output), str(source)], check=True)
            self.assertGreater(validate(output.read_bytes())["numbers"], 0)
            subprocess.run([str(ROOT / f".build/lua53{suffix}"), str(output)], check=True)


if __name__ == "__main__":
    unittest.main()
