"""ABI regression: matching headers must not admit stock-Lua constant tags."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from lua52 import HEADER, validate


def chunk(constants, instruction=0x0080001F):
    # Independent Lua 5.2 layout fixture with a dummy RETURN instruction.
    return (HEADER + struct.pack("<iiBBB", 0, 0, 0, 1, 2)
            + struct.pack("<II", 1, instruction)
            + struct.pack("<I", len(constants)) + b"".join(constants)
            + b"\0" * 24)  # no child functions, upvalues or debug data


class BytecodeABI(unittest.TestCase):
    def test_reject_no_argument_tail_call(self):
        with self.assertRaisesRegex(ValueError, "Zero-argument tail call"):
            validate(chunk([], 30 | (1 << 23)))

    def test_firmware_constants(self):
        data = chunk([b"\0", b"\1\1", b"\5" + struct.pack("<d", 16.4),
                      b"\6" + struct.pack("<I", 4) + b"MAV\0"])
        self.assertEqual(validate(data)["numbers"], 1)
        self.assertEqual(validate(data)["strings"], 1)

    def test_reject_stock_numbers_despite_matching_header(self):
        with self.assertRaisesRegex(ValueError, "constant tag 3"):
            validate(chunk([b"\3" + struct.pack("<d", 16.4)]))

    def test_reject_stock_strings_despite_matching_header(self):
        with self.assertRaisesRegex(ValueError, "constant tag 4"):
            validate(chunk([b"\4" + struct.pack("<I", 4) + b"MAV\0"]))

    def test_reject_oversized_string(self):
        with self.assertRaises(ValueError):
            validate(chunk([b"\6" + struct.pack("<I", 0xFFFFFFFF)]))

    def test_reject_truncation_and_trailing_data(self):
        for data in (chunk([])[:-1], chunk([]) + b"\0"):
            with self.assertRaises(ValueError):
                validate(data)

    def test_runner_rejects_stock_tags(self):
        root = Path(__file__).resolve().parents[1]
        runner = root / ".build" / ("lua.exe" if sys.platform == "win32" else "lua")
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "stock-tags.luac"
            path.write_bytes(chunk([b"\3" + struct.pack("<d", 16.4)]))
            result = subprocess.run([str(runner), str(path)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid firmware constant tag", result.stderr)

    def test_compiled_application(self):
        path = Path(__file__).resolve().parents[1] / ".build/MAV.lua"
        stats = validate(path.read_bytes())
        self.assertGreater(stats["functions"], 1)
        self.assertGreater(stats["numbers"], 0)
        self.assertGreater(stats["strings"], 0)


if __name__ == "__main__":
    unittest.main()
