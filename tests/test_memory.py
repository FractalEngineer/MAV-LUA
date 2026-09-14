"""Cold source loading must fit a capped allocator, including parser temporaries."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MemoryBudget(unittest.TestCase):
    def test_cold_source_load(self):
        runner = ROOT / ('.build/lua-memory.exe' if os.name == 'nt' else '.build/lua-memory')
        compiler = ROOT / ('.build/luac53.exe' if os.name == 'nt' else '.build/luac53')
        if not runner.exists():
            subprocess.run([sys.executable, 'tools/memory_test.py'], cwd=ROOT, check=True)
        self.assertTrue(compiler.exists(), 'run tools/build53.py first')
        with tempfile.TemporaryDirectory() as cache:
            for name in ('params', 'wire', 'pview', 'pdb', 'pinput'):
                subprocess.run([str(compiler), '-s', '-o', str(Path(cache) / (name + '.luac')),
                                str(ROOT / 'src/SCRIPTS/MAV' / (name + '.lua'))], check=True)
            for history, limit in (('', 136 * 1024), ('history', 144 * 1024)):
                env = dict(os.environ, MAV_TEST_HEAP_LIMIT=str(limit))
                result = subprocess.run([str(runner), 'tests/test_memory.lua', 'src', history, cache],
                                        cwd=ROOT, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
