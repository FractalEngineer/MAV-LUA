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
from lua53 import validate as validate53


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
                            # Readable source ships with a matching .luac cache. Compiling a
                            # module is what exhausts the radio heap the first time a pilot
                            # builds the parameter index, and a module that fails to compile is
                            # never written a cache, so the failure would repeat every retry.
                            cached = archive.read(str(Path(rel).with_suffix('.luac')).replace('\\', '/'))
                            self.assertTrue(cached.startswith(b'\x1bLua'), 'cache must be bytecode')
                            validate53(cached)
                        else:
                            validate(data)
                            self.assertEqual(data, archive.read(rel[:-4] + '.luac'))
                    # Packaged parameter databases are retired: names come from the connected
                    # vehicle, so shipping a name list would be dead weight and would also
                    # contradict the discovery rule. This asserts they do not creep back.
                    self.assertEqual([n for n in archive.namelist() if n.endswith('.pdb')], [],
                                     'packaged parameter databases must not ship')
                    # The standalone index builder is required, because building the index
                    # from inside the Parameters page does not fit the radio heap.
                    self.assertIn('SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua', archive.namelist())
                    # Card helpers ship unchanged and at the package root, where they sit
                    # beside SCRIPTS on the card so they can be run without a path.
                    for helper in sorted((ROOT / 'src').glob('*.bat')):
                        self.assertEqual(archive.read(helper.name), helper.read_bytes())
                    archive.extractall(extracted)
                if modern:
                    stale = extracted / 'old.lua'
                    stale.write_text("error('stale cache was executed')")
                    for rel in ('SCRIPTS/TELEMETRY/MAV', 'SCRIPTS/MAV/params',
                                'SCRIPTS/MAV/wire', 'SCRIPTS/MAV/pview',
                                'SCRIPTS/MAV/pdb', 'SCRIPTS/MAV/pinput',
                                'SCRIPTS/MAV/index'):
                        subprocess.run([str(ROOT / f'.build/luac53{suffix}'), '-s', '-o',
                                        str(extracted / (rel + '.luac')), str(stale)], check=True)
                subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix()], cwd=ROOT, check=True)
                subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix(), 'literal'], cwd=ROOT, check=True)
                if modern:
                    subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix(), 'error'], cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_tools.lua', extracted.as_posix(), 'moduleerror'], cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_params.lua', extracted.as_posix()], cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_pipeline.lua', extracted.as_posix()], cwd=ROOT, check=True)
                    # The Tools builder and its index path are the newest and least proven
                    # parts of the package, so both are exercised against the extracted ZIP.
                    subprocess.run([str(runner), 'tests/test_index_path.lua', extracted.as_posix()],
                                   cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_tool_screen.lua', extracted.as_posix()],
                                   cwd=ROOT, check=True)
                    # A monochrome radio has no `table` library, so the builder must complete a
                    # real build in a sandbox without it. Host Lua always provides it, which is
                    # why running the module the ordinary way proves nothing about the radio.
                    subprocess.run([str(runner), 'tests/test_index_sandbox.lua', extracted.as_posix()],
                                   cwd=ROOT, check=True)
                    # The builder must never accumulate a run in one string before writing it.
                    # That shape cost about 33 KiB of garbage per run and exhausted the radio
                    # heap at around 700 names; a capped-allocator test cannot see it, because a
                    # tight limit drives the collector and masks the accumulation.
                    subprocess.run([str(runner), 'tests/test_index_writes.lua', extracted.as_posix()],
                                   cwd=ROOT, check=True)
                    subprocess.run([str(runner), 'tests/test_radio_libs.lua', extracted.as_posix()],
                                   cwd=ROOT, check=True)
                else:
                    subprocess.run([str(runner), 'tests/test_package.lua',
                                    str(extracted / 'SCRIPTS/TELEMETRY/MAV.lua')], cwd=ROOT, check=True)


if __name__ == '__main__':
    unittest.main()
