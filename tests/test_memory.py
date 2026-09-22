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
        modules = ('params', 'wire', 'pview', 'pdb', 'pinput')
        with tempfile.TemporaryDirectory() as cache:
            for name in modules:
                subprocess.run([str(compiler), '-s', '-o', str(Path(cache) / (name + '.luac')),
                                str(ROOT / 'src/SCRIPTS/MAV' / (name + '.lua'))], check=True)
            # Opening the Parameters page must stay close to the level the radio already runs.
            # The index builder is loaded on demand, so it does not inflate the cold-open peak:
            # v0.1.3 needed 136 KiB and this build needs about 140, which is the budget below.
            # A regression that loads the builder eagerly, or grows these modules, breaks it.
            for history, limit in (('', 141 * 1024), ('history', 147 * 1024)):
                env = dict(os.environ, MAV_TEST_HEAP_LIMIT=str(limit))
                result = subprocess.run([str(runner), 'tests/test_memory.lua', 'src', history, cache],
                                        cwd=ROOT, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_open_compiles_once_then_uses_cache(self):
        """A package now ships a .luac per module, so an installed open must never compile.

        The first open of a package built without caches does compile each module, and that
        compile is the peak a pilot pays once. Every later open must load bytecode instead:
        recompiling while a cache exists re-pays the whole peak and is what made the radio
        report 'not enough memory' on an open which then worked on retry.
        """
        runner = ROOT / ('.build/lua-memory.exe' if os.name == 'nt' else '.build/lua-memory')
        compiler = ROOT / ('.build/luac53.exe' if os.name == 'nt' else '.build/luac53')
        if not runner.exists():
            subprocess.run([sys.executable, 'tools/memory_test.py'], cwd=ROOT, check=True)
        with tempfile.TemporaryDirectory() as cache:
            for name in ('params', 'wire', 'pview', 'pdb', 'pinput'):
                subprocess.run([str(compiler), '-s', '-o', str(Path(cache) / (name + '.luac')),
                                str(ROOT / 'src/SCRIPTS/MAV' / (name + '.lua'))], check=True)
            for mode, expected in (('nocache', 'First open: compiled'), ('', 'Warm open: loaded entirely from cache')):
                env = dict(os.environ, MAV_TEST_HEAP_LIMIT=str(152 * 1024))
                argv = [str(runner), 'tests/test_memory.lua', 'src', '', cache, '-', mode] if mode else \
                       [str(runner), 'tests/test_memory.lua', 'src', '', cache]
                result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected, result.stdout)

    def test_builder_loads_within_budget(self):
        """Requesting a build loads the index builder, which must also fit a capped allocator."""
        runner = ROOT / ('.build/lua-memory.exe' if os.name == 'nt' else '.build/lua-memory')
        compiler = ROOT / ('.build/luac53.exe' if os.name == 'nt' else '.build/luac53')
        if not runner.exists():
            subprocess.run([sys.executable, 'tools/memory_test.py'], cwd=ROOT, check=True)
        with tempfile.TemporaryDirectory() as cache:
            for name in ('params', 'wire', 'pview', 'pdb', 'pinput', 'index'):
                subprocess.run([str(compiler), '-s', '-o', str(Path(cache) / (name + '.luac')),
                                str(ROOT / 'src/SCRIPTS/MAV' / (name + '.lua'))], check=True)
            env = dict(os.environ, MAV_TEST_HEAP_LIMIT=str(163 * 1024))
            result = subprocess.run([str(runner), 'tests/test_memory.lua', 'src', '', cache, 'builder'],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Builder bytes live/peak:', result.stdout)

            # Prove the shipped cache is what makes a build affordable. With the opening set
            # cached but the builder itself not, the build must COMPILE it, which is far larger
            # than the budget above. That is the failure pilots hit: a compile which exhausts
            # the heap never writes a cache, so the build failed identically on every retry.
            # Asserting the failure keeps the reason for shipping .luac caches honest, and would
            # fail if the builder ever shrank enough to make the cache unnecessary.
            result = subprocess.run([str(runner), 'tests/test_memory.lua', 'src', '', cache,
                                     'builder', 'buildfirst'], cwd=ROOT, env=env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0,
                                'uncached builder compile unexpectedly fits the budget')
            # The harness returns nil when EdgeTX's loader cannot compile, so the assertion is
            # what trips rather than an explicit allocation message.
            self.assertIn('test_memory.lua:103', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
