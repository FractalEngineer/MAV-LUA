"""Compact parameter databases remain seekable, bounded, and deterministic."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("param_db", ROOT / "tools/param_db.py")
PARAM_DB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARAM_DB)


class ParameterDatabase(unittest.TestCase):
    @staticmethod
    def record(data, offset):
        value = data[offset:offset + 22]
        label = value[:16].rstrip(b"\0").decode("ascii")
        target = int.from_bytes(value[16:20], "little")
        raw_count = int.from_bytes(value[20:22], "little")
        return label, target, raw_count & 0x7FFF, bool(raw_count & 0x8000)

    def test_packaged_manifests_and_fixed_records(self):
        folder = ROOT / "src/SCRIPTS/MAV/DB"
        manifests = sorted(folder.glob("*.lua"))
        self.assertEqual(len(manifests), 6)
        self.assertEqual({path.stem for path in manifests},
                         {"a46c", "a46p", "a47c", "a47p", "a48c", "a48p"})
        for manifest in manifests:
            text = manifest.read_text(encoding="ascii")
            match = re.search(r',"/SCRIPTS/MAV/DB/[^\"]+\.pdb",(\d+)\}', text)
            self.assertIsNotNone(match, manifest.name)
            category_count = int(match.group(1))
            self.assertGreater(category_count, 50, manifest.name)
            data = manifest.with_suffix(".pdb").read_bytes()
            records = [self.record(data, index * 22) for index in range(category_count)]
            child_records = []
            for label, offset, count, folder_record in records:
                self.assertRegex(label, r"^[A-Z0-9_]{1,16}$")
                if folder_record:
                    self.assertGreaterEqual(offset, category_count * 22)
                    child_records.extend(self.record(data, offset + index * 22)
                                         for index in range(count))
            direct = [value for value in records + child_records if not value[3]]
            previous_end = (category_count + len(child_records)) * 22
            offsets = []
            for label, offset, count, folder_record in direct:
                self.assertRegex(label, r"^[A-Z0-9_]{1,16}$")
                block = data[offset:offset + count * 16]
                self.assertEqual(len(block), count * 16)
                for index in range(0, len(block), 16):
                    name = block[index:index + 16].rstrip(b"\0")
                    self.assertRegex(name.decode("ascii"), r"^[A-Z0-9_]{1,16}$")
                offsets.append((offset, offset + count * 16, label))
            for offset, end, label in sorted(offsets):
                self.assertEqual(offset, previous_end, (manifest.name, label))
                previous_end = end
            self.assertEqual(previous_end, len(data))
            labels = {value[0]: value for value in records}
            self.assertIn("RC", labels, manifest.name)
            self.assertTrue(labels["RC"][3], manifest.name)
            rc_children = [self.record(data, labels["RC"][1] + index * 22)[0]
                           for index in range(labels["RC"][2])]
            self.assertIn("RC", rc_children)
            self.assertIn("RC1", rc_children)

    def test_generator_filters_and_groups(self):
        document = {"Vehicle": {"SERVO1_FUNCTION": {}, "SERVO1_MIN": {},
                                "SERVO2_FUNCTION": {}, "SERVO2_MIN": {},
                                "SIM_SPEEDUP": {}, "ONEOFF": {}, "FOO_A": {}, "FOO_B": {}}}
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, output = base / "input.json", base / "out"
            source.write_text(json.dumps(document), encoding="utf-8")
            count, groups = PARAM_DB.generate(source, output, "4.7", "Copter", "c")
            self.assertEqual((count, groups), (7, 3))
            manifest = (output / "a47c.lua").read_text(encoding="ascii")
            self.assertIn('"/SCRIPTS/MAV/DB/a47c.pdb",3}', manifest)
            data = (output / "a47c.pdb").read_bytes()
            records = [self.record(data, i * 22) for i in range(3)]
            self.assertEqual([value[0] for value in records], ["GENERAL", "FOO", "SERVO"])
            self.assertTrue(records[2][3])
            children = [self.record(data, records[2][1] + i * 22)[0] for i in range(2)]
            self.assertEqual(children, ["SERVO1", "SERVO2"])
            self.assertNotIn(b"SIM_SPEEDUP", (output / "a47c.pdb").read_bytes())


if __name__ == "__main__":
    unittest.main()
