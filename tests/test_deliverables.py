"""Exercise the actual radio ZIPs, including a stale core bytecode cache."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from lua52 import validate


class Deliverables(unittest.TestCase):
    def test_radio_archives(self):
        folders = list((ROOT / 'dist').glob('*/SHA256SUMS.txt'))
        self.assertTrue(folders, 'build packages before testing')
        sums = max(folders, key=lambda p: p.stat().st_mtime)
        folder, version = sums.parent, sums.parent.name
        names = {f'MAV-LUA-{version}_{kind}.zip' for kind in ('source', 'precompiled')}
        self.assertEqual({p.name for p in folder.glob('*.zip')}, names)
        self.assertEqual({line.split()[1] for line in sums.read_text().splitlines()}, names)
        for line in sums.read_text().splitlines():
            digest, name = line.split()
            self.assertEqual(hashlib.sha256((folder / name).read_bytes()).hexdigest(), digest)
        suffix = '.exe' if os.name == 'nt' else ''
        for kind in ('source', 'precompiled'):
            modern = kind == 'source'
            runner = ROOT / f'.build/lua{"53" if modern else ""}{suffix}'
            with tempfile.TemporaryDirectory(dir=ROOT / '.build') as temp:
                extracted = Path(temp)
                with zipfile.ZipFile(folder / f'MAV-LUA-{version}_{kind}.zip') as archive:
                    self.assertFalse(any(n.startswith('bridge/') for n in archive.namelist()))
                    self.assertIn(version.encode(), archive.read('VERSION.txt'))
                    self.assertIn(b'PAGE changes pages', archive.read('VERSION.txt'))
                    for path in (ROOT / 'src').rglob('*.lua'):
                        rel = path.relative_to(ROOT / 'src').as_posix()
                        data = archive.read(rel)
                        if modern:
                            self.assertEqual(data, path.read_bytes())
                            self.assertNotIn(str(Path(rel).with_suffix('.luac')).replace('\\', '/'), archive.namelist())
                        else:
                            validate(data)
                            self.assertEqual(data, archive.read(rel[:-4] + '.luac'))
                    databases = [p.relative_to(ROOT / 'src').as_posix()
                                 for p in (ROOT / 'src/SCRIPTS/MAV/DB').glob('*.pdb')]
                    self.assertTrue(databases)
                    for rel in databases:
                        self.assertEqual(archive.read(rel), (ROOT / 'src' / rel).read_bytes())
                    archive.extractall(extracted)
                if modern:
                    stale = extracted / 'old.lua'
                    stale.write_text("error('stale cache was executed')")
                    for rel in ('SCRIPTS/TELEMETRY/MAV', 'SCRIPTS/MAV/params',
                                'SCRIPTS/MAV/wire', 'SCRIPTS/MAV/pview',
                                'SCRIPTS/MAV/pdb', 'SCRIPTS/MAV/pinput',
                                'SCRIPTS/MAV/DB/a47c'):
                        subprocess.run([str(ROOT / f'.build/luac53{suffix}'), '-s', '-o',
                                        str(extracted / (rel + '.luac')), str(stale)], check=True)
                subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix()], cwd=ROOT, check=True)
                subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix(), 'literal'], cwd=ROOT, check=True)
                if modern:
                    subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix(), 'error'], cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix(), 'moduleerror'], cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_params.lua', extracted.as_posix()], cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_pipeline.lua', extracted.as_posix()], cwd=ROOT, check=True)
                else:
                    subprocess.run([str(runner), 'tests/test_package.lua',
                                    str(extracted / 'SCRIPTS/TELEMETRY/MAV.lua')], cwd=ROOT, check=True)


if __name__ == '__main__':
    unittest.main()
