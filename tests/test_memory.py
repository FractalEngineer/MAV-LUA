"""Cold source loading must fit a capped allocator, including parser temporaries."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HeapProbe(unittest.TestCase):
    def test_probe_reports_instead_of_crashing_when_memory_runs_out(self):
        """The heap probe must survive exhaustion and still leave its answer on the card.

        The probe deliberately allocates until it fails, so the outcome that matters is not
        that it succeeds but that the failure is caught, written down and reported. Two
        defects are guarded here, both of which a single generous run hides:

        * A memory error escaping a step reaches the firmware's panic handler, which is what
          locks a radio up. Every allocation is therefore inside pcall.
        * Reporting before releasing. Formatting the result allocates, and at that moment the
          heap is by definition full, so building the text first fails and destroys the very
          measurement the run exists to produce. An earlier version did exactly that and
          wrote "ERROR: not enough memory" instead of the number.

        The capped allocator is used here for a purpose it is NOT valid for elsewhere in this
        repository: checking the probe's own error handling. That is legitimate because the
        assertion is about catching an allocation failure, not about predicting a radio. The
        distinction is the one AGENTS.md draws.
        """
        runner = ROOT / ('.build/lua-memory.exe' if os.name == 'nt' else '.build/lua-memory')
        if not runner.exists():
            subprocess.run([sys.executable, 'tools/memory_test.py'], cwd=ROOT, check=True)
        probe = ROOT / 'tools/diag/MAVHEAP.lua'
        self.assertTrue(probe.exists(), 'the heap probe must exist to be tested')
        # Several caps, because the defect only appears once the fill reaches the ceiling.
        for kib in (300, 260, 240, 220, 200, 180):
            env = dict(os.environ, MAV_TEST_HEAP_LIMIT=str(kib * 1024))
            result = subprocess.run([str(runner), 'tests/test_heap_probe.lua', 'tools/diag'],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0,
                             f'probe crashed at a {kib} KiB cap:\n{result.stdout}{result.stderr}')
            self.assertIn('PASS: heap probe', result.stdout)
            # The decisive number must be present, not merely the fact that it ran.
            self.assertIn('largest single allocation:', result.stdout)


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
